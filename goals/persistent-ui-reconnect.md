---
goal_id: "persistent-ui-reconnect"
title: "Persist moo ui across phone disconnects"
status: "done"            # active | blocked | exited | done
confidence_floor: 90        # a Task below this CANNOT be ticked done
created: "2026-06-17"
updated: "2026-06-17"
---

# Goal: `moo ui` reconnects to the same persistent UI manager after an ungraceful phone/SSH disconnect, with no required change to the user's normal `moo ui` workflow.

## 1. Invariants · the rules that must not break

This file is the only state — if it isn't written here, it didn't happen. The full
procedure (boot loop, confidence rubric, logging cadence) lives in the
**goal-driven-development** skill; these rules hold even if that skill isn't loaded:

- **Scope is frozen after user confirms DoD + Tasks.** Until then, §3 and §5 may be
  edited freely. After confirm, the only permitted edits are: tick checkboxes (Task
  **and** DoD), update Confidence, append Evidence, append to the live sections
  (§6/§7/§8), and update frontmatter `status`/`updated` — never add, remove, reword,
  split, or merge a DoD item or Task, and never rewrite or delete a live-section entry.
- **Never tick below the floor.** A task is ticked done only at Confidence ≥
  `confidence_floor`. If you cannot reach it, leave it unticked and fire `CONFIDENCE-STALL`.
- **Scope change is an exit, not a decision.** If scope must change, record the
  proposal in §6 and fire `SCOPE-CHANGE` — stop and surface it to the user.
- **Live sections are append-only.** Log each decision (§6) and learning (§7) at
  the moment it happens — before ticking the task it came from. Never delete entries.

---

## 2. References

Everything the agent needs before/while working. Each entry is `path-or-url — why it matters`.

- User report, 2026-06-17 — using `moo` from a phone works until the phone drops; after reconnect, `moo ui` exits and the user must manually reattach to the TUI. Desired outcome: `moo ui` resumes the same UI surface like herdr/tmux, without changing normal interaction.
- `README.md` — documents the current architecture: foreground client over a Unix socket to per-session daemons, and one attached client per session.
- `src/main.zig` — `cmdUi` currently resolves workspace/socket dir and calls `ui.run`; `cmdAttach` reports lost client connections differently from UI.
- `src/ui.zig` — current `moo ui` is a foreground client/compositor; it exits on `SIGHUP`, `SIGTERM`, or TTY EOF and holds the focused session view in process memory.
- `src/client.zig` — plain attach raw-TTY lifecycle, signal handling, and terminal restore logic to mirror or reuse for a thin UI viewer.
- `src/daemon.zig` — session daemons already ignore `SIGHUP`, keep PTY/terminal state alive, and detach dead attached clients; useful model for a persistent UI manager.
- `src/protocol.zig` — existing framed Unix-socket protocol; likely place to add or reuse messages between a UI viewer and a UI manager.
- `src/paths.zig` — socket directory and workspace resolution; UI manager socket must live under the resolved workspace dir so default and named workspace UIs are isolated.
- `test/integration.zig` — real-PTY harness and existing `moo ui` tests; extend this to simulate ungraceful viewer loss and reconnect.

---

## 3. Definition of Done · INVARIANT

Each item is **atomic** (one verifiable assertion per checkbox), tagged with a
stable id that Tasks reference via **Closes:**, and carries a concrete `verify by:`.

Tick a `DoD-N` box only when its own `verify by:` has been run and passed (not merely
because a closing Task is ticked). Log the command and its outcome as an Evidence bullet
under the Task that **Closes:** it. DONE requires every DoD box ticked.

- [x] **DoD-1** — Running `moo ui` remains the normal user entrypoint; no new command, wrapper, or manual `moo attach` step is required to open or resume the UI. — *verify by:* `mise run test-all`, including existing UI startup tests plus a new reconnect test that invokes `moo ui` for both first attach and resume.
- [x] **DoD-2** — Existing `moo ui` interaction is preserved for the main surface: every pre-existing `ui:` integration test still passes after the manager/viewer split. — *verify by:* `mise run test-all`, including all existing `ui:` integration tests.
- [x] **DoD-3** — An ungraceful PTY EOF while `moo ui` is open leaves the focused session attached by the same persistent UI manager instead of detaching it. — *verify by:* `mise run test-all`, including a real-PTY test that closes the viewer PTY without sending `C-a d`, waits for the first viewer to exit, records the manager identity before and after, and asserts `moo ls --json` reports the previously focused session as attached.
- [x] **DoD-4** — An ungraceful `SIGHUP`/SSH-loss style viewer death while `moo ui` is open leaves the focused session attached by the same persistent UI manager instead of detaching it. — *verify by:* `mise run test-all`, including a real-PTY test that sends `SIGHUP` or closes the controlling process group without sending `C-a d`, waits for the first viewer to exit, records the manager identity before and after, and asserts `moo ls --json` reports the previously focused session as attached.
- [x] **DoD-5** — Re-running `moo ui` after ungraceful viewer loss reconnects to the same manager and repaints a deliberately non-default focused session without requiring session selection or `moo attach <name>`. — *verify by:* `mise run test-all`, including a real-PTY reconnect test with at least two sessions where the focused session is not the one a fresh UI startup would auto-select, and the same manager identity handles reconnect.
- [x] **DoD-6** — Input typed after reconnect is delivered to the previously focused non-default session. — *verify by:* `mise run test-all`, including a reconnect test that types a unique marker after the second `moo ui` starts and verifies it appears only in `moo peek` output for that named focused session.
- [x] **DoD-7** — Deliberate `C-a d` from `moo ui` preserves current close semantics: the viewer exits cleanly, terminal restore and close notice behave as before, and the focused session is not left attached solely to keep a resumable manager alive. — *verify by:* `mise run test-all`, including the existing `ui: quit with C-a d leaves sessions running and restores the terminal` test plus an assertion that `moo ls --json` reports the focused session detached after deliberate quit.
- [x] **DoD-8** — A second `moo ui` viewer steals the UI surface cleanly from the first viewer; the manager identity and focused session remain alive. — *verify by:* `mise run test-all`, including a real-PTY test with two concurrent `moo ui` clients where the first receives a clean detach/stolen outcome and the second can type into the focused session.
- [x] **DoD-9** — UI manager sockets are workspace-scoped: default `moo ui`, `moo ui -w proj`, and `MOO_WORKSPACE=proj moo ui` do not share managers or focused-session state across workspace dirs. — *verify by:* `mise run test-all`, including concurrent workspace reconnect tests with same-named sessions or distinct focus markers proving each entrypoint resumes only its own manager.
- [x] **DoD-10** — Stale UI manager sockets do not wedge startup and do not cause ordinary session sockets to be deleted. — *verify by:* `mise run test-all`, including tests for connection-refused stale socket, EOF/short handshake, malformed manager response, and preservation of normal `<session>.sock` files.
- [x] **DoD-11** — No persistent UI manager is left running forever after its workspace has no sessions and no viewer. — *verify by:* `mise run test-all`, including a cleanup test that records manager identity, kills all sessions in a workspace, detaches the viewer, and asserts the old manager exits or its socket is removed/refuses before a later `moo ui` starts from a fresh empty state.

---

## 4. Exit Conditions

The goal terminates when **any** condition holds. On exit, state which fired —
explicitly — in the response to the user.

- **`DONE`** — all §3 items ticked and all §5 tasks ≥ confidence floor. *(primary)*
- **`BLOCKED-DEP`** — Zig 0.15.2 / the mise-pinned development toolchain, the macOS SDK/linker environment, or the real-PTY integration harness is unavailable after one direct retry. Exit without the blocked step; name it explicitly.
- **`SCOPE-CHANGE`** — work cannot complete without changing the user-facing `moo ui` entrypoint, requiring a wrapper command, or changing deliberate `C-a d` close semantics. Record the proposal in §6 and exit to the user.
- **`CONFIDENCE-STALL`** — a task cannot reach the floor after two focused implementation attempts. Exit, report the task and the gap.
- **`BUDGET`** — three implementation passes are exhausted without a passing ungraceful-disconnect reconnect integration test. Exit and report progress.

---

## 5. Tasks · INVARIANT

Ordered, dependency-aware units of work that together satisfy the DoD. Tick the
trailing `[x]` only when the Verification Contract passes and Confidence ≥ floor.

---

### T1 · Freeze the reconnect contract and add red PTY tests · [x]

**Steps**
- [x] Trace current `moo ui` lifecycle from `cmdUi` through signal handling, TTY EOF, view attach, and terminal restore.
- [x] Define the UI manager socket path under the resolved workspace dir, including default workspace and named workspace behavior.
- [x] Extend the PTY harness with explicit ungraceful viewer-drop helpers that cover both PTY EOF and `SIGHUP`-style SSH loss without sending `C-a d`.
- [x] Add a manager identity probe usable by tests, such as a socket handshake id or PID sidecar, without requiring a new daily user workflow.
- [x] Add a red integration test for ungraceful disconnect: start at least two sessions, deliberately focus the session a fresh `moo ui` would not auto-select, drop the viewer, wait for the first viewer to exit, assert the focused session remains attached, rerun `moo ui`, and assert the same manager identity and non-default focused session are rendered.
- [x] Add red integration tests for deliberate `C-a d` preserving current quit semantics, second-viewer steal, workspace isolation, stale UI socket recovery, and manager cleanup.
- [x] Confirm the new tests fail on the current implementation for the expected reason: `moo ui` is a foreground process and no persistent UI manager exists.

**Verification Contract**
- *Check:* The new tests fail against current code because `moo ui` exits and releases focused UI state on TTY loss, not because of harness timing or unrelated setup.
- *Method:* `mise run test-integration -- --summary all`
- *Expected:* Non-zero exit before implementation, with at least the reconnect test failing on detached/no-manager behavior.
- *BDD scenarios covered:* Given `moo ui` is open on a deliberately non-default focused session, when the phone/SSH PTY disappears without `C-a d`, then the same UI manager remains and a later `moo ui` resumes the same focused session. Given deliberate `C-a d`, then current close semantics are preserved. Given two viewers, then one surface is active and the manager survives.

**Confidence:** 95 / 90 · **Depends on:** none · **Closes:** none

**Evidence (required before tick; append-only)**
- 2026-06-17 — `mise run test-integration -- -Dtest-filter="ui manager: PTY EOF reconnect resumes same non-default focus" --summary all` in throwaway `/tmp/moo-redtest` with only test/build-harness diff applied to `HEAD` — exit 1 as expected; `0/1` passed; failed on `timeout: ui manager id never appeared`, proving old `moo ui` had no persistent UI manager.

---

### T2 · Add a persistent UI manager socket lifecycle · [x]

**Steps**
- [x] Add path helpers for a per-workspace UI manager socket that cannot collide with normal session names.
- [x] Add startup logic so `moo ui` connects to an existing manager or starts one when the socket is missing/stale.
- [x] Make stale socket handling deterministic: connection refused, EOF during handshake, or malformed manager response removes/replaces only the UI manager socket.
- [x] Ensure the UI manager process has daemon-safe signal behavior: client `SIGHUP` does not kill it, but workspace teardown/no-session idle cleanup can.
- [x] Keep normal session sockets and control commands unchanged.

**Verification Contract**
- *Check:* `moo ui` can start, reconnect, and recover from stale manager sockets without changing per-session daemon behavior.
- *Method:* `mise run test-integration -- --summary all`
- *Expected:* Exit 0 for startup, stale socket, and session attach/detach tests that do not exercise viewer transport details.
- *BDD scenarios covered:* Given no UI manager socket exists, `moo ui` starts one. Given a stale UI manager socket exists, `moo ui` removes or replaces it. Given a session daemon socket exists, manager socket cleanup does not delete it.

**Confidence:** 95 / 90 · **Depends on:** T1 · **Closes:** DoD-1, DoD-9, DoD-10

**Evidence (required before tick; append-only)**
- 2026-06-17 — `mise run test-integration -- --summary all` — exit 0; `99/99` integration tests passed, including first `moo ui` attach/resume via the same entrypoint, workspace manager isolation, and refused/EOF/malformed/silent stale UI socket recovery without deleting normal session sockets.

---

### T3 · Split `moo ui` into persistent manager and thin viewer · [x]

**Steps**
- [x] Move persistent UI state out of the foreground viewer: sessions list, selected/focused session, `View`, keyboard-mode mirror state, and reconnect-relevant status.
- [x] Keep TTY-specific state in the viewer: raw mode, terminal enter/restore, resize reads, signal pipe, and output writes to fd 1.
- [x] Define a framed viewer-manager protocol for terminal input, resize, repaint/output frames, lifecycle messages, and viewer detach/steal.
- [x] Preserve the existing UI compositor behavior when exactly one viewer is attached.
- [x] Ensure the manager continues polling focused session daemon sockets while no viewer is attached.

**Verification Contract**
- *Check:* Existing UI behavior still passes with the manager/viewer split, and the focused session remains attached when the viewer disappears.
- *Method:* `mise run test-integration -- --summary all`
- *Expected:* Exit 0 for all pre-existing `ui:` tests plus the ungraceful-disconnect attachment assertion.
- *BDD scenarios covered:* Given `moo ui` is used normally, the visible UI behaves as before. Given the viewer disappears, the manager keeps the focused session view attached. Given session output arrives while no viewer is attached, reconnect repaints from current state.

**Confidence:** 95 / 90 · **Depends on:** T2 · **Closes:** DoD-2, DoD-3, DoD-4

**Evidence (required before tick; append-only)**
- 2026-06-17 — `mise run test-integration -- --summary all` — exit 0; `99/99` integration tests passed, including all pre-existing `ui:` tests plus new PTY EOF and `SIGHUP` reconnect tests that assert the focused session stays attached through viewer loss.

---

### T4 · Implement reconnect, deliberate quit, and viewer-steal semantics · [x]

**Steps**
- [x] On new viewer attach, send a full repaint for the manager's current UI state and focused session.
- [x] On ungraceful viewer EOF, mark only the viewer detached; do not destroy the manager, selected session, or focused `View`.
- [x] On deliberate `C-a d`, preserve current quit semantics: close the UI surface, restore terminal state, and release the focused session rather than keeping it attached solely for resumability.
- [x] On a second viewer attach, detach or steal the previous viewer cleanly and keep manager state intact.
- [x] Make post-reconnect input flow to the manager's previously focused session without requiring selection.

**Verification Contract**
- *Check:* Reconnect after TTY drop, deliberate `C-a d` quit semantics, second-viewer steal, and post-reconnect input all pass against real PTYs.
- *Method:* `mise run test-integration -- --summary all`
- *Expected:* Exit 0 for reconnect-focused integration tests.
- *BDD scenarios covered:* Given an ungraceful phone drop, a later `moo ui` resumes the same focused session. Given deliberate `C-a d`, the UI closes as before and does not leave a hidden attachment behind. Given two viewers, the newer viewer controls the surface and the older one exits cleanly. Given input after reconnect, it reaches the same session.

**Confidence:** 95 / 90 · **Depends on:** T3 · **Closes:** DoD-5, DoD-6, DoD-7, DoD-8

**Evidence (required before tick; append-only)**
- 2026-06-17 — `mise run test-integration -- --summary all` — exit 0; `99/99` integration tests passed, including non-default focus repaint after reconnect, gap output while no viewer was attached, post-reconnect input delivered only to the previously focused session, deliberate `C-a d` detaching the session, and second-viewer steal.

---

### T5 · Prove workspace isolation and manager cleanup · [x]

**Steps**
- [x] Verify default workspace and each named workspace get independent UI manager sockets.
- [x] Verify `moo ui -w proj` and `MOO_WORKSPACE=proj moo ui` resume only the `proj` manager and never the default manager, using same-named sessions or distinct focus markers to prove state isolation.
- [x] Define and implement manager cleanup when no viewer is attached and the manager's workspace has no live user sessions.
- [x] Keep internal UI manager artifacts out of normal `moo ls` session listings.
- [x] Strengthen tests with manager identity/liveness evidence if a manager process, socket, or sidecar can outlive its useful workspace state.

**Verification Contract**
- *Check:* Workspace managers are isolated, do not appear as user sessions, and do not persist indefinitely after workspace teardown.
- *Method:* `mise run test-integration -- --summary all`
- *Expected:* Exit 0 for workspace reconnect and cleanup tests; `moo ls` output includes only user sessions and no old manager identity survives after cleanup.
- *BDD scenarios covered:* Given default and `proj` UIs both exist, reconnecting each returns to its own focus state. Given all sessions in `proj` are killed and the viewer detaches, the `proj` manager exits or is cleaned so the next UI starts from empty state.

**Confidence:** 95 / 90 · **Depends on:** T4 · **Closes:** DoD-9, DoD-11

**Evidence (required before tick; append-only)**
- 2026-06-17 — `mise run test-integration -- --summary all` — exit 0; `99/99` integration tests passed, including default vs `-w proj` vs `MOO_WORKSPACE=proj` manager identity/focus isolation and cleanup after the last session/viewer is gone.

---

### T6 · Final validation, documentation, and review · [x]

**Steps**
- [x] Update help/README only where the reconnect behavior or manager lifecycle needs user-visible documentation; do not require a new daily workflow.
- [x] Run formatting and unit tests.
- [x] Run the full PTY integration suite in the pinned Zig/mise environment.
- [x] Inspect `git diff --stat` and keep the diff limited to UI manager, protocol/path helpers, tests, and focused docs.
- [x] Get an independent completion review against the DoD and logged evidence before marking DONE.

**Verification Contract**
- *Check:* Full validation passes and documentation matches the no-UX-change product contract.
- *Method:* `mise run check-release`
- *Expected:* Exit 0; docs mention reconnect behavior without telling users to run a wrapper or manual attach step.
- *BDD scenarios covered:* Regression sweep for normal attach, normal UI use, reconnect after phone drop, workspace scope, and cleanup.

**Confidence:** 95 / 90 · **Depends on:** T5 · **Closes:** DoD-1, DoD-2, DoD-3, DoD-4, DoD-5, DoD-6, DoD-7, DoD-8, DoD-9, DoD-10, DoD-11

**Evidence (required before tick; append-only)**
- 2026-06-17 — `mise run fmt-check` — exit 0.
- 2026-06-17 — `mise run test -- --summary all` — exit 0; `162/162` unit tests passed.
- 2026-06-17 — `mise run test-integration -- --summary all` — exit 0; `99/99` integration tests passed.
- 2026-06-17 — `mise run test-all -- -Doptimize=ReleaseSafe --summary all` — exit 0; `261/261` tests passed (`162` unit, `99` integration).
- 2026-06-17 — `mise run check-release` — exit 0 after the final stale-handshake fix.
- 2026-06-17 — Final independent QA subagent review — verdict `pass`, findings empty; reviewer also ran `git diff --check` and `mise run check-release` successfully.
- 2026-06-17 — `git diff --stat` — scoped to `README.md`, `build.zig`, `src/help.zig`, `src/main.zig`, `src/paths.zig`, `src/ui.zig`, and `test/integration.zig`; no unrelated source files.

---

## 6. Decisions · LIVE (append-only)

Meaningful choices/concessions needing visibility. Scope impact must be `none`.

- 2026-06-17 — Preferred product fix is a per-workspace persistent UI manager socket, not a normal host session running `moo ui`, because a host session would need special raw/passthrough attach semantics to avoid nested `Ctrl-A` interception. Scope impact: none.
- 2026-06-17 — User-facing UX must stay effectively unchanged: `moo ui` opens/resumes the full-screen UI; reconnect should remove manual reattach friction rather than introduce a wrapper or separate resume command. Scope impact: none.
- 2026-06-17 — Adversarial review found that making deliberate `C-a d` resumable would change current close semantics, and that reconnect tests could falsely pass if a fresh manager auto-selected the same session. The goal was tightened to preserve deliberate quit behavior, require manager identity evidence, and focus a non-default session in reconnect tests. Scope impact: none.

---

## 7. Learnings · LIVE (append-only)

Flash cards: trigger → wrong action → revision → correct action, with impact `1–5`.
When an attempt failed and the fix is not yet known, log the **open form** —
trigger → wrong action → *(open: revision/correct not yet found)* → pointer to the raw
failure (log path or commit) — still impact-tagged, so a dead-end is recorded before a
fresh context re-treads it.

*(none yet)*
- 2026-06-17 — Trigger: ReleaseSafe stale EOF manager recovery intermittently surfaced `error: Unexpected` from the initial viewer attach write; wrong action: treating only `BrokenPipe` as the stale-manager handshake failure; revision: normalize any failed initial attach frame write into `ConnectionLost` before manager hello; correct action: stale manager sockets are replaced before any handshake is considered live. Impact: 4.
- 2026-06-17 — Trigger: final QA found reconnect races around stale host identity, silent pre-hello sockets, pre-hello output, coalesced attach/input, inherited SIGTERM handlers, and pending viewer replacement; wrong action: relying on broad reconnect tests alone; revision: add targeted manager tests and harden viewer handshake/manager loop semantics; correct action: reviewer-specific edge cases get explicit tests or loop invariants before marking DONE. Impact: 4.

---

## 8. Skills · LIVE (append-only)

Reusable workflows created via the **skill-creator** skill while working this goal.

*(none yet)*
