# Phase 1f — ProxyJump (jump-host chains)

**Date:** 2026-06-19
**Status:** Complete (5 integration tests green; `connect_jump` on `master`)
**Spec:** `docs/superpowers/specs/2026-06-17-chain-auth-design.md` (UX framing; the
iOS Face-ID summary modal is macOS-gated and deferred — this phase delivers the
Rust-core nested-channel mechanism only).
**Roadmap exit criterion:** "cert auth + a 2-hop ProxyJump pass."

## Goal

Connect to a target host *through* one or more SSH jump hosts, the way
`ssh -J bastion target` does: each hop is a full SSH transport, and the next
hop's transport rides inside a `direct-tcpip` channel opened on the previous
hop. Prove an arbitrary-depth chain establishes and that channels (shell,
forwards) work on the final, jumped connection.

## Mechanism

Nested SSH over `russh::client::connect_stream`, which accepts any
`AsyncRead + AsyncWrite + Unpin + Send` stream. A `russh::Channel::into_stream()`
(`ChannelStream`) is exactly such a stream. So one jump is:

1. On the current `Connection`, open `channel_open_direct_tcpip(next_host,
   next_port, "127.0.0.1", 0)`.
2. `channel.into_stream()`.
3. `connect_stream(config, stream, handler)` with a **fresh** `ClientHandler`
   (own host-key verifier, own Tier-3 tracking, own forwards map) → new `Handle`.
4. Wrap it in a new `Connection` that **keeps the parent handles alive**.

The caller drives the whole chain by reusing the existing auth methods, in the
serial order the chain-auth spec describes:

```
let jump  = connect("bastion:22", …)?;  jump.authenticate_*(…)?;
let target = jump.connect_jump("target", 22, …)?;  target.authenticate_*(…)?;
// use target.open_shell / open_*_forward
```

No new auth code: per-hop auth is just the existing methods called on each
intermediate `Connection`. Each hop's host key is verified independently by the
verifier passed to that hop.

## API

One new method on `Connection`, mirroring `connect`:

```rust
pub async fn connect_jump(
    &self,
    target_host: String,
    target_port: u16,
    allow_legacy: bool,
    allow_deprecated: bool,
    verifier: Arc<dyn HostKeyVerifier>,
) -> Result<Arc<Connection>, ConnectError>
```

## Lifetime / teardown

`Connection` gains `parents: Vec<Arc<Mutex<Handle>>>` — the handle-Arcs of every
hop closer to the device. `connect_jump` sets the child's `parents` to
`self.parents.clone()` + `self.handle`. Keeping a parent's `Handle` alive keeps
its russh session loop running, which keeps the `direct-tcpip` channel (and thus
the child's transport) alive. Dropping the final `Connection` drops all parent
Arcs, tearing the chain down. A direct (non-jumped) connection has an empty
`parents`.

## Refactor

Extract the shared config + handler construction (currently inline in
`connect_core`) into a private helper used by both `connect_core` and
`connect_jump`, including the `rejected → HostKeyRejected` mapping.

## Tests (TDD, against docker `sshd` / `sshd-legacy`)

Both fixtures share the compose network, so from the `sshd` container the next
hop (`sshd-legacy:22`, or `127.0.0.1:22` = itself) is reachable.

1. **Two-hop shell** — dev → `sshd` (jump) → `sshd-legacy` (target); open a
   shell on the target, run `echo`, assert the marker appears. Proves the full
   nested path and that channels work on the jumped connection. (`sshd-legacy`
   offers only Tier-3 algorithms, so the target hop uses
   `allow_deprecated = true` — also exercises per-hop algorithm policy.)
2. **Forward over a jump** — dev → `sshd` → `sshd` (via `127.0.0.1:22`); open a
   local forward on the jumped connection to `127.0.0.1:22` and read an `SSH-`
   banner through it. Proves forwards compose with jumps.
3. **Target host key rejected** — verifier on the target hop returns false;
   `connect_jump` returns `ConnectError::HostKeyRejected` (the specific variant,
   not a generic transport error).
4. **Target auth failure is independent** — jump-host auth succeeds, target-host
   auth with a wrong password is `AuthOutcome::Failure` (not an error, and the
   jump transport is unaffected).

## Out of scope

- iOS Face-ID summary modal and serial-prompt UX (macOS-gated; chain-auth spec).
- Host-key cert-variant allowlist additions (separate remaining Phase 1 item).
