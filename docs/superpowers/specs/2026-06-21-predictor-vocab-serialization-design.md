# Predictor vocabulary serialization (seed-blob foundation)

**Date:** 2026-06-21
**Status:** Locked
**Phase:** 4i (predictor) — serialize/deserialize a populated ``Vocabulary`` and
``BigramVocabulary`` to a self-describing blob, so a seed can be built once and
loaded back as a queryable ``CandidateSource``. The foundational brick under the
seed-blob pipeline of [[2026-06-13-predictor-design]] (steps 5–7). Pure value
types, Linux-testable.

## The gap this fills

[[2026-06-21-predictor-core-sketches-design]] gave ``CountMinSketch`` a
fail-closed `serialize` / `init?(deserializing:)`. But a CMS is **lossy — it
cannot enumerate its keys**, so a sketch blob alone can't answer "what follows
`git`?". A usable seed must round-trip the *whole* vocabulary: the
``PrefixIndex`` (the actual token strings, the candidate set) **and** the sketch
(their scores). Nothing above the CMS serializes today; this slice adds it.

The seed-blob pipeline (4j builds it, 4k loads it) needs exactly one capability
from this slice: **populate a ``BigramVocabulary`` → `serialize()` → bytes on
disk → `init?(deserializing:)` → an identical, queryable store.**

## Three nested formats, all in the ``CountMinSketch`` mould

Each is self-describing (4-byte magic + 1-byte version), little-endian, and
**fails closed** — wrong magic, unknown version, a length field that overruns the
buffer, or a structural invariant violation yields `nil`, never a half-built or
invariant-broken value. Synced/seed blobs are treated as potentially hostile
(same threat model as the CMS format).

### PrefixIndex — `GPIX` v1

```
magic "GPIX" (4) | version (1) | count (LE32) | [ len (LE32) | UTF-8 bytes ]×count
```

- **Invariant validation on read.** ``PrefixIndex`` binary-search correctness
  depends on tokens being **strictly ascending by UTF-8 bytes, unique**
  ([[2026-06-21-predictor-prefix-ranking-design]]). Deserialization enforces it:
  each token must be strictly greater (by bytes) than its predecessor, else
  `nil`. A corrupt/hostile blob can't produce an index that silently breaks
  `matching`.
- **No untrusted pre-allocation.** `count` and each `len` are checked against the
  remaining buffer before reading; capacity is never reserved from an unverified
  count (a hostile `count = 0xFFFFFFFF` must fail, not OOM).
- Trailing bytes after the declared `count` tokens → `nil` (no slack).

### Vocabulary — `GVOC` v1

```
magic "GVOC" (4) | version (1) | idxLen (LE32) | idxBlob | cmsLen (LE32) | cmsBlob
```

The two sub-blobs are length-prefixed because each sub-deserializer requires its
*exact* byte slice (the CMS checks `bytes.count == expected`). Deserialize slices
each sub-blob by its length, then delegates to ``PrefixIndex`` /
``CountMinSketch`` `init?(deserializing:)`; any sub-failure propagates to `nil`.
Index/sketch consistency is *not* cross-validated — the sketch is lossy by design
and `estimate` is well-defined for any key, so a faithful round-trip of each part
suffices.

### BigramVocabulary — `GBGM` v1

```
magic "GBGM" (4) | version (1) | vocabBlob (rest)
```

A ``BigramVocabulary`` *is* a ``Vocabulary`` over composite keys
([[2026-06-21-predictor-bigram-next-token-design]]), so its blob is just the
inner vocabulary's blob under a distinct magic. The distinct magic is the
type-safety guard: loading a unigram `GVOC` blob as a bigram store (or vice
versa) fails closed instead of silently mis-querying. No length prefix — the
vocab blob is the sole trailing payload, and ``Vocabulary`` deserialization
already rejects any length mismatch.

## Why round-trip equality is the load-bearing test

`deserialize(serialize(v)) == v` (plus a behavioral check — the restored store
returns the same `candidates`/`suggestions`) is the property the pipeline relies
on. The corruption tests (truncation, wrong magic/version, hostile length,
non-ascending index) prove the fail-closed half. Both halves are required: the
seed is built by one program and read by another (later, the app), possibly after
transit through CloudKit.

## Out of scope (later slices)

- **The build executable + carapace/tldr ingestion** (4j) — consumes this
  `serialize`.
- **Runtime first-launch load + `seed_pinned`** (4k) — consumes
  `init?(deserializing:)`.
- **RollingVocabulary serialization** — the user's windowed learned store; a
  separate persistence slice (the seed is a single pinned sketch, not windowed).
