# Scan Progress Accuracy Results

## Outcome

Radix's displayed full-scan progress now tracks elapsed work materially more
closely on a package-heavy scan, remains monotonic at both the estimator and UI
publication boundaries, preserves millisecond-scale cancellation termination,
stays inside the predeclared scan-speed gate, and retains result semantics.

The accepted implementation is intentionally work-based. Production code does
not use elapsed time, add a prewalk, read file contents, persist estimates, add a
cache, or increase the progress-event cadence. Elapsed time exists only in the
opt-in `RadixCoreTests` probe and is used retrospectively after a scan completes.

## Isolation and Scope

- Branch: `perf/scan-progress-accuracy`
- Worktree: `.build/worktrees/scan-progress-accuracy`
- Base: `main` at `53b203ada5897500c82b98f39c9a42d1712e0f01`
- The active `fix/incremental-fsevents-history` checkout and its uncommitted
  changes were not modified.
- The implementation plan was written before production edits in
  `SCAN_PROGRESS_ACCURACY_PLAN.md`.

## What Changed

### Six review findings closed

1. **Stale task-local snapshots:** scanner-owned base metrics now stay inside the
   progress coordinator. Summary workers receive a value snapshot and may report
   a current path or overlay only; they cannot write an old base snapshot back
   over newer canonical counters.
2. **Summary/ordinary overlap:** direct children transferred to an auto summary
   are tracked separately from the ordinary discovered/frontier population.
   Committed summary work records only additional descendants, so the direct
   children are never counted in both populations.
3. **Mixed package and auto-summary work:** registered active work, unregistered
   package estimates, and pending auto-summary represented entries are disjoint
   terms that are summed. The earlier `max` assumption could discard real
   remaining work when different summary kinds overlapped.
4. **Reused-entry stalls:** the production reused-entry path now resumes through
   the existing summary pool. Preloaded entries produce the same in-flight visit
   overlay as filesystem-enumerated entries without a second traversal.
5. **Cancellation measurement:** the opt-in probe waits until it has seen both
   active progress and an active summary worker, then measures from cancellation
   until the consumer has returned *and* all observed summary workers are
   quiescent. It no longer labels consumer detachment as producer shutdown.
6. **Fallback generation race:** the progress generation is restarted before
   replacement Foundation enumeration is made runnable, so a fast fallback
   worker cannot publish into the superseded generation.

Deterministic regressions cover every item above, including overlay-to-commit
continuity. The coordinator also clamps each same-operation UI publication to
the already displayed fraction. New paths and counters still publish, while a
regressing producer sample cannot move the visible percentage backward.

### Descendant-aware work cap

`ScanMetrics.recalculateProgress` retains recursively partitioned subtree weight
as its geometric estimate, but caps it with a disjoint work model built from
existing scan observations:

- ordinary completed items, enumerated directories, and remaining frontier;
- additional descendants committed by summaries;
- visited and estimated remaining work for active summaries;
- conservative estimates for packages not yet registered with the pool; and
- represented direct entries pending transfer to auto summaries.

A newly discovered package receives the summary pool's conservative 64-item
estimate until observations replace it. Summary visits use one unit from resume
through retry, active overlay, and commit. All updates remain O(1); the change
adds no filesystem calls, prewalk, result-sized allocation, cache, or event-rate
increase.

### Test-only measurement

`ProgressAccuracyProbeTests` remains opt-in and under `RadixCoreTests`. It now:

- measures `ScanProgressState`, including the coordinator's 100 ms latest-value
  throttle, rather than raw engine event density;
- uses `ContinuousClock` and exactly integrates the piecewise-held displayed
  curve against normalized elapsed time;
- reports time-weighted MAE/RMSE, signed bias, lead/lag, milestones, integer
  stalls, completion jump, finalization share, bounds, and monotonicity;
- preserves authoritative publication order when timestamps are equal;
- prints result counts, sizes, node count, a sorted category/path/message warning
  fingerprint, and the same tree-semantic fingerprint used by the benchmark; and
- measures active-worker cancellation through worker quiescence.

## Accuracy Measurements

Method:

- Release-optimized XCTest bundle;
- three warm samples per target before and after;
- actual coordinator-published progress values;
- piecewise-held time-weighted error;
- unchanged local filesystem during each comparison;
- medians reported below.

`/Applications` exercises package/atomic-summary-heavy behavior.

| UI-facing metric | Before | After | Change |
| --- | ---: | ---: | ---: |
| Time-weighted MAE | 0.321 | 0.233 | **-27.4%** |
| Time-weighted RMSE | 0.380 | 0.275 | **-27.8%** |
| Signed bias | +0.315 | +0.227 | **-28.0%** |
| Maximum lead | 0.639 | 0.486 | **-24.0%** |
| Maximum lag | -0.066 | -0.066 | effectively flat |
| Reported 25% at elapsed fraction | 0.076 | 0.076 | effectively flat |
| Reported 50% at elapsed fraction | 0.147 | 0.148 | effectively flat |
| Reported 75% at elapsed fraction | 0.147 | 0.367 | closer |
| Reported 90% at elapsed fraction | 0.365 | 0.684 | closer |
| Reported 95% at elapsed fraction | 0.602 | 0.979 | closer |
| Longest unchanged integer share | 0.392 | 0.204 | **-47.9%** |
| Monotonic violations | 0 | 0 | unchanged |

`/System/Library` is the ordinary wide/deep-tree counterexample.

| UI-facing metric | Before | After | Change |
| --- | ---: | ---: | ---: |
| Time-weighted MAE | 0.114 | 0.102 | **-10.5%** |
| Time-weighted RMSE | 0.143 | 0.131 | **-8.0%** |
| Signed bias | -0.045 | -0.046 | effectively flat |
| Maximum lead | 0.181 | 0.121 | **-33.0%** |
| Maximum lag | -0.325 | -0.309 | 0.016 less late |
| Longest unchanged integer share | 0.269 | 0.339 | +26.1% |
| Finalization elapsed share | 0.131 | 0.122 | workload-sensitive |
| Monotonic violations | 0 | 0 | unchanged |

The primary acceptance metric improved materially on `/Applications` and also
improved on the counterexample. `/System/Library`'s longest unchanged integer
percentage did worsen in these samples, which is recorded rather than presented
as a uniform win. The fixed 95...99% finalization mapping was left unchanged
because the smaller accounting correction passed the predeclared cross-target
integrated-error gate.

The earlier preliminary probe (before Phase 1) measured raw engine events and
reported a `/Applications` MAE around 0.362. Acceptance comparisons above use
only the stricter, UI-facing harness on both sides.

## Throughput and Result Correctness

Throughput was accepted from five interleaved pristine-`main`/final pairs per
target so cache and system-load changes affected the two variants locally:

| Metric | Pristine `main` | Final |
| --- | ---: | ---: |
| `/Applications` median elapsed | 1.381 s | 1.382 s (+0.1%) |
| `/Applications` median progress events | 55 | 55 |
| `/System/Library` median elapsed | 3.032 s | 3.023 s (-0.3%) |
| `/System/Library` median progress events | 4,000 | 4,000 |
| `/Applications` files | 353,823 | 353,823 |
| `/Applications` folders | 52 | 52 |
| `/Applications` nodes | 56 | 56 |
| `/Applications` warnings | 0 | 0 |
| `/Applications` allocated bytes | 38,128,799,744 | 38,128,799,744 |
| `/Applications` tree fingerprint | `3ab296b5e497068b` | `3ab296b5e497068b` |
| `/Applications` warning fingerprint | `a8c7f832281a39c5` | `a8c7f832281a39c5` |

Both elapsed medians stayed effectively flat, inside the plan's 5% rejection
threshold, with unchanged median event traffic. The supported conclusion is no
measured scan-speed or event-cadence regression, not a claimed speedup.

The `/System/Library` accuracy runs also retained identical results before and
after: 260,961 files, 68,915 folders, 223,619 nodes, 8 warnings,
10,061,148,160 allocated bytes, tree fingerprint `8a47056c50953e74`, and
category/path/message warning fingerprint `5942b118278a79eb`.

## Cancellation

The test-only cancellation probe waits for both progress and active summary work,
cancels the Release scan after the configured 150 ms minimum delay, and measures
until stream consumption has returned and all observed workers are quiescent.

| Metric | Before median | After median |
| --- | ---: | ---: |
| Worker shutdown latency | 0.856 ms | 0.657 ms |
| Samples observing active work before cancellation | 3 / 3 | 3 / 3 |
| Samples quiescing all observed workers | 3 / 3 | 3 / 3 |
| Samples emitting `.finished` after cancellation | 0 / 3 | 0 / 3 |

The final median is 0.199 ms faster and well inside the plan's 50 ms rejection
threshold; cancellation remains promptly responsive. Existing deterministic
traversal, wide-directory, package-summary, descriptor-pool, and stale-event
cancellation tests also pass.

## Automated Validation

- Focused estimator, overlay-to-commit, publication-order, cancellation, and
  fingerprint tests: passed.
- Full SwiftPM suite: 767 tests executed, 20 opt-in/filesystem skips, 0 failures.
- Complete Debug macOS app build: passed.
- Complete unsigned Release macOS app build: passed.
- `git diff --check`: passed.

## Release Exclusion

Source boundary:

- `Package.swift` keeps `RadixCoreTests` in a separate `.testTarget` at
  `path: "RadixCoreTests"`.
- The Xcode app target compiles production sources under `Radix/`; the generated
  Release `Radix.SwiftFileList` includes `ScanProgress.swift`, `ScanCoordinator.swift`,
  and `ScanEngine.swift`, but contains no `RadixCoreTests` or probe source.

Built-artifact boundary:

- recursive binary search of `Radix.app` found no
  `RADIX_PROGRESS_PROBE`, `RADIX_PROGRESS_ACCURACY_RESULT`,
  `RADIX_PROGRESS_CANCELLATION_RESULT`, or `ProgressAccuracyProbeTests`;
- `strings` over the Release executable found none of those tokens and no
  `XCTest` token;
- `otool -L` shows no XCTest/Testing dependency.

The opt-in measurement code is therefore present in Release-optimized test
bundles when explicitly requested, but absent from the Release application.

## Reproduction

```sh
rtk env RADIX_PROGRESS_PROBE=1 RADIX_PROGRESS_PROBE_PATH=/Applications \
  swift test -c release --filter ProgressAccuracyProbeTests/testProgressCurve

rtk env RADIX_PROGRESS_PROBE=1 RADIX_PROGRESS_PROBE_PATH=/System/Library \
  swift test -c release --filter ProgressAccuracyProbeTests/testProgressCurve

rtk env RADIX_PROGRESS_PROBE_CANCEL=1 RADIX_PROGRESS_PROBE_PATH=/Applications \
  swift test -c release --filter ProgressAccuracyProbeTests/testCancellationLatency

rtk env RADIX_BENCH=1 RADIX_BENCH_PATH=/Applications \
  swift test -c release --filter ScanBenchmarkTests/testRealWorldScanBenchmark
```
