# Full-Disk Scan Scaling Results

## Outcome

The Release matrix demonstrated one production defect that clearly exceeded the
noise threshold: cancellation could deadlock when concurrent atomic-summary
workers published progress while the stream consumer was being cancelled. The
fix moves stream publication off the progress-coordinator lock while preserving
publication order. The previously stalled scenario now cancels in milliseconds,
and all 45 post-fix matrix samples completed their cancellation checks.

No scan-throughput optimization was retained. Time Profiler showed exclusion
matching in the representative no-match arm, but its repeated wall-time cost was
only about 2–4% on the stable `/Applications` corpus and overlapped the measured
noise in three of four representation arms. That is not strong enough evidence
for another production change.

## Environment and method

- Base: `origin/main` at `3aa59cfb3d7659a2f229ee2d7028138ba0c0a738`
- Branch: `perf/full-disk-scan-scaling`
- Host: Apple M5 MacBook Air, 10 cores, 32 GB RAM
- Software: macOS 26.6.1 (25G76), Xcode 26.6 (17F113), Swift 6.3.3
- Build: SwiftPM Release test bundle, invoked as a fresh `xctest` process for
  each scenario
- Sampling: three interleaved rounds per completed scenario; 5 ms resident
  memory sampling; process `getrusage` CPU deltas
- Bounded factorial: all 12 combinations on `/Applications`
- Full disk: collapsed packages + automatic summarization with none, no-match,
  and common exclusions on `/`, explicitly authorized with
  `RADIX_BENCH_FULL_SCAN_ALLOW_ROOT=1`
- Cancellation: a separate scan per sample, cancelled after 150 ms on
  `/Applications` and 250 ms on `/`; latency ends only after the stream and
  summary-worker pool terminate

The first `/` `expanded-manual-none` feasibility run exceeded ten minutes and
was terminated. It produced no finished snapshot and left no scanner process
behind. Repeating an arm already shown to be nonviable would have added thermal
and memory pressure without useful precision, so the full 12-arm factorial was
bounded to `/Applications`.

## Stable factorial results

Medians of three interleaved `/Applications` runs are below. RSS uses decimal GB
for compactness. “Observed” combines ordinary discovered work with additional
summary work; “metadata” is files visited plus directories visited. This is the
Release scanner's post-filter work count, not a raw count of every native
directory entry returned before exclusions are applied.

| Scenario | Wall s | User / system CPU s | Peak RSS GB | Observed | Retained | Metadata | Dir enumerations | Cancel ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| collapsed-auto-none | 1.413 | 2.396 / 5.860 | 0.136 | 423,261 | 63 | 354,648 | 5 | 2.60 |
| collapsed-auto-no-match | 1.468 | 3.324 / 5.607 | 0.137 | 423,261 | 63 | 354,648 | 5 | 2.71 |
| collapsed-auto-common | 1.362 | 2.702 / 5.818 | 0.136 | 416,183 | 61 | 348,762 | 5 | 2.47 |
| collapsed-manual-none | 1.377 | 2.405 / 5.892 | 0.134 | 423,261 | 63 | 354,648 | 5 | 2.82 |
| collapsed-manual-no-match | 1.425 | 3.254 / 5.708 | 0.135 | 423,261 | 63 | 354,648 | 5 | 2.83 |
| collapsed-manual-common | 1.362 | 2.701 / 5.656 | 0.134 | 416,183 | 61 | 348,762 | 5 | 2.50 |
| expanded-auto-none | 2.727 | 4.313 / 5.149 | 0.848 | 423,261 | 423,247 | 411,018 | 56,422 | 8.14 |
| expanded-auto-no-match | 2.791 | 4.704 / 5.120 | 0.849 | 423,261 | 423,247 | 411,018 | 56,422 | 8.16 |
| expanded-auto-common | 2.693 | 4.077 / 5.019 | 0.838 | 416,151 | 416,137 | 403,915 | 55,205 | 9.55 |
| expanded-manual-none | 2.644 | 3.854 / 4.987 | 0.847 | 423,261 | 423,261 | 411,025 | 56,429 | 8.14 |
| expanded-manual-no-match | 2.717 | 4.125 / 4.847 | 0.848 | 423,261 | 423,261 | 411,025 | 56,429 | 8.07 |
| expanded-manual-common | 2.549 | 3.561 / 4.913 | 0.838 | 416,151 | 416,151 | 403,922 | 55,212 | 8.14 |

### Setting overhead versus reduced scan volume

- The strict none/no-match controls have identical observed work, retained
  nodes, warning sets, aggregates, and representation-neutral semantic
  fingerprints on `/Applications`.
- No-match median wall overhead is +3.92% collapsed-auto, +3.51%
  collapsed-manual, +2.35% expanded-auto, and +2.76% expanded-manual. The
  baseline relative-spread gates are 3.00%, 4.60%, 3.00%, and 3.00%,
  respectively. Only collapsed-auto narrowly clears its timing gate, and the
  other three do not; this is not a robust cross-arm throughput target.
- The common patterns reduce observed work by about 1.7% on this corpus. Their
  lower times are therefore a change in data scanned, not lower per-item
  scanner overhead.
- Package expansion is the dominant bounded-corpus scaling cost: retained nodes
  rise from 63 to roughly 423,000, peak RSS from about 0.135 GB to 0.848 GB, and
  wall time from roughly 1.4 s to 2.6–2.7 s.
- Automatic summarization has little effect on this corpus. With expanded
  packages it retained only 14 fewer nodes; with collapsed packages it did not
  select an additional ordinary directory.

## Full-disk scaling envelope

Medians of three interleaved `/` runs:

| Scenario | Wall s | User / system CPU s | Current / peak RSS GB | Observed | Retained | Metadata | Dir enumerations | Warnings | Cancel ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| collapsed-auto-none | 27.83 | 37.42 / 62.36 | 3.31 / 4.30 | 3,230,165 | 2,507,573 | 2,980,219 | 349,206 | 470 | 4.71 |
| collapsed-auto-no-match | 29.77 | 43.80 / 61.43 | 4.30 / 4.33 | 3,230,165 | 2,507,573 | 2,980,219 | 349,206 | 470 | 5.45 |
| collapsed-auto-common | 22.04 | 26.40 / 42.91 | 3.19 / 3.19 | 2,582,787 | 1,869,186 | 2,354,365 | 277,669 | 470 | 6.26 |

The none arm's min/median/max wall times were 26.74/27.83/28.32 s (5.70%
relative spread). No-match was 27.21/29.77/31.03 s (12.83% spread), so its
+6.98% median overhead does not clear the full-disk noise gate. Common
exclusions reduce observed work by about 20.0%, retained nodes by about 25.5%,
and peak RSS by about 25.8%; that is a data-volume effect.

The live root changed while the matrix ran. Warning-set fingerprints remained
stable, and work counts were nearly stable, but content and exact-tree
fingerprints changed between samples. `/Applications` is therefore the strict
same-semantics setting-overhead control; `/` is the real multi-million-node
resource envelope.

The earlier single full-disk feasibility sample took 61.91 s and peaked at
3.84 GB while observing 3.24 million items. It preceded cache warming and the
post-fix interleaved matrix, so the later 27.83 s median is not attributed to
the cancellation fix.

## Demonstrated cancellation defect and fix

The pre-fix `/Applications` matrix completed six arms, then
`collapsed-manual-none` stopped making progress. Sampling the process showed a
three-lock cycle:

1. a summary worker held the progress-coordinator lock and entered
   `AsyncThrowingStream.Continuation.yield`;
2. cancellation held Swift's task-status lock and waited for the summary pool;
3. another pool worker held the pool condition and waited for the progress
   lock.

`AtomicSummaryProgressCoordinator` now queues stream publications on a serial
dispatch queue, releases its own lock before publication, and flushes queued
events at scanner-controlled ordering and shutdown boundaries. This removes the
cycle without changing scanner data or adding telemetry.

The exact formerly stalled Release scenario completed after the fix and its
cancellation path terminated in 2.50 ms. The focused regression repeats a
concurrent package-summary cancellation eight times with a two-second deadline.
Across the 36 bounded and 9 full-disk post-fix samples there were zero stream,
pool-shutdown, worker-quiescence, unexpected-error, or post-cancel-finished
failures.

## Profile evidence and no-throughput-change decision

The profiled process was the actual Release `xctest` binary running
`collapsed-auto-no-match` on `/Applications`, with cancellation disabled. It
completed in 1.98 s under Instruments. Of 2,469 exported Time Profiler rows:

- 2,344 included the atomic-summary pool worker closure;
- 1,991 included pooled summary-item processing;
- 489 included bulk-entry materialization;
- 412 included entry staging;
- 128 included `PatternMatcher.matches` (~5.2% inclusive);
- 112 included basename matching and 21 included general glob matching.

Self cost was dominated by allocation/free, retain/release, URL/String work,
copying, and Foundation path validation. The profile confirms exclusion-setting
overhead but not a large isolated matcher bottleneck. Because the stable matrix
does not show a repeatable improvement opportunity beyond noise, no matcher,
metadata, traversal, retention, or caching change was made.

## Semantic fingerprints

- Collapsed `/Applications` none/no-match pairs have identical
  representation-neutral and exact-tree fingerprints.
- Expanded runs have stable representation-neutral content fingerprints and
  aggregate counts, but some exact-tree fingerprints and package-node counts
  vary. `PackageClassifier` intentionally caches one Foundation package
  decision per ambiguous extension, so parallel first-observation order can
  select a different cached classification for mixed directories sharing an
  extension. Existing tests explicitly cover that policy. This is surfaced as
  a semantic-stability follow-up, not changed in a scan-scaling branch.
- Full-disk warning-set fingerprints were stable; warning-order fingerprints
  varied as expected under parallel discovery.

## Reproduction

The committed benchmark defaults to `/Applications`, matching the existing
real-world scan benchmark:

```sh
RADIX_BENCH_FULL_SCAN_SCALING=1 \
rtk swift test -c release \
  --filter FullDiskScanScalingBenchmarkTests/testFullDiskScanScalingBenchmark
```

Select a matrix arm with `RADIX_BENCH_FULL_SCAN_SCENARIO`. A startup-volume run
must provide both the path and its explicit safety authorization:

```sh
RADIX_BENCH_FULL_SCAN_SCALING=1 \
RADIX_BENCH_FULL_SCAN_PATH=/ \
RADIX_BENCH_FULL_SCAN_ALLOW_ROOT=1 \
RADIX_BENCH_FULL_SCAN_SCENARIO=collapsed-auto-none \
rtk swift test -c release \
  --filter FullDiskScanScalingBenchmarkTests/testFullDiskScanScalingBenchmark
```

Package-expanded startup-volume scenarios additionally require
`RADIX_BENCH_FULL_SCAN_ALLOW_EXPANDED_ROOT=1`. The plan, raw JSONL samples,
one-off matrix runner, and analysis script were measurement artifacts and are
deliberately not part of the committed benchmark.

## Validation

- Focused benchmark-support, exclusion, package-classifier, and all 111
  `ScanEngineTests`: passed.
- Full `swift test`: 793 tests passed, 24 opt-in benchmarks skipped, zero
  failures.
- Deterministic Debug app build: passed.
- Deterministic Release app build: passed.
- Exact Release-bundle search for the benchmark class, opt-in environment name,
  result marker, and test method: no matches.
