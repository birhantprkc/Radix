# Treemap Viewport Zoom and Pan Plan

## Objective

Add responsive 100–400% optical zoom and bounded pan to the treemap with the
same user-facing controls and shortcuts as the sunburst. Preserve folder
double-click “zoom” as hierarchy navigation; viewport zoom must never change
the focused folder, selection, rendered depth, or grouping.

## Non-negotiable invariants

1. `baseChartFrame` is the only size used for `TreemapLayoutTaskID` and
   `TreemapChartModel.loadLayout`.
2. Viewport gestures only change local presentation state. They must not start
   a layout request, change segment IDs/count, or rebuild the tree.
3. Render, hover, selection, click, discard drag, tooltip, and keyboard reveal
   must use the same viewport mapping.
4. Canvas and compositing surfaces remain bounded by the visible base chart
   size. Do not create a `scale²` enlarged treemap surface.
5. Discard-pile drag from an eligible tile keeps priority over mouse-drag pan.
6. The viewport remains local and ephemeral: reset on semantic `layoutID`
   changes, constrain on resize, and do not persist it.
7. Scanning and chart input must remain responsive.

## Coordinate spaces

| Space | Responsibilities |
| --- | --- |
| Base chart frame | Layout, grouping, task/cache identity, viewport clip |
| Transformed content frame | Segment rectangle mapping and inverse hit tests |
| Outer pane | Controls, tooltip, loading, and error presentation |

Keep these spaces explicit in names and APIs. Never pass a transformed size to
the layout service.

## Implementation checkpoints

### 1. Share chart viewport primitives

- Rename `SunburstViewportTransform` to `ChartViewportTransform`.
- Rename focused viewport actions to chart-generic names.
- Extract `ChartViewportControls`.
- Share only stable AppKit pointer mechanics: drag threshold, magnification,
  modified-scroll zoom, scroll normalization, and pan deltas.
- Keep chart-specific hit tests, drag payloads, and drag preview drawing in
  their respective overlays.
- Preserve all existing sunburst behavior and tests.

Checkpoint commit:

`refactor(charts): share viewport primitives`

Review before committing:

- Inspect the complete diff for accidental sunburst behavior changes.
- Confirm the `RadixCore` source list is correct.
- Run focused viewport tests and `swift test`.

### 2. Add bounded fixed-size treemap rendering

- Add local `ChartViewportTransform.identity` state to `TreemapChartView`.
- Keep treemap Canvases at `baseChartFrame.size`.
- Extend `TreemapRenderer` with origin-aware content-frame mapping.
- Map normalized segment rectangles into the transformed content frame while
  keeping strokes, corner radii, display insets, and text in screen points.
- Explicitly clip drawing to the Canvas bounds.
- Cull with a simple visible unit-rectangle intersection before constructing
  paths or resolving text. Preserve parent-before-descendant draw order.
- Include viewport geometry in Canvas equality.
- Inverse-map pointer coordinates before querying the existing hit-test index.
- Keep the 18-point chart padding visually empty so it is a dependable
  mouse-pan start gutter.

Checkpoint commit:

`feat(treemap): add viewport rendering`

Review before committing:

- Confirm no viewport value participates in layout task identity.
- Confirm all four visual layers use identical geometry.
- Check 100%, 200%, and 400% nested-container appearance.
- Run treemap geometry/model tests and `swift test`.

### 3. Add gestures, commands, accessibility, and reveal

- Match sunburst zoom limits, button steps, animations, menu shortcuts, pinch,
  and Command/Option-scroll behavior.
- Pan with two-finger/mouse-wheel scrolling only above 100%.
- Latch mouse drag intent at mouse-down:
  - eligible tile → discard drag;
  - empty gutter/gap or non-draggable content while zoomed → pan;
  - sub-threshold movement → click.
- Keep ordinary click, double-click folder navigation, free-space behavior,
  aggregates, and discard callbacks unchanged.
- Choose arrow-key neighbors using base-layout geometry so optical scale cannot
  change navigation. Map the chosen navigation point through the viewport and
  minimally reveal it with padding.
- Re-hit-test hover with the next transform for pointer gestures. Clear hover
  and tooltip for programmatic zoom/reset until the next pointer movement.
- Add the same custom accessibility actions as the sunburst.
- Reuse existing localized zoom strings. Translate any new or revised hint for
  `en`, `de`, `es`, `fr`, `it`, and `zh-Hans`.
- Keep the compact material controls above chart content and make tooltip
  placement avoid their footprint.

Checkpoint commit:

`feat(treemap): add viewport interactions`

Review before committing:

- Verify pan and discard drag cannot switch intent mid-drag.
- Verify transformed clicks and drag payloads resolve the visible tile.
- Verify keyboard reveal does not alter selection candidates.
- Run `swift test` and build the complete app.

## Test additions

- Preserve and rename all viewport transform tests.
- Add anchored zoom after an existing pan.
- Add non-square combined zoom/pan inverse mapping.
- Add transformed treemap deepest-segment hit testing.
- Add origin-aware renderer rectangle tests.
- Add keyboard-neighbor invariance across optical scale.
- Add offscreen selection reveal and already-visible no-op coverage.
- If drag arbitration becomes a pure helper, cover eligible tile, gutter,
  non-draggable tile, threshold, and latched intent.

## Manual validation matrix

- Trackpad pinch at center and near every edge.
- Natural and non-natural two-axis scrolling.
- Mouse wheel, Command-scroll, and Option-scroll.
- Command-Plus, Command-Minus, Command-0, HUD buttons, and accessibility
  actions at 100% and 400%.
- Click, double-click, hover, tooltip, selection highlight, free space,
  aggregate tiles, and discard drag at several viewport positions.
- Arrow navigation to content beyond every viewport edge.
- Resize while panned; semantic layout change; layout retry; visualization
  mode switch; live and imported snapshots.
- Reduce Motion, VoiceOver, Full Keyboard Access, narrow pane, and large
  Retina window.

## Performance review

- Confirm gestures issue no layout request and preserve segment count.
- Profile a dense, wide treemap at 400%.
- Verify Canvas/offscreen dimensions remain at the base viewport size.
- Start with O(n) rectangle culling and no new cache.
- If measured label work prevents responsive pan, first suppress labels during
  an active pan and restore them on gesture end. Add a spatial query or cache
  only with profiling evidence.

## Final validation

```sh
rtk swift test
rtk xcodebuild -project Radix.xcodeproj -scheme Radix \
  -configuration Debug -destination 'platform=macOS' build
```

Before the final handoff, review every touched production file for redundant
state, repeated coordinate conversion, unnecessary abstractions, full-array
work inside pointer events, and divergence between rendering and hit testing.

## Implementation record

Completed on 2026-07-23 in the dedicated
`/Users/colin/Programming/Radix/.build/worktrees/treemap-viewport` worktree on
branch `feat/treemap-viewport`.

Checkpoint commits:

- `5f46a57 docs: add treemap viewport implementation plan`
- `1850009 refactor(charts): share viewport primitives`
- `67cc666 feat(treemap): add viewport rendering`
- `d177b51 feat(treemap): add viewport interactions`

Review and validation completed:

- Full `swift test`: 708 tests executed, 18 skipped, 0 failures.
- Complete Debug app build with `xcodebuild`.
- Hands-on app checks at 100%, 125%, 156%, and 400% for HUD controls,
  shortcuts, transformed selection and folder navigation, keyboard reveal,
  hover/tooltip behavior, mouse and scroll pan, discard-drag arbitration,
  accessibility zoom, visualization switching, and window resizing.
- Verified the sunburst viewport still zooms after the shared refactor.
- Verified resize keeps the prior normalized treemap interactive when its
  replacement layout request is cancelled; interaction remains blocked while
  a layout request is actively pending.
- Final review found no viewport value in treemap layout identity, no enlarged
  Canvas surface, no persisted viewport state, and no new cache or dependency.
