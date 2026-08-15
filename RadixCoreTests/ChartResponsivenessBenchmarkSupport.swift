import Foundation
@testable import RadixCore

enum ChartResponsivenessBenchmarkSupport {
    static let fnvOffsetBasis: UInt64 = 14_695_981_039_346_656_037
    private static let fnvPrime: UInt64 = 1_099_511_628_211

    static func node(
        id: String,
        name: String,
        isDirectory: Bool,
        allocatedSize: Int64,
        descendantFileCount: Int
    ) -> FileNodeRecord {
        FileNodeRecord(
            id: id,
            url: URL(
                filePath: id,
                directoryHint: isDirectory ? .isDirectory : .notDirectory
            ),
            name: name,
            isDirectory: isDirectory,
            isSymbolicLink: false,
            allocatedSize: allocatedSize,
            logicalSize: allocatedSize,
            descendantFileCount: descendantFileCount,
            lastModified: nil,
            isPackage: false,
            isAccessible: true,
            isSelfAccessible: true,
            isSynthetic: false,
            isAutoSummarized: false
        )
    }

    @inline(__always)
    static func hash(_ string: String, into hash: inout UInt64) {
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= fnvPrime
        }
        Self.hash(0xff, into: &hash)
    }

    @inline(__always)
    static func hash(_ value: UInt64, into hash: inout UInt64) {
        var value = value
        for _ in 0..<MemoryLayout<UInt64>.size {
            hash ^= value & 0xff
            hash &*= fnvPrime
            value >>= 8
        }
    }

    @MainActor
    static func measureAsync<Value>(
        _ operation: () async throws -> Value
    ) async rethrows -> BenchmarkMeasurement<Value> {
        let startedAt = ContinuousClock.now
        let value = try await operation()
        return BenchmarkMeasurement(
            value: value,
            seconds: BenchmarkSupport.durationSeconds(startedAt.duration(to: .now))
        )
    }
}
