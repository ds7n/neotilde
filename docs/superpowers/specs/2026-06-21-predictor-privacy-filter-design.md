# Predictor privacy write-time filter

**Date:** 2026-06-21
**Status:** Locked
**Phase:** 4f (predictor) — the write-time exclude filter that keeps secrets out
of the learned vocabulary. Pure value type, Linux-testable, **security-critical**.
Implements the "Pattern-exclude list" + "high-entropy" privacy controls of
[[2026-06-13-predictor-design]].

## Principle: filter at write time, not read time

When the user types a token matching an exclude rule, **it is never recorded** —
the secret never enters any sketch or the token index. Reading is never gated by
patterns; the data simply isn't there ([[2026-06-13-predictor-design]] §"Privacy-
pattern matching at write time"). So this slice is a single pure predicate,
`TokenFilter.excludes(_ token:) -> Bool`, that the recording orchestration
consults before calling `record`. Belt-and-suspenders against learning
credentials: the worst failure mode (learning a secret) is irreversible-ish, so
the filter fails *toward exclusion*.

## Rules

Two tiers — high-confidence deterministic patterns, plus an entropy backstop.

### Deterministic patterns (`ExcludePattern`)

| Case | Match | Why this form |
|---|---|---|
| `.contains(s)` | case-**insensitive** substring | `password`/`token`/`secret` appear anywhere, any casing (`MyPassword`, `API_TOKEN`) |
| `.hasPrefix(s)` | case-**sensitive** prefix | real key prefixes are fixed-case (`ghp_`, `sk-`); matching case avoids over-blocking unrelated uppercase tokens |

**Shipped defaults** (user-editable later):

```
.contains("password"), .contains("token"), .contains("secret"),
.hasPrefix("ghp_"), .hasPrefix("gho_"), .hasPrefix("ghs_"),   // GitHub classic PATs
.hasPrefix("github_pat_"),                                    // GitHub fine-grained PATs
.hasPrefix("sk-"),                                            // OpenAI API keys
.hasPrefix("sk_"), .hasPrefix("pk_")                          // Stripe secret / publishable keys
```

Prefix formats are exact: OpenAI uses `sk-` (hyphen), Stripe uses `sk_`/`pk_`
(underscore) — both are shipped. An empty pattern string is treated as a no-op
(never a match-everything rule), guarding the future user-edit path.

A typed enum, **not raw regex**: the defaults need only "contains" / "prefix",
and a closed set avoids ReDoS and the anchoring foot-guns of user-authored regex.
(A `.regex` case can be added when user-authored rules ship; deferred.)

### Entropy backstop

Random-looking secrets that match no known prefix (a pasted API key, a session
blob) are caught by Shannon entropy. A token is excluded when **both**:

- `length >= entropyMinLength` (default **16**) and
- `shannonEntropy(token) >= entropyThreshold` (default **4.0** bits/char).

The two interact: reaching `4.0` bits/char requires ≥ 16 distinct symbols, so a
token shorter than 16 chars *cannot* hit the threshold — 16 is the natural floor,
and a higher min-length (e.g. 20) would only create a 16–19-char gap through which
a random 16-char secret could slip. Min-length 16 closes that gap at near-zero
cost (a legit 16-char token random enough to reach 4.0 bits/char is not useful
vocabulary anyway), consistent with *fail toward exclusion*.

Shannon entropy is `H = -Σ pᵢ·log2(pᵢ)` over per-character (Unicode-scalar)
frequencies — bits per character, length-independent. A 32-char base64 blob lands
~5–6; a normal command/path lands ~3–3.8; a repeated string (`aaaa…`) lands ~0.
`4.0` clears base64/random secrets while letting most real tokens through; it is
a **tunable starting point** (like the predictor's other knobs) needing empirical
tuning, and is the secondary net — the deterministic patterns are the
high-confidence layer. Setting `entropyThreshold = nil` disables the backstop.

## API

```
enum ExcludePattern { case contains(String), hasPrefix(String) }

struct TokenFilter {
    var patterns: [ExcludePattern]          // default: the shipped list
    var entropyThreshold: Double?           // default 4.0; nil disables
    var entropyMinLength: Int               // default 20
    func excludes(_ token: String) -> Bool  // true ⇒ never record
}
```

The recording orchestration (a later facade that tokenizes input and drives
`RollingVocabulary.record`) calls `if !filter.excludes(t) { store.record(t) }`.
This slice ships the predicate and proves the gating pattern; the facade is out
of scope.

## Testing (Critical tier — security; EP + BVA + adversarial)

Adversarial catalog — a positive case per vector and negatives that must record:

- **Each default pattern** matches: `password`, `api_token`, `secret`, and the
  five key prefixes (`ghp_…`, `gho_…`, `ghs_…`, `sk-…`, `pk_…`).
- **Case-insensitive contains:** `MyPassword`, `API_TOKEN`, `Secret` excluded.
- **Case-sensitive prefix:** `ghp_real…` excluded; an uppercased `GHP_…` (not a
  real PAT) is *not* prefix-excluded — documents the intent, no over-block.
- **Negatives (must be recorded):** `git`, `deploy`, `kubectl`, `password`-free
  normal tokens → `excludes == false`.
- **Entropy BVA:** a 16-char all-distinct string (entropy `log2(16) = 4.0`,
  exactly the threshold) excluded; an 18-char one (the 16–19 gap) excluded; a
  15-char string *not* excluded (can't reach 4.0); a long low-entropy string
  (`aaaa…`) *not* excluded; `entropyThreshold = nil` disables it.
- **Empty pattern:** `.contains("")` / `.hasPrefix("")` exclude *nothing*, not
  everything.
- **Fail-toward-exclusion:** a token matching both a pattern and entropy is
  excluded (result agrees either way; no path records a flagged token).

## Out of scope (later slices)

- The **recording facade / tokenizer** that splits input and calls `excludes`
  before `record`.
- **User-editable rules** UI + `.regex` pattern case.
- Read-only mode, per-host incognito, master-off (orchestration-level toggles in
  [[2026-06-13-predictor-design]] §"Privacy controls", not write-time token rules).

## Related

- [[2026-06-13-predictor-design]] — privacy controls (pattern-exclude + entropy)
- [[2026-06-21-predictor-daily-rollover-design]] — the `record` path this gates
