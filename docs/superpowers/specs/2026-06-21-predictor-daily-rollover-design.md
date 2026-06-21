# Predictor daily rollover

**Date:** 2026-06-21
**Status:** Locked
**Phase:** 4e (predictor) — the write-side of windowing: the `RollingVocabulary`
state machine that maintains `today` and the `rolling_7d/30d/90d` pre-aggregates
the 4d ``AggregateCandidateSource`` reads. Pure value type, Linux-testable.
Implements the "Daily versioning + pre-computed rolling aggregates" section of
[[2026-06-13-predictor-design]].

## State (one token store, several sketches)

Matching the spec's split (token strings in one store, sketches as many blobs):

- `index: PrefixIndex` — the single token store, shared across windows.
- `today: CountMinSketch` — the hot day; `record` writes here.
- `rolling7 / rolling30 / rolling90: CountMinSketch` — each the pointwise sum of
  the most recent 7 / 30 / 90 sealed daily sketches.
- `dailies: [CountMinSketch]` — sealed daily sketches, oldest first, kept up to
  the 90-day retention horizon (the largest window's reach) for eviction.

All sketches share the `depth × width` dims (default unigram `4 × 2^14`), so the
4a `merge`/`subtract` primitives apply directly — no new sketch code.

## record

```
record(token, count):
  guard non-empty token, count > 0
  index.insert(token)
  today.add(token, count)
```

## rollover (at user-local midnight)

Maintains the invariant **`rolling_W = sum of the most recent W sealed dailies`**
as a sliding-window sum — add the newly sealed day, subtract the one that just
fell out of each window:

```
rollover():
  sealed = today
  dailies.append(sealed)          # seal today
  n = dailies.count
  for W in (7, 30, 90):
    rolling_W.merge(sealed)              # add the new day
    if n > W: rolling_W.subtract(dailies[n - 1 - W])   # evict the day that left the window
  today = zeroed sketch
  if dailies.count > 90: drop oldest down to 90        # prune past the horizon
```

**Eviction index derivation.** After appending, the new window is
`dailies[n-W ..< n]`; the previous `rolling_W` summed `dailies[n-1-W ..< n-1]`.
The delta is `+dailies[n-1]` (today) and `−dailies[n-1-W]` (only when `n > W`).
Pruning to 90 happens **after** the subtracts, so the 90-day window's evicted
daily (`dailies[n-1-90]`, the oldest) is still present when needed, then dropped.

### Two load-bearing decisions

- **`subtract` clamps at zero** (4a): a hash collision can drive a cell negative
  on eviction; clamping is the spec's accepted, tolerable noise — an evicted
  sketch may then slightly under-estimate, which is fine.
- **The token index is monotonic** — eviction subtracts *counts*, never removes
  *strings*. A token whose count drops to ~0 lingers in the index but estimates
  ~0, so it ranks below the confidence floor and never surfaces. This keeps one
  shared index instead of reconstructing per-window token sets; growth is bounded
  by lifetime distinct vocabulary (small for terminal tokens).

## Query

`learnedSource(window:) -> AggregateCandidateSource` returns
`today ⊕ rolling_<window>` as two `IndexedSketch` views (the shared index paired
with a sketch), summed by the 4d aggregate. The caller passes it as the `learned`
source to a ``SeededSuggester``:

```
suggester = SeededSuggester(learned: store.learnedSource(window: .days30),
                            seed: seedVocabulary)
```

`IndexedSketch` (index + sketch → `candidates(forPrefix:)`) is the small adapter
that turns the shared index + a chosen sketch into a `CandidateSource`. Copying
it per query is cheap — `PrefixIndex`/`CountMinSketch` are copy-on-write structs,
so the snapshot shares storage until something mutates.

## Testing (Core tier — the windowing correctness)

- **today contributes** before any rollover.
- **rollover moves today → rolling and resets today** (a token isn't double-
  counted after sealing).
- **accumulation**: a token recorded across two in-window days sums.
- **7-day eviction (BVA)**: present after 7 rollovers, evicted after the 8th.
- **window independence**: what the 7-day window evicts, the 30-day still holds.
- **90-day boundary (BVA)**: present after 90 rollovers, evicted after the 91st
  (also exercises pruning, which must not drop a daily a window still needs).
- **guards**: empty token / zero count never recorded.

All assertions go through the public `learnedSource(...).candidates(...)` surface
(black-box), using the rollover sequencing to isolate today vs. rolling.

## Out of scope (later slices)

- **Persistence** — SQLite token metadata, file-protected sketch blobs, the
  append-only event log, format-version migration, CloudKit sync envelope.
- **When** to roll over — the midnight scheduler / local-time handling (this slice
  is the pure mechanism; the caller decides when to call `rollover()`).
- **Bigram windowing**, output-token harvesting decay, privacy write-time filter.

## Related

- [[2026-06-21-predictor-candidate-aggregate-design]] — the read-side this feeds
- [[2026-06-21-predictor-core-sketches-design]] — `merge`/`subtract`/clamp
- [[2026-06-13-predictor-design]] — daily versioning + rolling aggregates
