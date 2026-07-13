import XCTest
@testable import RadixCore

final class ScanBenchmarkTests: XCTestCase {
    func testRealWorldScanBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RADIX_BENCH"] == "1" else {
            throw XCTSkip("Set RADIX_BENCH=1 to run the real-world scan benchmark.")
        }

        let benchmarkPath = environment["RADIX_BENCH_PATH"] ?? "/Applications"
        let targetURL = URL(filePath: benchmarkPath, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: targetURL.path) else {
            throw XCTSkip("Benchmark path does not exist: \(targetURL.path)")
        }

        let engine = ScanEngine()
        var options = ScanOptions()
        options.includeHiddenFiles = environment["RADIX_BENCH_INCLUDE_HIDDEN"] == "1"
        if environment["RADIX_BENCH_COMMON_EXCLUSIONS"] == "1" {
            options.exclusionPatterns = ScanExclusionMatcher.commonPresetPatterns
        }
        let startedAt = ContinuousClock.now
        var progressEvents = 0
        var warningEvents = 0
        var finalSnapshot: ScanSnapshot?

        for try await event in engine.scan(target: ScanTarget(url: targetURL), options: options) {
            switch event {
            case .progress:
                progressEvents += 1
            case .warning:
                warningEvents += 1
            case .finished(let snapshot):
                finalSnapshot = snapshot
            }
        }

        let elapsed = startedAt.duration(to: .now)
        let snapshot = try XCTUnwrap(finalSnapshot)
        let elapsedSeconds = Double(elapsed.components.seconds) + (Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000)

        print(
            """
            RADIX_BENCH_RESULT path=\(targetURL.path)
            elapsed=\(String(format: "%.3f", elapsedSeconds))s
            include_hidden=\(options.includeHiddenFiles)
            exclusions=\(options.exclusionPatterns.count)
            files=\(snapshot.aggregateStats.fileCount)
            folders=\(snapshot.aggregateStats.directoryCount)
            warnings=\(snapshot.scanWarnings.count)
            progress_events=\(progressEvents)
            discovered=\(snapshot.aggregateStats.totalAllocatedSize)
            """
        )
    }

    /// Release gate for the startup-volume namespace. It compares the optimized
    /// bulk/descriptor scanner with the independent Foundation enumeration path
    /// and verifies that macOS firmlink roots were actually traversed.
    func testStartupVolumeScannerParityGate() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RADIX_STARTUP_SCAN_REGRESSION"] == "1" else {
            throw XCTSkip(
                "Set RADIX_STARTUP_SCAN_REGRESSION=1 to compare startup-volume scanner paths."
            )
        }

        let rootURL = URL(filePath: "/", directoryHint: .isDirectory)
        let target = ScanTarget(url: rootURL, kind: .volume)
        var options = ScanOptions()
        // macOS marks several startup-volume namespace roots (including
        // /private) hidden even though they are essential to whole-disk parity.
        options.includeHiddenFiles = true
        // Keep the release gate bounded and machine-independent by excluding
        // user homes and volatile per-user system caches. Both scanner paths
        // receive identical rules; firmlink opening and aggregate parity across
        // the startup-volume namespace remain covered.
        options.exclusionPatterns = ScanExclusionMatcher.commonPresetPatterns + [
            "Users/*/",
            "private/var/",
        ]
        let optimizedSnapshot = try await finishedSnapshot(
            target: target,
            options: options,
            engine: ScanEngine()
        )
        let foundationSnapshot = try await finishedSnapshot(
            target: target,
            options: options,
            engine: ScanEngine(directoryContents: { url, keys, enumerationOptions, cancellationCheck in
                try cancellationCheck()
                let contents = try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: keys,
                    options: enumerationOptions
                )
                try cancellationCheck()
                return contents
            })
        )

        let firmlinkRoots = [
            "/Applications",
            "/Library",
            "/Users",
            "/private",
        ]

        let optimizedRootChildIDs = optimizedSnapshot.treeStore.childIDs(of: optimizedSnapshot.root.id)
        let foundationRootChildIDs = foundationSnapshot.treeStore.childIDs(of: foundationSnapshot.root.id)

        for path in firmlinkRoots where FileManager.default.fileExists(atPath: path) {
            let optimizedNode = try XCTUnwrap(
                optimizedSnapshot.treeStore.node(id: path),
                "Optimized startup scan omitted firmlink root \(path). Root children: \(optimizedRootChildIDs)"
            )
            let foundationNode = try XCTUnwrap(
                foundationSnapshot.treeStore.node(id: path),
                "Foundation startup scan omitted firmlink root \(path). Root children: \(foundationRootChildIDs)"
            )
            XCTAssertTrue(optimizedNode.isSelfAccessible, "Optimized startup scan could not open \(path)")
            XCTAssertTrue(foundationNode.isSelfAccessible, "Foundation startup scan could not open \(path)")
            if path != "/Users" {
                XCTAssertGreaterThan(optimizedNode.allocatedSize, 0, "Optimized startup scan found no data at \(path)")
                XCTAssertGreaterThan(foundationNode.allocatedSize, 0, "Foundation startup scan found no data at \(path)")
            }
        }

        let optimizedStaleWarnings = optimizedSnapshot.scanWarnings.filter {
            $0.message.localizedCaseInsensitiveContains("stale")
        }
        let foundationStaleWarnings = foundationSnapshot.scanWarnings.filter {
            $0.message.localizedCaseInsensitiveContains("stale")
        }
        XCTAssertTrue(optimizedStaleWarnings.isEmpty, "Optimized scan reported stale handles: \(optimizedStaleWarnings)")
        XCTAssertTrue(foundationStaleWarnings.isEmpty, "Foundation scan reported stale handles: \(foundationStaleWarnings)")

        assertWithinRelativeTolerance(
            optimizedSnapshot.aggregateStats.totalAllocatedSize,
            foundationSnapshot.aggregateStats.totalAllocatedSize,
            // Live allocated-byte metadata is the noisiest signal: APFS clones,
            // sparse files, and directories that become inaccessible between
            // the sequential scans can shift it without changing traversal.
            // The v1.5 regression was orders of magnitude larger.
            tolerance: 0.15,
            label: "allocated bytes"
        )
        assertWithinRelativeTolerance(
            Int64(optimizedSnapshot.aggregateStats.fileCount),
            Int64(foundationSnapshot.aggregateStats.fileCount),
            tolerance: 0.05,
            label: "file count"
        )
        assertWithinRelativeTolerance(
            Int64(optimizedSnapshot.aggregateStats.directoryCount),
            Int64(foundationSnapshot.aggregateStats.directoryCount),
            tolerance: 0.05,
            label: "directory count"
        )

        print(
            """
            RADIX_STARTUP_SCAN_REGRESSION_RESULT
            optimized_bytes=\(optimizedSnapshot.aggregateStats.totalAllocatedSize)
            foundation_bytes=\(foundationSnapshot.aggregateStats.totalAllocatedSize)
            optimized_files=\(optimizedSnapshot.aggregateStats.fileCount)
            foundation_files=\(foundationSnapshot.aggregateStats.fileCount)
            optimized_folders=\(optimizedSnapshot.aggregateStats.directoryCount)
            foundation_folders=\(foundationSnapshot.aggregateStats.directoryCount)
            optimized_warnings=\(optimizedSnapshot.scanWarnings.count)
            foundation_warnings=\(foundationSnapshot.scanWarnings.count)
            """
        )
    }

    func testWideDirectoryClassificationBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RADIX_BENCH_WIDE_DIRECTORY"] == "1" else {
            throw XCTSkip("Set RADIX_BENCH_WIDE_DIRECTORY=1 to run the wide-directory benchmark.")
        }

        let fileCounts = Self.integerList(
            from: environment["RADIX_BENCH_WIDE_FILE_COUNTS"],
            defaultValues: [128, 1_000, 10_000]
        )
        let iterations = environment["RADIX_BENCH_WIDE_ITERATIONS"]
            .flatMap(Int.init)
            .map { max(1, $0) } ?? 3
        let traversalWorkers = environment["RADIX_BENCH_WIDE_TRAVERSAL_WORKERS"]
            .flatMap(Int.init)
            .map { max(1, $0) } ?? 4
        let classificationWorkers = environment["RADIX_BENCH_WIDE_CLASSIFICATION_WORKERS"]
            .flatMap(Int.init)
            .map { max(1, $0) } ?? 4

        let configurations = [
            WideDirectoryBenchmarkConfiguration(
                name: "default-policy",
                traversalWorkerLimit: nil,
                classificationWorkerLimit: nil
            ),
            WideDirectoryBenchmarkConfiguration(
                name: "serial",
                traversalWorkerLimit: 1,
                classificationWorkerLimit: 1
            ),
            WideDirectoryBenchmarkConfiguration(
                name: "parallel-classification",
                traversalWorkerLimit: 1,
                classificationWorkerLimit: classificationWorkers
            ),
            WideDirectoryBenchmarkConfiguration(
                name: "traversal-requested-classification",
                traversalWorkerLimit: traversalWorkers,
                classificationWorkerLimit: classificationWorkers
            )
        ]

        for fileCount in fileCounts {
            let rootURL = try makeWideBenchmarkDirectory(fileCount: fileCount)
            defer { try? FileManager.default.removeItem(at: rootURL) }

            for configuration in configurations {
                _ = try await runWideDirectoryBenchmark(
                    rootURL: rootURL,
                    fileCount: fileCount,
                    configuration: configuration,
                    iteration: 0,
                    isWarmup: true
                )
            }

            var elapsedByConfiguration: [String: [Double]] = [:]
            for iteration in 1...iterations {
                for configuration in configurations {
                    let elapsedSeconds = try await runWideDirectoryBenchmark(
                        rootURL: rootURL,
                        fileCount: fileCount,
                        configuration: configuration,
                        iteration: iteration,
                        isWarmup: false
                    )
                    elapsedByConfiguration[configuration.name, default: []].append(elapsedSeconds)
                }
            }

            for configuration in configurations {
                let elapsed = elapsedByConfiguration[configuration.name, default: []]
                guard !elapsed.isEmpty else { continue }
                let average = elapsed.reduce(0, +) / Double(elapsed.count)
                print(
                    """
                    RADIX_BENCH_WIDE_SUMMARY files=\(fileCount)
                    config=\(configuration.name)
                    traversal_workers=\(configuration.traversalWorkerDescription)
                    requested_classification_workers=\(configuration.classificationWorkerDescription)
                    iterations=\(elapsed.count)
                    avg_elapsed=\(String(format: "%.3f", average))s
                    min_elapsed=\(String(format: "%.3f", elapsed.min() ?? average))s
                    max_elapsed=\(String(format: "%.3f", elapsed.max() ?? average))s
                    """
                )
            }
        }
    }

    func testFanoutWideDirectoryClassificationBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RADIX_BENCH_WIDE_FANOUT"] == "1" else {
            throw XCTSkip("Set RADIX_BENCH_WIDE_FANOUT=1 to run the fanout wide-directory benchmark.")
        }

        let childDirectoryCounts = Self.integerList(
            from: environment["RADIX_BENCH_WIDE_FANOUT_DIR_COUNTS"],
            defaultValues: [8]
        )
        let filesPerDirectoryCounts = Self.integerList(
            from: environment["RADIX_BENCH_WIDE_FANOUT_FILES_PER_DIR"],
            defaultValues: [1_000]
        )
        let iterations = environment["RADIX_BENCH_WIDE_ITERATIONS"]
            .flatMap(Int.init)
            .map { max(1, $0) } ?? 3
        let traversalWorkers = environment["RADIX_BENCH_WIDE_TRAVERSAL_WORKERS"]
            .flatMap(Int.init)
            .map { max(1, $0) } ?? 4
        let classificationWorkers = environment["RADIX_BENCH_WIDE_CLASSIFICATION_WORKERS"]
            .flatMap(Int.init)
            .map { max(1, $0) } ?? 4

        let configurations = [
            WideDirectoryBenchmarkConfiguration(
                name: "default-policy",
                traversalWorkerLimit: nil,
                classificationWorkerLimit: nil
            ),
            WideDirectoryBenchmarkConfiguration(
                name: "serial",
                traversalWorkerLimit: 1,
                classificationWorkerLimit: 1
            ),
            WideDirectoryBenchmarkConfiguration(
                name: "traversal-only",
                traversalWorkerLimit: traversalWorkers,
                classificationWorkerLimit: 1
            ),
            WideDirectoryBenchmarkConfiguration(
                name: "parallel-classification",
                traversalWorkerLimit: 1,
                classificationWorkerLimit: classificationWorkers
            ),
            WideDirectoryBenchmarkConfiguration(
                name: "traversal-requested-classification",
                traversalWorkerLimit: traversalWorkers,
                classificationWorkerLimit: classificationWorkers
            )
        ]

        for childDirectoryCount in childDirectoryCounts {
            for filesPerDirectory in filesPerDirectoryCounts {
                let rootURL = try makeFanoutWideBenchmarkDirectory(
                    childDirectoryCount: childDirectoryCount,
                    filesPerDirectory: filesPerDirectory
                )
                defer { try? FileManager.default.removeItem(at: rootURL) }
                let fileCount = childDirectoryCount * filesPerDirectory

                for configuration in configurations {
                    _ = try await runWideDirectoryBenchmark(
                        rootURL: rootURL,
                        fileCount: fileCount,
                        configuration: configuration,
                        iteration: 0,
                        isWarmup: true
                    )
                }

                var elapsedByConfiguration: [String: [Double]] = [:]
                for iteration in 1...iterations {
                    for configuration in configurations {
                        let elapsedSeconds = try await runWideDirectoryBenchmark(
                            rootURL: rootURL,
                            fileCount: fileCount,
                            configuration: configuration,
                            iteration: iteration,
                            isWarmup: false
                        )
                        elapsedByConfiguration[configuration.name, default: []].append(elapsedSeconds)
                    }
                }

                for configuration in configurations {
                    let elapsed = elapsedByConfiguration[configuration.name, default: []]
                    guard !elapsed.isEmpty else { continue }
                    let average = elapsed.reduce(0, +) / Double(elapsed.count)
                    print(
                        """
                        RADIX_BENCH_WIDE_FANOUT_SUMMARY child_dirs=\(childDirectoryCount)
                        files_per_dir=\(filesPerDirectory)
                        files=\(fileCount)
                        config=\(configuration.name)
                        traversal_workers=\(configuration.traversalWorkerDescription)
                        requested_classification_workers=\(configuration.classificationWorkerDescription)
                        iterations=\(elapsed.count)
                        avg_elapsed=\(String(format: "%.3f", average))s
                        min_elapsed=\(String(format: "%.3f", elapsed.min() ?? average))s
                        max_elapsed=\(String(format: "%.3f", elapsed.max() ?? average))s
                        """
                    )
                }
            }
        }
    }

    func testAtomicProbeResumeBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RADIX_BENCH_ATOMIC_PROBE"] == "1" else {
            throw XCTSkip("Set RADIX_BENCH_ATOMIC_PROBE=1 to run the atomic-probe benchmark.")
        }

        let directoryCount = environment["RADIX_BENCH_ATOMIC_PROBE_DIRS"]
            .flatMap(Int.init)
            .map { max(1, $0) } ?? 32
        let filesPerDirectory = environment["RADIX_BENCH_ATOMIC_PROBE_FILES_PER_DIR"]
            .flatMap(Int.init)
            .map { max(1, $0) } ?? 200
        let minFileCount = environment["RADIX_BENCH_ATOMIC_PROBE_THRESHOLD"]
            .flatMap(Int.init)
            .map { max(1, $0) } ?? 5_000
        let iterations = environment["RADIX_BENCH_ATOMIC_PROBE_ITERATIONS"]
            .flatMap(Int.init)
            .map { max(1, $0) } ?? 3
        let workerLimit = environment["RADIX_BENCH_ATOMIC_PROBE_WORKERS"]
            .flatMap(Int.init)
            .map { max(1, $0) } ?? 8
        let fileCount = directoryCount * filesPerDirectory
        guard fileCount >= minFileCount else {
            throw XCTSkip("Atomic-probe fixture must contain at least the threshold file count.")
        }

        let rootURL = try makeAtomicProbeBenchmarkDirectory(
            directoryCount: directoryCount,
            filesPerDirectory: filesPerDirectory
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let metadataLoader = ScanMetadataLoader()
        let rootMetadata = try metadataLoader.metadata(for: rootURL)
        let rootEntries = try XCTUnwrap(BulkDirectoryEnumerator.directoryEntries(
            at: rootURL,
            includeHiddenFiles: true,
            metadataLoader: metadataLoader,
            cancellationCheck: {}
        )).entries

        for resumesProbe in [false, true] {
            _ = try await runAtomicProbeBenchmark(
                rootURL: rootURL,
                rootEntries: rootEntries,
                rootMetadata: rootMetadata,
                expectedFileCount: fileCount,
                minFileCount: minFileCount,
                workerLimit: workerLimit,
                resumesProbe: resumesProbe
            )
        }

        var elapsedByMode: [Bool: [Double]] = [:]
        for iteration in 1...iterations {
            for resumesProbe in [false, true] {
                let elapsed = try await runAtomicProbeBenchmark(
                    rootURL: rootURL,
                    rootEntries: rootEntries,
                    rootMetadata: rootMetadata,
                    expectedFileCount: fileCount,
                    minFileCount: minFileCount,
                    workerLimit: workerLimit,
                    resumesProbe: resumesProbe
                )
                elapsedByMode[resumesProbe, default: []].append(elapsed)
                print(
                    "RADIX_BENCH_ATOMIC_PROBE_RESULT mode=\(resumesProbe ? "resume" : "restart") iteration=\(iteration) elapsed=\(String(format: "%.3f", elapsed))s"
                )
            }
        }

        for resumesProbe in [false, true] {
            let elapsed = elapsedByMode[resumesProbe, default: []]
            let average = elapsed.reduce(0, +) / Double(elapsed.count)
            print(
                "RADIX_BENCH_ATOMIC_PROBE_SUMMARY mode=\(resumesProbe ? "resume" : "restart") files=\(fileCount) threshold=\(minFileCount) workers=\(workerLimit) iterations=\(elapsed.count) avg_elapsed=\(String(format: "%.3f", average))s"
            )
        }
    }

    func testPackageClassifierBenchmark() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RADIX_BENCH_PACKAGE_CLASSIFIER"] == "1" else {
            throw XCTSkip("Set RADIX_BENCH_PACKAGE_CLASSIFIER=1 to run the package-classifier benchmark.")
        }

        let directoryCount = environment["RADIX_BENCH_PACKAGE_CLASSIFIER_DIRS"]
            .flatMap(Int.init)
            .map { max(1, $0) } ?? 10_000
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "radix-package-classifier-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        var directoryURLs: [URL] = []
        directoryURLs.reserveCapacity(directoryCount)
        for index in 0..<directoryCount {
            let name: String
            if index.isMultiple(of: 1_000) {
                name = "Candidate-\(index).app"
            } else if index.isMultiple(of: 997) {
                name = "Ambiguous-\(index).radixunknown"
            } else if index.isMultiple(of: 2) {
                name = "Ordinary-\(index).txt"
            } else {
                name = "Extensionless-\(index)"
            }
            let url = rootURL.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            directoryURLs.append(url)
        }

        let legacyStart = ContinuousClock.now
        let legacyValues = directoryURLs.map { url in
            (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
        }
        let legacyElapsed = Self.elapsedSeconds(since: legacyStart)

        let counter = PackageClassifierBenchmarkCounter()
        let classifier = PackageClassifier(foundationPackageProvider: { url in
            counter.recordLookup()
            return try? url.resourceValues(forKeys: [.isPackageKey]).isPackage
        })
        let coldStart = ContinuousClock.now
        let coldValues = directoryURLs.map {
            classifier.classification(for: $0, hasFinderPackageFlag: false).isPackage
        }
        let coldElapsed = Self.elapsedSeconds(since: coldStart)
        let coldLookups = counter.lookupCount

        let warmStart = ContinuousClock.now
        let warmValues = directoryURLs.map {
            classifier.classification(for: $0, hasFinderPackageFlag: false).isPackage
        }
        let warmElapsed = Self.elapsedSeconds(since: warmStart)
        let warmLookups = counter.lookupCount - coldLookups

        XCTAssertEqual(coldValues, legacyValues)
        XCTAssertEqual(warmValues, legacyValues)
        let extensionlessCount = directoryURLs.count { $0.pathExtension.isEmpty }
        let foundationExtensionCount = Set(
            directoryURLs.lazy.map(\.pathExtension).filter { !$0.isEmpty && $0 != "txt" }
        ).count
        XCTAssertEqual(coldLookups, extensionlessCount + foundationExtensionCount)
        XCTAssertEqual(warmLookups, extensionlessCount)
        XCTAssertLessThan(coldLookups, directoryCount)
        let reduction = 100 * (1 - Double(coldLookups) / Double(directoryCount))
        print(
            "RADIX_BENCH_PACKAGE_CLASSIFIER dirs=\(directoryCount) legacy_elapsed=\(String(format: "%.3f", legacyElapsed))s cold_elapsed=\(String(format: "%.3f", coldElapsed))s warm_elapsed=\(String(format: "%.3f", warmElapsed))s cold_foundation_lookups=\(coldLookups) warm_foundation_lookups=\(warmLookups) lookup_reduction=\(String(format: "%.1f", reduction))%"
        )
    }

    func testPackageSummaryBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RADIX_BENCH_PACKAGE_SUMMARY"] == "1" else {
            throw XCTSkip("Set RADIX_BENCH_PACKAGE_SUMMARY=1 to run the package summary benchmark.")
        }

        let directoryCounts = Self.integerList(
            from: environment["RADIX_BENCH_PACKAGE_DIR_COUNTS"],
            defaultValues: [16]
        )
        let filesPerDirectoryCounts = Self.integerList(
            from: environment["RADIX_BENCH_PACKAGE_FILES_PER_DIR"],
            defaultValues: [2_500]
        )
        let symlinksPerDirectoryCounts = Self.integerList(
            from: environment["RADIX_BENCH_PACKAGE_SYMLINKS_PER_DIR"],
            defaultValues: [0]
        )
        let iterations = environment["RADIX_BENCH_PACKAGE_ITERATIONS"]
            .flatMap(Int.init)
            .map { max(1, $0) } ?? 3
        let summaryWorkers = environment["RADIX_BENCH_PACKAGE_SUMMARY_WORKERS"]
            .flatMap(Int.init)
            .map { max(1, $0) } ?? 8

        let configurations = [
            PackageSummaryBenchmarkConfiguration(name: "default-policy", atomicSummaryWorkerLimit: nil),
            PackageSummaryBenchmarkConfiguration(name: "serial-summary", atomicSummaryWorkerLimit: 1),
            PackageSummaryBenchmarkConfiguration(name: "parallel-summary", atomicSummaryWorkerLimit: summaryWorkers)
        ]

        for directoryCount in directoryCounts {
            for filesPerDirectory in filesPerDirectoryCounts {
                for symlinksPerDirectory in symlinksPerDirectoryCounts {
                    let rootURL = try makePackageSummaryBenchmarkDirectory(
                        directoryCount: directoryCount,
                        filesPerDirectory: filesPerDirectory,
                        symlinksPerDirectory: symlinksPerDirectory
                    )
                    defer { try? FileManager.default.removeItem(at: rootURL) }
                    let fileCount = directoryCount * filesPerDirectory + (symlinksPerDirectory > 0 ? directoryCount : 0)
                    let symlinkCount = directoryCount * symlinksPerDirectory

                    for configuration in configurations {
                        _ = try await runPackageSummaryBenchmark(
                            rootURL: rootURL,
                            fileCount: fileCount,
                            symlinkCount: symlinkCount,
                            packageCount: 1,
                            configuration: configuration,
                            iteration: 0,
                            isWarmup: true
                        )
                    }

                    var elapsedByConfiguration: [String: [Double]] = [:]
                    for iteration in 1...iterations {
                        for configuration in configurations {
                            let elapsedSeconds = try await runPackageSummaryBenchmark(
                                rootURL: rootURL,
                                fileCount: fileCount,
                                symlinkCount: symlinkCount,
                                packageCount: 1,
                                configuration: configuration,
                                iteration: iteration,
                                isWarmup: false
                            )
                            elapsedByConfiguration[configuration.name, default: []].append(elapsedSeconds)
                        }
                    }

                    for configuration in configurations {
                        let elapsed = elapsedByConfiguration[configuration.name, default: []]
                        guard !elapsed.isEmpty else { continue }
                        let average = elapsed.reduce(0, +) / Double(elapsed.count)
                        print(
                            """
                            RADIX_BENCH_PACKAGE_SUMMARY dirs=\(directoryCount)
                            files_per_dir=\(filesPerDirectory)
                            symlinks_per_dir=\(symlinksPerDirectory)
                            files=\(fileCount)
                            symlinks=\(symlinkCount)
                            config=\(configuration.name)
                            summary_workers=\(configuration.workerDescription)
                            iterations=\(elapsed.count)
                            avg_elapsed=\(String(format: "%.3f", average))s
                            min_elapsed=\(String(format: "%.3f", elapsed.min() ?? average))s
                            max_elapsed=\(String(format: "%.3f", elapsed.max() ?? average))s
                            """
                        )
                    }
                }
            }
        }

        let siblingPackageCount = environment["RADIX_BENCH_PACKAGE_SIBLING_COUNT"]
            .flatMap(Int.init)
            .map { max(2, $0) } ?? 32
        let siblingFilesPerPackage = environment["RADIX_BENCH_PACKAGE_SIBLING_FILES"]
            .flatMap(Int.init)
            .map { max(1, $0) } ?? 64
        let siblingRootURL = try makeSiblingPackageSummaryBenchmarkDirectory(
            packageCount: siblingPackageCount,
            filesPerPackage: siblingFilesPerPackage
        )
        defer { try? FileManager.default.removeItem(at: siblingRootURL) }
        let siblingFileCount = siblingPackageCount * siblingFilesPerPackage
        for configuration in configurations {
            _ = try await runPackageSummaryBenchmark(
                rootURL: siblingRootURL,
                fileCount: siblingFileCount,
                symlinkCount: 0,
                packageCount: siblingPackageCount,
                configuration: configuration,
                iteration: 0,
                isWarmup: true
            )
            for iteration in 1...iterations {
                _ = try await runPackageSummaryBenchmark(
                    rootURL: siblingRootURL,
                    fileCount: siblingFileCount,
                    symlinkCount: 0,
                    packageCount: siblingPackageCount,
                    configuration: configuration,
                    iteration: iteration,
                    isWarmup: false
                )
            }
        }
    }

    private struct WideDirectoryBenchmarkConfiguration {
        let name: String
        let traversalWorkerLimit: Int?
        let classificationWorkerLimit: Int?

        var traversalWorkerDescription: String {
            traversalWorkerLimit.map(String.init) ?? "default"
        }

        var classificationWorkerDescription: String {
            classificationWorkerLimit.map(String.init) ?? "default"
        }
    }

    private struct PackageSummaryBenchmarkConfiguration {
        let name: String
        let atomicSummaryWorkerLimit: Int?

        var workerDescription: String {
            atomicSummaryWorkerLimit.map(String.init) ?? "default"
        }
    }

    private static func integerList(from value: String?, defaultValues: [Int]) -> [Int] {
        guard let value else { return defaultValues }
        let parsed = value
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { $0 > 0 }
        return parsed.isEmpty ? defaultValues : parsed
    }

    private static func elapsedSeconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now)
        return Double(elapsed.components.seconds) +
            Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
    }

    private func makeAtomicProbeBenchmarkDirectory(
        directoryCount: Int,
        filesPerDirectory: Int
    ) throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "radix-atomic-probe-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let payload = Data(repeating: 0x41, count: 32)
        for directoryIndex in 0..<directoryCount {
            let directoryURL = rootURL.appending(
                path: String(format: "shard-%04d", directoryIndex),
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            for fileIndex in 0..<filesPerDirectory {
                try payload.write(
                    to: directoryURL.appending(path: String(format: "payload-%06d.dat", fileIndex))
                )
            }
        }
        return rootURL
    }

    private func runAtomicProbeBenchmark(
        rootURL: URL,
        rootEntries: [DirectoryEntry],
        rootMetadata: NodeMetadata,
        expectedFileCount: Int,
        minFileCount: Int,
        workerLimit: Int,
        resumesProbe: Bool
    ) async throws -> Double {
        let metadataLoader = ScanMetadataLoader()
        let summarizer = AtomicDirectorySummarizer(metadataLoader: metadataLoader)
        let exclusionMatcher = ScanExclusionMatcher(
            patterns: [],
            rootURL: rootURL,
            includeCloudStorage: true
        )
        var progressContinuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation!
        let progressStream = AsyncThrowingStream<ScanProgressEvent, Error> { continuation in
            progressContinuation = continuation
        }
        defer { progressContinuation.finish() }
        var metrics = ScanMetrics()
        var emissionState = ScanEmissionState()
        let startedAt = ContinuousClock.now
        let summary: AtomicDirectorySummary?

        if resumesProbe {
            summary = try await summarizer.summaryIfNeeded(
                url: rootURL,
                childEntries: rootEntries,
                metadata: rootMetadata,
                includeHiddenFiles: true,
                treatPackagesAsDirectories: false,
                isNodeDependencyLayout: true,
                minFileCount: minFileCount,
                maxAverageFileSize: 256,
                workerLimit: workerLimit,
                exclusionMatcher: exclusionMatcher,
                cancellationCheck: {},
                metrics: &metrics,
                continuation: progressContinuation,
                emissionState: &emissionState
            )
        } else {
            let outcome = try summarizer.descendantAtomicProbeProfile(
                at: rootURL,
                rootEntries: rootEntries,
                rootMetadata: rootMetadata,
                includeHiddenFiles: true,
                treatPackagesAsDirectories: false,
                isNodeDependencyLayout: true,
                minFileCount: minFileCount,
                maxAverageFileSize: 256,
                exclusionMatcher: exclusionMatcher,
                cancellationCheck: {},
                metrics: &metrics,
                continuation: progressContinuation,
                emissionState: &emissionState
            )
            XCTAssertTrue(outcome.profile.suggestsAtomicDirectory(
                minFileCount: minFileCount,
                maxAverageFileSize: 256
            ))
            summary = try await summarizer.summarize(
                at: rootURL,
                includeHiddenFiles: true,
                treatPackagesAsDirectories: false,
                workerLimit: workerLimit,
                ownerNodeID: rootURL.path,
                exclusionMatcher: exclusionMatcher,
                cancellationCheck: {},
                metrics: &metrics,
                continuation: progressContinuation,
                emissionState: &emissionState
            )
        }
        _ = progressStream

        XCTAssertEqual(summary?.descendantFileCount, expectedFileCount)
        let elapsed = startedAt.duration(to: .now)
        return Double(elapsed.components.seconds) +
            Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
    }

    private func makeWideBenchmarkDirectory(fileCount: Int) throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "radix-wide-directory-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let payload = Data([0x41])
        for index in 0..<fileCount {
            let fileURL = rootURL.appending(path: String(format: "file-%08d.dat", index))
            try payload.write(to: fileURL, options: .atomic)
        }

        return rootURL
    }

    private func makeFanoutWideBenchmarkDirectory(
        childDirectoryCount: Int,
        filesPerDirectory: Int
    ) throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "radix-wide-fanout-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let payload = Data([0x41])
        for directoryIndex in 0..<childDirectoryCount {
            let directoryURL = rootURL.appending(path: String(format: "group-%03d", directoryIndex), directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            for fileIndex in 0..<filesPerDirectory {
                let fileURL = directoryURL.appending(path: String(format: "file-%08d.dat", fileIndex))
                try payload.write(to: fileURL, options: .atomic)
            }
        }

        return rootURL
    }

    private func makePackageSummaryBenchmarkDirectory(
        directoryCount: Int,
        filesPerDirectory: Int,
        symlinksPerDirectory: Int
    ) throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "radix-package-summary-\(UUID().uuidString)", directoryHint: .isDirectory)
        let packageURL = rootURL.appending(path: "Payload.app", directoryHint: .isDirectory)
        let resourcesURL = packageURL
            .appending(path: "Contents", directoryHint: .isDirectory)
            .appending(path: "Resources", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)

        let payload = Data([0x41])
        for directoryIndex in 0..<directoryCount {
            let directoryURL = resourcesURL.appending(path: String(format: "bucket-%03d", directoryIndex), directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            let targetURL = directoryURL.appending(path: "symlink-target.dat")
            if symlinksPerDirectory > 0 {
                try payload.write(to: targetURL, options: .atomic)
            }
            for fileIndex in 0..<filesPerDirectory {
                let fileURL = directoryURL.appending(path: String(format: "asset-%08d.dat", fileIndex))
                try payload.write(to: fileURL, options: .atomic)
            }
            for symlinkIndex in 0..<symlinksPerDirectory {
                let symlinkURL = directoryURL.appending(path: String(format: "alias-%08d.dat", symlinkIndex))
                try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: targetURL)
            }
        }

        return rootURL
    }

    private func makeSiblingPackageSummaryBenchmarkDirectory(
        packageCount: Int,
        filesPerPackage: Int
    ) throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "radix-sibling-package-summary-\(UUID().uuidString)", directoryHint: .isDirectory)
        let payload = Data([0x41])
        for packageIndex in 0..<packageCount {
            let packageURL = rootURL.appending(
                path: String(format: "Payload-%04d.app", packageIndex),
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
            for fileIndex in 0..<filesPerPackage {
                try payload.write(
                    to: packageURL.appending(path: String(format: "asset-%06d.dat", fileIndex)),
                    options: .atomic
                )
            }
        }
        return rootURL
    }

    private func runWideDirectoryBenchmark(
        rootURL: URL,
        fileCount: Int,
        configuration: WideDirectoryBenchmarkConfiguration,
        iteration: Int,
        isWarmup: Bool
    ) async throws -> Double {
        var options = ScanOptions()
        options.directoryTraversalWorkerLimit = configuration.traversalWorkerLimit
        options.directoryClassificationWorkerLimit = configuration.classificationWorkerLimit

        let engine = ScanEngine()
        let startedAt = ContinuousClock.now
        var finalSnapshot: ScanSnapshot?

        for try await event in engine.scan(target: ScanTarget(url: rootURL), options: options) {
            if case .finished(let snapshot) = event {
                finalSnapshot = snapshot
            }
        }

        let elapsed = startedAt.duration(to: .now)
        let elapsedSeconds = Double(elapsed.components.seconds) +
            (Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000)
        let snapshot = try XCTUnwrap(finalSnapshot)
        XCTAssertEqual(snapshot.aggregateStats.fileCount, fileCount)
        XCTAssertEqual(snapshot.root.descendantFileCount, fileCount)

        let phase = isWarmup ? "warmup" : "measure"
        print(
            """
            RADIX_BENCH_WIDE_RESULT phase=\(phase)
            files=\(fileCount)
            config=\(configuration.name)
            iteration=\(iteration)
            traversal_workers=\(configuration.traversalWorkerDescription)
            requested_classification_workers=\(configuration.classificationWorkerDescription)
            elapsed=\(String(format: "%.3f", elapsedSeconds))s
            """
        )

        return elapsedSeconds
    }

    private func runPackageSummaryBenchmark(
        rootURL: URL,
        fileCount: Int,
        symlinkCount: Int,
        packageCount: Int,
        configuration: PackageSummaryBenchmarkConfiguration,
        iteration: Int,
        isWarmup: Bool
    ) async throws -> Double {
        var options = ScanOptions()
        options.atomicSummaryWorkerLimit = configuration.atomicSummaryWorkerLimit

        let workerProbe = PackageSummaryBenchmarkWorkerProbe()
        let engine = ScanEngine(atomicSummaryWorkerObserver: AtomicSummaryWorkerObserver(
            didStart: workerProbe.didStart,
            didFinish: workerProbe.didFinish
        ))
        let startedAt = ContinuousClock.now
        var finalSnapshot: ScanSnapshot?

        for try await event in engine.scan(target: ScanTarget(url: rootURL), options: options) {
            if case .finished(let snapshot) = event {
                finalSnapshot = snapshot
            }
        }

        let elapsed = startedAt.duration(to: .now)
        let elapsedSeconds = Double(elapsed.components.seconds) +
            (Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000)
        let snapshot = try XCTUnwrap(finalSnapshot)
        let packageNodes = snapshot.treeStore.children(of: snapshot.root.id).filter(\.isPackage)
        XCTAssertEqual(snapshot.aggregateStats.fileCount, fileCount)
        XCTAssertEqual(packageNodes.count, packageCount)
        XCTAssertEqual(packageNodes.reduce(0) { $0 + $1.descendantFileCount }, fileCount)
        XCTAssertTrue(packageNodes.allSatisfy { !snapshot.treeStore.childIDsByID.keys.contains($0.id) })
        if let configuredLimit = configuration.atomicSummaryWorkerLimit {
            XCTAssertLessThanOrEqual(workerProbe.peakWorkerCount, configuredLimit)
        }

        let phase = isWarmup ? "warmup" : "measure"
        print(
            """
            RADIX_BENCH_PACKAGE_RESULT phase=\(phase)
            packages=\(packageCount)
            files=\(fileCount)
            symlinks=\(symlinkCount)
            config=\(configuration.name)
            iteration=\(iteration)
            summary_workers=\(configuration.workerDescription)
            peak_workers=\(workerProbe.peakWorkerCount)
            peak_concurrent_packages=\(workerProbe.peakOwnerCount)
            elapsed=\(String(format: "%.3f", elapsedSeconds))s
            """
        )

        return elapsedSeconds
    }

    private func finishedSnapshot(
        target: ScanTarget,
        options: ScanOptions,
        engine: ScanEngine
    ) async throws -> ScanSnapshot {
        var finalSnapshot: ScanSnapshot?
        for try await event in engine.scan(target: target, options: options) {
            if case .finished(let snapshot) = event {
                finalSnapshot = snapshot
            }
        }
        return try XCTUnwrap(finalSnapshot)
    }

    private func assertWithinRelativeTolerance(
        _ first: Int64,
        _ second: Int64,
        tolerance: Double,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let denominator = max(Double(max(abs(first), abs(second))), 1)
        let relativeDifference = Double(abs(first - second)) / denominator
        XCTAssertLessThanOrEqual(
            relativeDifference,
            tolerance,
            "Startup scanner \(label) differed by \(relativeDifference * 100)%",
            file: file,
            line: line
        )
    }
}

private final class PackageClassifierBenchmarkCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var lookups = 0

    var lookupCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return lookups
    }

    func recordLookup() {
        lock.lock()
        lookups += 1
        lock.unlock()
    }
}

private final class PackageSummaryBenchmarkWorkerProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var activeWorkers = 0
    private var peakWorkers = 0
    private var activeCountsByOwner: [String: Int] = [:]
    private var peakOwners = 0

    var peakWorkerCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return peakWorkers
    }

    var peakOwnerCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return peakOwners
    }

    func didStart(ownerNodeID: String, itemURL: URL) {
        _ = itemURL
        lock.lock()
        activeWorkers += 1
        peakWorkers = max(peakWorkers, activeWorkers)
        activeCountsByOwner[ownerNodeID, default: 0] += 1
        peakOwners = max(peakOwners, activeCountsByOwner.count)
        lock.unlock()
    }

    func didFinish(ownerNodeID: String, itemURL: URL) {
        _ = itemURL
        lock.lock()
        activeWorkers = max(activeWorkers - 1, 0)
        let remaining = max(activeCountsByOwner[ownerNodeID, default: 0] - 1, 0)
        if remaining == 0 {
            activeCountsByOwner.removeValue(forKey: ownerNodeID)
        } else {
            activeCountsByOwner[ownerNodeID] = remaining
        }
        lock.unlock()
    }
}
