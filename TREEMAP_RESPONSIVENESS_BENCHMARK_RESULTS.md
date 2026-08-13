# Treemap Responsiveness Benchmark Results

## Scope and setup

The opt-in Release benchmark ran from the isolated
`perf/treemap-responsiveness` worktree on an Apple M5 MacBook Air (10 cores,
32 GB), macOS 26.6.1 (25G76), Xcode 26.6 (17F113), and Apple Swift 6.3.3.
The branch was created from `main` at
`53b203ada5897500c82b98f39c9a42d1712e0f01`. The current production diff has
SHA-256
`70669136367e81f2d8d781a07f7123c6d047351d136801ce681d38e78f42bb14`.
The table below retains the three-process medians from the final optimization
run. A subsequent current-source Release smoke run, after review cleanup,
preserved every fingerprint, count, cancellation outcome, and publication rule.

The deterministic fixtures cover:

- a 1,008,202-node scan: 200 directories × 5,000 files plus one dense
  8,000-file directory;
- a separate flat root with 50,000 equal-weight immediate files, which
  deterministically collapses to one aggregate tile;
- a 1,600 × 1,000 primary chart and 1,024 × 1,320 alternate aspect ratio;
- depth 3 for the million-node traversal and depth 1 for dense/flat layouts;
- 100,000 deterministic hit tests and 1,000 keyboard moves per aspect;
- bursts of six resize layouts and four semantic navigation layouts.

Benchmark code is confined to
`RadixCoreTests/TreemapResponsivenessBenchmarkTests.swift` and runs only when
`RADIX_BENCH_TREEMAP=1` is set. Measurements use `ContinuousClock`; each
cross-process sample below came from a fresh Release test process, and the
harness retains only scalar measurements between repetitions.

Reproduce with:

```sh
rtk env RADIX_BENCH_TREEMAP=1 swift test -c release \
  --filter TreemapResponsivenessBenchmarkTests/testLargeScanTreemapResponsivenessBenchmark
```

## Measurement gate

Three pre-change processes established the main baseline. The final medians
come from three fresh processes against the exact final production source. The
flat-root seam was added during final review; two pre-change processes on the
then-current source established its focused baseline before the retained-index
optimization, followed by the same three final processes.

| Phase | Baseline median | Final median | Change |
| --- | ---: | ---: | ---: |
| Million-node layout | 163.298 ms | 118.705 ms | 27.3% faster |
| Dense-folder layout/navigation | 19.782 ms | 14.759 ms | 25.4% faster |
| Flat 50,000-child root | 20.320 ms (2) | 8.303 ms (3) | 59.1% faster |
| Rapid resize, newest request | 168.561 ms | 131.594 ms | 21.9% faster |
| Rapid resize, full burst | 171.739 ms | 135.463 ms | 21.1% faster |
| Rapid semantic navigation, newest request | 25.333 ms | 19.082 ms | 24.7% faster |
| Rapid semantic navigation, full burst | 27.893 ms | 21.430 ms | 23.2% faster |
| Keyboard selection, wide, 1,000 moves | 2,596.756 ms | 163.892 ms | 93.7% faster |
| Keyboard selection, tall, 1,000 moves | 2,575.346 ms | 164.117 ms | 93.6% faster |
| Render-state publication/indexing | 9.568 ms | 9.182 ms | within noise |
| Hit testing, 100,000 points | 92.577 ms | 89.575 ms | within noise |
| Cancellation after request | 0.139 ms | 0.126 ms | already sub-millisecond |

The million-node layout peak-RSS increase after fixture construction fell from
a 6,094,848-byte median to 2,293,760 bytes, 3,801,088 bytes less transient
growth. The added flat fixture changes the later suite peak, so no whole-suite
RSS comparison is claimed.

Compact per-process values, in seconds:

```text
phase                     baseline                               final
layout_large_scan         .163298 .164103 .159421                .118288 .118705 .132616
layout_dense_folder       .019918 .019782 .019732                .014249 .015316 .014759
layout_flat_high_fanout   .020702 .019937                        .007781 .008303 .008648
render_publication        .009343 .010020 .009568                .009115 .009182 .009722
hit_testing               .093697 .092201 .092577                .089575 .087548 .094748
keyboard_wide             2.596756 2.762740 2.546495             .163892 .162463 .172604
keyboard_tall             2.575346 2.644258 2.574176             .164000 .164117 .308074
cancel_layout             .000114 .000139 .000196                .000115 .000126 .000177
resize_latest             .166716 .170114 .168561                .130693 .131594 .160677
resize_total              .169911 .174168 .171739                .133232 .135463 .164686
navigation_latest         .025455 .024696 .025333                .018887 .019082 .021212
navigation_total          .028119 .026925 .027893                .021242 .021430 .023612
```

## Accepted production changes

1. Keyboard navigation prepares displayed selection rectangles and shallow
   entry candidates once per rendered layout and exact display size. It reuses
   the render state's existing node lookup to recognize the current selection.
   A size change invalidates the cache so fixed-point header geometry and
   aspect-ratio selection remain current.
2. Small-child grouping keeps only the count, accumulated size, and sole-child
   case instead of copying every grouped `FileNodeRecord`.
3. Focused navigation resolves the root color branch once rather than walking
   the same ancestry for every immediate child. For broad roots, color setup
   still scans every global branch to preserve index/count and cancellation,
   but retains dictionary entries only for branches that can render.
4. A pending resize for the same semantic layout and retry generation keeps the
   normalized current render visible and interactive. Explicit retries use a
   new request identity, while a different semantic layout or pending
   visualization input still blocks stale interaction.

No production benchmark instrumentation, dependency, cross-feature cache,
hit-test-grid change, publication-index consolidation, or cancellation-frequency
change was added. Publication, hit testing, and cancellation were left alone
because their baselines did not justify extra production state.

## Correctness evidence

All baseline and final samples preserved:

- million-node layout: 402 segments, fingerprint `84ccd1f6b22ca3fd`;
- dense folder: 8,000 segments, fingerprint `f595374a01f8e2c9`;
- flat root: one aggregate segment containing all 50,000 items, fingerprint
  `b4c991f7480ea3af` before and after its focused optimization;
- 100,000 hit tests: 80,117 hits, fingerprint `3c6c559e6ca749d7`;
- wide keyboard trace: 625 selections, fingerprint `9a467eadac606460`;
- tall keyboard trace: 626 selections, fingerprint `633bed2aab2413c1`;
- every default resize burst: one applied request and five cancelled requests;
- every default navigation burst: one applied request, three cancelled requests,
  and only `navigation-final` published.

The segment fingerprint covers ordered IDs, node/container identity, labels,
depth, rectangle bit patterns, sizes, aggregate/directory/header flags, and all
color-token fields. The flat phase also asserts the aggregate node semantics,
item count, and total size rather than relying only on fingerprint repeatability.
Focused tests cover deepest-tile and gutter hit testing, transformed/fractional
geometry, current-size keyboard selection, exposed headers, focused-root color
identity, superseded-task cancellation, stale-result rejection, and same- versus
different-request presentation.

## Validation boundary

The benchmark covers core layout generation, request supersession, main-actor
publication/index creation, hit queries, and keyboard selection. It does not
measure SwiftUI Canvas frame pacing; resize and navigation behavior therefore
also require checking in the exact locally built app.

Final automated validation completed successfully after the current-source
benchmark smoke run:

- focused Treemap geometry/model/presentation tests: 33 passed;
- full SwiftPM suite: 760 tests, 20 opt-in skips, 0 failures;
- complete Debug app build: passed at `.build/xcode-derived-data`;
- complete unsigned Release app build: passed at
   `.build/treemap-release-derived-data`;
- Release source and link file lists contained no `RadixCoreTests` or Treemap
  benchmark source;
- the Release bundle, executable strings/symbols, production source graph, and
  bundle filenames contained none of `RADIX_BENCH_TREEMAP`,
  `RADIX_TREEMAP_BENCH_RESULT`, or
  `TreemapResponsivenessBenchmarkTests`.

Before the review-only retry-identity and allocation cleanup, manual testing of
the otherwise equivalent Debug bundle covered Treemap rendering, pointer tile
selection, arrow-key header/child/sibling movement, semantic zoom-in/parent
navigation, and post-window-resize keyboard selection; the render remained
present and interactive through resize.
