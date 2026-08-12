# AGENTS.md

## Project

Radix is a native macOS 14+ disk-space analyzer built with Swift 6.2,
SwiftUI, and Xcode 26+.

Preserve these product guarantees:

- Scanning remains responsive and does not block the UI.
- Files are never modified or removed without an explicit user action.
- Visualizations and the file browser remain primary navigation surfaces.

Prefer SwiftUI for UI. Use AppKit only when required for macOS system integration.

## Architecture and task routing

- Scanner or data behavior: `Radix/Services/`, `Radix/Models/`
- Tree and indexing: `Radix/Models/FileTreeStore.swift`
- App coordination, navigation, or selection: `Radix/ViewModels/AppModel.swift`
- Search and sorting: `Radix/Services/FileBrowserModel.swift`
- Sunburst or treemap layout: the corresponding geometry/chart model in
  `Radix/Services/`
- Feature UI: `Radix/Features/`
- Tests: `RadixCoreTests/`

`Package.swift` defines the non-UI `RadixCore` target. When adding or moving a
non-UI Swift file, update its explicit source list. The Xcode project builds
the complete app.

## Change guidelines

- Fix data behavior in models or services; fix UI coordination in view models.
- Add or update tests for scanner, tree, path, archive, comparison, geometry,
  search, and formatting changes.
- Add new user-facing text to the appropriate `.xcstrings` catalog for every
  supported locale: `en`, `de`, `es`, `fr`, `it`, and `zh-Hans`.
- Avoid new dependencies unless clearly justified. `RadixCore` has none.
- Sparkle is managed through Xcode Swift Package Manager; never vendor it.
- Use current documentation for version-sensitive Apple or external APIs.

## Validation

Run core tests:

    swift test

Build the complete app into a deterministic DerivedData location:

    xcodebuild -project Radix.xcodeproj -scheme Radix \
      -configuration Debug -destination 'platform=macOS' \
      -derivedDataPath .build/xcode-derived-data build

For routine manual testing with Computer Use:

- Stop any other running Radix instances, then launch this checkout's exact
  Debug bundle:

      open -n .build/xcode-derived-data/Build/Products/Debug/Radix.app

- Use the full absolute path to that bundle for every Computer Use `app`
  argument. Require exactly one running Radix instance before testing; the
  `open -n` command deliberately starts a new instance.
- Never target the app as `Radix` or `com.colinkim.Radix`. Installed, archived,
  release, and DerivedData builds share that identity, so generic lookup can
  launch the wrong copy, including `/Applications/Radix.app`.

When the test specifically requires LLDB, scheme launch arguments, sanitizers,
or other Xcode diagnostics, start the shared scheme from the command line
instead of clicking Xcode's Run button with Computer Use:

    xed -b Radix.xcodeproj
    xcrun xcdebug -s Radix -B -b

`xcdebug -B` performs the scheme's Build and Run action and attaches Xcode's
debugger; the `-b` options leave Xcode in the background.

Use small, focused Conventional Commits and Conventional Commit PR titles.

## Simplicity and Code Economy

- Prefer the smallest coherent implementation that preserves correctness, clarity, and performance.
- Reuse or extend an existing abstraction before adding another cache, helper, wrapper, state owner, or model field.
- Keep state at the narrowest layer that needs it; add model or persistence fields only for a concrete consumer.
- Consolidate mechanisms that enforce the same invariant, not those with merely similar shapes.
- Add the minimum high-signal tests needed to cover the behavior and distinct edge cases; avoid duplicating the same scenario across layers.
- Treat a focused change exceeding roughly 200 production lines or introducing several new types as a design-review trigger, not a hard limit.
- Before finishing, review the diff and touched code for redundant state, branches, abstractions, repeated work, duplicate tests, and opportunities to simplify data flow; avoid unrelated refactors.
- In performance-sensitive paths, look for repeated traversal, allocation, I/O, or main-actor work. Measure meaningful performance changes when practical, and do not add caching without evidence of repeated cost.
