# File Browser Million-Node Benchmark Results

## Environment

- Source baseline: `fbda1505c81a7582ff600a2f66df498fcae2b09b`
- Hardware: Apple M5 MacBook Air, 10 cores, 32 GB memory
- OS: macOS 26.6.1 (25G76)
- Toolchain: Xcode 26.6 (17F113), Apple Swift 6.3.3
- Build: SwiftPM `release`
- Fixture: 1,000 directories × 1,000 files plus the root (1,001,001 nodes)
- Warm iterations per process: 3

The baseline used the unmodified production sources from `main` plus the same test-only benchmark file. Three full-process samples were collected before the production change and three after it. Values below are medians unless noted. RSS is process-wide peak RSS, not an attribution of every resident byte to File Browser.

## Reproduction

```sh
rtk env RADIX_BENCH_FILE_BROWSER=1 swift test -c release \
  --filter FileBrowserBenchmarkTests/testMillionNodeFileBrowserBenchmark
```

Optional fixture and iteration overrides:

- `RADIX_BENCH_FILE_BROWSER_DIRECTORIES`
- `RADIX_BENCH_FILE_BROWSER_FILES_PER_DIRECTORY`
- `RADIX_BENCH_FILE_BROWSER_WARM_ITERATIONS`

The benchmark emits stable `RADIX_FILE_BROWSER_BENCH_RESULT` lines for extraction.

## Timing results

| Phase | Baseline | Optimized | Change | Interpretation |
| --- | ---: | ---: | ---: | --- |
| Cold index construction estimate | 1.382 s | 1.408 s | +1.9% | Unchanged production path; within cross-run drift. |
| Warm text search | 0.303 s | 0.311 s | +2.5% | Unchanged production path; within cross-run drift. |
| First path search | 2.658 s | 2.699 s | +1.6% | Unchanged production path; includes lazy path normalization. |
| Warm path search | 1.329 s | 1.411 s | +6.2% | Unchanged production path; later runs were consistently warmer/slower, so no causal claim. |
| Filter-only, 1,000,000 results | 0.191 s | 0.197 s | +2.9% | Unchanged production path; within baseline measurement spread. |
| Allocated-size sort, 1,000,000 results | 3.048 s | 2.793 s | **−8.4%** | Meaningful improvement beyond the approximately 3% baseline spread. |
| Main-actor publication, 1,000,000 results | 0.283 s | 0.261 s | −7.8% | Corrected harness includes the synchronous `@Published` replacement and notification; three-process spreads overlap, so no speedup or regression is claimed. |
| Cold end-to-end model request | 5.024 s | 4.934 s | −1.8% | Within noise; not claimed as an end-to-end speedup. |
| Cancellation during active sort | 1.348 s | 0.092 s | **−93.2%** | Corrected three-process harness medians; every run threw `CancellationError` after the request rather than merely returning normally. |

Cold-search cancellation completed in sub-millisecond time after the request in both versions. The result count remained exactly 1,000,000 for the large filter and sort phases, and the before/after ordering fingerprint remained `8f64003a74b8684` in every full run.

The publication and cancellation rows were refreshed after review with three new full processes per version and a byte-identical benchmark harness. Other rows retain the original acceptance samples. The refreshed ordering check validates the complete descriptor order plus deterministic name/ID fallback across every adjacent result, including ties spanning sorted runs.

## Peak RSS results

- Peak RSS at completion of the measured sort fell from a 2,034.97 MiB baseline median to 1,946.66 MiB: **88.31 MiB lower (4.3%)**.
- Relative to the preceding filter phase, the sort raised process peak RSS by 473.27 MiB before and 384.94 MiB after: **88.33 MiB less incremental peak growth (18.7%)**.
- Fixture construction itself raised peak RSS by about 823 MiB, and the retained search index added about 108 MiB. These are reported to keep fixture/search memory visible, but fixture allocation is not a production File Browser optimization target.
- The benchmark reports suite peak RSS as well. Because cancellation placement deliberately differs from the earlier provisional harness and process allocators retain freed pages, phase-aligned sort peak is the primary before/after memory comparison.

## Bottleneck and accepted change

Large-result sorting was the dominant actionable phase: approximately 3.05 seconds, versus 2.66 seconds for first-time path search, 1.38 seconds for cold index construction, and 0.25 seconds for main-actor publication.

The accepted production change is limited to sorting:

1. Prepare localized item-kind text and displayed descendant counts only when an active sort descriptor needs them. No cache or persisted state was added.
2. Sort bounded 16,384-row runs, then merge them through two reusable contiguous buffers with cancellation checks every 256 output rows.

The bounded runs avoid Swift's prior multi-second non-cancellable monolithic sort. Smaller 8,192-row runs reduced throughput without improving measured cancellation; larger 65,536-row runs were faster but increased the observed cancellation bound. A pairwise chunk-merge prototype improved cancellation but materially increased peak RSS, and a heap-based merge removed that memory spike but erased the speed improvement; both prototypes were discarded.

## Validation summary

- Focused `FileBrowserModelTests`: 40 passed, 0 failed.
- Complete `swift test`: 747 passed, 19 opt-in benchmarks skipped, 0 failed.
- Complete Debug app build: passed.
- Complete Release app build: passed.
- Release bundle, executable, and Swift source list searches found no `RADIX_BENCH_FILE_BROWSER`, `RADIX_FILE_BROWSER_BENCH_RESULT`, `FileBrowserBenchmarkTests`, `FileBrowserPublicationProbe`, test-target path, or benchmark-named file.
- No Discard Pile, sidebar scan caching, snapshot scoping, chart filtering, localization, archive, or unrelated production files were changed.
