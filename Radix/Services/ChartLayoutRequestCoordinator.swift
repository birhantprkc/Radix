//
//  ChartLayoutRequestCoordinator.swift
//  Radix
//

import Foundation

struct ChartLayoutFailure: Equatable, Sendable {
    let message: String

    init(error: any Error) {
        let localizedDescription = error.localizedDescription
        message = localizedDescription.isEmpty ? String(describing: error) : localizedDescription
    }
}

struct ChartLayoutRequest<Output: Sendable> {
    let generation: Int
    let layoutID: String
    let task: Task<Output, any Error>
}

enum ChartLayoutRequestOutcome<Output: Sendable> {
    case success(Output)
    case failure(ChartLayoutFailure)
    case cancelled
    case superseded
}

/// Owns the cancellation and stale-result rules shared by asynchronous chart layouts.
@MainActor
final class ChartLayoutRequestCoordinator<Output: Sendable> {
    private var generation = 0
    private var activeLayoutID: String?
    private var activeTask: Task<Output, any Error>?

    deinit {
        activeTask?.cancel()
    }

    func start(
        layoutID: String,
        operation: @escaping @Sendable () async throws -> Output
    ) -> ChartLayoutRequest<Output> {
        generation += 1
        activeLayoutID = layoutID
        activeTask?.cancel()

        let task = Task(priority: .userInitiated) {
            try await operation()
        }
        activeTask = task
        return ChartLayoutRequest(
            generation: generation,
            layoutID: layoutID,
            task: task
        )
    }

    func outcome(
        for request: ChartLayoutRequest<Output>
    ) async -> ChartLayoutRequestOutcome<Output> {
        do {
            let output = try await withTaskCancellationHandler {
                try await request.task.value
            } onCancel: {
                request.task.cancel()
            }
            try Task.checkCancellation()
            guard isCurrent(request) else { return .superseded }

            activeTask = nil
            return .success(output)
        } catch is CancellationError {
            guard isCurrent(request) else { return .superseded }

            activeTask = nil
            return .cancelled
        } catch {
            guard isCurrent(request) else { return .superseded }

            activeTask = nil
            return .failure(ChartLayoutFailure(error: error))
        }
    }

    private func isCurrent(_ request: ChartLayoutRequest<Output>) -> Bool {
        generation == request.generation && activeLayoutID == request.layoutID
    }
}
