# Scan Progress Accuracy Plan

## Objective

Make Radix's displayed full-scan percentage follow elapsed scan work more closely while preserving four hard guarantees:

1. the displayed percentage never moves backward during one scan operation;
2. stopping a scan remains promptly cancellation-responsive;
3. scan throughput does not materially regress;
4. the resulting tree, aggregate counts, warnings, sizes, and ordering remain unchanged.

This work is isolated on `perf/scan-progress-accuracy` at baseline commit
`53b203ada5897500c82b98f39c9a42d1712e0f01`, in
`.build/worktrees/scan-progress-accuracy`. The active
`fix/incremental-fsevents-history` checkout and its uncommitted changes are out of
scope.

## Scope

In scope:

- full-scan progress estimation in `ScanMetrics`, `ScanEngine`, and the atomic
  summary progress coordinator;
- the `ScanCoordinator` publication boundary if a same-operation monotonic clamp
  is needed for the actual UI-facing value;
- focused unit/integration tests for progress, completion, and cancellation;
- opt-in measurement code in `RadixCoreTests` only;
- Debug and Release build/artifact verification.

Out of scope:

- FSEvents and incremental-scan behavior, including the active incremental work;
- changing scan results, auto-summary eligibility, concurrency limits, or event
  cadence;
- prewalking the tree, reading file contents, persistent estimates, telemetry,
  caches, new dependencies, and unrelated performance work;
- redesigning the progress UI or adding user-facing text.

## Current Pipeline and Baseline

The engine emits `ScanMetrics` through an `AsyncThrowingStream`. Traversal events
are normally limited to roughly 150 ms, atomic-summary progress is merged under a
lock, and `ScanCoordinator` publishes the latest value on the main actor with a
100 ms throttle. `WorkspaceStateViews` renders that published
`progressFraction` directly.

The estimator currently:

- recursively divides geometric subtree weight, assigning a fixed 8x unit to a
  directory relative to a file;
- adds fractional progress for in-flight package/atomic summaries;
- caps geometric progress using discovered/completed item and frontier counts;
- exempts committed summary weight from that count cap;
- maps traversal to 0...95%, bottom-up assembly to 95...99%, and completion to
  100%;
- preserves monotonicity inside `ScanMetrics` with a progress floor.

Three warm Release probe runs against `/Applications` produced the following
baseline. Accuracy is measured against elapsed wall time only after the scan has
completed; elapsed time is the best observable proxy for real completed work and
does not drive production progress.

| Metric | Baseline |
| --- | ---: |
| Total elapsed, median | 1.405 s |
| Time-integrated absolute error, median | 0.362 |
| Time-integrated RMSE, median | 0.416 |
| Signed time-integrated bias, median | +0.360 |
| Maximum lead | 0.651...0.660 |
| Reported 50% at elapsed fraction | 0.084...0.094 |
| Monotonic violations | 0 |
| Result files / folders | 353,234 / 52 |

The corresponding three warm Release scan benchmarks took 1.436 s, 1.780 s,
and 1.604 s (median 1.604 s), all with 56 nodes, no warnings, 37,941,534,720
allocated bytes, and fingerprint `a4f0f5f526a65c7b`.

The dominant observed defect is a strongly early curve on package-heavy scans:
packages receive similar sibling weight even when their descendant work differs
greatly, committed summary weight bypasses the item cap, and the UI can sit near
95% while the last large package is still being summarized. Separate audits also
identified two secondary estimator mismatches: successful directory
enumeration/classification receives no completed weight, and bottom-up assembly
is represented by a fixed four-point span even when it is a larger share of
elapsed work.

## Measurement Design

Extend the existing opt-in `ProgressAccuracyProbeTests` harness rather than add
production diagnostics. Keep it gated by `RADIX_PROGRESS_PROBE=1` and located
only in `RadixCoreTests`.

For each real-path sample, record:

- continuous elapsed time and reported fraction for every progress event;
- actual UI-facing samples after the same main-actor publication path and
  throttle, or an equivalent explicitly labelled engine curve when measuring
  the estimator alone;
- time-integrated absolute error (area between held reported fraction and
  normalized elapsed time);
- time-integrated RMSE and signed bias;
- maximum lead and lag;
- elapsed fraction when displayed progress first reaches 25%, 50%, 75%, 90%,
  and 95%;
- monotonic violations, longest progress-update gap, and the traversal-to-
  finalization transition;
- elapsed time, result counts, warning count, allocated size, node count, and a
  deterministic result fingerprint.

Use at least two materially different stable local targets:

- `/Applications` for package/atomic-summary-heavy behavior;
- `/System/Library` for a wide/deep ordinary-tree counterexample.

Use `/usr` only as a quick development signal because its sub-second runtime is
too noisy for a release claim. Run three warm Release samples for accepted
before/after comparisons and compare medians. Capture cold build time separately
and never include it in scan timing.

Add a separate opt-in cancellation measurement that starts a real scan, waits
until active progress is observed, cancels the consuming task, and measures time
until the stream terminates. Keep deterministic cancellation unit tests as the
correctness gate; use the real-path result as a regression signal rather than a
fragile absolute test assertion.

## Implementation Strategy and Decision Gates

### Post-implementation review remediation

A second review of the accepted four-commit range identified four additional
edge conditions. Address them before treating the branch as merge-ready:

1. Preserve the reused-immediate-entry path's metadata fallback semantics when
   routing work through the summary pool. An entry whose prefetched metadata is
   unavailable must still receive the same one-time metadata reload and warning
   behavior as before the pool integration.
2. Put a package selected as the scan root into the same pending/active summary
   accounting as a package discovered under an enumerated parent, so summary-only
   scans do not bypass the work cap or jump directly to completion.
3. Make the cancellation probe observe completed pool shutdown, not a transient
   zero-active-lease interval between descendant or fallback leases.
4. Fingerprint warning fields independently and record both ordered and
   order-independent warning signatures, avoiding delimiter collisions while
   keeping warning-order changes observable.

Add focused regressions for missing prefetched metadata, package-root progress,
fallback/descendant worker gaps, and delimiter/order-sensitive warning sets.
After these fixes, repeat the full suite, Debug and unsigned Release builds,
Release-artifact exclusion checks, semantic benchmarks, and a fresh review of
the complete branch diff.

### Final full-branch review remediation

The fresh review after the four edge-condition fixes identified two bounded
cleanup items before final validation:

1. Bound the cancellation probe's wait for stream termination and pool shutdown
   with one deadline. A cancellation regression must fail the opt-in probe
   promptly instead of hanging the test process indefinitely.
2. Make the pool's shutdown notification exactly-once even if cleanup is invoked
   redundantly or success/cancellation cleanup races. Add a deterministic
   lifecycle assertion for this contract.

Afterward, regenerate the result evidence so the documented test count,
cancellation fields, and length-prefixed warning fingerprints describe the
reviewed branch rather than the preceding checkpoint.

### Review remediation before acceptance

The first implementation pass is not merge-ready until the six code-review
findings are resolved. The remediation will be split into logical checkpoints:

1. Make scanner-owned base metrics immutable to worker-side progress reporting.
   Summary workers may publish path and overlay deltas, but may not replace or
   receive the scanner's canonical counters.
2. Make work-count populations disjoint. Track transferred direct children for
   auto summaries, distinguish registered package work from queued packages,
   subtract represented direct entries from committed summary descendants, and
   sum active and unregistered remaining work instead of combining them with
   `max`.
3. Route the reused-immediate-entry production path through the existing summary
   pool so it reports in-flight visits without a second filesystem traversal.
4. Advance the progress generation before restarted Foundation work becomes
   runnable.
5. Upgrade the cancellation probe to wait for observed summary-worker activity
   and worker quiescence after cancellation; label the measured interval
   accordingly rather than treating consumer detachment as producer shutdown.
6. Add deterministic regressions for stale base snapshots, auto-summary overlap,
   mixed package/auto-summary work, reused-entry progress, fallback ordering, and
   overlay-to-commit continuity before re-running real-path measurements.

Each production checkpoint must pass its focused tests before commit. The final
checkpoint must pass the full suite, Debug and unsigned Release app builds,
Release-artifact exclusion checks, semantic fingerprints, throughput gates, and
the two-target accuracy comparison.

### Phase 1: Make the probe quantitative

1. Replace `Date` timing in the test-only probe with `ContinuousClock`.
2. Compute and print one machine-readable summary per run while retaining raw
   samples behind an opt-in verbose flag.
3. Include semantic result fields and cancellation timing so one harness can
   compare accuracy, speed, cancellation, and correctness.
4. Re-run the untouched baseline on both primary targets before production edits.

Gate: do not modify production estimation until the baseline is reproducible and
the metric distinguishes the observed early `/Applications` curve from a
reasonably tracking curve.

### Phase 2: Correct the demonstrated estimator defect

Start with the smallest O(1)-per-event change supported by measurements:

1. make summary progress participate in a work-count estimate using counters
   already collected by the scanner (`filesVisited`, `directoriesVisited`,
   atomic-summary visited work, known discovered items, frontier estimates, and
   atomic-summary estimated remaining work), rather than allowing committed
   summary weight to bypass the cap wholesale;
2. retain geometric subtree weight as a complementary upper bound and retain the
   monotonic floor;
3. preserve the existing 95% per-job ceiling until a summary commits, so unknown
   work cannot report completion;
4. avoid extra filesystem calls, traversals, allocations proportional to result
   size, and extra progress emissions.

If that isolated change does not improve the median accuracy metric on both
primary targets, evaluate at most these bounded alternatives, one at a time:

- reserve a small, measured portion of each directory's weight for its completed
  enumeration/classification work before splitting the remainder among children;
- calibrate finalization using existing node/edge work counts and explicit tail
  stages instead of a fixed 95...99% mapping.

Discard any alternative that improves one fixture by making the other
materially worse, adds time-driven fake progress, needs a prewalk/cache, or costs
more than the accepted throughput budget.

### Phase 3: Enforce displayed monotonicity

Add a narrow same-operation clamp at the `ScanCoordinator` publication boundary
only if tests show the UI can receive a regressing value. The clamp must not
retain events from stale operation IDs, delay cancellation, or touch the
incremental-to-full-fallback policy in this change.

### Phase 4: Focused correctness and cancellation tests

Add the minimum high-signal coverage for:

- summary-heavy work no longer advancing far ahead of known completed work;
- progress remains within 0...1, monotonic, and reaches exactly 1 only on
  completion;
- atomic-summary overlay-to-commit transitions do not double-count or regress;
- finalization remains monotonic if its mapping changes;
- coordinator publication does not regress within one full-scan operation, if
  the boundary clamp is implemented;
- cancellation during traversal, atomic summary work, and finalization still
  terminates promptly;
- fixture result topology, counts, sizes, warnings, and fingerprint are
  unchanged.

## Acceptance Criteria

Accuracy:

- median time-integrated absolute error improves materially on `/Applications`
  (target at least 25% relative improvement from 0.362);
- maximum lead on `/Applications` is materially lower than the 0.651...0.660
  baseline;
- `/System/Library` median integrated error does not regress by more than 10%
  relative or 0.02 absolute, whichever allowance is larger;
- all displayed samples are monotonic and terminal progress is exactly 1.0.

Performance and cancellation:

- median Release scan elapsed time on each primary target does not regress by
  more than 5%; values inside normal baseline spread are treated as noise;
- no increase in production progress-event cadence;
- cancellation latency remains within baseline noise and deterministic
  cancellation tests pass; any repeatable regression over 50 ms requires
  rejection or redesign.

Correctness:

- before/after result fingerprint, node count, file/folder counts, allocated
  size, and warnings match for each unchanged real target;
- focused progress and scan tests pass;
- the full SwiftPM test suite passes;
- the complete Debug and Release macOS app builds pass.

Code economy:

- prefer a change confined to the existing progress model/coordinator;
- no new cache, dependency, persistent model field, or second estimator owner;
- review the final diff for duplicate state, repeated calculations, and obsolete
  tests/comments.

## Release-Exclusion Verification

All measurement code must remain under `RadixCoreTests`, which is a separate
SwiftPM `.testTarget` and is not part of the Xcode app target. After the Release
app build:

1. inspect `Package.swift` and the Xcode target source membership;
2. search the Release app bundle and executable for probe class names, gate
   strings (`RADIX_PROGRESS_PROBE`, cancellation/verbose variants), and output
   prefixes;
3. inspect the Release Swift source file list to confirm that no
   `RadixCoreTests` source is compiled;
4. report source-boundary and built-artifact evidence separately.

## Planned Validation Commands

Run all commands from the isolated worktree and with the repository-required
`rtk` prefix.

```sh
rtk env RADIX_PROGRESS_PROBE=1 RADIX_PROGRESS_PROBE_PATH=/Applications \
  swift test -c release --filter ProgressAccuracyProbeTests/testProgressCurve

rtk env RADIX_PROGRESS_PROBE=1 RADIX_PROGRESS_PROBE_PATH=/System/Library \
  swift test -c release --filter ProgressAccuracyProbeTests/testProgressCurve

rtk env RADIX_BENCH=1 RADIX_BENCH_PATH=/Applications \
  swift test -c release --filter ScanBenchmarkTests/testRealWorldScanBenchmark

rtk swift test --filter ScanEngineTests
rtk swift test --filter ScanCoordinatorTests
rtk swift test

rtk xcodebuild -project Radix.xcodeproj -scheme Radix \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/xcode-derived-data build

rtk xcodebuild -project Radix.xcodeproj -scheme Radix \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath .build/xcode-derived-data-release build
```

## Deliverables

- this plan, written before production edits;
- quantitative baseline and after-change results in a companion Markdown report;
- a small measured production change, if and only if it passes the gates above;
- focused regression tests and the improved opt-in test-only probe;
- Debug/Release, full-suite, result-correctness, cancellation, and Release-
  exclusion evidence.
