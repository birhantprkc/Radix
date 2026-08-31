import XCTest
@testable import RadixCore

final class SharedAllocationOwnerAccumulatorTests: XCTestCase {
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
            let accumulator = SharedAllocationOwnerAccumulator(order)

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
        var accumulator = SharedAllocationOwnerAccumulator()

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
        let firstLocal = SharedAllocationOwnerAccumulator(firstClaims)
        let secondLocal = SharedAllocationOwnerAccumulator(secondClaims)

        var forward = firstLocal
        forward.merge(secondLocal)
        var reverse = secondLocal
        reverse.merge(firstLocal)
        let direct = SharedAllocationOwnerAccumulator(firstClaims + secondClaims)

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
        let accumulator = SharedAllocationOwnerAccumulator([
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
        let accumulator = SharedAllocationOwnerAccumulator([repeated, repeated, repeated])

        XCTAssertEqual(try XCTUnwrap(accumulator.winner(for: identity)).ownerNodeID, repeated.ownerNodeID)
        XCTAssertEqual(accumulator.duplicateAllocatedSizeByOwner, [repeated.ownerNodeID: 256])
    }

    func testCorrectionMaterializationChecksCancellationDuringTraversal() {
        let claims = (0..<512).map { index in
            claim(
                FileIdentity(device: 6, inode: UInt64(index)),
                owner: "/owner-\(index)",
                path: "/file-\(index)",
                size: 1
            )
        }
        let accumulator = SharedAllocationOwnerAccumulator(claims)
        var checkCount = 0

        XCTAssertThrowsError(try accumulator.duplicateAllocatedSizeByOwner {
            checkCount += 1
            if checkCount == 2 {
                throw CancellationError()
            }
        }) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(checkCount, 2)
    }

    func testStandaloneCloneCorrectionMaterializationChecksCancellationDuringTraversal() {
        let claims = (0..<512).flatMap { index in
            let cloneIdentity = CloneIdentity(device: 7, cloneID: UInt64(index))
            return [
                cloneClaim(
                    fileIdentity: FileIdentity(device: 7, inode: UInt64(index * 2)),
                    cloneIdentity: cloneIdentity,
                    owner: "/winner-\(index)",
                    path: "/a-\(index)",
                    totalSize: 1,
                    dataSize: 1
                ),
                cloneClaim(
                    fileIdentity: FileIdentity(device: 7, inode: UInt64(index * 2 + 1)),
                    cloneIdentity: cloneIdentity,
                    owner: "/loser-\(index)",
                    path: "/z-\(index)",
                    totalSize: 1,
                    dataSize: 1
                ),
            ]
        }
        let accumulator = SharedAllocationOwnerAccumulator(claims)
        var checkCount = 0

        XCTAssertThrowsError(try accumulator.duplicateAllocatedSizeByOwner {
            checkCount += 1
            if checkCount == 2 {
                throw CancellationError()
            }
        }) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(checkCount, 2)
    }

    func testMixedCloneCorrectionChecksCancellationDuringHardLinkReduction() {
        let claims = (0..<768).flatMap { index in
            let device = UInt64(8)
            let cloneIdentity = CloneIdentity(device: device, cloneID: UInt64(index))
            let hardLinkIdentity = FileIdentity(device: device, inode: UInt64(index * 2))
            return [
                cloneClaim(
                    fileIdentity: FileIdentity(device: device, inode: UInt64(index * 2 + 1)),
                    cloneIdentity: cloneIdentity,
                    owner: "/standalone-\(index)",
                    path: "/a-\(index)",
                    totalSize: 1,
                    dataSize: 1
                ),
                cloneClaim(
                    fileIdentity: hardLinkIdentity,
                    hardLinkIdentity: hardLinkIdentity,
                    cloneIdentity: cloneIdentity,
                    owner: "/hard-link-\(index)",
                    path: "/z-\(index)",
                    totalSize: 1,
                    dataSize: 1
                ),
            ]
        }
        let accumulator = SharedAllocationOwnerAccumulator(claims)
        var checkCount = 0

        XCTAssertThrowsError(try accumulator.duplicateAllocatedSizeByOwner {
            checkCount += 1
            if checkCount == 3 {
                throw CancellationError()
            }
        }) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(checkCount, 3)
    }

    func testZeroDataCloneDoesNotCreateCloneAccountingState() {
        let device = UInt64(9)
        let cloneIdentity = CloneIdentity(device: device, cloneID: 1)
        let standalone = SharedAllocationOwnerAccumulator([
            cloneClaim(
                fileIdentity: FileIdentity(device: device, inode: 1),
                cloneIdentity: cloneIdentity,
                owner: "/standalone",
                totalSize: 32,
                dataSize: 0
            ),
        ])
        let hardLinkIdentity = FileIdentity(device: device, inode: 2)
        let hardLinked = SharedAllocationOwnerAccumulator([
            cloneClaim(
                fileIdentity: hardLinkIdentity,
                hardLinkIdentity: hardLinkIdentity,
                cloneIdentity: cloneIdentity,
                owner: "/hard-link",
                totalSize: 32,
                dataSize: 0
            ),
        ])

        XCTAssertTrue(standalone.isEmpty)
        XCTAssertEqual(standalone.identityCount, 0)
        XCTAssertTrue(standalone.duplicateAllocatedSizeByOwner.isEmpty)
        XCTAssertFalse(hardLinked.isEmpty)
        XCTAssertEqual(hardLinked.identityCount, 1)
        XCTAssertTrue(hardLinked.duplicateAllocatedSizeByOwner.isEmpty)
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

        let accumulator = SharedAllocationOwnerAccumulator([source, hardLink, cloneWithResourceFork])

        XCTAssertEqual(accumulator.duplicateAllocatedSizeByOwner, [
            "/b-hard-link": 100,
            "/z-clone": 80,
        ])
    }

    func testStandaloneCloneWinsAcrossMultipleHardLinkedInodes() {
        let cloneIdentity = CloneIdentity(device: 1, cloneID: 100)
        let firstHardLinkIdentity = FileIdentity(device: 1, inode: 20)
        let secondHardLinkIdentity = FileIdentity(device: 1, inode: 21)
        let claims = [
            cloneClaim(
                fileIdentity: firstHardLinkIdentity,
                hardLinkIdentity: firstHardLinkIdentity,
                cloneIdentity: cloneIdentity,
                owner: "/hard-link-b",
                path: "/b",
                totalSize: 100,
                dataSize: 80
            ),
            cloneClaim(
                fileIdentity: secondHardLinkIdentity,
                hardLinkIdentity: secondHardLinkIdentity,
                cloneIdentity: cloneIdentity,
                owner: "/hard-link-c",
                path: "/c",
                totalSize: 130,
                dataSize: 80
            ),
            cloneClaim(
                fileIdentity: secondHardLinkIdentity,
                hardLinkIdentity: secondHardLinkIdentity,
                cloneIdentity: cloneIdentity,
                owner: "/hard-link-d",
                path: "/d",
                totalSize: 130,
                dataSize: 80
            ),
            cloneClaim(
                fileIdentity: FileIdentity(device: 1, inode: 22),
                cloneIdentity: cloneIdentity,
                owner: "/standalone-a",
                path: "/a",
                totalSize: 110,
                dataSize: 80
            ),
        ]

        let accumulator = SharedAllocationOwnerAccumulator(claims)

        XCTAssertEqual(accumulator.duplicateAllocatedSizeByOwner, [
            "/hard-link-b": 80,
            "/hard-link-c": 80,
            "/hard-link-d": 130,
        ])
    }

    func testStandaloneCloneGroupRetainsOneIdentityAndAccumulatesLosers() {
        let cloneIdentity = CloneIdentity(device: 1, cloneID: 99)
        let claims = (0..<10_000).map { index in
            cloneClaim(
                fileIdentity: FileIdentity(device: 1, inode: UInt64(index)),
                cloneIdentity: cloneIdentity,
                owner: "/summary",
                path: String(format: "/file-%05d", index),
                totalSize: 130,
                dataSize: 80
            )
        }

        let accumulator = SharedAllocationOwnerAccumulator(claims.reversed())

        XCTAssertEqual(accumulator.identityCount, 1)
        XCTAssertEqual(accumulator.duplicateAllocatedSizeByOwner, [
            "/summary": 9_999 * 80,
        ])
    }

    func testStandaloneCloneMergeMatchesDirectAccumulationInEitherOrder() {
        let cloneIdentity = CloneIdentity(device: 2, cloneID: 7)
        let firstClaims = [
            cloneClaim(
                fileIdentity: FileIdentity(device: 2, inode: 1),
                cloneIdentity: cloneIdentity,
                owner: "/summary-a",
                path: "/z",
                totalSize: 100,
                dataSize: 80
            ),
            cloneClaim(
                fileIdentity: FileIdentity(device: 2, inode: 2),
                cloneIdentity: cloneIdentity,
                owner: "/summary-a",
                path: "/y",
                totalSize: 100,
                dataSize: 80
            ),
        ]
        let secondClaims = [
            cloneClaim(
                fileIdentity: FileIdentity(device: 2, inode: 3),
                cloneIdentity: cloneIdentity,
                owner: "/summary-b",
                path: "/a",
                totalSize: 100,
                dataSize: 80
            ),
        ]
        let first = SharedAllocationOwnerAccumulator(firstClaims)
        let second = SharedAllocationOwnerAccumulator(secondClaims)

        var forward = first
        forward.merge(second)
        var reverse = second
        reverse.merge(first)
        let direct = SharedAllocationOwnerAccumulator(firstClaims + secondClaims)

        XCTAssertEqual(forward.duplicateAllocatedSizeByOwner, direct.duplicateAllocatedSizeByOwner)
        XCTAssertEqual(reverse.duplicateAllocatedSizeByOwner, direct.duplicateAllocatedSizeByOwner)
        XCTAssertEqual(forward.duplicateAllocatedSizeByOwner, [
            "/summary-a": 160,
        ])
        XCTAssertEqual(forward.identityCount, 1)
        XCTAssertEqual(reverse.identityCount, 1)
    }

    private func claim(
        _ identity: FileIdentity,
        owner: String,
        path: String,
        size: Int64
    ) -> SharedAllocationClaim {
        SharedAllocationClaim(
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
        path: String? = nil,
        totalSize: Int64,
        dataSize: Int64
    ) -> SharedAllocationClaim {
        SharedAllocationClaim(
            fileIdentity: fileIdentity,
            hardLinkIdentity: hardLinkIdentity,
            cloneIdentity: cloneIdentity,
            ownerNodeID: owner,
            path: path ?? owner,
            allocatedSize: totalSize,
            cloneAllocatedSize: dataSize
        )
    }
}
