---
goal_id: "http-rest-api"
title: "Ship remote HTTP API"
status: "complete"
confidence_floor: 90
created: "2026-06-24"
updated: "2026-06-24"
---

# Goal: Remote clients can create, inspect, drive, wait on, and retire `moo` sessions through a localhost-first REST API backed by existing libghostty session daemons.

## 1. Invariants

This is the root orchestration document for this goal. A fresh orchestrator or
subagent should be able to resume from this file without prior chat context.

- Keep the central state in this root-level `GOAL.md`; do not move it to
  `goals/`.
- Treat section 3 DoD and section 5 Tasks as invariant now that the goal has
  been implemented.
- Tick a DoD or Task only when its verification command has passed and the task
  confidence is at least `confidence_floor`.
- Append decisions, learnings, and evidence; do not erase useful history.
- Subagent results are evidence candidates. The orchestrator must validate
  through local commands before marking the goal complete.
- Preserve the current product model: session daemons own libghostty terminal
  state, and HTTP is a control-plane gateway over them.

## 2. References

- `README.md` - public usage docs and architecture overview.
- `src/main.zig` - CLI command routing plus the new `moo serve` HTTP gateway.
- `src/client.zig` - Unix-socket control bridge to per-session daemons.
- `src/daemon.zig` - per-session daemon, PTY/libghostty owner, and control
  commands.
- `src/protocol.zig` - length-prefixed Unix-socket protocol and payload limits.
- `src/window.zig` - libghostty-backed terminal screen/input/resize primitives.
- `src/paths.zig` - runtime directory, workspace, sidecar, and transcript paths.
- `src/harness.zig` - live agent transcript detection and dump behavior.
- `test/integration.zig` - end-to-end PTY, agent, CLI, and HTTP integration
  harness.
- `docs/http-api.md` - v1 HTTP API contract.
- `docs/adrs/0001-http-api-gateway.md` - architecture decision record.
- `build.zig` and `justfile` - build, test, format, and full check surfaces.

## 3. Definition Of Done

- [x] **DoD-1** - `moo serve` can start a localhost HTTP server, report its
  effective bind address, and shut down cleanly without creating or stealing a
  terminal session. Verify by: `nix develop --command zig build
  test-integration -Dtest-filter "http api: serve lifecycle"`.
- [x] **DoD-2** - REST workspace and session management supports create, list,
  inspect, rename, and delete while preserving existing workspace isolation.
  Verify by: `nix develop --command zig build test-integration -Dtest-filter
  "http api: workspace session management"`.
- [x] **DoD-3** - REST input, screen snapshot, and wait endpoints can drive a
  detached interactive PTY and read libghostty-rendered screen state without
  using `attach` or stealing the session. Verify by: `nix develop --command zig
  build test-integration -Dtest-filter "http api: drive wait screen"`.
- [x] **DoD-4** - REST transcript endpoints expose existing `--agent
  claude|codex|pi` status and de-noised transcript JSON for live sessions.
  Verify by: `nix develop --command zig build test-integration -Dtest-filter
  "http api: agent transcript"`.
- [x] **DoD-5** - REST long-poll event endpoints return monotonic cursors for
  session lifecycle and output-related changes, including timeout behavior with
  no false progress. Verify by: `nix develop --command zig build
  test-integration -Dtest-filter "http api: event cursors"`.
- [x] **DoD-6** - HTTP exposure is localhost-first and guarded by token auth for
  any non-loopback bind or configured token, with unauthorized requests rejected
  before touching session state. Verify by: `nix develop --command zig build
  test-integration -Dtest-filter "http api: auth and bind safety"`.
- [x] **DoD-7** - The REST API contract is documented with endpoint paths,
  methods, JSON request/response schemas, status codes, auth rules, and curl
  examples for AI-agent coordination. Verify by: `test -f docs/http-api.md &&
  rg -n "POST /v1/workspaces/.*/sessions|Authorization|event cursor|curl"
  docs/http-api.md`.
- [x] **DoD-8** - The implementation passes the full existing gate plus the new
  HTTP integration coverage without weakening current CLI, workspace, PTY, UI,
  or agent transcript behavior. Verify by: `just check`.

## 4. Exit Conditions

- **`DONE`** - all DoD items and all tasks are complete with valid evidence.
- **`BLOCKED-DEP`** - Zig/Nix/libghostty/PTY prerequisites are unavailable after
  a clean retry and targeted diagnosis.
- **`SCOPE-CHANGE`** - completion requires replacing the session-daemon model,
  mandatory SSH, splits/tabs, or mandatory SSE/WebSocket for v1.
- **`CONFIDENCE-STALL`** - any task remains below 90 confidence after three
  focused attempts and one independent review pass.

Current exit condition: `DONE`.

## 5. Tasks

### T1 - Confirm architecture and freeze REST contract - [x]

**Steps**
- [x] Assign a read-only architecture subagent to map session creation, daemon
  control, workspace isolation, transcript handling, and test harnesses.
- [x] Write `docs/http-api.md` with endpoint table, auth policy, JSON shapes,
  lifecycle model, cursor semantics, and non-goals.
- [x] Choose long-poll event cursors for v1; keep SSE/WebSocket out of scope.
- [x] Reconcile payload limits, NUL handling, workspace resolution, and attached
  client semantics.

**Confidence:** 95 / 90 - **Closes:** DoD-7

**Evidence**
- 2026-06-24: `test -f docs/http-api.md && rg -n "POST /v1/workspaces/.*/sessions|Authorization|event cursor|curl" docs/http-api.md` exited 0.

### T2 - Extract reusable session operations from CLI code - [x]

**Steps**
- [x] Introduce reusable helpers for session create, resolve, list, inspect,
  input, wait, transcript, rename, resize, and kill operations.
- [x] Preserve existing CLI output and exit behavior by keeping CLI wrappers on
  top of shared helpers.
- [x] Use `client.control` for daemon interaction; do not shell out to `moo` from
  HTTP handlers.
- [x] Add focused unit coverage for extracted parsing and address behavior.

**Confidence:** 95 / 90 - **Depends on:** T1 - **Closes:** none

**Evidence**
- 2026-06-24: `nix develop --command zig build test -Dtest-filter=parse` exited 0; `just check` covered the broader CLI and integration matrix.

### T3 - Add `moo serve` lifecycle and routing foundation - [x]

**Steps**
- [x] Add `moo serve --addr` and optional `--token-env`, including bind-to-port-0
  readiness output.
- [x] Implement bounded HTTP/1.1 request parsing, JSON response helpers, and
  structured errors.
- [x] Ensure `serve` starts no session and never attaches to an existing session.
- [x] Add lifecycle integration coverage.

**Confidence:** 95 / 90 - **Depends on:** T2 - **Closes:** DoD-1

**Evidence**
- 2026-06-24: `nix develop --command zig build test-integration -Dtest-filter='http api: serve lifecycle'` exited 0.

### T4 - Implement workspace and session management endpoints - [x]

**Steps**
- [x] Implement `GET /v1/workspaces`.
- [x] Implement create/list/inspect/rename/delete session endpoints.
- [x] Preserve workspace isolation for every workspace-scoped request.
- [x] Cover bad names, missing sessions, duplicate names across workspaces, and
  scoped delete behavior.

**Confidence:** 95 / 90 - **Depends on:** T3 - **Closes:** DoD-2

**Evidence**
- 2026-06-24: `nix develop --command zig build test-integration -Dtest-filter='http api: workspace session management'` exited 0.

### T5 - Implement input, screen, wait, and resize endpoints - [x]

**Steps**
- [x] Implement text input and document current NUL/binary constraints.
- [x] Implement visible screen and scrollback snapshots with geometry and title.
- [x] Implement wait for visible text and idle with bounded timeout semantics.
- [x] Add daemon `resize` control and REST resize endpoint.
- [x] Prove HTTP does not use `attach` or steal an attached session.

**Confidence:** 95 / 90 - **Depends on:** T4 - **Closes:** DoD-3

**Evidence**
- 2026-06-24: `nix develop --command zig build test-integration -Dtest-filter='http api:'` exited 0; HTTP group covered drive/wait/screen and resize scenarios.

### T6 - Implement live agent transcript endpoints - [x]

**Steps**
- [x] Expose live-session transcript state through sidecars and `harness.Agent`
  behavior.
- [x] Document saved-log transcript reads as out of scope for the HTTP MVP.
- [x] Preserve supported states including `idle`, `running`,
  `waiting_for_input`, `truncated`, `unknown`, and `exited`.
- [x] Cover REST-created and CLI-created agent sessions.

**Confidence:** 95 / 90 - **Depends on:** T4 - **Closes:** DoD-4

**Evidence**
- 2026-06-24: `nix develop --command zig build test-integration -Dtest-filter='http api:'` exited 0; HTTP group covered agent transcript scenarios.

### T7 - Add long-poll event cursors for async coordination - [x]

**Steps**
- [x] Define a monotonic per-session cursor covering input, output, resize,
  rename, lifecycle, and exit-related changes.
- [x] Implement `GET .../events?since=<cursor>&timeout=<duration>`.
- [x] Document cursor limitations and non-durable history.
- [x] Keep SSE/WebSocket out of v1.

**Confidence:** 95 / 90 - **Depends on:** T5 - **Closes:** DoD-5

**Evidence**
- 2026-06-24: `nix develop --command zig build test-integration -Dtest-filter='http api:'` exited 0; HTTP group covered event cursor advance and timeout scenarios.

### T8 - Enforce HTTP auth and bind safety - [x]

**Steps**
- [x] Require bearer auth when `--token-env` is set.
- [x] Refuse non-loopback binds unless token auth is configured.
- [x] Reject unauthorized requests before session state is accessed.
- [x] Return structured errors without transcript/env leakage.

**Confidence:** 95 / 90 - **Depends on:** T3 - **Closes:** DoD-6

**Evidence**
- 2026-06-24: `nix develop --command zig build test-integration -Dtest-filter='http api:'` exited 0; HTTP group covered auth and bind safety.

### T9 - Integrate docs, examples, and full verification - [x]

**Steps**
- [x] Update README and help text with `moo serve` discovery.
- [x] Add curl examples in `docs/http-api.md`.
- [x] Run targeted HTTP tests, unit tests, integration tests, format check, and
  full `just check`.
- [x] Coordinate bounded subagents for architecture, tests, implementation, and
  completion review.
- [x] Clean up temporary API processes and avoid relying on subagent output as
  proof without local verification.

**Confidence:** 95 / 90 - **Depends on:** T1, T2, T3, T4, T5, T6, T7, T8 -
**Closes:** DoD-8

**Evidence**
- 2026-06-24: `just fmt-check` exited 0.
- 2026-06-24: `just test` exited 0.
- 2026-06-24: `just check` exited 0 after format check, ReleaseSafe build, unit
  tests, and the full PTY integration suite.

## 6. Decisions

### 2026-06-24 - Root-level GDD document

- **Context:** The GDD skill defaults to `goals/<slug>.md`, but the user
  requested a root-level `GOAL.md`.
- **Decision:** Keep central orchestration state at repository root as
  `GOAL.md`.
- **Alternatives rejected:** Creating only `goals/http-rest-api.md`; maintaining
  duplicate goal files.
- **Scope impact:** none.

### 2026-06-24 - MVP transport shape

- **Context:** The request asks for HTTP RESTful async interactions and SSH-free
  remote coordination.
- **Decision:** Deliver a central `moo serve` HTTP gateway over existing session
  daemons, with long-poll event cursors for async coordination.
- **Alternatives rejected:** HTTP listener inside every session daemon; mandatory
  SSH bridge; mandatory WebSocket/SSE in the MVP; adding splits/tabs first.
- **Scope impact:** none.

### 2026-06-24 - HTTP gateway implementation shape

- **Context:** The implementation needed to preserve libghostty/PTTY ownership
  and existing CLI semantics while adding remote interaction.
- **Decision:** Implement HTTP routing in `src/main.zig`, keep terminal state in
  session daemons, extend `src/daemon.zig` with `state`, `resize`, and event
  cursor controls, and cover behavior with real integration tests.
- **Alternatives rejected:** Shelling out from HTTP handlers; replacing daemon
  control; moving terminal state into the API server.
- **Scope impact:** none.

### 2026-06-24 - Completion evidence

- **Commands passed:**
  - `nix develop --command zig build test -Dtest-filter=parse`
  - `nix develop --command zig build test-integration -Dtest-filter='http api: serve lifecycle'`
  - `nix develop --command zig build test-integration -Dtest-filter='http api: workspace session management'`
  - `nix develop --command zig build test-integration -Dtest-filter='http api:'`
  - `test -f docs/http-api.md && rg -n "POST /v1/workspaces/.*/sessions|Authorization|event cursor|curl" docs/http-api.md`
  - `just fmt-check`
  - `just test`
  - `just check`
- **DoD closed:** DoD-1 through DoD-8.
- **Task confidence:** T1 through T9 are marked 95/90.
- **Exit condition:** `DONE`.

## 7. Learnings

### 2026-06-24 - Bound reviewer delegation explicitly

- Trigger -> review prompts asked for subagents but did not forbid
  subdelegation.
- Wrong action -> reviewers recursively spawned more reviewers and stalled the
  authoring flow.
- Revision -> interrupt recursive fanout and continue with bounded direct
  review.
- Correct action -> future reviewer prompts in this goal should request exactly
  one read-only reviewer with no further subdelegation.
- impact: 4/5

### 2026-06-24 - Keep HTTP accepted fds out of daemon children

- Trigger -> HTTP-created sessions daemonized while inheriting the accepted
  client connection fd.
- Wrong action -> attempted broad inherited-fd closure in the child process.
- Revision -> close only the known accepted HTTP connection fd before daemonize.
- Correct action -> keep `session_child_close_fd` narrowly scoped to the session
  start path used by HTTP handlers.
- impact: 4/5

## 8. Skills

- `engineering-practices` - used for implementation discipline, bounded
  delegation, and verification.
- `goal-driven-development` - used for DoD/task structure, confidence floor, and
  central orchestration state.

## 9. Current State

- `status`: complete.
- `confidence`: 95 / 90.
- `latest proof`: rerun targeted HTTP coverage and `just check` after any code
  changes before merging.
- `residual risk`: HTTP is a simple JSON HTTP/1.1 gateway, not a durable event
  log or streaming terminal protocol. Binary/NUL-safe input remains out of v1.
