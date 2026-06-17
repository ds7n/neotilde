# Glymr Implementation Roadmap

> **For agentic workers:** This is the **top-level roadmap** — it sequences the
> ~25 locked design specs into dependency-ordered phases. It is NOT a bite-sized
> task plan. Each phase gets its own detailed plan (see
> `docs/superpowers/plans/`) written with `superpowers:writing-plans` when that
> phase is next. Phase 0 is already detailed:
> `2026-06-17-phase-0-foundation.md`.

**Goal:** Ship Glymr v1 — an iOS SSH/mosh client with a tmux-control-mode session
engine, context-aware keybar, on-device predictor, and security-first credential
handling — building up from a verified foundation in dependency order.

**Architecture:** A Rust SSH core (`russh`) is bridged to Swift via a thin
UniFFI binding and consumed by a SwiftUI app. `tmux -CC` control mode runs over
the SSH channel; a Swift-side protocol parser turns its event stream into a
native pane model rendered with SwiftUI/UIKit. Secrets live in iCloud
Keychain / Secure Enclave; host metadata lives in CloudKit Private DB under
client-side AES-256-GCM.

**Tech Stack:** Swift 6 / SwiftUI, Rust (`russh` 0.61+, `tokio`, UniFFI 0.31+),
SwiftTerm (terminal emulator — see Decision D1), CryptoKit, CloudKit, Keychain
Services, Secure Enclave.

---

## Locked stack decisions (2026-06-17)

| Decision | Choice | Rationale / evidence |
|---|---|---|
| **SSH stack** | **russh** (Rust, Apache-2.0, v0.61.2) | Only actively-maintained stack with `mlkem768x25519` + OpenSSH cert auth + full per-category algorithm control + all forward types. Compiles for iOS today (cryptovec fix PR #483; aws-lc-rs ≥1.14 or `ring` backend). |
| **Swift↔Rust bridge** | **UniFFI 0.31+** with `#[uniffi::export(async_runtime = "tokio")]` | Full async→Swift `async/await` mapping; ships XCFramework tooling; proven by prior art (nikhilsh/conduit, jowparks/server-remote). No reusable russh→Swift binding exists — we build a thin one (~12–20 methods). |
| **Rust crypto backend** | Default **aws-lc-rs ≥1.14** for device; `ring` as the conservative fallback (`--no-default-features --features ring`) | aws-lc-rs iOS-sim bindgen fix landed v1.14.0 (2025-09-24). FIPS unsupported on iOS — use non-FIPS. |
| **Terminal emulator** | **SwiftTerm** (recommended — see Decision D1) | Maps ~1:1 to `terminal-emulator-scope-design`: xterm-256, truecolor, SGR mouse modes, DECSCUSR, OSC. Confirm before Phase 3. |

## Open decisions to resolve before their phase

- **D1 — Terminal emulator (before Phase 3):** SwiftTerm vs roll-own. Recommend
  SwiftTerm. Not yet user-confirmed.
- **D2 — `sntrup761x25519` gap (before Phase 1 ships):** russh has
  `mlkem768x25519` but **not** `sntrup761x25519` (russh issue #626). The
  Tier-1 allowlist in `ssh-algorithms-design.md` lists both. Options: (a) wait
  for upstream, (b) contribute it to russh, (c) amend the spec to make sntrup761
  opportunistic. Decide before declaring Tier-1 complete.
- **D3 — CloudKit container provisioning (before Phase 2):** needs an Apple
  Developer account + iCloud container identifier. Procurement, not engineering.

---

## Phase sequence

Phases are ordered so each builds only on verified, earlier work. Each produces
working, testable software on its own.

### Phase 0 — Foundations *(detailed plan written)*
Workspace + toolchain (Cargo workspace, SwiftPM packages, xcframework build
pipeline), Rust core crate + UniFFI bridge proof, the design-token layer, the
core data model (`Host`/`Identity`/`Defaults` + resolution), and the AES-256-GCM
record envelope.
**Specs:** `design-tokens`, `host-config-model` (schema + storage primitive only).
**Exit:** `swift test` green across all four task suites; `coreVersion()` round-trips Rust→Swift.

### Phase 1 — SSH core (the de-risking spike)
russh behind the UniFFI bridge: TCP+SSH handshake, host-key TOFU delegate,
auth (publickey / password / keyboard-interactive), OpenSSH cert presentation,
raw PTY shell channel with stdin write + stdout/stderr stream + resize,
`direct-tcpip` / `forwarded-tcpip` forwards, ProxyJump as nested channels, and
the four-tier algorithm allowlist enforced via russh's per-category config.
**Specs:** `ssh-algorithms`, `host-key-trust`, `ssh-cert-auth`, `chain-auth`.
**Exit:** integration tests against a containerized `sshd` in CI; cert auth + a 2-hop ProxyJump pass.

### Phase 2 — Storage & sync
Keychain identity store (iCloud-Keychain + Secure-Enclave flavors via
`SecAccessControl`), `known_hosts` in Keychain, CloudKit Private DB host/Defaults
records wrapped in the Phase-0 AES envelope, per-category iCloud sync toggles.
**Specs:** `host-config-model` (storage backbone), `identities-keys-management`
(store layer), `icloud-sync-scope`.
**Exit:** identity create→store→fetch round-trips on-device; CloudKit records readable only as ciphertext.

### Phase 3 — Terminal core + tmux control mode
SwiftTerm integration (Decision D1), the `tmux -CC` control-mode protocol parser
(`%output`/`%window-*`/`%layout-change`/`%begin`/`%end`), the native pane model,
SwiftUI pane rendering, degraded raw-PTY fallback, and the terminal feature set.
**Specs:** `terminal-emulator-scope`, `terminal-ux-additions`, `terminal-feedback`,
`degraded-mode`, `context-detection`, `function-keys`, `tmux-session`.
**Exit:** connect → tmux `-CC` → native panes render; split/new-window/resize work; raw-PTY fallback verified.

### Phase 4 — Keybar, input & predictor
Keybar layout/customization engine (locked-left + scroll, Esc pill, Pad,
sticky/lockable modifiers), macro/snippet unification, gesture ownership,
external-keyboard adaptation + Cmd-shortcut map, and the on-device predictor
(CMS + Bloom vocabulary, suggestion strip, seeded defaults).
**Specs:** `keybar-customization`, `function-keys` (keybar side), `external-keyboard`,
`predictor` (`docs/superpowers/specs/2026-06-13-predictor-design.md`).
**Exit:** keybar drives real input into a live pane; predictor suggests from learned vocabulary.

### Phase 5 — Host & identity UI
Host CRUD form (nine sections, default-collapse, inline identity sub-flow),
Identities & Keys management surface, first-host onboarding + Tips & Gestures.
**Specs:** `host-crud`, `identities-keys-management` (UI), `first-host-onboarding`.
**Exit:** create a host end-to-end through the UI and connect to it.

### Phase 6 — Connection management UI
Multi-connection lifecycle (Active / Live·Awake / Live·Sleeping / Recent),
Esc-pill picker, status banners + expanded banner templates, mosh roaming +
SSH sleep/reattach.
**Specs:** `multi-connection-switching`, `banner-expanded`.
**Exit:** 8-connection soft cap + LRU demotion; banner expand/collapse; mosh resume path.

### Phase 7 — Settings, security surface & ship polish
Settings sub-screens (Security / App preferences / About & Help), privacy
statement content, screen-capture protection, Pro/paid IAP, theme-picker
plumbing (hidden in v1), iPad single-window size-class pass.
**Specs:** `settings-sub-screens`, `privacy-statement`, `screen-capture-protection`,
`pro-paid-scope`, `design-tokens` (picker UI), `ipad-scope`.
**Exit:** App Store submission readiness — privacy section, IAP, all settings reachable.

---

## Cross-cutting constraints (apply to every phase)

- **No telemetry, analytics, crash reporting, ads, or third-party SDKs** (`privacy-statement-design`).
- **tmux ≥ 3.0** required for control mode; below that → raw-PTY degraded mode.
- **No inline hex in UI** — colors only via `Color.theme.*` tokens.
- **Secrets never in CloudKit** — keys/passwords/passphrases/`known_hosts` live in Keychain/SE; CloudKit holds only AES-GCM ciphertext of metadata.
- **Conventional commits**; squash-merge to keep history clean.
- **UUIDs internal, labels for humans** — references survive label edits.

## Dependency notes

- Phase 1 depends on Phase 0's Rust/UniFFI toolchain (Task 1) only.
- Phase 2 depends on Phase 0's data model (Task 3) + AES envelope (Task 4).
- Phase 3 depends on Phase 1 (SSH channel) and Phase 0 tokens.
- Phases 5–7 depend on the data/UI layers beneath them but are largely
  parallelizable once Phase 3 lands.
</content>
</invoke>
