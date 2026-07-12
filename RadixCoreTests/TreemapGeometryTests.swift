import CoreGraphics
import XCTest
@testable import RadixCore

final class TreemapGeometryTests: XCTestCase {
    func testTopLevelTilesFillBoundsProportionallyWithoutOverlap() {
        let large = makeTestFileNode(id: "/root/large", name: "large", size: 75)
        let small = makeTestFileNode(id: "/root/small", name: "small", size: 25)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [large, small])
        let store = FileTreeStore(root: root, childrenByID: [root.id: [large, small]])

        let segments = TreemapLayout.segments(
            in: store,
            rootID: root.id,
            depthLimit: 1,
            size: CGSize(width: 400, height: 200),
            minimumTileArea: 1
        )

        XCTAssertEqual(segments.count, 2)
        let areaByID = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0.rect.area) })
        XCTAssertEqual(areaByID[large.id] ?? 0, 0.75, accuracy: 0.000_001)
        XCTAssertEqual(areaByID[small.id] ?? 0, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(segments.reduce(0) { $0 + $1.rect.area }, 1, accuracy: 0.000_001)
        XCTAssertTrue(segments[0].rect.intersection(segments[1].rect).area < 0.000_001)
    }

    func testNestedDirectoryReservesHeaderAndContainsDescendantTiles() throws {
        let nestedA = makeTestFileNode(id: "/root/folder/a", name: "a", size: 60)
        let nestedB = makeTestFileNode(id: "/root/folder/b", name: "b", size: 40)
        let folder = makeTestDirectoryNode(
            id: "/root/folder",
            name: "folder",
            children: [nestedA, nestedB]
        )
        let sibling = makeTestFileNode(id: "/root/sibling", name: "sibling", size: 25)
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [folder, sibling])
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [folder, sibling],
                folder.id: [nestedA, nestedB]
            ]
        )

        let segments = TreemapLayout.segments(
            in: store,
            rootID: root.id,
            depthLimit: 3,
            size: CGSize(width: 800, height: 400),
            minimumTileArea: 1
        )

        let folderSegment = try XCTUnwrap(segments.first { $0.id == folder.id })
        let firstChildSegment = try XCTUnwrap(segments.first { $0.id == nestedA.id })
        let secondChildSegment = try XCTUnwrap(segments.first { $0.id == nestedB.id })

        XCTAssertTrue(folderSegment.showsContainerHeader)
        XCTAssertEqual(firstChildSegment.depth, 1)
        XCTAssertEqual(secondChildSegment.depth, 1)
        XCTAssertTrue(folderSegment.rect.contains(firstChildSegment.rect))
        XCTAssertTrue(folderSegment.rect.contains(secondChildSegment.rect))
        XCTAssertGreaterThan(firstChildSegment.rect.minY, folderSegment.rect.minY)
        XCTAssertGreaterThan(secondChildSegment.rect.minY, folderSegment.rect.minY)
    }

    func testSmallSiblingsCollapseIntoAggregateTile() {
        let large = makeTestFileNode(id: "/root/large", name: "large", size: 10_000)
        let smallNodes = (0..<4).map {
            makeTestFileNode(id: "/root/small-\($0)", name: "small-\($0)", size: 1)
        }
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [large] + smallNodes)
        let store = FileTreeStore(root: root, childrenByID: [root.id: [large] + smallNodes])

        let segments = TreemapLayout.segments(
            in: store,
            rootID: root.id,
            depthLimit: 1,
            size: CGSize(width: 500, height: 300)
        )

        XCTAssertEqual(segments.count, 2)
        let aggregate = segments.first { $0.isAggregate }
        XCTAssertEqual(aggregate?.label, "Smaller Items")
        XCTAssertEqual(aggregate?.totalSize, 4)
        XCTAssertEqual(aggregate?.groupedItemCount, 4)
        XCTAssertNil(aggregate?.nodeID)
    }

    func testAggregateSizeDoesNotCountZeroByteLayoutWeightsAsDiskUsage() throws {
        let large = makeTestFileNode(id: "/root/large", name: "large", size: 10_000)
        let empty = (0..<3).map {
            makeTestFileNode(id: "/root/empty-\($0)", name: "empty-\($0)", size: 0)
        }
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [large] + empty)
        let store = FileTreeStore(root: root, childrenByID: [root.id: [large] + empty])

        let segments = TreemapLayout.segments(
            in: store,
            rootID: root.id,
            depthLimit: 1,
            size: CGSize(width: 500, height: 300)
        )

        let aggregate = try XCTUnwrap(segments.first(where: \.isAggregate))
        XCTAssertEqual(aggregate.totalSize, 0)
        XCTAssertEqual(aggregate.groupedItemCount, 3)
    }

    func testAggregateTileIsSortedBySizeBeforeSquarification() {
        let large = makeTestFileNode(id: "/root/large", name: "large", size: 10_000)
        let medium = makeTestFileNode(id: "/root/medium", name: "medium", size: 100)
        let smallNodes = (0..<200).map {
            makeTestFileNode(id: "/root/small-\($0)", name: "small-\($0)", size: 1)
        }
        let children = [large, medium] + smallNodes
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: children)
        let store = FileTreeStore(root: root, childrenByID: [root.id: children])

        let segments = TreemapLayout.segments(
            in: store,
            rootID: root.id,
            depthLimit: 1,
            size: CGSize(width: 1_000, height: 1_000)
        )

        XCTAssertEqual(segments.map(\.id), [large.id, "treemap-aggregate-\(root.id)", medium.id])
    }

    func testHitTestingPrefersDeepestContainingTile() throws {
        let nested = makeTestFileNode(id: "/root/folder/nested", name: "nested", size: 100)
        let folder = makeTestDirectoryNode(id: "/root/folder", name: "folder", children: [nested])
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [folder])
        let store = FileTreeStore(
            root: root,
            childrenByID: [root.id: [folder], folder.id: [nested]]
        )
        let size = CGSize(width: 600, height: 300)
        let segments = TreemapLayout.segments(
            in: store,
            rootID: root.id,
            depthLimit: 3,
            size: size,
            minimumTileArea: 1
        )
        let nestedSegment = try XCTUnwrap(segments.first { $0.id == nested.id })
        let point = CGPoint(
            x: nestedSegment.rect.midX * size.width,
            y: nestedSegment.rect.midY * size.height
        )

        let hit = TreemapHitTestIndex(segments: segments).segment(at: point, in: size)

        XCTAssertEqual(hit?.id, nested.id)
    }

    func testHitTestingLeavesStructuralGuttersUnassigned() {
        let left = makeTreemapSegment(
            id: "left",
            rect: CGRect(x: 0, y: 0, width: 0.5, height: 1)
        )
        let right = makeTreemapSegment(
            id: "right",
            rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        )
        let size = CGSize(width: 600, height: 300)
        let index = TreemapHitTestIndex(segments: [left, right])

        XCTAssertNil(index.segment(at: CGPoint(x: 300, y: 150), in: size))
    }

    func testHitTestingMatchesRenderedRectsAcrossFractionalChartSize() {
        let segments = [
            makeTreemapSegment(id: "left", rect: CGRect(x: 0, y: 0, width: 0.6, height: 1)),
            makeTreemapSegment(id: "right", rect: CGRect(x: 0.6, y: 0, width: 0.4, height: 1)),
        ]
        let size = CGSize(width: 617.5, height: 293.25)
        let index = TreemapHitTestIndex(segments: segments)

        for x in stride(from: CGFloat(0.25), to: size.width, by: 3.75) {
            for y in stride(from: CGFloat(0.25), to: size.height, by: 4.5) {
                let point = CGPoint(x: x, y: y)
                let expected = segments.last { segment in
                    TreemapRenderer.displayRect(for: segment, in: size).contains(point)
                }
                XCTAssertEqual(
                    index.segment(at: point, in: size)?.id,
                    expected?.id,
                    "Hit-test mismatch at (\(point.x), \(point.y))"
                )
            }
        }
    }

    func testSmallTilesDoNotProduceAnOutOfBoundsSelectionStrokeRect() {
        let segment = makeTreemapSegment(
            id: "tiny",
            rect: CGRect(x: 0, y: 0, width: 0.004, height: 1)
        )
        let size = CGSize(width: 500, height: 300)

        XCTAssertNil(
            TreemapRenderer.strokeRect(
                for: segment,
                in: size,
                lineWidth: 2.75
            )
        )
    }

    func testDescendantsKeepTopLevelBranchColorFamily() throws {
        let nested = makeTestFileNode(id: "/root/folder/nested", name: "nested", size: 100)
        let folder = makeTestDirectoryNode(id: "/root/folder", name: "folder", children: [nested])
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: [folder])
        let store = FileTreeStore(
            root: root,
            childrenByID: [root.id: [folder], folder.id: [nested]]
        )

        let segments = TreemapLayout.segments(
            in: store,
            rootID: root.id,
            depthLimit: 3,
            size: CGSize(width: 600, height: 300),
            minimumTileArea: 1
        )
        let folderSegment = try XCTUnwrap(segments.first { $0.id == folder.id })
        let nestedSegment = try XCTUnwrap(segments.first { $0.id == nested.id })

        XCTAssertEqual(folderSegment.colorToken.branchID, folder.id)
        XCTAssertEqual(nestedSegment.colorToken.branchID, folder.id)
        XCTAssertNotEqual(folderSegment.colorToken.localID, nestedSegment.colorToken.localID)
    }

    func testLayoutStopsWhenCancellationCheckThrows() {
        let children = (0..<100).map {
            makeTestFileNode(id: "/root/\($0)", name: "\($0)", size: Int64(100 - $0))
        }
        let root = makeTestDirectoryNode(id: "/root", name: "root", children: children)
        let store = FileTreeStore(root: root, childrenByID: [root.id: children])
        var checks = 0

        XCTAssertThrowsError(try TreemapLayout.segments(
            in: store,
            rootID: root.id,
            depthLimit: 3,
            size: CGSize(width: 800, height: 400),
            cancellationCheck: {
                checks += 1
                if checks > 4 { throw CancellationError() }
            }
        ))
    }
}

private func makeTreemapSegment(id: String, rect: CGRect) -> TreemapSegment {
    TreemapSegment(
        id: id,
        nodeID: id,
        containerNodeID: "/root",
        label: id,
        rect: rect,
        depth: 0,
        colorToken: .single(id: id),
        totalSize: 1,
        isAggregate: false,
        groupedItemCount: nil,
        isDirectory: false,
        showsContainerHeader: false
    )
}

private extension CGRect {
    var area: CGFloat {
        isNull || isInfinite ? 0 : max(width, 0) * max(height, 0)
    }
}
