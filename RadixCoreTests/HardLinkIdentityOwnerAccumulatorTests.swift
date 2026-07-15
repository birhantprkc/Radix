import XCTest
@testable import RadixCore

final class HardLinkIdentityOwnerAccumulatorTests: XCTestCase {
    func testWinnerAndCorrectionsAreIndependentOfArrivalOrder() throws {
        let identity = FileIdentity(device: 1, inode: 42)
        let expectedWinner = claim(identity, owner: "/owner-a", path: "/a", size: 100)
        let tiedPathLoser = claim(identity, owner: "/owner-b", path: "/a", size: 100)
        let laterPathLoser = claim(identity, owner: "/owner-z", path: "/z", size: 100)
        let orders = [
            [expectedWinner, tiedPathLoser, laterPathLoser],
            [expectedWinner, laterPathLoser, tiedPathLoser],
            [tiedPathLoser, expectedWinner, laterPathLoser],
            [tiedPathLoser, laterPathLoser, expectedWinner],
            [laterPathLoser, expectedWinner, tiedPathLoser],
            [laterPathLoser, tiedPathLoser, expectedWinner],
        ]

        for order in orders {
            let accumulator = HardLinkIdentityOwnerAccumulator(order)

            let winner = try XCTUnwrap(accumulator.winner(for: identity))
            XCTAssertEqual(winner.path, expectedWinner.path)
            XCTAssertEqual(winner.ownerNodeID, expectedWinner.ownerNodeID)
            XCTAssertEqual(accumulator.duplicateAllocatedSizeByOwner, [
                tiedPathLoser.ownerNodeID: 100,
                laterPathLoser.ownerNodeID: 100,
            ])
        }
    }

    func testRecordingEarlierWinnerMovesPreviousWinnerIntoCorrections() throws {
        let identity = FileIdentity(device: 2, inode: 7)
        var accumulator = HardLinkIdentityOwnerAccumulator()

        accumulator.record(claim(identity, owner: "/z-owner", path: "/z", size: 80))
        XCTAssertTrue(accumulator.duplicateAllocatedSizeByOwner.isEmpty)

        accumulator.record(claim(identity, owner: "/m-owner", path: "/m", size: 80))
        accumulator.record(claim(identity, owner: "/a-owner", path: "/a", size: 80))

        XCTAssertEqual(try XCTUnwrap(accumulator.winner(for: identity)).path, "/a")
        XCTAssertEqual(accumulator.duplicateAllocatedSizeByOwner, [
            "/m-owner": 80,
            "/z-owner": 80,
        ])
        XCTAssertEqual(accumulator.identityCount, 1)
    }

    func testMergingLocalAccumulatorsMatchesDirectAccumulationInEitherOrder() throws {
        let firstIdentity = FileIdentity(device: 3, inode: 10)
        let secondIdentity = FileIdentity(device: 3, inode: 11)
        let firstClaims = [
            claim(firstIdentity, owner: "/package-a/z", path: "/z", size: 64),
            claim(firstIdentity, owner: "/package-a/y", path: "/y", size: 64),
            claim(secondIdentity, owner: "/shared-owner", path: "/b", size: 32),
        ]
        let secondClaims = [
            claim(firstIdentity, owner: "/package-b/a", path: "/a", size: 64),
            claim(secondIdentity, owner: "/shared-owner", path: "/c", size: 32),
        ]
        let firstLocal = HardLinkIdentityOwnerAccumulator(firstClaims)
        let secondLocal = HardLinkIdentityOwnerAccumulator(secondClaims)

        var forward = firstLocal
        forward.merge(secondLocal)
        var reverse = secondLocal
        reverse.merge(firstLocal)
        let direct = HardLinkIdentityOwnerAccumulator(firstClaims + secondClaims)

        XCTAssertEqual(forward.duplicateAllocatedSizeByOwner, direct.duplicateAllocatedSizeByOwner)
        XCTAssertEqual(reverse.duplicateAllocatedSizeByOwner, direct.duplicateAllocatedSizeByOwner)
        XCTAssertEqual(try XCTUnwrap(forward.winner(for: firstIdentity)).path, "/a")
        XCTAssertEqual(try XCTUnwrap(reverse.winner(for: firstIdentity)).path, "/a")
        XCTAssertEqual(try XCTUnwrap(forward.winner(for: secondIdentity)).path, "/b")
        XCTAssertEqual(forward.duplicateAllocatedSizeByOwner["/shared-owner"], 32)
        XCTAssertEqual(forward.identityCount, 2)
    }

    func testNonpositiveClaimsDoNotCreateOwnersOrCorrections() {
        let identity = FileIdentity(device: 4, inode: 9)
        let accumulator = HardLinkIdentityOwnerAccumulator([
            claim(identity, owner: "/zero", path: "/zero", size: 0),
            claim(identity, owner: "/negative", path: "/negative", size: -1),
        ])

        XCTAssertTrue(accumulator.isEmpty)
        XCTAssertEqual(accumulator.identityCount, 0)
        XCTAssertTrue(accumulator.duplicateAllocatedSizeByOwner.isEmpty)
        XCTAssertNil(accumulator.winner(for: identity))
    }

    func testRepeatedIdenticalClaimsPreserveExistingDeduplicationSemantics() throws {
        let identity = FileIdentity(device: 5, inode: 20)
        let repeated = claim(identity, owner: "/owner", path: "/file", size: 128)
        let accumulator = HardLinkIdentityOwnerAccumulator([repeated, repeated, repeated])

        XCTAssertEqual(try XCTUnwrap(accumulator.winner(for: identity)).ownerNodeID, repeated.ownerNodeID)
        XCTAssertEqual(accumulator.duplicateAllocatedSizeByOwner, [repeated.ownerNodeID: 256])
    }

    func testHardLinkedCloneEntersCloneAccountingOnlyOnce() {
        let fileIdentity = FileIdentity(device: 1, inode: 10)
        let cloneIdentity = CloneIdentity(device: 1, cloneID: 99)
        let source = cloneClaim(
            fileIdentity: fileIdentity,
            hardLinkIdentity: fileIdentity,
            cloneIdentity: cloneIdentity,
            owner: "/a-source",
            totalSize: 100,
            dataSize: 80
        )
        let hardLink = cloneClaim(
            fileIdentity: fileIdentity,
            hardLinkIdentity: fileIdentity,
            cloneIdentity: cloneIdentity,
            owner: "/b-hard-link",
            totalSize: 100,
            dataSize: 80
        )
        let cloneWithResourceFork = cloneClaim(
            fileIdentity: FileIdentity(device: 1, inode: 11),
            cloneIdentity: cloneIdentity,
            owner: "/z-clone",
            totalSize: 130,
            dataSize: 80
        )

        let accumulator = HardLinkIdentityOwnerAccumulator([source, hardLink, cloneWithResourceFork])

        XCTAssertEqual(accumulator.duplicateAllocatedSizeByOwner, [
            "/b-hard-link": 100,
            "/z-clone": 80,
        ])
    }

    private func claim(
        _ identity: FileIdentity,
        owner: String,
        path: String,
        size: Int64
    ) -> HardLinkClaim {
        HardLinkClaim(
            identity: identity,
            ownerNodeID: owner,
            path: path,
            allocatedSize: size
        )
    }

    private func cloneClaim(
        fileIdentity: FileIdentity,
        hardLinkIdentity: FileIdentity? = nil,
        cloneIdentity: CloneIdentity,
        owner: String,
        totalSize: Int64,
        dataSize: Int64
    ) -> HardLinkClaim {
        HardLinkClaim(
            fileIdentity: fileIdentity,
            hardLinkIdentity: hardLinkIdentity,
            cloneIdentity: cloneIdentity,
            ownerNodeID: owner,
            path: owner,
            allocatedSize: totalSize,
            cloneAllocatedSize: dataSize
        )
    }
}
