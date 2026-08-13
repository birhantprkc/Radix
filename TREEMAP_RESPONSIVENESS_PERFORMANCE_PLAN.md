# Treemap Responsiveness Performance Plan

## Objective and constraints

Improve Treemap responsiveness on large scans while preserving the current
geometry, rendering, hit-testing, viewport, pointer, and keyboard-selection
semantics.

This work is isolated in
`/Users/colin/Programming/Radix/.build/worktrees/treemap-responsiveness` on
`perf/treemap-responsiveness`, created from `main` at
`53b203ada5897500c82b98f39c9a42d1712e0f01`. The canonical checkout and its
active `fix/incremental-fsevents-history` changes are out of scope.

Benchmark code will live only in `RadixCoreTests`. Production code will not
contain benchmark gates, reporters, fixtures, or instrumentation. No cache,
index, state owner, or layout shortcut will be added unless the baseline shows
a material cost in a user-facing path.

## Current pipeline and invariants

1. `TreemapChartView` buckets the available base chart size in 24-point steps
   and starts a layout task when the semantic layout identity, size bucket,
   pending-input state, or retry generation changes.
2. `TreemapChartModel` asks the actor-backed `TreemapLayoutService` for geometry.
   `ChartLayoutRequestCoordinator` cancels the prior task and rejects stale
   success or failure results.
3. `TreemapLayout` reads visible child records, groups sub-threshold children,
   squarifies the remaining entries, assigns stable color branches, and
   recursively emits normalized rectangles.
4. Publishing a layout rebuilds ID lookup, node lookup, and the bucketed
   `TreemapHitTestIndex` once. Pointer hit testing then searches only the unit
   grid bucket under the transformed point.
5. Keyboard selection currently derives displayed/selectable rectangles from
   every rendered segment on every arrow-key move, then performs the existing
   directional edge-distance selection.

The following behavior is non-negotiable:

- Segment IDs, node IDs, depth, aggregate membership/count/size, normalized
  geometry, container headers, color tokens, and z-order remain deterministic.
- Layout uses the base chart size; viewport zoom and pan never trigger or alter
  squarification.
- Structural gutters remain non-interactive, the deepest visible tile wins a
  hit test, free-space and aggregate tiles retain their selection behavior, and
  transformed pointer coordinates map back to base geometry.
- Keyboard entry starts among the shallowest selectable tiles, directional
  moves use displayed aspect ratio and exposed container-header geometry, and
  viewport reveal remains a presentation concern.
- Superseded resize or navigation work cannot publish stale tiles or failures;
  cancellation must be observed promptly enough that the newest request is not
  queued behind obsolete CPU work.

## Phase 1: test-target benchmark harness

Add one opt-in `RadixCoreTests/TreemapResponsivenessBenchmarkTests.swift` suite,
gated by `RADIX_BENCH_TREEMAP=1`. Its deterministic synthetic scan will combine
wide directories with deep enough layout traversal to represent a large scan
without filesystem I/O.

Record machine-readable `RADIX_TREEMAP_BENCH_RESULT` lines for:

- fixture construction and peak resident memory;
- cold layout generation at representative chart sizes;
- repeated layout generation for stable throughput and fingerprints;
- a flat 50,000-child root that isolates broad-root grouping and color-index
  preparation;
- a rapid sequence of resize requests, including newest-request latency,
  applied render count/version, and superseded/cancelled outcomes;
- rapid semantic navigation requests between large roots, with the same stale
  result checks;
- cancellation latency for an in-progress large layout;
- render-state/index publication cost;
- deterministic dense hit testing across tiles, gutters, and misses;
- repeated keyboard selection at a fixed size and after a size/aspect change.

Correctness data will include segment count plus a stable fingerprint over the
semantic fields and rectangle bit patterns, deterministic hit-test results, and
keyboard-selection fingerprints. The harness will retain only scalar samples
between repetitions so its own arrays do not inflate later RSS readings.

Run the benchmark in Release configuration at least three times before any
production edit. Use medians and observed sample spread; do not claim changes
within noise. Keep a raw baseline log outside the source tree or in ignored
build output, and summarize accepted results in a Markdown results file.

## Phase 2: measurement gate and focused optimization

Profile the phase timings and inspect scaling at more than one fixture size.
Only address costs that are both material and attributable to production code.
Candidate hypotheses, not pre-approved changes, are:

- layout generation may copy or retain child records that are used only for an
  aggregate count/size;
- color-branch derivation may repeat ancestor/index work for entries sharing the
  same layout root branch;
- non-cancellable sorting may dominate a very wide visible sibling set;
- render publication may rebuild overlapping lookups/indexes with redundant
  passes;
- keyboard moves may repeatedly map, filter, and index the same rendered
  segments before doing the unavoidable directional scan;
- the current hit-test grid dimensions or bucket population may be suboptimal
  for dense layouts.

For each experiment:

1. change the smallest coherent production seam;
2. add or adjust only high-signal semantic tests for that seam;
3. rerun the relevant benchmark samples and cancellation case;
4. discard the experiment if throughput, tail latency, or memory regresses, or
   if the change complicates state without a clear measured gain;
5. compare fingerprints and interaction results before accepting it.

No unrelated chart/UI refactor, visualization filtering change, discard-pile
change, or cross-feature cache is in scope.

## Phase 3: validation and release boundary

- Run focused Treemap geometry/model, spatial-selection, viewport-transform,
  layout-presentation, tooltip, and color tests.
- Run the full `swift test` suite.
- Build the complete Debug app at `.build/xcode-derived-data`.
- Build the complete Release app at a separate deterministic DerivedData path.
- Inspect `Package.swift`, the Xcode source graph, the Release executable, and
  the Release `.app` bundle for the benchmark filename, class name, environment
  gate, and output prefix. Passing source inspection alone is not sufficient.
- Review the final diff for duplicate state, repeated traversal/allocation,
  unnecessary abstractions, and benchmark leakage.
- Recheck the canonical checkout status and verify its pre-existing changes are
  unchanged.

## Acceptance criteria

- At least one demonstrated material bottleneck is improved beyond baseline
  variance, or the final result candidly reports that no safe optimization met
  the evidence gate.
- Superseded resize/navigation work cancels promptly and only the latest layout
  is published.
- Layout, hit-test, and keyboard fingerprints and focused semantic tests remain
  stable.
- Full tests and Debug/Release app builds pass.
- Release artifact inspection finds no Treemap benchmark code or identifying
  strings.
- Only the isolated worktree contains task changes.
