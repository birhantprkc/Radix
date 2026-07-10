import XCTest
@testable import RadixCore

/// Diagnostic probe (opt-in, like the scan benchmarks): records the reported
/// progress fraction over wall-clock time for a real scan so the accuracy of
/// the progress curve can be inspected. Prints one PROBE line per progress
/// event: elapsed seconds, elapsed/total, reported fraction, and the raw
/// counters feeding `ScanMetrics.recalculateProgress`.
final class ProgressAccuracyProbeTests: XCTestCase {
    func testProgressCurve() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RADIX_PROGRESS_PROBE"] == "1" else {
            throw XCTSkip("Set RADIX_PROGRESS_PROBE=1 to run the progress accuracy probe.")
        }

        let path = environment["RADIX_PROGRESS_PROBE_PATH"] ?? "/Applications"
        let targetURL = URL(filePath: path, directoryHint: .isDirectory)
        let engine = ScanEngine()
        let options = ScanOptions()

        struct Sample {
            let elapsed: TimeInterval
            let fraction: Double
            let weight: Double
            let atomicWeight: Double
            let completed: Int
            let discovered: Int
            let enumerated: Int
            let pending: Int
            let isFinalizing: Bool
        }

        let start = Date()
        var samples: [Sample] = []
        var finalSnapshot: ScanSnapshot?
        for try await event in engine.scan(target: ScanTarget(url: targetURL), options: options) {
            switch event {
            case .progress(let metrics):
                samples.append(Sample(
                    elapsed: Date().timeIntervalSince(start),
                    fraction: metrics.progressFraction,
                    weight: metrics.completedTraversalWeight,
                    atomicWeight: metrics.atomicSummaryCompletedTraversalWeight,
                    completed: metrics.completedItems,
                    discovered: metrics.discoveredItems,
                    enumerated: metrics.enumeratedDirectoryCount,
                    pending: metrics.pendingDirectoryCount,
                    isFinalizing: metrics.isFinalizing
                ))
            case .warning:
                break
            case .finished(let snapshot):
                finalSnapshot = snapshot
            }
        }
        let total = Date().timeIntervalSince(start)

        print("PROBE_HEADER elapsed timeFraction reportedFraction weight atomicWeight completed discovered enumerated pending finalizing")
        for sample in samples {
            print(String(
                format: "PROBE %.3f %.4f %.4f %.4f %.4f %d %d %d %d %d",
                sample.elapsed,
                sample.elapsed / total,
                sample.fraction,
                sample.weight,
                sample.atomicWeight,
                sample.completed,
                sample.discovered,
                sample.enumerated,
                sample.pending,
                sample.isFinalizing ? 1 : 0
            ))
        }
        let stats = finalSnapshot?.aggregateStats
        print(String(
            format: "PROBE_TOTAL %.3f files=%d folders=%d samples=%d",
            total,
            stats?.fileCount ?? -1,
            stats?.directoryCount ?? -1,
            samples.count
        ))
    }
}
