# Result Finalization Invariants Plan

## Objective

Correct the scoped tree-removal finalization and File Browser result projection
without changing their ordering semantics, adding persistent state, or weakening
cancellation. Preserve the measured large-result sorting design and keep all
benchmark code in the test target.

## Scope

Production files:

- `Radix/Models/FileTreeStore.swift`
- `Radix/Services/FileBrowserResults.swift`

Focused tests:

- `RadixCoreTests/FileTreeStoreTests.swift`
- `RadixCoreTests/FileBrowserModelTests.swift`

Benchmark harness:

- `RadixCoreTests/FileBrowserBenchmarkTests.swift`

No user-facing text, dependencies, archive formats, or unrelated scanner,
visualization, navigation, and search behavior will change.

## Required behavior

### Scoped tree removal

1. If repairing an affected directory changes child display order, the compact
   topology's preorder must be rebuilt from the final child indices.
2. Aggregate accessibility counts must describe the repaired records, including
   ancestors that become accessible after their last inaccessible descendant is
   removed.
3. Repairing a wide directory must check cancellation while reading surviving
   child records and must not allocate an unnecessary `[FileNodeRecord]` copy.
4. Direct logical-scope removal must remain equivalent to materializing the
   scope first and then removing the same subtree.

### File Browser results

1. Converting sorted prepared rows back to `[FileNodeRecord]` must check
   cancellation at a bounded interval.
2. Sort order, deterministic fallback behavior, and result counts must remain
   unchanged.
3. Convenience entry points must not silently swallow future internal errors.
   Use `rethrows` through the cancellation-aware helper chain while preserving
   nonthrowing wrappers for ordinary synchronous callers.

## Implementation approach

### FileTreeStore

1. Add regression tests that fail on the current scoped-removal fast path:
   - a no-hard-link tree whose repaired child changes root ordering;
   - removal of the only inaccessible descendant;
   - a wide affected directory whose repair phase demonstrably performs
     periodic cancellation checks.
2. During affected-directory repair, accumulate `MaterializedDirectoryTotals`
   directly from child indices with a check every 256 children.
3. Update aggregate accessibility accounting when a repaired directory's
   accessibility changes. Keep file/directory counts derived from surviving
   membership and total sizes derived from the repaired root.
4. Track whether any child slice actually changes. Recompute preorder from the
   final compact child topology only when needed, using the existing cancellable
   preorder helper.
5. Add a final cancellation check before publishing the compacted store.

### FileBrowserResults

1. Replace the final `map(\.node)` with a reserved-capacity projection loop that
   checks cancellation every 256 rows.
2. Add a deterministic cancellation probe that throws during this projection,
   after preparation and sorting have completed.
3. Convert the cancellation-aware helper chain to `rethrows`. Retain the two
   nonthrowing wrappers because Swift treats an omitted default throwing closure
   as potentially throwing, but remove their `try?` fallbacks so errors cannot
   be silently swallowed.
4. Preserve the current 16,384-row direct-sort/run boundary and merge algorithm.

## Validation

Run in this worktree:

1. `rtk swift test --filter FileTreeStoreTests`
2. `rtk swift test --filter FileBrowserModelTests`
3. `rtk swift test`
4. `rtk xcodebuild -project Radix.xcodeproj -scheme Radix -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/xcode-derived-data build`
5. The opt-in logical-scope tree-removal benchmark, with and without hard links.
6. The opt-in million-node File Browser benchmark in Release configuration.
7. `rtk git diff --check` and a final diff audit for redundant passes, allocations,
   state, abstractions, and duplicated tests.

## Acceptance criteria

- Scoped `childIDs` and `indexedNodeIDs` represent the same final preorder.
- Scoped accessibility totals equal the final records and their sum equals
  `nodeCount`.
- Cancellation is observed during wide directory repair and final File Browser
  projection at no more than the established 256-row interval.
- Existing sort fingerprints, counts, and comparator behavior are unchanged.
- Focused tests, the full Swift package suite, and the complete Debug app build
  pass.
- Benchmarks show no meaningful throughput or peak-RSS regression; cancellation
  does not regress.
- The final change is split into focused Conventional Commits.
