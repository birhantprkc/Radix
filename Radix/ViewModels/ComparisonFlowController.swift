//
//  ComparisonFlowController.swift
//  Radix
//

import Foundation

/// Owns the snapshot-comparison state machines: the pending setup sheet and
/// the active comparison result. AppModel wires `onChange` to refresh the
/// setup-sheet presentation and publish object changes.
@MainActor
final class ComparisonFlowController {
    /// Invoked on the main actor after every mutating assignment below.
    var onChange: (() -> Void)?

    private(set) var scanComparison: ScanComparison? {
        didSet { notifyChanged() }
    }

    var pendingComparisonSetup: ScanComparisonSetup? {
        didSet { notifyChanged() }
    }

    init(
        scanComparison: ScanComparison? = nil,
        pendingComparisonSetup: ScanComparisonSetup? = nil
    ) {
        self.scanComparison = scanComparison
        self.pendingComparisonSetup = pendingComparisonSetup
    }

    func setScanComparison(_ comparison: ScanComparison?) {
        scanComparison = comparison
    }

    private func notifyChanged() {
        onChange?()
    }
}
