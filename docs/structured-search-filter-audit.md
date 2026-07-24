# Structured Search Filter Audit

## Goal

Audit the complete structured-search-filter change for correctness, regressions,
performance, maintainability, localization, accessibility, and visual quality.
Keep fixes narrowly scoped to verified problems.

## Review plan

1. Compare the complete feature diff with `origin/main`.
2. Trace `FileBrowserQuery` through Current Contents and Entire Scan searches.
3. Check boundary handling, invalid input, path matching, kind classification,
   allocated-size semantics, sorting, cancellation, and stale async results.
4. Review ownership and data flow for duplicate state, repeated traversal,
   unnecessary allocations, or redundant abstractions.
5. Inspect filter controls across inactive and active states, compact windows,
   keyboard/focus behavior, accessibility output, and every localization.
6. Add focused tests for distinct uncovered behavior and fix only confirmed
   defects or unnecessary complexity.
7. Run core tests, a complete macOS build, rendered UI checks, and a final diff
   review.

## Findings

- Prevented an integer-conversion trap for nonrepresentable size thresholds.
  Invalid values now clear without activating a filter.
- Preserved fractional thresholds when reopening the popover by selecting a
  display unit that can round-trip the stored byte count.
- Normalized backslashes for path-oriented text searches so the existing path
  detection behavior produces matching results.
- Exposed structured-filter state and field purposes to accessibility clients,
  including the active filter count and labels for the size controls.
- Verified that Current Contents and Entire Scan keep independent structured
  queries and that clearing one scope does not affect the other.
- Removed an unused production search-text mutation API and stale localization
  entries from an abandoned filter-chip design.
- Kept the existing single-pass search, stale-result rejection, hidden-node
  handling, sorting, and index invalidation architecture; the audit found no
  reason to add another cache or state owner.

## Validation

- Focused search/model suite: 38 tests passed.
- Complete Swift suite: 709 tests passed, 18 benchmark/probe-only tests skipped,
  and 0 failures.
- Complete Debug macOS app build passed.
- The built app was exercised with Current Contents and Entire Scan, fractional
  size thresholds, a nonrepresentable size value, popover dismissal/reopening,
  and accessibility inspection.
- The final diff was reviewed for redundant state, branches, helpers, and tests.
