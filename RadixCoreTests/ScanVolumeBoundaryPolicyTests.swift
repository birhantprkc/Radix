import XCTest
@testable import RadixCore

final class ScanVolumeBoundaryPolicyTests: XCTestCase {
    private let systemVolumeDevice: UInt64 = 0x0100_0001
    private let dataVolumeDevice: UInt64 = 0x0100_0005
    private let externalVolumeDevice: UInt64 = 0x0200_0002
    private let diskImageDevice: UInt64 = 0x0300_0004

    private func makeDefaultMounts() -> [ScanEngine.ScanMountedFileSystem] {
        [
            ScanEngine.ScanMountedFileSystem(
                mountPath: "/",
                deviceName: "/dev/disk1s1s1",
                fileSystemType: "apfs"
            ),
            ScanEngine.ScanMountedFileSystem(
                mountPath: "/System/Volumes/Data",
                deviceName: "/dev/disk1s5",
                fileSystemType: "apfs"
            ),
            ScanEngine.ScanMountedFileSystem(
                mountPath: "/System/Volumes/VM",
                deviceName: "/dev/disk1s4",
                fileSystemType: "apfs"
            ),
            ScanEngine.ScanMountedFileSystem(
                mountPath: "/Volumes/External",
                deviceName: "/dev/disk2s2",
                fileSystemType: "apfs"
            ),
            ScanEngine.ScanMountedFileSystem(
                mountPath: "/home",
                deviceName: "map auto_home",
                fileSystemType: "autofs"
            ),
        ]
    }

    func testFirmlinkedSameContainerMountsRemainTraversable() {
        let policy = ScanEngine.ScanVolumeBoundaryPolicy.resolve(
            rootPath: "/",
            rootDeviceID: systemVolumeDevice,
            mountedFileSystems: makeDefaultMounts()
        )

        XCTAssertFalse(policy.shouldStopDescent(
            childPath: "/System/Volumes/Data",
            childDeviceID: dataVolumeDevice
        ))
        XCTAssertFalse(policy.shouldStopDescent(
            childPath: "/System/Volumes/Data/Users/colin",
            childDeviceID: dataVolumeDevice
        ))
        XCTAssertFalse(policy.shouldStopDescent(
            childPath: "/System/Volumes/VM/swapfile0",
            childDeviceID: 0x0100_0004
        ))
    }

    func testForeignContainerMountsBecomeLeaves() {
        let policy = ScanEngine.ScanVolumeBoundaryPolicy.resolve(
            rootPath: "/",
            rootDeviceID: systemVolumeDevice,
            mountedFileSystems: makeDefaultMounts()
        )

        XCTAssertTrue(policy.shouldStopDescent(
            childPath: "/Volumes/External",
            childDeviceID: externalVolumeDevice
        ))
        XCTAssertTrue(policy.shouldStopDescent(
            childPath: "/Volumes/External/Backup/Library",
            childDeviceID: externalVolumeDevice
        ))
        XCTAssertTrue(policy.shouldStopDescent(
            childPath: "/home/smb-user",
            childDeviceID: externalVolumeDevice
        ))
    }

    func testDiskImageMountInsideScannedTreeBecomesLeaf() {
        var mounts = makeDefaultMounts()
        mounts.append(ScanEngine.ScanMountedFileSystem(
            mountPath: "/Users/colin/MountedImage",
            deviceName: "/dev/disk3s4",
            fileSystemType: "apfs"
        ))
        let policy = ScanEngine.ScanVolumeBoundaryPolicy.resolve(
            rootPath: "/System/Volumes/Data/Users/colin",
            rootDeviceID: dataVolumeDevice,
            mountedFileSystems: mounts
        )

        XCTAssertTrue(policy.shouldStopDescent(
            childPath: "/Users/colin/MountedImage",
            childDeviceID: diskImageDevice
        ))
        XCTAssertFalse(policy.shouldStopDescent(
            childPath: "/Users/colin/Documents",
            childDeviceID: dataVolumeDevice
        ))
    }

    func testFolderScanOnExternalVolumeUsesItsOwnContainer() {
        var mounts = makeDefaultMounts()
        mounts.append(ScanEngine.ScanMountedFileSystem(
            mountPath: "/Volumes/External/SecondSlice",
            deviceName: "/dev/disk2s3",
            fileSystemType: "apfs"
        ))
        let policy = ScanEngine.ScanVolumeBoundaryPolicy.resolve(
            rootPath: "/Volumes/External/scan-me",
            rootDeviceID: externalVolumeDevice,
            mountedFileSystems: mounts
        )

        XCTAssertFalse(policy.shouldStopDescent(
            childPath: "/Volumes/External/SecondSlice/data",
            childDeviceID: 0x0200_0003
        ))
        XCTAssertTrue(policy.shouldStopDescent(
            childPath: "/System/Volumes/Data/Users/colin",
            childDeviceID: dataVolumeDevice
        ))
    }

    func testMissingDeviceInformationNeverStopsTraversal() {
        let policy = ScanEngine.ScanVolumeBoundaryPolicy.resolve(
            rootPath: "/",
            rootDeviceID: systemVolumeDevice,
            mountedFileSystems: makeDefaultMounts()
        )
        XCTAssertFalse(policy.shouldStopDescent(childPath: "/Volumes/Unknown", childDeviceID: nil))

        let unresolvedPolicy = ScanEngine.ScanVolumeBoundaryPolicy.resolve(
            rootPath: "/",
            rootDeviceID: nil,
            mountedFileSystems: makeDefaultMounts()
        )
        XCTAssertFalse(unresolvedPolicy.shouldStopDescent(
            childPath: "/Volumes/External",
            childDeviceID: externalVolumeDevice
        ))
    }

    func testNonAPFSMountsWithMatchingDiskPrefixStayBlocked() {
        var mounts = makeDefaultMounts()
        mounts.append(ScanEngine.ScanMountedFileSystem(
            mountPath: "/LegacySlice",
            deviceName: "/dev/disk1s7",
            fileSystemType: "hfs"
        ))
        let policy = ScanEngine.ScanVolumeBoundaryPolicy.resolve(
            rootPath: "/",
            rootDeviceID: systemVolumeDevice,
            mountedFileSystems: mounts
        )

        XCTAssertTrue(policy.shouldStopDescent(
            childPath: "/LegacySlice/data",
            childDeviceID: 0x0100_0007
        ))
    }

    func testSimilarMountPathsDoNotAliasEachOther() {
        var mounts = makeDefaultMounts()
        mounts.append(ScanEngine.ScanMountedFileSystem(
            mountPath: "/System/Volumes/DataPrivate",
            deviceName: "/dev/disk9s9",
            fileSystemType: "apfs"
        ))
        let policy = ScanEngine.ScanVolumeBoundaryPolicy.resolve(
            rootPath: "/",
            rootDeviceID: systemVolumeDevice,
            mountedFileSystems: mounts
        )

        XCTAssertTrue(policy.shouldStopDescent(
            childPath: "/System/Volumes/DataPrivate/stash",
            childDeviceID: 0x0900_0009
        ))
        XCTAssertFalse(policy.shouldStopDescent(
            childPath: "/System/Volumes/Data/Users",
            childDeviceID: dataVolumeDevice
        ))
    }
}
