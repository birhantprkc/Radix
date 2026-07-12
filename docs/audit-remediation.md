# Audit Remediation Ledger

This file tracks the July 2026 code audit through validation, implementation,
testing, and logical commit checkpoints. CI work is intentionally deferred for
a separate collaboration.

## Working rules

- Validate each report against current code before changing behavior.
- Preserve native macOS behavior and unrelated working-tree changes.
- Add focused regression coverage before considering a finding resolved.
- Run the full SwiftPM suite and an unsigned Xcode build before completion.
- Commit each coherent outcome separately using Conventional Commits.

## Findings

| Area | Original finding | Validation | Planned resolution | Status |
| --- | --- | --- | --- | --- |
| Trash safety | Identity verification and path-based trash mutation are separated by a wide TOCTOU window, especially for batches. | Confirmed. `FileManager.trashItem(at:)` cannot make identity verification and mutation fully atomic. | Verification now occurs in the same per-node operation immediately before native trashing; batches verify and move one item at a time. The unavoidable final platform-level window is documented. | Resolved in `ac594ed` |
| Tree topology | The general `FileTreeStore` initializer can precondition-fail when its root is absent. | The precondition exists, but current scanner/import paths validate or construct the root first. No user-triggerable path is known. | Rejected as non-actionable: synthesizing a root would corrupt semantics, while throwing would churn invariant-preserving internal callers without improving a production boundary. | Closed without code change |
| Aggregate overflow | Filesystem/archive-derived size and count aggregation uses trapping arithmetic. | Confirmed for malformed archive-derived aggregate repair. | Size and count repair now use saturating arithmetic with `Int64.max`/`Int.max` boundary tests. | Resolved in `ac594ed` |
| Chart failures | Non-cancellation layout errors are converted to a successful empty render in both chart models. | Confirmed. Callers could not distinguish failure from valid empty geometry. | Shared request coordination now preserves prior renders, publishes failure, rejects stale results, and powers accessible Retry banners in both charts. | Resolved in `e4ae1ab` and `4974403` |
| Modal arbitration | Onboarding, discard review, import preview, comparison setup, alerts, and trash confirmation can compete. | Confirmed at the state-model level; opening an archive during onboarding could create overlapping sheet state. | A single presentation coordinator serializes sheets/dialogs and queues document opens deterministically. | Resolved in `e4ae1ab` and `1f8e441` |
| Split divider accessibility | The custom divider supports mouse dragging only. | Confirmed. It had no adjustable accessibility action/value or keyboard operation. | Added keyboard focus, arrow-key resizing, focus indication, an accessibility percentage value, and adjustable increment/decrement actions. | Resolved in `38a4e06` |
| Capacity lookup | Available capacity is queried synchronously during SwiftUI body evaluation. | Confirmed. Navigation/view invalidations repeated filesystem resource lookups on the main actor. | Live lookup now runs in a utility task and publishes a snapshot-keyed cache refreshed by explicit snapshot/setting/mount events with cancellation and stale-result protection. | Resolved in `48af56c` |
| Comparison performance | Filtering, sorting, and significant projection run synchronously on the main actor for input changes. | Confirmed from `ScanComparisonView`. | A dedicated browser model debounces search, computes off-main, cancels and rejects stale work, preserves published results, and reconciles selection. | Resolved in `178bc59` |
| Discard pluralization | The sidebar emits `1 items`. | Rejected after inspecting the current catalog: it already contains an English singular variation (`1 item`). The button did lack an explicit dynamic accessibility value. | Preserved the working plural rule and added a stable accessibility label/value. | Resolved in `38a4e06` |
| Settings synchronization | Exclusion edits remain local until focus loss, submit, structural edit, or disappearance. | Confirmed; a scan can start while visible text is not reflected in preferences. | Publish normalized committed patterns on every field edit so another window cannot start a scan with stale visible input. | Resolved in `38a4e06` |
| AppModel size | `AppModel` owns many independent workflows and cancellation tokens. | Confirmed structural risk; decomposition had to preserve heavily tested behavior. | Presentation state, comparison browsing, and the six-path archive lifecycle were extracted into focused coordinators. Trash/navigation remain in AppModel because their state transitions are tightly coupled to the active snapshot and selection; moving them for line count alone would increase coupling. | Resolved by bounded extraction |
| Chart duplication | Sunburst and treemap duplicate asynchronous generation/cancellation/stale-result logic. | Confirmed. | Consolidated request lifecycle while retaining chart-specific lookup/render behavior. | Resolved in `e4ae1ab` and `4974403` |
| SwiftPM parity | SwiftPM compiled production sources without the app target's MainActor-default/approachable-concurrency settings. | Confirmed against Xcode frontend flags. | SwiftPM now applies MainActor default, InferIsolatedConformances, and NonisolatedNonsendingByDefault to `RadixCore`; background-safe values/algorithms are explicitly nonisolated and XCTest remains non-default-isolated. | Resolved in `749c162` |
| Oversized views | `ContentView`, `ScanComparisonView`, and `SettingsView` combine substantial workflow state with rendering and are excluded from SwiftPM UI compilation. | Confirmed structural/testability issue. | Extracted presentation routing from `ContentView` and async browser state from `ScanComparisonView`; retained declarative rendering sections where moving them would not improve invariants. | Resolved by targeted extraction |
| Localization coverage | SwiftPM excludes UI sources/resources, so package tests could not prove application resource compilation. | Confirmed. | Tests now scan all app Swift sources, both string tables, supported translations, Package source membership, and Xcode synchronized resource membership. The application resource build is verified with Xcode. | Resolved in `54f05b2` and `9434356` |
| CI/release automation | No tracked CI or Xcode test target. | Confirmed. | Deferred at the user's request. | Deferred |

## Checkpoints

- `38a4e06 fix(ui): improve workspace interaction access`
  - Debug Xcode application build passed.
  - Focused diff validation passed.
  - Covered by the final full-suite validation below.
- `ac594ed fix(files): revalidate identity before trashing`
  - `FileTreeStoreTests`, `AppModelDependencyTests`, and
    `SystemIntegrationTests`: 128 tests passed.
  - Documents the residual `lstat` to path-based `trashItem` platform window.
- `e4ae1ab refactor(app): centralize async request state`
  - Adds independently testable chart-request and presentation coordinators.
- `1f8e441 fix(app): serialize modal presentation flows`
  - Presentation coordinator tests: 5 passed.
  - AppModel dependency tests: 86 passed.
  - Debug Xcode application build passed.
- `4974403 fix(charts): preserve layouts when rendering fails`
  - Sunburst/treemap model tests: 15 passed.
  - Debug Xcode application build passed.
- `178bc59 perf(comparison): process browser updates off main`
  - Comparison browser concurrency tests: 4 passed.
  - Debug Xcode application build passed.
- `48af56c perf(disk-map): cache volume capacity off main`
  - AppModel dependency tests: 89 passed under production actor isolation.
  - Debug Xcode application build passed.
- `749c162 build(swift): align package actor isolation`
  - Generated SwiftPM build plan contains the three Xcode-equivalent concurrency flags.
  - Full suite: 556 tests passed, 11 skipped, zero failures.
- `f62e1a2 refactor(archive): centralize workflow lifecycle`
  - Archive coordinator stale-result tests: 3 passed.
  - AppModel dependency tests: 89 passed.
  - Debug Xcode application build passed.
- `54f05b2 test(localization): audit all interface sources`
  - Six localization/resource/source-membership tests passed.
  - 111 Swift files, 507 literals, and 477 keys validated with no gaps or duplicates.
- `9434356 test(localization): parse project regions robustly`
  - Removed formatting sensitivity exposed by the first full-suite run.

## Final validation

- `rtk swift test --scratch-path .build/parity-mainactor --jobs 1`
  - 560 tests passed, 11 skipped, zero failures.
- `rtk xcodebuild -quiet -project Radix.xcodeproj -scheme Radix -configuration Debug build CODE_SIGNING_ALLOWED=NO`
  - Succeeded.
- `rtk git diff --check`
  - Succeeded.
- CI creation and Xcode test-target work remain intentionally deferred for the
  requested follow-up collaboration.
