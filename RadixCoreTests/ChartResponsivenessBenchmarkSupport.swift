import Darwin
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

    static func measure<Value>(
        _ operation: () throws -> Value
    ) rethrows -> ChartBenchmarkMeasurement<Value> {
        let startedAt = ContinuousClock.now
        let value = try operation()
        return ChartBenchmarkMeasurement(
            value: value,
            seconds: durationSeconds(startedAt.duration(to: .now))
        )
    }

    @MainActor
    static func measureAsync<Value>(
        _ operation: () async throws -> Value
    ) async rethrows -> ChartBenchmarkMeasurement<Value> {
        let startedAt = ContinuousClock.now
        let value = try await operation()
        return ChartBenchmarkMeasurement(
            value: value,
            seconds: durationSeconds(startedAt.duration(to: .now))
        )
    }

    static func durationSeconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds)
            + (Double(components.attoseconds) / 1_000_000_000_000_000_000)
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sortedValues = values.sorted()
        let midpoint = sortedValues.count / 2
        if sortedValues.count.isMultiple(of: 2) {
            return (sortedValues[midpoint - 1] + sortedValues[midpoint]) / 2
        }
        return sortedValues[midpoint]
    }

    static func report(
        prefix: String,
        phase: String,
        seconds: Double,
        count: Int,
        peakRSS: UInt64,
        extra: String = ""
    ) {
        print(
            "\(prefix) phase=\(phase) "
                + "seconds=\(format(seconds)) count=\(count) "
                + "peak_rss=\(peakRSS) \(extra)"
        )
    }

    static func format(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    static func peakResidentBytes() -> UInt64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return UInt64(max(usage.ru_maxrss, 0))
    }

    static func byteDelta(from start: UInt64, to end: UInt64) -> UInt64 {
        end >= start ? end - start : 0
    }
}

struct ChartBenchmarkMeasurement<Value> {
    let value: Value
    let seconds: Double
}
