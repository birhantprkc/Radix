import XCTest
@testable import RadixCore

@MainActor
final class AppPresentationCoordinatorTests: XCTestCase {
    func testArchiveOpenWaitsForOnboardingToDismiss() {
        let archiveURL = URL(filePath: "/tmp/queued.radixscan")
        let coordinator = AppPresentationCoordinator(
            initialDestination: .sheet(.onboarding)
        )

        XCTAssertEqual(coordinator.requestArchiveImport(archiveURL), .queued)
        XCTAssertEqual(coordinator.activeSheet, .onboarding)

        let resumedURL = coordinator.cancel(.sheet(.onboarding))

        XCTAssertEqual(resumedURL, archiveURL)
        XCTAssertNil(coordinator.activeDestination)
    }

    func testPresentationsAdvanceInRequestOrder() {
        let coordinator = AppPresentationCoordinator(
            initialDestination: .sheet(.onboarding)
        )

        coordinator.present(.sheet(.discardPileReview))
        coordinator.present(.dialog(.trashConfirmation))

        XCTAssertNil(coordinator.cancel(.sheet(.onboarding)))
        XCTAssertEqual(coordinator.activeSheet, .discardPileReview)
        XCTAssertNil(coordinator.activeDialog)

        XCTAssertNil(coordinator.cancel(.sheet(.discardPileReview)))
        XCTAssertEqual(coordinator.activeDialog, .trashConfirmation)
        XCTAssertNil(coordinator.activeSheet)
    }

    func testCancellingQueuedPresentationPreventsItFromAppearing() {
        let coordinator = AppPresentationCoordinator(
            initialDestination: .sheet(.onboarding)
        )

        coordinator.present(.dialog(.error))
        XCTAssertNil(coordinator.cancel(.dialog(.error)))
        XCTAssertNil(coordinator.cancel(.sheet(.onboarding)))

        XCTAssertNil(coordinator.activeDestination)
    }

    func testQueuedDestinationKeepsLatestPayload() {
        let firstID = UUID()
        let latestID = UUID()
        let coordinator = AppPresentationCoordinator(
            initialDestination: .sheet(.onboarding)
        )

        coordinator.present(.sheet(.comparisonSetup(firstID)))
        coordinator.present(.sheet(.comparisonSetup(latestID)))
        XCTAssertNil(coordinator.cancel(.sheet(.onboarding)))

        XCTAssertEqual(coordinator.activeSheet, .comparisonSetup(latestID))
    }

    func testMultipleArchiveOpensResumeOneAtATimeAroundPreview() {
        let firstURL = URL(filePath: "/tmp/first.radixscan")
        let secondURL = URL(filePath: "/tmp/second.radixscan")
        let coordinator = AppPresentationCoordinator(
            initialDestination: .sheet(.onboarding)
        )

        XCTAssertEqual(coordinator.requestArchiveImport(firstURL), .queued)
        XCTAssertEqual(coordinator.requestArchiveImport(secondURL), .queued)
        XCTAssertEqual(coordinator.cancel(.sheet(.onboarding)), firstURL)

        coordinator.present(.sheet(.importPreview(firstURL)))
        XCTAssertEqual(coordinator.cancel(.sheet(.importPreview(firstURL))), secondURL)
        XCTAssertNil(coordinator.activeDestination)
    }
}
