# Quick Look implementation review

Reviewed September 17, 2026. The original review below describes the implementation before migration; the approved design has now been implemented.

## Implementation outcome

The workspace now presents Quick Look through SwiftUI's collection `quickLookPreview` modifier. `AppQuickLookController` owns the optional preview session and cancellable validation. The custom panel presenter, system-action forwarding closures, global key monitor, monitor token, window observer, and window-number routing have been removed.

The clarified navigation requirement is preserved: with Quick Look closed, Up/Down browses the file table and each chart retains its spatial arrow navigation. Plain Space opens a preview from those focused surfaces. While Quick Look is open, macOS owns keyboard behavior and navigation within the explicitly selected collection; no custom event bridge was added.

Selected groups use the displayed table order and start at the primary item. Native preview navigation leaves the workspace's selected set intact. Inspector requests remain scoped to the primary item. Explicit requests and automatic selection following share live-path and imported-identity validation, performed off the main actor before publishing URLs. Cancellation, dismissal, and snapshot replacement prevent pending work from reopening a stale preview.

Implementation validation:

- Full core suite: `rtk swift test`, 948 tests in 65 suites passed.
- Complete Debug app: the documented `rtk xcodebuild` command passed; the only build warning was the existing no-AppIntents-metadata warning.
- Exact Debug bundle on macOS 27.0: verified table Up/Down, spatial selection in both charts, Space from all three surfaces, search-field Space, Command-Y open/close, group context-menu preview, native group arrow navigation, index-sheet ordering after reverse-name sorting, and Space/Escape/titlebar dismissal without losing workspace selection.
- Automated coverage includes imported-identity rejection during automatic following, whole-group validation failure, disabled/synthetic selections, delayed validation cancellation, latest-selection wins, primary-item scope, and workflow/snapshot dismissal.
- macOS 14 runtime testing and the broader media/large-selection matrix below remain unverified; this machine runs macOS 27. Text fixtures exercised the actual app integration.

## Original recommendation

**Recommendation: let SwiftUI present Quick Look, keep a small preview-session owner, and move Space handling onto the file browser and charts.** Start by preserving single-item behavior and fixing validation. Then enable Quick Look for explicitly selected groups using the collection API. A proper AppKit panel controller remains the better option if navigating the underlying table/chart while the panel is key is a product requirement.

This recommendation is based on reading the implementation and its callers, checking Apple's current documentation and the installed SDK, building Radix, running the existing Quick Look tests, exercising this checkout's Debug app, and running an isolated SwiftUI probe.

## What the current implementation does

The path is `ContentView` / menu commands → `AppModel` → `AppQuickLookController` → six `AppQuickLookActions` closures → `SystemIntegration` wrappers → a singleton `QuickLookPreviewPresenter` → `QLPreviewPanel.shared()`.

The controller also installs an app-wide local event monitor. A custom `WorkspaceWindowObserver` reports a window number so the monitor can decide whether Space belongs to Radix's workspace. It then excludes text fields, buttons, other controls, blocked workflows, and the preview panel.

The dedicated controller and presenter contain 264 lines, before the system-action wrappers, monitor token, window observer, AppModel integration, and tests. The split isolates dependencies, but much of it exists to manually coordinate presentation that SwiftUI already exposes as state.

## Findings

| Finding | Evidence and consequence |
| --- | --- |
| Panel ownership does not follow Apple's contract | `QuickLookIntegration.swift:53` assigns `dataSource` and changes panel state, but the singleton never participates in `acceptsPreviewPanelControl`, `beginPreviewPanelControl`, or `endPreviewPanelControl`. Apple says panel state must only be changed by its controller. The panel searches the responder chain as key/main windows change. This is a lifecycle defect, although I did not reproduce a crash. |
| Open and follow-selection paths have different validation | `AppQuickLookController.swift:89` calls `validatedSelectionForQuickLook()`, which checks live-path availability and imported-file identity. `syncVisiblePreview()` at line 76 only checks action availability; the presenter then checks existence. In a locally actionable imported scan, selecting a replaced file while Quick Look is open can therefore preview a path that an explicit open would reject. This follows directly from the code; it was not reproduced with an archive fixture. |
| The panel interrupts keyboard browsing | `makeKeyAndOrderFront` makes the panel key, but no `QLPreviewPanelDelegate` routes unhandled events to the source browser. In the exact Debug app, Down and Right did not advance a three-file fixture selection while Quick Look was open. Space and Escape dismissed normally. |
| Multiple selection is deliberately unsupported | The selection availability policy and shortcut guard disable Quick Look for more than one node. The presenter always contains one URL. After a multiple selection settled in the Debug app, Space did not open a preview. Quick Look itself supports collections and an index sheet. |
| Selection updates do more work than necessary | Every visible update repeats a filesystem existence check, resets the index, reloads the data, and calls `refreshCurrentPreviewItem()`. Apple's SDK distinguishes loading changed items from recomputing the current preview. Selection-set changes can invoke this path even when the primary URL stays the same. Extra regeneration is evident; an actual playback/page-position reset was not measured. |
| A close request unnecessarily validates a file | `toggleSelected()` validates before reaching the presenter's visibility check. Dismissing an already-open preview should not require the selected path to still exist or match an imported identity. |
| The keyboard mechanism is broader than the feature | Every key-down reaches the app-wide monitor. Exclusions encode knowledge of AppKit responder classes rather than expressing which browsing surfaces own Space. There is no repeat-event exclusion. A repeated-key flicker was not reproduced, and panel focus affects whether subsequent repeats reach the monitor. |
| Tests mainly verify plumbing | The eight tests whose names include QuickLook cover monitor installation/removal, basic window scoping, injected actions, selection synchronization, and suspension. They pass, but do not establish panel ownership, native keyboard behavior, imported identity on automatic updates, or a complete presentation lifecycle. |

The existing restrictions on synthetic nodes and imported snapshots are useful and must remain. Imported scans are not universally forbidden: `ScanSnapshotSource` permits live path actions only for imports whose capability is `.pathValidation`, with additional identity checks when available.

## Proposed design

**One small owner for intent and policy.** Retain `AppQuickLookController` as an observable presentation owner, or rename it to make its responsibility clearer. Its state should be an optional preview session containing the ordered URLs and current URL. A nil session means dismissed. Avoid separate flags for requested visibility, actual visibility, panel key status, and presentation mode unless a concrete behavior requires them.

Keep validation at the boundary between scanned nodes and preview URLs. All entry points—menu, context menu, chart, Space, and following a changed workspace selection—must use the same validation policy. Dismissal should immediately clear the session, before looking up or validating any selection. A failed automatic follow should close the preview; an explicit request can report the existing error.

**SwiftUI owns presentation.** Attach the modifier once to the stable workspace view. The conceptual integration is:

```swift
import QuickLook

workspace
    .quickLookPreview(previewSelectionBinding, in: previewURLs)
```

The binding reads and updates the session's current URL; a nil write clears the session. Enforce that a non-nil current URL belongs to the session's URLs. Apple documents that an out-of-collection selection behaves like nil. Ignore identical writes, and keep binding callbacks small and idempotent.

Do not bind the modifier directly to `WorkspaceNavigationModel.selectedNodeID` or a URL derived unconditionally from it. That would open previews merely by selecting files, and dismissal could clear the workspace selection. In the probe, Quick Look wrote nil on dismissal while the table selection remained intact.

When the workspace selection changes, only update Quick Look if a preview session already exists. Preserve current close-on-background, close-on-main-window-disappearance, comparison, tour, and scan-reset behavior by clearing the session. SwiftUI handles native panel presentation, item navigation, and user dismissal.

**Space belongs to browsing surfaces.** Use `.onKeyPress(.space, phases: .down)` on the contents table, with an empty-modifier check. Do not put it on the whole workspace, which contains search fields and controls. Keep Radix's `tableKeyboardFocus` helper: I reproduced the macOS 27 table-focus issue in the probe before adding the same FocusState/tap workaround.

Charts already implement native keyboard handling in `ChartKeyboardInteractionView`; add a plain-Space action there, ignoring repeats and retaining `super.keyDown` for unhandled input. There is no reason to convert chart input to SwiftUI solely for this change. Preserve Command-Y as a command and context-menu Quick Look as a present action.

**An explicit group is the preview collection.** For the next step, preview the user's selected files in displayed order, starting at the primary item. Obtain that order from `FileBrowserModel.displayedNodes(ids:)`, which already has an indexed selection projection. `WorkspaceNavigationModel.selectedNodes` uses the underlying table nodes and a sorted-ID fallback; it is not necessarily the filtered/sorted order currently on screen, especially for entire-scan search.

Navigating within a multi-item preview should move the session's current item while retaining the workspace's selected set. Otherwise one arrow press could collapse the group and change the targets of later bulk actions. A single-item session continues to follow an explicit new selection in the workspace. If the selected set changes while open, rebuild the session from that new selection, preserving the current item when it remains a member.

Do not silently hand Quick Look the entire scan, every descendant of a folder, or all global-search results. Keep chart and inspector requests scoped to their selected node. Previewing all neighboring rows is a separate browsing policy with additional ordering, validation, and cost implications.

**Validate before handing a collection to the framework.** A SwiftUI binding notification reports the file being previewed; it is not a documented preflight permission callback. In particular, do not plan to reject an imported identity only after Quick Look has already moved to the URL. Validate the candidate group before publishing it. If any item fails validation, retain the existing explicit error behavior rather than silently previewing a misleading subset.

Avoid duplicating `fileExists` in the presenter after domain validation. Filesystem checks can block on remote/offline storage; move expensive group preparation off the main actor and discard stale results if selection, snapshot, or dismissal changes while preparation runs. Do not stat every file in the scan when selection moves. No custom preview cache or preview-rendering service is needed.

## Alternatives and tradeoffs

| Approach | What it buys | Why choose or reject it |
| --- | --- | --- |
| SwiftUI `quickLookPreview` | Native panel, collection browsing/index sheet, item binding, dismissal binding, very little platform plumbing; available since macOS 11 | Recommended for Radix's existing explicit-preview workflow and selected-group browsing. It does not expose a panel delegate or a before-navigation validation hook. |
| Proper `QLPreviewPanel` controller | Explicit lifecycle, unhandled-event delegation, source-frame transitions, more direct control over refresh and display state | Choose if panel-key Up/Down must move the underlying table selection, chart arrows must retain spatial meaning, or per-item preflight is necessary for a large browsable sequence. Implement ownership through a window/view controller in the actual responder chain; merely declaring the lifecycle methods on a detached singleton is insufficient. |
| Embedded `QLPreviewView` | A preview directly in Radix's inspector; compact style and asynchronous loading | Useful for a deliberate inspector redesign. It does not provide the existing floating panel experience by itself, and auto-previewing every selection changes resource usage and interaction. Not a simpler substitute for this task. |
| Shelling out to `qlmanage` or launching another app | A quick debugging shortcut | Does not solve in-app ownership, selection synchronization, or lifecycle. Adds an external process boundary without fixing the design. |

The key tradeoff is real: **SwiftUI is substantially simpler, but native collection Left/Right browsing is not the same as Finder-style Up/Down navigation of the underlying browser.** In the SwiftUI text-file probe, Right advanced to the next file and Down did not. Quick Look's unhandled-event delegate is also not an unconditional key interceptor; previews may consume keys themselves. If exact source navigation is required, prototype it across text, images, PDF, and video using a proper AppKit controller before committing to that behavior.

Do not combine a SwiftUI-owned preview panel with a second custom object assigning that panel's delegate/data source. Pick one presentation owner.

## What can disappear

With the SwiftUI design:

- Remove `QuickLookPreviewPresenter` and the six Quick Look forwarding methods in `SystemIntegration`.
- Remove `AppQuickLookActions`; domain validation dependencies remain injectable.
- Remove the Quick Look local event monitor and its installer from `AppSystemActions`.
- Remove `AppEventMonitorToken`, which currently has no other production consumer.
- Remove `WorkspaceWindowObserver`, window-number storage/forwarding, and the responder-class exclusion list, all of which currently serve this monitor.
- Reduce `AppQuickLookController` to session changes and validation coordination. Its current selection context need not carry trash policy and active target just to compute Quick Look availability.
- Replace monitor-lifecycle and forwarded-action tests with tests of observable preview behavior.

Update `Package.swift` when removing/moving its explicitly listed sources. The UI modifier belongs in app UI code; the session policy can remain in `RadixCore` for tests. This change needs no additional dependency or deployment-target increase. New user-facing text, if introduced with group previews, needs all six locales.

## Migration and acceptance checks

1. Migrate single-item presentation and focused Space together. Fix the inconsistent validation path and dismiss-before-validation behavior. Preserve existing commands and workflow dismissal behavior.
2. Add explicit selected-group preview, displayed-order projection, and session-current-item handling. Keep this separate from expanding the preview set to all siblings or search results.
3. Only add an AppKit adapter if a demonstrated interaction requirement needs it. Do not retain both presentation implementations speculatively.

Test policy rather than framework internals: closed selection changes stay closed; a validated explicit request opens; dismissal retains workspace selection; following a selected imported file performs identity validation; unsupported or unavailable items never enter a new session; cancellation prevents delayed reopening; same-item updates do not regenerate state; an invalid item does not prevent dismissal; group ordering matches sorting/filtering; group navigation preserves bulk selection; and scan/source changes invalidate the session even if a path string remains the same.

Manually exercise the exact Debug bundle on the minimum supported macOS and current macOS: table and both charts, search fields, controls, modifiers and held Space, Command-Y, context menus, Space/Escape/titlebar close, full screen, switching windows, backgrounding, closing/reopening the workspace, target changes, rescan/trash/removal, empty selection, and group preview. Include files, folders, packages, PDF, images, audio/video, unavailable paths, actionable imports with replaced identities, and non-actionable imports. Those are migration acceptance checks, not claims that the current investigation exercised every case.

## Validation performed

- `rtk xcodebuild -project Radix.xcodeproj -scheme Radix -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/xcode-derived-data build`: passed. Xcode emitted its duplicate-destination and no-AppIntents-metadata warnings.
- `rtk swift test --filter '.*QuickLook.*'`: 8 tests passed. This was a targeted baseline run, not the entire core suite.
- Native UI: stopped other Radix instances, verified one process, and tested `/Users/colin/Programming/Radix/.build/xcode-derived-data/Build/Products/Debug/Radix.app` with three generated local text files.
- Isolated probe: compiled against the installed SDK with deployment target macOS 14. Verified table-scoped Space, retained spaces in the search field, native collection Right-arrow navigation, no next-item action from Down, item-binding updates, Space/Escape dismissal, retained table selection, visible updates after changing the bound URL, and programmatic dismissal by setting nil. The index-sheet control was present; its full behavior was not exercised.
- Runtime was macOS 27.0 (26A428), with the macOS 27 SDK. Availability was also checked in SDK declarations and Apple's documentation. This does not establish macOS 14 runtime behavior, video/PDF navigation, or large-selection performance.
- The original review changed no production Swift files, resources, or build configuration. The implementation outcome above records the subsequent migration. The attached probe remains experimental evidence and is not part of either production target.

## Primary references

- [SwiftUI single-URL preview](https://developer.apple.com/documentation/swiftui/view/quicklookpreview(_:)): presentation/dismissal through an optional URL binding.
- [SwiftUI collection preview](https://developer.apple.com/documentation/swiftui/view/quicklookpreview(_:in:)): membership requirement, current-item updates, and dismissal updates.
- [QLPreviewPanel](https://developer.apple.com/documentation/quicklookui/qlpreviewpanel) and [currentController](https://developer.apple.com/documentation/quicklookui/qlpreviewpanel/currentcontroller): shared-panel ownership and the responder chain. The installed `QLPreviewPanel.h` also documents the accept/begin/end lifecycle.
- [Panel event delegation](https://developer.apple.com/documentation/quicklookui/qlpreviewpaneldelegate/previewpanel(_:handle:)): events Quick Look does not handle.
- [SwiftUI key phases](https://developer.apple.com/documentation/swiftui/view/onkeypress(_:phases:action:)): focused keyboard handling, available on macOS 14.
- [QLPreviewView](https://developer.apple.com/documentation/quicklookui/qlpreviewview): embedded preview alternative.

## Reproducing the isolated probe

Source: `docs/quick-look-review/QuickLookProbe.swift`. It uses three disposable text fixtures in `/tmp/radix-quicklook-fixtures`, and is not included in either production target. Run the following from the repository root on an Apple Silicon Mac with Xcode installed; close an existing probe instance before launching another. The experiment intentionally offers all three fixture files as a collection to exercise native navigation, regardless of which table row is selected.

```sh
mkdir -p /tmp/radix-quicklook-fixtures /tmp/RadixQuickLookProbe.app/Contents/MacOS
python3 - <<'PY'
from pathlib import Path
import plistlib

fixtures = Path('/tmp/radix-quicklook-fixtures')
for name in ('First', 'Second', 'Third'):
    (fixtures / f'{name}.txt').write_text(f'{name.upper()} DOCUMENT\nQuick Look API experiment.\n' * 8)
info = {
    'CFBundleIdentifier': 'dev.radix.QuickLookProbe',
    'CFBundleExecutable': 'RadixQuickLookProbe',
    'CFBundleName': 'RadixQuickLookProbe',
    'CFBundlePackageType': 'APPL',
}
with open('/tmp/RadixQuickLookProbe.app/Contents/Info.plist', 'wb') as output:
    plistlib.dump(info, output)
PY
rtk proxy swiftc -parse-as-library -target arm64-apple-macos14.0 \
  -module-cache-path /tmp/radix-quicklook-module-cache \
  docs/quick-look-review/QuickLookProbe.swift \
  -o /tmp/RadixQuickLookProbe.app/Contents/MacOS/RadixQuickLookProbe
open -n /tmp/RadixQuickLookProbe.app
```

Select a row, then press Space. Right/Left browses the three-item collection; Escape or Space dismisses. The status text records changed binding values. Search-field Space should insert a space. The two delayed-action buttons test updating and clearing the URL while the preview owns keyboard focus.
