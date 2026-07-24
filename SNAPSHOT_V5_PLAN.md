# Snapshot v5 Lossless Compression Plan

## Status

Implemented and release-validated on 2026-07-23. This document was completed
before production implementation began, then updated with implementation
evidence, rejected experiments, and final release-gate results.

Branch: `feat/snapshot-v5-compression`

Worktree:
`/Users/colin/Programming/Radix/.build/worktrees/snapshot-v5-compression`

## Objective

Make format-version 5 Radix scan snapshots materially smaller without changing
what an exact snapshot means.

The change must:

- remain truly lossless;
- preserve the `.radixscan` extension and macOS package experience;
- keep manifest-based preview cheap;
- import existing v3 and v4 snapshots;
- allow v3/v4/v5 snapshots to participate in the same comparison pipeline;
- preserve every model field and topology relationship;
- retain streaming, cancellation, progress reporting, atomic installation, and
  bounded-memory validation;
- fail safely and clearly for unsupported, corrupted, truncated, oversized, or
  malicious payloads;
- avoid a new dependency;
- demonstrate meaningful size reduction without unacceptable time or memory
  regressions.

This project does **not** add lossy or thresholded snapshots. A future summary
snapshot feature would need separate fidelity and comparison semantics.

## Existing Behavior and Constraints

### Package layout

Format v4 is a `.radixscan` package containing:

- `manifest.json`
- `nodes.jsonl`
- `topology.json`
- `warnings.json`
- `stats.json`

The manifest is decoded before any body section and contains the format version,
snapshot metadata, section file names, and the SHA-256 digest of `nodes.jsonl`.

### Current logical representation

- Nodes are compact JSONL records.
- Ordinary nodes store one relative path component rather than repeating full
  paths.
- Topology uses node ordinals.
- v4 node order normally places parents before children.
- The importer can still handle compact records stored before their parents.
- The importer repairs materialized-directory aggregate fields from children.
- Imported snapshots are normalized into `ScanSnapshot` and `FileTreeStore`.
- Comparison operates on those normalized models, not archive bytes or archive
  versions.

### Current performance work

Radix 1.6.0 already optimized exact snapshot opening:

- ordinal-based compact archive construction;
- concurrent batched JSON decoding;
- pipelined I/O, decode, and node materialization;
- inherited and deduplicated path-containment validation;
- direct compact `FileTreeStore` construction;
- combined tree finalization;
- import and comparison phase profiling.

v5 should extend this pipeline, not replace it with a second importer or regress
to whole-section node buffering.

### Current validation

Existing coverage includes:

- complete graph and metadata round trips;
- Unicode paths and names;
- hard-link and clone identity;
- v3 full-path import;
- v4 compact order and parent-after-child import;
- manifest, stats, topology, warning, and node bounds;
- node checksum mismatch;
- malformed topology and unsafe paths;
- missing sections and escaping symlinks;
- cancellation and atomic replacement;
- deep and wide trees;
- repaired stats and directory totals;
- unsupported old and future versions;
- synthetic and real-snapshot benchmarks.

v5 tests should extend this coverage instead of duplicating every v4 test.

## Documentation and Platform Evidence

Radix targets macOS 14. Apple’s installed SDK exposes the Compression framework
stream API and `COMPRESSION_LZFSE` starting in macOS 10.11.

Apple documents that:

- the Compression framework is lossless;
- stream compression is intended for large or incrementally produced data;
- `compression_stream_process` resumes across noncontiguous input and output
  buffers;
- encoding returns `COMPRESSION_STATUS_END` only after all input and the end
  marker are emitted with `COMPRESSION_STREAM_FINALIZE`;
- decoding returns `COMPRESSION_STATUS_END` only after the encoded end marker is
  consumed and all output is written;
- callers must set `COMPRESSION_STREAM_FINALIZE` when no more decode input is
  available, or a truncated stream can otherwise make no progress indefinitely;
- `COMPRESSION_STATUS_ERROR` represents malformed or corrupted input;
- LZFSE is Apple’s stable general-purpose balance of speed and compression.

Apple’s latest documentation mentions newer algorithms, but the installed SDK
header used by this macOS 14 deployment target does not expose them. v5 will use
LZFSE rather than add an availability split or raise the deployment target.

Use the lower-level `compression_stream` API rather than whole-buffer helpers or
filter objects. It provides explicit buffer bounds, status handling, end-marker
validation, no-progress detection, and cancellation points.

Official references:

- <https://developer.apple.com/documentation/compression>
- <https://developer.apple.com/documentation/compression/compression_stream>
- <https://developer.apple.com/documentation/compression/compression_stream_flags>
- <https://developer.apple.com/documentation/compression/compression_lzfse>

Context7 was queried first as required by the repository documentation workflow,
but its index did not contain Apple’s Compression framework. The installed SDK
header and official Apple documentation are therefore authoritative here.

## Format v5 Design

### Format family

v5 remains part of the existing Radix scan archive family:

- same format identifier: `dev.colinkim.radix.scan`;
- same `.radixscan` extension;
- same package UTI and save/open-panel behavior;
- same logical node, topology, warning, stats, and snapshot schemas;
- same normalized `ScanSnapshot` result.

Only the section transport and integrity manifest evolve.

The v5 exporter writes v5 by default. The v5 importer accepts v3, v4, and v5.
Radix 1.6.0 will reject v5 cleanly as an unsupported future version, which is
preferable to accepting v4 and then trying to decode compressed bytes as JSON.

### Section layout

Proposed v5 package:

- `manifest.json` — uncompressed
- `nodes.jsonl.lzfse` — LZFSE stream
- `topology.json.lzfse` — LZFSE stream
- `warnings.json` — uncompressed
- `stats.json` — uncompressed

Nodes and topology accounted for approximately 99% of the representative
synthetic package measured during design. Compressing only those sections
captures nearly all expected benefit while keeping preview metadata and small
diagnostic sections simple.

Warnings remain uncompressed in v5. They are usually small, have an existing
decoded-size bound, and are read after the expensive tree payload. Compressing
them would widen the first change without materially helping ordinary archives.

### Manifest changes

Add an optional top-level section-encoding description:

```json
{
  "sectionEncodings": {
    "nodes": "lzfse",
    "topology": "lzfse",
    "warnings": "identity",
    "stats": "identity"
  }
}
```

Rules:

- v3/v4 manifests omit `sectionEncodings`; all sections are identity encoded.
- v5 manifests must provide it.
- v5 initially accepts exactly the values shown above.
- unknown or missing v5 encodings are manifest errors, not codec guesses.
- the manifest remains uncompressed and bounded by the existing 1 MiB limit.

Explicit encodings are preferred to inference from file extensions. This makes
the contract reviewable, rejects unsupported algorithms before body processing,
and leaves room for a future format version to choose another transport.

Set `createdBy.swiftSchema` to `ScanArchiveV5` for v5 exports. Preserve existing
v3/v4 values when importing them.

### Integrity changes

Keep SHA-256 and define v5 digests over **decoded logical section bytes**.

Extend `integrity` with:

```json
{
  "algorithm": "sha256",
  "domain": "decoded-section-bytes",
  "nodes": "...",
  "topology": "...",
  "warnings": "...",
  "stats": "..."
}
```

Rules:

- v3/v4 require only the existing node digest.
- v5 requires the domain and all four section digests.
- node bytes include the existing trailing newline behavior.
- topology, warnings, and stats are hashed exactly as emitted by the existing
  deterministic section encoder.
- v5 import hashes bytes after decompression and before JSON decoding.
- stats integrity is checked during both preview and full import.
- compression status validates the encoded stream; SHA-256 validates the exact
  decoded logical content.

Hashing decoded bytes has two advantages:

1. compression cannot mask semantic corruption;
2. transport bytes do not define snapshot semantics.

JSON object key order is not part of the logical archive schema and may differ
between independent encodes, so cross-version losslessness is proven through
decoded model equivalence rather than requiring independently generated
section digests to match.

An implementation experiment enabled `JSONEncoder` key sorting to stabilize
compressed byte counts. The 64,065-node export median regressed from roughly
0.31 seconds to roughly 2.52 seconds, exceeding the 1.50x export gate by a wide
margin. The experiment was rejected. Byte-for-byte output determinism is not
part of the losslessness contract.

### Stored byte counts

Add required v5 stored byte counts for all four body sections. Verify them
against regular-file sizes before decoding. This detects appended or truncated
transport bytes even when the codec accepts padding after an otherwise valid
end marker.

This requirement was added after an integration test demonstrated that Apple’s
LZFSE decoder can accept at least some appended padding without leaving
unconsumed source bytes. Decoded SHA-256 still protects logical content; stored
byte counts protect the transport boundary.

The manifest cannot hash itself without a circular construction and remains
protected by strict decoding, format validation, and body digests.

## Streaming Architecture

### Shared section writer

Introduce one focused archive-section stream helper backed by Apple’s
Compression framework.

The writer:

- owns one destination `FileHandle`;
- optionally owns an initialized LZFSE encode stream;
- accepts decoded bytes incrementally;
- updates SHA-256 from those decoded bytes;
- buffers no more than a fixed plaintext chunk and fixed encoded output chunk;
- writes encoded output incrementally;
- checks cancellation between chunks;
- finalizes with `COMPRESSION_STREAM_FINALIZE`;
- requires `COMPRESSION_STATUS_END`;
- detects a status-OK/no-input/no-output loop as an error;
- always destroys initialized compression state;
- returns the decoded-byte checksum after a successful finish.

The existing JSONL and topology writers should append to this helper rather than
create a parallel buffering abstraction. Preserve their current progress cadence
and `Task.yield()` behavior.

For v4 test exports, the same writer uses identity encoding and writes the
unchanged bytes.

### Shared section reader

Introduce a reader that presents decoded chunks regardless of section encoding.

Identity mode delegates to `FileHandle.read(upToCount:)`.

LZFSE mode:

- owns one source `FileHandle` and one initialized decode stream;
- reads fixed-size encoded chunks;
- produces fixed-size decoded chunks;
- retains only unconsumed encoded bytes required by the stream;
- sets `COMPRESSION_STREAM_FINALIZE` once encoded EOF is known;
- requires `COMPRESSION_STATUS_END`;
- treats EOF without END as truncation;
- detects no-progress states;
- rejects bytes trailing the encoded end marker;
- checks cancellation between input/output chunks;
- always destroys initialized compression state.

The node pipeline consumes decoded chunks exactly where it currently consumes
file chunks. Existing JSONL line limits, record-count checks, batch ordering,
concurrent decoding, decoded-byte hashing, and progress remain intact.

Topology is decompressed through the same reader into bounded `Data`. Its limit
continues to apply to **decoded** bytes, preventing a compressed expansion from
bypassing the current topology bound.

### Error mapping

The compression helper should expose small internal error cases:

- initialization failure;
- processing failure;
- truncated stream;
- trailing encoded data;
- no progress;
- write/read failure.

Callers map them to the existing section-specific public errors:

- node stream failures → `ScanArchiveError.nodes` or `.integrity`;
- topology stream failures → `ScanArchiveError.topology` or `.integrity`;
- unsupported encoding contract → `.manifest`.

Do not expose raw implementation pointers or Apple status integers to users.

### Atomicity and cleanup

The existing temporary-package workflow remains:

1. create a sibling temporary package;
2. completely write and finalize compressed sections;
3. write metadata and the manifest only after section checksums exist;
4. check cancellation;
5. atomically install or replace the destination;
6. remove the temporary package on every failure or cancellation.

A partially finalized compressed stream must never replace an existing archive.

## Export-Version Control for Tests

Production UI always uses the current format.

Add an internal export-format selector to `ScanArchiveExportOptions`, defaulting
to `currentFormatVersion`. Permit v4 and v5 export internally; reject unsupported
export versions.

Rationale:

- tests need authoritative v4 archives after the default changes to v5;
- the same logical writers can prove v4/v5 checksum and model equivalence;
- existing malformed-v4 tests can continue mutating plaintext sections;
- no user-facing compatibility switch or preference is introduced.

Avoid maintaining a second hand-written v4 exporter in tests.

## Compatibility Matrix

| Reader | v3 | v4 | v5 exact |
| --- | --- | --- | --- |
| Radix 1.6.0 | Yes | Yes | Clean unsupported-version error |
| v5 Radix | Yes | Yes | Yes |

Comparison under v5 Radix:

| Earlier | Later | Expected behavior |
| --- | --- | --- |
| v3 | v5 | Normal exact comparison |
| v4 | v5 | Normal exact comparison |
| v5 | v4 | Normal exact comparison |
| v5 | v5 | Normal exact comparison |

Archive versions do not enter comparison logic after successful import.

## Losslessness Contract

For an exact snapshot, v5 import must preserve:

- snapshot UUID;
- target path, display name, and kind;
- start and finish times;
- completion state;
- scan options and their fingerprint;
- volume capacity;
- warning path, message, category, and order;
- root ID;
- node count and deterministic traversal order;
- every parent-child edge and child order;
- node ID, URL path, and name;
- directory, symlink, package, synthetic, and summarized flags;
- allocated, unduplicated allocated, data allocated, and logical sizes;
- descendant file count;
- modification date;
- file identity and link count;
- clone identity;
- accessibility fields;
- aggregate stats after the existing directory-total reconciliation;
- imported trust context and path-mode behavior.

Warning UUIDs are intentionally reconstructed today and are not serialized.

Losslessness is semantic rather than compressed-byte determinism. Re-exported
LZFSE bytes need not be identical as long as decoded section bytes and the
normalized snapshot are identical.

## Test Plan

### Codec-focused tests

- empty stream round trip;
- one-byte and small-stream round trips;
- input spanning multiple source chunks;
- output spanning multiple destination chunks;
- large repetitive and incompressible streams;
- Unicode UTF-8 content;
- truncated stream at the beginning, middle, and end;
- flipped encoded bytes;
- valid stream with trailing bytes;
- cancellation during encode and decode;
- compressor/decompressor state cleanup on failure.

Prefer testing through archive-section helpers or archive behavior rather than
exposing implementation solely for tests.

### v5 archive tests

- default export writes format version 5 and `ScanArchiveV5`;
- manifest remains readable JSON;
- expected section encodings and filenames are present;
- nodes and topology are not plaintext;
- preview reads metadata without opening nodes or topology;
- complete snapshot round trip covers every losslessness field above;
- Unicode, hard-link, clone, inaccessible, synthetic, package, and summarized
  nodes survive;
- deep and wide topologies survive;
- decoded v4 and v5 models are semantically identical;
- all v5 section checksums are verified;
- corrupted/truncated nodes fail safely;
- corrupted/truncated topology fails safely;
- valid JSON tampering in identity sections fails checksum validation;
- missing or unsupported v5 encoding metadata fails before body decoding;
- decoded topology size limits still apply after decompression;
- decoded node-line limits still apply after decompression;
- node-count overrun is rejected during streaming;
- missing compressed sections map to archive errors;
- escaping section symlinks remain rejected;
- cancelled export preserves an existing archive and removes its temporary
  sibling;
- cancelled import never publishes a snapshot.

### Backward compatibility tests

- v3 fixture import remains unchanged;
- internally exported v4 import remains unchanged;
- pre-parent v4 compact nodes remain supported;
- v4 archives without newer optional manifest fields remain supported;
- unsupported old and future versions still fail from the minimal manifest;
- malformed-v4 plaintext tests explicitly request v4 export.

### Cross-version comparison tests

Export the same rich snapshot as v4 and v5, import both, then assert:

- equivalent node records and topology;
- equivalent warnings, options, capacities, and aggregate stats;
- identical semantic node checksum;
- zero comparison rows in both v4→v5 and v5→v4 directions;
- zero summary deltas;
- equivalent coverage assessment.

Also mutate one source snapshot, export versions independently, and assert v4/v5
comparison rows equal the v4/v4 baseline. This catches version-dependent move,
hard-link, clone, path, or size behavior that a zero-diff test could miss.

### Regression suite

Required before completion:

```sh
swift test
xcodebuild -project Radix.xcodeproj -scheme Radix \
  -configuration Debug -destination 'platform=macOS' build
```

Every shell invocation remains prefixed with `rtk` per repository policy.

## Benchmark Plan and Go/No-Go Gates

### Baseline

Use the existing archive benchmark to export the same in-memory snapshot as v4
and v5 in the same build. Measure at least:

- package bytes and per-section bytes;
- export wall time;
- import wall time;
- export peak RSS delta;
- import peak RSS delta;
- node count and shape.

Cases:

- small metadata-rich fixture;
- 10,000-file wide tree;
- at least 12,000-node deep tree;
- at least 64,000-node fan-out tree;
- a representative real archive when one is available locally.

Run multiple iterations for nontrivial cases and compare medians. Debug-build
microbenchmarks are noisy, so combine ratios with absolute tolerances.

### Required size impact

For wide and large synthetic exact snapshots:

- v5 total package size must be no more than 50% of v4;
- nodes plus topology must show the expected dominant reduction;
- no claim is made that tiny archives always shrink.

Failure means reconsider the codec or project value before shipping.

### Time guardrails

For nontrivial synthetic cases, median v5 time must satisfy:

- export ≤ `max(v4 × 1.50, v4 + 100 ms)`;
- import ≤ `max(v4 × 1.25, v4 + 100 ms)`.

For a representative real snapshot, any slower result must be explained by
phase profiling and judged against the actual size benefit. A repeatable
user-visible opening regression is a no-go.

### Memory guardrails

For nontrivial cases:

- import peak RSS delta must not exceed v4 by more than
  `max(v4 × 10%, 8 MiB)`;
- export must remain bounded with section size and must not materialize complete
  node or topology payloads.

Compression is not expected to reduce reconstructed `FileTreeStore` memory.

### Measured results

The direct comparison benchmark exported and imported v4 and v5 from the same
in-memory snapshots in one debug-build process. Each nontrivial result is the
median of three iterations:

| Shape | Nodes | v4 bytes | v5 bytes | v5/v4 size | Export ratio | Import ratio |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Small | 7 | 1,619 | 1,842 | 113.8% | 0.93x | 1.01x |
| Wide | 10,001 | 608,878 | 41,248 | 6.8% | 1.05x | 0.67x |
| Deep | 12,001 | 1,286,800 | 62,389 | 4.8% | 1.06x | 0.66x |
| Large | 64,065 | 3,896,308 | 333,778 | 8.6% | 1.08x | 0.78x |

The small fixture grows by 223 bytes because its richer v5 manifest outweighs
the body-section savings. The design explicitly makes no tiny-archive shrinkage
claim. All representative nontrivial cases exceed the 50% size-reduction gate,
stay far inside both time guardrails, and open faster than v4 in this run.

Median large-case import peak RSS delta fell from 31,244,288 bytes for v4 to
131,072 bytes for v5. Other nontrivial RSS deltas stayed within the 8 MiB
absolute-noise allowance. Export remains a bounded stream and reported a zero
median RSS delta for both formats in the large case.

No real `.radixscan` package was present under the local Documents, Downloads,
or Desktop folders, so the planned real-archive supplement was not available.
The 64,065-node mixed fan-out case is the release-gate representative.

Benchmark command:

```sh
rtk env RADIX_BENCH_ARCHIVE=1 \
  RADIX_BENCH_ARCHIVE_COMPARE_FORMATS=1 \
  RADIX_BENCH_ARCHIVE_ITERATIONS=3 \
  RADIX_BENCH_ARCHIVE_WIDE_FILES=10000 \
  RADIX_BENCH_ARCHIVE_DEEP_DEPTH=12000 \
  RADIX_BENCH_ARCHIVE_LARGE_DIRS=64 \
  RADIX_BENCH_ARCHIVE_LARGE_FILES_PER_DIR=1000 \
  swift test --filter ScanArchiveBenchmarkTests/testArchiveExportImportBenchmark
```

## Documentation and Localization

Update:

- README architecture text to state that current exact archives use compressed
  transport while older versions remain readable;
- benchmark output/version assumptions;
- this document if implementation details change during evidence gathering.

New user-facing failure details must be added to `Localizable.xcstrings` for:

- `en`
- `de`
- `es`
- `fr`
- `it`
- `zh-Hans`

If existing localized archive errors can accurately wrap the new details, avoid
adding redundant top-level UI strings.

No export UI change is required: compression is transparent and exact.

## Implementation Sequence

1. Run the existing archive service tests and capture a v4 benchmark baseline.
2. Add v5 manifest models and internal v4/v5 export selection.
3. Add the bounded LZFSE section writer/reader with focused tests.
4. Route v5 node and topology export through the writer.
5. Route v5 topology and node import through the reader.
6. Add decoded-section integrity for topology, warnings, and stats.
7. Convert existing plaintext-mutation tests to explicit v4 export where
   appropriate.
8. Add rich v5 losslessness and corruption tests.
9. Add cross-version comparison tests.
10. Extend benchmarks to compare v4 and v5 directly.
11. Run focused tests and benchmarks; inspect phase-level regressions.
12. Simplify duplicated state, branches, buffers, and error mapping.
13. Update docs and localization.
14. Run the full Swift test suite and complete macOS app build.
15. Audit every objective requirement against current code and command evidence.

## Review Checklist

### Format

- [x] v5 is a new format version, not compressed bytes mislabeled as v4.
- [x] Manifest and preview metadata stay uncompressed.
- [x] Same extension, UTI, and package behavior.
- [x] v3/v4 import remains supported.
- [x] Old readers fail cleanly on v5.

### Losslessness

- [x] Every serialized model field is asserted.
- [x] Topology and child order are asserted.
- [x] v4/v5 decoded models and comparison results match.
- [x] Cross-version comparisons match same-version baselines.

### Streaming and safety

- [x] Nodes never materialize as one decoded payload.
- [x] Topology decoded bytes remain bounded.
- [x] EOF uses FINALIZE and requires END.
- [x] No-progress states cannot loop.
- [x] Trailing encoded bytes are rejected.
- [x] Compression state is destroyed on all exits.
- [x] Cancellation and progress remain responsive.
- [x] Temporary packages are cleaned up.

### Integrity

- [x] Decoded bytes are hashed before JSON decoding.
- [x] All v5 body-section checksums are required.
- [x] Preview verifies stats integrity.
- [x] Truncation and corruption produce section-specific archive errors.

### Impact

- [x] Size gate passes.
- [x] Export-time gate passes.
- [x] Import-time gate passes.
- [x] Peak-memory gate passes.
- [x] No new dependency.

### Validation

- [x] Focused archive tests pass: 56 tests, 0 failures.
- [x] Cross-version comparison tests pass.
- [x] Full `swift test` passes: 717 tests, 18 skipped, 0 failures.
- [x] Full macOS app build passes.
- [x] Localization is complete.
- [x] Final diff is reviewed for code economy and unrelated changes.

## Rollback and Release Strategy

The v5 exporter should be isolated behind `currentFormatVersion = 5`; the v3/v4
reader paths remain intact. If release-candidate evidence shows a regression,
the low-risk rollback is to keep the v5 reader code dormant and restore default
export to v4 before release. Do not ship a partially validated v5 writer.

Because v5 is the only new output, no user migration is needed. Existing
archives remain readable. Re-exporting a v4 archive as v5 is optional and should
produce an equivalent exact snapshot.

## Completion Standard

Do not declare this work complete merely because round-trip tests pass.
Completion requires:

- requirement-by-requirement evidence;
- backward import compatibility;
- cross-version comparison equivalence;
- safe malformed-stream behavior;
- measurable size benefit;
- acceptable export/import time and memory;
- complete tests, build, docs, and localization;
- no known regression.
