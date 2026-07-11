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
        XCTAssertNil(aggregate?.nodeID)
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

private extension CGRect {
    var area: CGFloat {
        isNull || isInfinite ? 0 : max(width, 0) * max(height, 0)
    }
}
