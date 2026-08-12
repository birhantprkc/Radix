# File Browser Million-Node Performance Plan

## Objective

Measure and, only if the evidence supports it, improve File Browser responsiveness and memory use for a synthetic scan containing approximately one million nodes. The change must preserve File Browser query, sorting, display, and cancellation semantics. A production optimization is optional: if no dominant, worthwhile bottleneck is found, the benchmark and its evidence remain the deliverable.

## Scope and non-goals

This work is limited to the File Browser pipeline in:

- `Radix/Services/FileBrowserSearch.swift`
- `Radix/Services/FileBrowserResults.swift`
- `Radix/Services/FileBrowserDisplayState.swift`
- `Radix/Services/FileBrowserModel.swift`
- focused tests under `RadixCoreTests/`

Explicitly out of scope:

- Discard Pile behavior or visualization
- sidebar scan caching
- snapshot scoping or archive format work
- sunburst, treemap, or other chart filtering
- unrelated open issues or cleanup
- new dependencies
- speculative caches or persistent model state

The product guarantees remain unchanged: work that scales with scan size stays off the main actor except for the final publication boundary, cancellation remains prompt, files are never mutated, and File Browser results remain a primary navigation surface.

## Current pipeline and initial hypotheses

The existing entire-scan path is:

1. `FileBrowserModel` debounces and schedules an async search.
2. `FileSearchService` builds and retains one normalized metadata index per snapshot/tree content identity.
3. Each query scans that index, optionally normalizes paths lazily, materializes matching `FileNodeRecord` values, and sorts the result.
4. The model returns to the main actor and publishes a new `FileBrowserDisplayState`.
5. `FileBrowserDisplayState` deduplicates the result and constructs an ID-to-row-index dictionary.

The measurements will test, rather than assume, these candidate costs:

- cold normalization/index construction and its retained memory;
- linear warm scans for text, path, and metadata-only filters;
- temporary allocation and comparison cost when sorting a very large match set;
- main-actor deduplication/index-map construction for a very large published result;
- cancellation latency within index scans, filtering, and sorting.

## Benchmark design

### Location and opt-in gate

Add a dedicated `RadixCoreTests/FileBrowserBenchmarkTests.swift` file to the Swift Package test target. The benchmark will be skipped unless `RADIX_BENCH_FILE_BROWSER=1` is set. Production files will contain no benchmark environment variables, result logging, fixture generators, timers, RSS samplers, or benchmark-only conditionals.

The default fixture will contain one root plus 1,000 directories and 1,000 files per directory (1,001,001 total nodes). Environment overrides may reduce the fixture for benchmark development, but the recorded acceptance run must use the million-node default. The fixture will use the verified indexed `FileTreeStore` initializer so fixture setup does not add dictionary-based topology construction noise to the measured search phases.

File names, paths, types, sizes, and modification dates will be deterministic. Selected names and directory paths will create known sparse text/path matches, while a file-kind or size-only query will return a deliberately large result set.

### Timing method

Use `ContinuousClock` and report seconds with enough precision to compare repeated runs. Fixture construction is reported separately and excluded from query timings. Each warm phase will run multiple iterations in the same test process; the report will include individual samples plus median (and spread where practical), so a claimed improvement must exceed normal run-to-run variation.

Measure these phases:

1. **Fixture construction wall time** — build the synthetic nodes/topology and `FileTreeStore`; useful context, not a File Browser optimization target.
2. **Cold index construction** — time a fresh `FileSearchService` with a deterministic no-match text query and no sort. Because the production service intentionally keeps index construction private, also measure the identical warm no-match scan and report the cold-minus-warm delta as the index-construction estimate. Do not add a production benchmark hook merely to time the private helper.
3. **Warm text search** — repeat a normalized name/kind query against the retained index with a small known result set and no sort.
4. **Path search** — measure a path-only query whose name/kind check misses, including its first lazy path normalization pass, then repeat it warm to distinguish retained-path lookup from first-pass work.
5. **Filter-only large-result query** — run a metadata-only query returning most file nodes, initially with no sort, and record the exact result count.
6. **Sorting** — sort a pre-materialized large result set separately with the normal allocated-size order and deterministic fallback; report exact count and a result fingerprint so an optimization cannot silently change ordering.
7. **Main-actor result publication** — on `MainActor`, construct and assign the same `FileBrowserDisplayState` shape used by `FileBrowserModel`, recording the time and verifying row lookup/deduplication invariants. If necessary, a test-only `FileSearching` stub will isolate model publication from search work.
8. **Cancellation** — cancel active cold search/filter/sort work after it has started, measure wall time from cancellation request to task completion, require `CancellationError`, and verify no stale model result is published.
9. **End-to-end wall time** — measure an actual `FileBrowserModel` entire-scan request from query change through current-result publication for a representative large-result query.
10. **Peak RSS** — sample/report process resident memory before the fixture, after the fixture, after the retained search index, and at suite peak. Use Darwin process information from the test target only. Report absolute peak and deltas; treat values as process-level context rather than attributing every byte to one phase.

Every report line will use a stable `RADIX_FILE_BROWSER_BENCH_RESULT` prefix so before/after results can be extracted without including benchmark code in the app.

## Baseline and profiling procedure

1. Build and run the opt-in benchmark in the isolated worktree with a dedicated SwiftPM scratch path.
2. Run at least three full million-node samples when runtime permits; run additional repetitions of lower-variance warm phases within each sample.
3. Record wall time, phase medians, result counts/fingerprints, cancellation latency, and peak RSS.
4. Use the phase breakdown and, if needed, Instruments/`sample`-style stack evidence to identify the single dominant actionable bottleneck.
5. Separate fixture cost from product cost and separate one-time cold cost from repeated interaction cost.

No optimization will be selected from source inspection alone.

## Optimization decision gate

A production change is justified only when all of the following hold:

- one requested File Browser phase is clearly dominant or presents a concrete responsiveness/memory risk;
- the cost is in production code, not benchmark fixture setup;
- a small coherent change addresses that cost without a new speculative cache;
- repeated before/after samples show a meaningful improvement larger than observed noise;
- result counts, ordering fingerprints, lookup behavior, and cancellation behavior remain equivalent.

Prefer removing repeated traversal, avoidable allocation, or main-actor work over introducing another state owner. Change only the dominant mechanism. If the evidence is mixed or the improvement is marginal, revert the production experiment and keep the benchmark.

## Correctness and cancellation coverage

Add the minimum focused tests needed for the measured path and any chosen optimization. Expected coverage includes:

- text, path, and metadata-only queries preserve AND semantics and exact matches;
- large-result sorting preserves requested comparator order and deterministic name/ID fallback;
- display publication preserves input order after deduplication and correct ID lookup;
- cancellation during the affected long-running phase terminates promptly and cannot publish stale results;
- existing current-contents and entire-scan query behavior remains unchanged.

Avoid duplicating scenarios already covered by `FileBrowserModelTests`; new tests should specifically protect the optimized boundary or the benchmark's newly exposed cancellation risk.

## Validation and release isolation

Run, in order:

1. focused File Browser tests;
2. the opt-in million-node benchmark for final after-data;
3. `swift test` for the complete core suite;
4. the complete Debug app build required by `AGENTS.md`;
5. a Release app build;
6. binary/bundle inspection for `RADIX_BENCH_FILE_BROWSER`, `RADIX_FILE_BROWSER_BENCH_RESULT`, benchmark test class names, and fixture/RSS sampler symbols, requiring no matches in the Release app product;
7. `git diff --check`, focused diff review, and status checks in both the worktree and canonical checkout.

The final report will distinguish measured baseline, measured after-state, local validation, Release benchmark-code exclusion, and any work not performed. It will not claim release readiness beyond the evidence collected.
