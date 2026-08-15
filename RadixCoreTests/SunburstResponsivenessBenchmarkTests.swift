import CoreGraphics
import Foundation
import XCTest
@testable import RadixCore

private typealias ChartBenchmarkSupport = ChartResponsivenessBenchmarkSupport

@MainActor
final class SunburstResponsivenessBenchmarkTests: XCTestCase {
    func testLargeScanSunburstResponsivenessBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["RADIX_BENCH_SUNBURST"] == "1" else {
            throw XCTSkip(
                "Set RADIX_BENCH_SUNBURST=1 to run the large-scan Sunburst benchmark."
            )
        }

        let denseFileCount = 1_000_000
        let branchCount = 120
        let renderedDepth = 10
        let sampleCount = 3
        let hitTestIterationCount = 100_000
        let overlayIterationCount = 20_000
        let keyboardIterationCount = 20_000
        let chartSize = CGSize(width: 1_200, height: 1_200)

        let initialPeakRSS = BenchmarkSupport.peakResidentBytes()
        let fixtureMeasurement = BenchmarkSupport.measure {
            Self.makeDenseFixture(fileCount: denseFileCount)
        }
        let denseFixture = fixtureMeasurement.value
        XCTAssertEqual(denseFixture.store.nodeCount, denseFileCount + 2)
        Self.report(
            phase: "fixture",
            seconds: fixtureMeasurement.seconds,
            count: denseFixture.store.nodeCount,
            peakRSS: BenchmarkSupport.peakResidentBytes(),
            extra: "rss_delta=\(BenchmarkSupport.byteDelta(from: initialPeakRSS, to: BenchmarkSupport.peakResidentBytes()))"
        )

        let denseDiskMapStore = DiskMapTreeStore(denseFixture.store)
        var largeLayoutSamples: [LayoutSample] = []
        largeLayoutSamples.reserveCapacity(sampleCount)
        for _ in 0..<sampleCount {
            let measurement = try BenchmarkSupport.measure {
                try SunburstLayout.segments(
                    in: denseDiskMapStore,
                    rootID: denseFixture.store.rootID,
                    depthLimit: 2,
                    cancellationCheck: {}
                )
            }
            largeLayoutSamples.append(LayoutSample(
                seconds: measurement.seconds,
                segmentCount: measurement.value.count,
                fingerprint: Self.segmentFingerprint(measurement.value)
            ))
        }
        let expectedLargeCount = try XCTUnwrap(largeLayoutSamples.first?.segmentCount)
        let expectedLargeFingerprint = try XCTUnwrap(largeLayoutSamples.first?.fingerprint)
        XCTAssertTrue(largeLayoutSamples.allSatisfy {
            $0.segmentCount == expectedLargeCount
                && $0.fingerprint == expectedLargeFingerprint
        })
        let largeLayoutMedian = try XCTUnwrap(
            BenchmarkSupport.median(largeLayoutSamples.map(\.seconds))
        )
        Self.report(
            phase: "layout_large_scan",
            seconds: largeLayoutMedian,
            count: expectedLargeCount,
            peakRSS: BenchmarkSupport.peakResidentBytes(),
            extra: "samples=\(largeLayoutSamples.map { BenchmarkSupport.format($0.seconds) }.joined(separator: ",")) "
                + "fingerprint=\(expectedLargeFingerprint)"
        )

        let denseLayoutMeasurement = try BenchmarkSupport.measure {
            try SunburstLayout.segments(
                in: denseDiskMapStore,
                rootID: denseFixture.denseDirectoryID,
                depthLimit: 1,
                cancellationCheck: {}
            )
        }
        let denseSegments = denseLayoutMeasurement.value
        XCTAssertEqual(denseSegments.count, 1)
        XCTAssertTrue(try XCTUnwrap(denseSegments.first).isAggregate)
        let denseFingerprint = Self.segmentFingerprint(denseSegments)
        Self.report(
            phase: "layout_dense_root",
            seconds: denseLayoutMeasurement.seconds,
            count: denseFileCount,
            peakRSS: BenchmarkSupport.peakResidentBytes(),
            extra: "segments=\(denseSegments.count) fingerprint=\(denseFingerprint)"
        )

        let interactionFixture = Self.makeInteractionFixture(
            branchCount: branchCount,
            renderedDepth: renderedDepth
        )
        let interactionDiskMapStore = DiskMapTreeStore(interactionFixture.store)
        let interactionLayoutMeasurement = try BenchmarkSupport.measure {
            try SunburstLayout.segments(
                in: interactionDiskMapStore,
                rootID: interactionFixture.store.rootID,
                depthLimit: renderedDepth,
                cancellationCheck: {}
            )
        }
        let interactionSegments = interactionLayoutMeasurement.value
        XCTAssertEqual(interactionSegments.count, branchCount * renderedDepth)
        let interactionFingerprint = Self.segmentFingerprint(interactionSegments)
        Self.report(
            phase: "layout_interaction_geometry",
            seconds: interactionLayoutMeasurement.seconds,
            count: interactionSegments.count,
            peakRSS: BenchmarkSupport.peakResidentBytes(),
            extra: "fingerprint=\(interactionFingerprint)"
        )

        let publicationModel = SunburstChartModel(
            layoutService: PrecomputedSunburstLayoutService(segments: interactionSegments)
        )
        let publicationMeasurement = await ChartBenchmarkSupport.measureAsync {
            await publicationModel.loadLayout(
                treeStore: interactionDiskMapStore,
                rootID: interactionFixture.store.rootID,
                depthLimit: renderedDepth,
                layoutID: "interaction-publication"
            )
        }
        XCTAssertTrue(publicationMeasurement.value)
        XCTAssertEqual(
            Self.segmentFingerprint(publicationModel.renderedSegments),
            interactionFingerprint
        )
        Self.report(
            phase: "render_state_publication",
            seconds: publicationMeasurement.seconds,
            count: interactionSegments.count,
            peakRSS: BenchmarkSupport.peakResidentBytes()
        )

        let hitTestMeasurement = BenchmarkSupport.measure {
            Self.runHitTests(
                model: publicationModel,
                size: chartSize,
                iterationCount: hitTestIterationCount
            )
        }
        XCTAssertGreaterThan(hitTestMeasurement.value.selectionCount, 0)
        Self.report(
            phase: "hit_testing",
            seconds: hitTestMeasurement.seconds,
            count: hitTestIterationCount,
            peakRSS: BenchmarkSupport.peakResidentBytes(),
            extra: "hits=\(hitTestMeasurement.value.selectionCount) "
                + "fingerprint=\(hitTestMeasurement.value.fingerprint)"
        )

        let overlayInputs = Self.makeOverlayInputs(
            rootID: interactionFixture.store.rootID,
            branchCount: min(branchCount, 64),
            renderedDepth: renderedDepth
        )
        let coldOverlayMeasurement = BenchmarkSupport.measure {
            Self.runSelectionOverlays(
                model: publicationModel,
                inputs: overlayInputs,
                iterationCount: overlayIterationCount
            )
        }
        XCTAssertEqual(
            coldOverlayMeasurement.value.selectionCount,
            overlayIterationCount * renderedDepth
        )
        Self.report(
            phase: "selection_overlay_alternating",
            seconds: coldOverlayMeasurement.seconds,
            count: overlayIterationCount,
            peakRSS: BenchmarkSupport.peakResidentBytes(),
            extra: "segments=\(coldOverlayMeasurement.value.selectionCount) "
                + "fingerprint=\(coldOverlayMeasurement.value.fingerprint)"
        )

        let cacheHitOverlayMeasurement = try BenchmarkSupport.measure {
            Self.runSelectionOverlays(
                model: publicationModel,
                inputs: [try XCTUnwrap(overlayInputs.first)],
                iterationCount: overlayIterationCount
            )
        }
        XCTAssertEqual(
            cacheHitOverlayMeasurement.value.selectionCount,
            overlayIterationCount * renderedDepth
        )
        Self.report(
            phase: "selection_overlay_same_selection",
            seconds: cacheHitOverlayMeasurement.seconds,
            count: overlayIterationCount,
            peakRSS: BenchmarkSupport.peakResidentBytes(),
            extra: "segments=\(cacheHitOverlayMeasurement.value.selectionCount) "
                + "fingerprint=\(cacheHitOverlayMeasurement.value.fingerprint)"
        )

        let keyboardMeasurement = BenchmarkSupport.measure {
            Self.runKeyboardSelection(
                model: publicationModel,
                iterationCount: keyboardIterationCount
            )
        }
        XCTAssertEqual(keyboardMeasurement.value.selectionCount, keyboardIterationCount)
        Self.report(
            phase: "keyboard_selection",
            seconds: keyboardMeasurement.seconds,
            count: keyboardIterationCount,
            peakRSS: BenchmarkSupport.peakResidentBytes(),
            extra: "selections=\(keyboardMeasurement.value.selectionCount) "
                + "fingerprint=\(keyboardMeasurement.value.fingerprint)"
        )

        let cancellationMeasurement = try await Self.measureLayoutCancellation(
            store: denseDiskMapStore,
            rootID: denseFixture.denseDirectoryID,
            baselineLayoutSeconds: denseLayoutMeasurement.seconds
        )
        XCTAssertTrue(
            cancellationMeasurement.wasCancelled
                || cancellationMeasurement.completedBeforeCancellation,
            "Large layout returned normally after cancellation was requested."
        )
        Self.report(
            phase: "cancel_layout",
            seconds: cancellationMeasurement.seconds,
            count: denseFileCount,
            peakRSS: BenchmarkSupport.peakResidentBytes(),
            extra: "cancelled=\(cancellationMeasurement.wasCancelled) "
                + "completed_before_cancel=\(cancellationMeasurement.completedBeforeCancellation)"
        )

        let rapidChangeMeasurement = try await Self.measureRapidRootAndDepthChanges(
            fixture: denseFixture,
            diskMapStore: denseDiskMapStore
        )
        XCTAssertEqual(rapidChangeMeasurement.appliedCount, 1)
        XCTAssertEqual(rapidChangeMeasurement.completedCount, 1)
        XCTAssertEqual(
            rapidChangeMeasurement.cancelledCount,
            rapidChangeMeasurement.requestCount - 1
        )
        XCTAssertEqual(rapidChangeMeasurement.renderedLayoutID, "root-depth-final")
        XCTAssertEqual(rapidChangeMeasurement.segmentCount, denseSegments.count)
        XCTAssertEqual(rapidChangeMeasurement.fingerprint, denseFingerprint)
        Self.report(
            phase: "rapid_root_depth_changes",
            seconds: rapidChangeMeasurement.latestRequestSeconds,
            count: rapidChangeMeasurement.requestCount,
            peakRSS: BenchmarkSupport.peakResidentBytes(),
            extra: "total_seconds=\(BenchmarkSupport.format(rapidChangeMeasurement.totalSeconds)) "
                + "applied=\(rapidChangeMeasurement.appliedCount) "
                + "cancelled=\(rapidChangeMeasurement.cancelledCount) "
                + "fingerprint=\(rapidChangeMeasurement.fingerprint)"
        )

        Self.report(
            phase: "suite_peak_rss",
            seconds: 0,
            count: denseFixture.store.nodeCount,
            peakRSS: BenchmarkSupport.peakResidentBytes(),
            extra: "rss_delta=\(BenchmarkSupport.byteDelta(from: initialPeakRSS, to: BenchmarkSupport.peakResidentBytes()))"
        )
    }

    private static func measureRapidRootAndDepthChanges(
        fixture: SunburstDenseBenchmarkFixture,
        diskMapStore: DiskMapTreeStore
    ) async throws -> RequestSequenceMeasurement {
        let requests = [
            SunburstBenchmarkRequest(
                rootID: fixture.store.rootID,
                depthLimit: 2,
                layoutID: "root-depth-1"
            ),
            SunburstBenchmarkRequest(
                rootID: fixture.denseDirectoryID,
                depthLimit: 1,
                layoutID: "root-depth-2"
            ),
            SunburstBenchmarkRequest(
                rootID: fixture.store.rootID,
                depthLimit: 2,
                layoutID: "root-depth-3"
            ),
            SunburstBenchmarkRequest(
                rootID: fixture.denseDirectoryID,
                depthLimit: 1,
                layoutID: "root-depth-final"
            ),
        ]
        let probe = SunburstBenchmarkLayoutProbe()
        let service = InstrumentedSunburstLayoutService(
            probe: probe,
            suspendedRequestCount: requests.count - 1
        )
        let model = SunburstChartModel(layoutService: service)
        var tasks: [Task<Bool, Never>] = []
        tasks.reserveCapacity(requests.count)
        let sequenceStartedAt = ContinuousClock.now
        var latestRequestStartedAt = sequenceStartedAt

        for (index, request) in requests.enumerated() {
            if index == requests.count - 1 {
                latestRequestStartedAt = ContinuousClock.now
            }
            tasks.append(Task { @MainActor in
                await model.loadLayout(
                    treeStore: diskMapStore,
                    rootID: request.rootID,
                    depthLimit: request.depthLimit,
                    layoutID: request.layoutID
                )
            })
            try await waitForStartedRequestCount(index + 1, probe: probe)
        }

        let latestDidApply = await tasks[tasks.count - 1].value
        let latestCompletedAt = ContinuousClock.now
        var results: [Bool] = []
        results.reserveCapacity(tasks.count)
        for task in tasks {
            results.append(await task.value)
        }
        let probeSnapshot = await probe.snapshot()

        XCTAssertTrue(latestDidApply)
        XCTAssertEqual(probeSnapshot.startedCount, requests.count)
        return RequestSequenceMeasurement(
            requestCount: requests.count,
            appliedCount: results.filter { $0 }.count,
            completedCount: probeSnapshot.completedCount,
            cancelledCount: probeSnapshot.cancelledCount,
            latestRequestSeconds: BenchmarkSupport.durationSeconds(
                latestRequestStartedAt.duration(to: latestCompletedAt)
            ),
            totalSeconds: BenchmarkSupport.durationSeconds(sequenceStartedAt.duration(to: latestCompletedAt)),
            renderedLayoutID: model.layoutReadiness.renderedLayoutID,
            segmentCount: model.renderedSegments.count,
            fingerprint: segmentFingerprint(model.renderedSegments)
        )
    }

    private static func waitForStartedRequestCount(
        _ expectedCount: Int,
        probe: SunburstBenchmarkLayoutProbe
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while await probe.startedCount < expectedCount,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .microseconds(100))
        }
        guard await probe.startedCount >= expectedCount else {
            throw SunburstBenchmarkTimeoutError(
                message: "Timed out waiting for Sunburst layout request \(expectedCount) to start."
            )
        }
    }

    private static func measureLayoutCancellation(
        store: DiskMapTreeStore,
        rootID: String,
        baselineLayoutSeconds: Double
    ) async throws -> CancellationMeasurement {
        let task = Task.detached {
            _ = try SunburstLayout.segments(
                in: store,
                rootID: rootID,
                depthLimit: 1,
                cancellationCheck: Task.checkCancellation
            )
            return ContinuousClock.now
        }
        let delaySeconds = min(max(baselineLayoutSeconds * 0.25, 0.002), 0.05)
        try await Task.sleep(for: .seconds(delaySeconds))

        let cancellationRequestedAt = ContinuousClock.now
        task.cancel()
        do {
            let completedAt = try await task.value
            return CancellationMeasurement(
                seconds: BenchmarkSupport.durationSeconds(cancellationRequestedAt.duration(to: .now)),
                wasCancelled: false,
                completedBeforeCancellation: completedAt <= cancellationRequestedAt
            )
        } catch is CancellationError {
            return CancellationMeasurement(
                seconds: BenchmarkSupport.durationSeconds(cancellationRequestedAt.duration(to: .now)),
                wasCancelled: true,
                completedBeforeCancellation: false
            )
        }
    }

    private static func runHitTests(
        model: SunburstChartModel,
        size: CGSize,
        iterationCount: Int
    ) -> InteractionMeasurement {
        var state = UInt64(0x9e3779b97f4a7c15)
        var fingerprint = ChartBenchmarkSupport.fnvOffsetBasis
        var hitCount = 0

        for _ in 0..<iterationCount {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let xUnit = Double(UInt32(truncatingIfNeeded: state)) / Double(UInt32.max)
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let yUnit = Double(UInt32(truncatingIfNeeded: state)) / Double(UInt32.max)
            let point = CGPoint(
                x: CGFloat(xUnit) * size.width,
                y: CGFloat(yUnit) * size.height
            )
            if let segment = model.segment(at: point, in: size) {
                hitCount += 1
                ChartBenchmarkSupport.hash(segment.id, into: &fingerprint)
            } else {
                ChartBenchmarkSupport.hash(UInt64.max, into: &fingerprint)
            }
        }
        return InteractionMeasurement(
            selectionCount: hitCount,
            fingerprint: String(fingerprint, radix: 16)
        )
    }

    private static func runSelectionOverlays(
        model: SunburstChartModel,
        inputs: [OverlayInput],
        iterationCount: Int
    ) -> InteractionMeasurement {
        var fingerprint = ChartBenchmarkSupport.fnvOffsetBasis
        var segmentCount = 0

        for offset in 0..<iterationCount {
            let input = inputs[offset % inputs.count]
            let overlays = model.selectionOverlaySegments(
                selectedNodeID: input.selectedNodeID,
                selectedAncestorIDs: input.ancestorIDs
            )
            segmentCount += overlays.count
            for overlay in overlays {
                ChartBenchmarkSupport.hash(overlay.id, into: &fingerprint)
                switch overlay.role {
                case .ancestor:
                    ChartBenchmarkSupport.hash(0, into: &fingerprint)
                case .selected:
                    ChartBenchmarkSupport.hash(1, into: &fingerprint)
                }
            }
        }
        return InteractionMeasurement(
            selectionCount: segmentCount,
            fingerprint: String(fingerprint, radix: 16)
        )
    }

    private static func runKeyboardSelection(
        model: SunburstChartModel,
        iterationCount: Int
    ) -> InteractionMeasurement {
        let directions: [ChartSpatialSelectionDirection] = [.right, .down, .left, .up]
        var selectedNodeID: String?
        var selectionCount = 0
        var fingerprint = ChartBenchmarkSupport.fnvOffsetBasis

        for offset in 0..<iterationCount {
            let segment = model.keyboardSelection(
                from: selectedNodeID,
                moving: directions[offset % directions.count]
            )
            selectedNodeID = segment?.nodeID
            if let selectedNodeID {
                selectionCount += 1
                ChartBenchmarkSupport.hash(selectedNodeID, into: &fingerprint)
            } else {
                ChartBenchmarkSupport.hash(UInt64.max, into: &fingerprint)
            }
        }
        return InteractionMeasurement(
            selectionCount: selectionCount,
            fingerprint: String(fingerprint, radix: 16)
        )
    }

    private static func makeDenseFixture(
        fileCount: Int
    ) -> SunburstDenseBenchmarkFixture {
        let rootIndex = FileTreeNodeIndex(rawValue: 0)
        let denseIndex = FileTreeNodeIndex(rawValue: 1)
        let rootID = "/sunburst-benchmark"
        let denseDirectoryID = rootID + "/dense"
        var nodes = [
            ChartBenchmarkSupport.node(
                id: rootID,
                name: "sunburst-benchmark",
                isDirectory: true,
                allocatedSize: Int64(fileCount),
                descendantFileCount: fileCount
            ),
            ChartBenchmarkSupport.node(
                id: denseDirectoryID,
                name: "dense",
                isDirectory: true,
                allocatedSize: Int64(fileCount),
                descendantFileCount: fileCount
            ),
        ]
        nodes.reserveCapacity(fileCount + 2)
        var childIndicesByIndex = Array(
            repeating: [FileTreeNodeIndex](),
            count: fileCount + 2
        )
        var denseChildren: [FileTreeNodeIndex] = []
        denseChildren.reserveCapacity(fileCount)
        var parentIndices = Array<FileTreeNodeIndex?>(
            repeating: nil,
            count: fileCount + 2
        )
        parentIndices[Int(denseIndex.rawValue)] = rootIndex

        for fileOffset in 0..<fileCount {
            let fileID = String(format: "%@/item-%07d.dat", denseDirectoryID, fileOffset)
            let fileIndex = FileTreeNodeIndex(rawValue: UInt32(nodes.count))
            nodes.append(ChartBenchmarkSupport.node(
                id: fileID,
                name: String(format: "item-%07d.dat", fileOffset),
                isDirectory: false,
                allocatedSize: 1,
                descendantFileCount: 1
            ))
            denseChildren.append(fileIndex)
            parentIndices[Int(fileIndex.rawValue)] = denseIndex
        }
        childIndicesByIndex[Int(rootIndex.rawValue)] = [denseIndex]
        childIndicesByIndex[Int(denseIndex.rawValue)] = denseChildren

        let store = FileTreeStore(
            verifiedRootIndex: rootIndex,
            nodes: nodes,
            childIndicesByIndex: childIndicesByIndex,
            parentIndices: parentIndices,
            orderedNodeIndices: nodes.indices.map {
                FileTreeNodeIndex(rawValue: UInt32($0))
            },
            aggregateStats: ScanAggregateStats(
                totalAllocatedSize: Int64(fileCount),
                totalLogicalSize: Int64(fileCount),
                fileCount: fileCount,
                directoryCount: 2,
                accessibleItemCount: fileCount + 2,
                inaccessibleItemCount: 0
            )
        )
        return SunburstDenseBenchmarkFixture(
            store: store,
            denseDirectoryID: denseDirectoryID
        )
    }

    private static func makeInteractionFixture(
        branchCount: Int,
        renderedDepth: Int
    ) -> SunburstInteractionBenchmarkFixture {
        let rootID = "/sunburst-interaction"
        let rootIndex = FileTreeNodeIndex(rawValue: 0)
        let nodeCount = 1 + (branchCount * renderedDepth)
        var nodes = [ChartBenchmarkSupport.node(
            id: rootID,
            name: "sunburst-interaction",
            isDirectory: true,
            allocatedSize: Int64(branchCount),
            descendantFileCount: branchCount
        )]
        nodes.reserveCapacity(nodeCount)
        var childIndicesByIndex = Array(
            repeating: [FileTreeNodeIndex](),
            count: nodeCount
        )
        var parentIndices = Array<FileTreeNodeIndex?>(
            repeating: nil,
            count: nodeCount
        )
        childIndicesByIndex[Int(rootIndex.rawValue)].reserveCapacity(branchCount)

        for branchOffset in 0..<branchCount {
            var parentIndex = rootIndex
            for depth in 0..<renderedDepth {
                let id = interactionNodeID(
                    rootID: rootID,
                    branchOffset: branchOffset,
                    depth: depth
                )
                let index = FileTreeNodeIndex(rawValue: UInt32(nodes.count))
                nodes.append(ChartBenchmarkSupport.node(
                    id: id,
                    name: depth == 0
                        ? String(format: "branch-%03d", branchOffset)
                        : String(format: "level-%02d", depth),
                    isDirectory: depth + 1 < renderedDepth,
                    allocatedSize: 1,
                    descendantFileCount: 1
                ))
                parentIndices[Int(index.rawValue)] = parentIndex
                childIndicesByIndex[Int(parentIndex.rawValue)].append(index)
                parentIndex = index
            }
        }

        let store = FileTreeStore(
            verifiedRootIndex: rootIndex,
            nodes: nodes,
            childIndicesByIndex: childIndicesByIndex,
            parentIndices: parentIndices,
            orderedNodeIndices: nodes.indices.map {
                FileTreeNodeIndex(rawValue: UInt32($0))
            },
            aggregateStats: ScanAggregateStats(
                totalAllocatedSize: Int64(branchCount),
                totalLogicalSize: Int64(branchCount),
                fileCount: branchCount,
                directoryCount: 1 + (branchCount * max(renderedDepth - 1, 0)),
                accessibleItemCount: nodeCount,
                inaccessibleItemCount: 0
            )
        )
        return SunburstInteractionBenchmarkFixture(store: store)
    }

    private static func makeOverlayInputs(
        rootID: String,
        branchCount: Int,
        renderedDepth: Int
    ) -> [OverlayInput] {
        (0..<branchCount).map { branchOffset in
            let ancestorIDs = Set((0..<(renderedDepth - 1)).map { depth in
                interactionNodeID(
                    rootID: rootID,
                    branchOffset: branchOffset,
                    depth: depth
                )
            })
            return OverlayInput(
                selectedNodeID: interactionNodeID(
                    rootID: rootID,
                    branchOffset: branchOffset,
                    depth: renderedDepth - 1
                ),
                ancestorIDs: ancestorIDs
            )
        }
    }

    private static func interactionNodeID(
        rootID: String,
        branchOffset: Int,
        depth: Int
    ) -> String {
        let branchID = String(format: "%@/branch-%03d", rootID, branchOffset)
        guard depth > 0 else { return branchID }
        return (1...depth).reduce(branchID) { path, level in
            path + String(format: "/level-%02d", level)
        }
    }

    private static func segmentFingerprint(_ segments: [SunburstSegment]) -> String {
        var hash = ChartBenchmarkSupport.fnvOffsetBasis
        for segment in segments {
            ChartBenchmarkSupport.hash(segment.id, into: &hash)
            ChartBenchmarkSupport.hash(segment.nodeID ?? "<aggregate>", into: &hash)
            ChartBenchmarkSupport.hash(segment.label, into: &hash)
            ChartBenchmarkSupport.hash(segment.startAngle.radians.bitPattern, into: &hash)
            ChartBenchmarkSupport.hash(segment.endAngle.radians.bitPattern, into: &hash)
            ChartBenchmarkSupport.hash(Double(segment.innerRadius).bitPattern, into: &hash)
            ChartBenchmarkSupport.hash(Double(segment.outerRadius).bitPattern, into: &hash)
            ChartBenchmarkSupport.hash(UInt64(bitPattern: Int64(segment.depth)), into: &hash)
            ChartBenchmarkSupport.hash(UInt64(bitPattern: segment.totalSize), into: &hash)
            ChartBenchmarkSupport.hash(UInt64(segment.isAggregate ? 1 : 0), into: &hash)
            ChartBenchmarkSupport.hash(segment.colorToken.branchID, into: &hash)
            ChartBenchmarkSupport.hash(segment.colorToken.localID, into: &hash)
            ChartBenchmarkSupport.hash(UInt64(bitPattern: Int64(segment.colorToken.branchIndex)), into: &hash)
            ChartBenchmarkSupport.hash(UInt64(bitPattern: Int64(segment.colorToken.branchCount)), into: &hash)
            ChartBenchmarkSupport.hash(UInt64(bitPattern: Int64(segment.colorToken.siblingIndex)), into: &hash)
            ChartBenchmarkSupport.hash(UInt64(bitPattern: Int64(segment.colorToken.siblingCount)), into: &hash)
            ChartBenchmarkSupport.hash(UInt64(bitPattern: Int64(segment.colorToken.depth)), into: &hash)
            switch segment.colorToken.role {
            case .normal:
                ChartBenchmarkSupport.hash(0, into: &hash)
            case .aggregate:
                ChartBenchmarkSupport.hash(1, into: &hash)
            case .freeSpace:
                ChartBenchmarkSupport.hash(2, into: &hash)
            }
        }
        return String(hash, radix: 16)
    }

    private static func report(
        phase: String,
        seconds: Double,
        count: Int,
        peakRSS: UInt64,
        extra: String = ""
    ) {
        BenchmarkSupport.report(
            prefix: "RADIX_SUNBURST_BENCH_RESULT",
            phase: phase,
            seconds: seconds,
            count: count,
            peakRSS: peakRSS,
            extra: extra
        )
    }
}

private actor InstrumentedSunburstLayoutService: SunburstLayouting {
    let probe: SunburstBenchmarkLayoutProbe
    let suspendedRequestCount: Int

    init(
        probe: SunburstBenchmarkLayoutProbe,
        suspendedRequestCount: Int
    ) {
        self.probe = probe
        self.suspendedRequestCount = suspendedRequestCount
    }

    func segments(
        in treeStore: DiskMapTreeStore,
        rootID: String,
        depthLimit: Int
    ) async throws -> [SunburstSegment] {
        let requestNumber = await probe.recordStarted()
        do {
            if requestNumber <= suspendedRequestCount {
                try await Task.sleep(for: .seconds(5))
                throw SunburstBenchmarkTimeoutError(
                    message: "Expected Sunburst request \(requestNumber) to be superseded."
                )
            }
            let segments = try SunburstLayout.segments(
                in: treeStore,
                rootID: rootID,
                depthLimit: depthLimit,
                cancellationCheck: Task.checkCancellation
            )
            await probe.recordCompleted()
            return segments
        } catch is CancellationError {
            await probe.recordCancelled()
            throw CancellationError()
        }
    }
}

private actor SunburstBenchmarkLayoutProbe {
    private(set) var startedCount = 0
    private var completedCount = 0
    private var cancelledCount = 0

    func recordStarted() -> Int {
        startedCount += 1
        return startedCount
    }

    func recordCompleted() {
        completedCount += 1
    }

    func recordCancelled() {
        cancelledCount += 1
    }

    func snapshot() -> SunburstBenchmarkLayoutProbeSnapshot {
        SunburstBenchmarkLayoutProbeSnapshot(
            startedCount: startedCount,
            completedCount: completedCount,
            cancelledCount: cancelledCount
        )
    }
}

private struct PrecomputedSunburstLayoutService: SunburstLayouting {
    let segments: [SunburstSegment]

    func segments(
        in treeStore: DiskMapTreeStore,
        rootID: String,
        depthLimit: Int
    ) async throws -> [SunburstSegment] {
        segments
    }
}

private struct SunburstDenseBenchmarkFixture: Sendable {
    let store: FileTreeStore
    let denseDirectoryID: String
}

private struct SunburstInteractionBenchmarkFixture: Sendable {
    let store: FileTreeStore
}

private struct SunburstBenchmarkRequest {
    let rootID: String
    let depthLimit: Int
    let layoutID: String
}

private struct SunburstBenchmarkLayoutProbeSnapshot {
    let startedCount: Int
    let completedCount: Int
    let cancelledCount: Int
}

private struct OverlayInput {
    let selectedNodeID: String
    let ancestorIDs: Set<String>
}

private struct LayoutSample {
    let seconds: Double
    let segmentCount: Int
    let fingerprint: String
}

private struct InteractionMeasurement {
    let selectionCount: Int
    let fingerprint: String
}

private struct CancellationMeasurement {
    let seconds: Double
    let wasCancelled: Bool
    let completedBeforeCancellation: Bool
}

private struct RequestSequenceMeasurement {
    let requestCount: Int
    let appliedCount: Int
    let completedCount: Int
    let cancelledCount: Int
    let latestRequestSeconds: Double
    let totalSeconds: Double
    let renderedLayoutID: String?
    let segmentCount: Int
    let fingerprint: String
}

private struct SunburstBenchmarkTimeoutError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}
