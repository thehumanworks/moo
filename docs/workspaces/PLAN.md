# Workspaces — implementation plan & execution loop

Status: ready for handover. Owner of record: orchestrator (this session).

Companion docs: `GOAL.md` (what done means) and `HANDOFF.md` (how to orchestrate
the delivery — start there when told to execute). This file holds the per-task
specs, the gate, and the loop.

A **workspace** is a named socket subdirectory. Sessions in a workspace live in
their own directory under the base moo dir, so listing, killing, and the UI are
scoped by *which directory they open* rather than by a filter every call site
must remember. The directory boundary is moo's existing unit of isolation
(everything keys off `paths.socketDir`), so this design reuses it instead of
adding a new cross-cutting dimension.

```
$MOO_DIR (or $XDG_RUNTIME_DIR/moo, or /tmp/moo-<uid>)   ← base dir = default workspace
├── work.sock / work.agent           ← unnamed sessions (today's behaviour, unchanged)
└── ws/
    └── <workspace>/                  ← one dir per named workspace, mode 0700
        ├── fix.sock / fix.agent
        └── fix.store/
```

Active workspace resolves: `-w/--workspace <name>` flag → `MOO_WORKSPACE` env →
none (base dir). The daemon exports `MOO_WORKSPACE` into each session's env, so an
orchestrator running *inside* a workspace session inherits it and every `moo`
call it makes is physically confined to that directory — it cannot see or kill
sessions in other workspaces. That is the isolation guarantee, by construction.

Open product decision (does not block W1–W5): in the Phase-2 UI, should `moo ui`
with no `-w` default to **scoped to the active workspace** (recommended) or
**show-all-grouped**? W6 is written for scoped-by-default with a toggle.

---

## The verification gate ("definition of done")

Zig has no separate linter: `zig fmt --check` is the format/lint gate and a clean
`zig build` (the compiler's semantic analysis) is the rest. The toolchain is
**pinned to Zig 0.15.2 via `mise`** — the host Zig is 0.16.0 and is
rejected by ghostty, so bare `zig` will fail. Always go through `mise run` tasks
so the repo-pinned Zig/Bun tools are active.

Every task is done only when ALL of these are captured green:

| Gate | Command | Applies to |
|------|---------|------------|
| Format / lint | `mise run fmt-check` | every task |
| Build (compiler analysis) | `mise run build` | every task |
| Unit tests | `mise run test` | every task |
| PTY integration tests | `mise run test-all` | tasks touching runtime/CLI/daemon/UI behaviour |
| ReleaseSafe full | `mise run check-release` | final pre-merge pass only |

`mise run check` = `fmt-check` + `build` + `test-all` in one shot; that is the
standard per-task gate. CI enforces the same set (`.github/workflows/ci.yml`:
`zig fmt --check`, `zig build`, `zig build test`, `zig build test-integration`,
plus a ReleaseSafe `test-all`).

Baseline status on the pulled tree (commit 7ac284f, macOS aarch64): GREEN.
- Unit `156/156`; PTY integration `72/72`; `zig fmt --check` clean; `mise run check`
  exit 0 (228/228), confirmed even with `MOO` set in the shell.
- One integration test (`ui: create and kill sessions from the ui`) initially
  failed locally ONLY because the suite was run from inside a moo session, so
  `MOO=<name>` leaked into the spawned `moo ui` and was taken as its host name
  (src/ui.zig:1039), colliding with the cwd-derived name of the session that
  `C-a c` creates. Fixed in W0.1 by making the harness hermetic (it now clears
  `MOO`/`MOO_FOREGROUND`/`MOO_LOG`); no production code changed. CI was never
  affected (`$MOO` unset there); it was not a product bug or a regression.

Gate rule: every task must leave `mise run check` fully green (all 228 tests pass).

A completion claim for any task must cite the captured exit code / summary line
of `mise run check` (or `mise run check-release` for the final pass), plus the new test
that was observed **failing before** the implementation and **passing after**.
No proxy (it compiles, the process is alive) counts as done.

---

## The loop: goal-driven, role-separated

Each task runs through four roles. Roles are **different agents** — the
implementer must never grade its own work, and must treat the authored tests as a
fixed contract it may not weaken, skip, or delete. A one-line mechanical task may
collapse roles, but every W-task below is non-trivial enough to keep them split.

```
  ┌─ 1. TEST AUTHOR ──────────────────────────────────────────────┐
  │  Reads the real interfaces. Writes the failing test(s)         │
  │  encoding the acceptance criteria. Runs them, captures RED.    │
  │  Output: test diff + captured failing output.                  │
  └───────────────────────────────────────────────────────────────┘
                     │ contract (tests) is now fixed
                     ▼
  ┌─ 2. IMPLEMENTER ──────────────────────────────────────────────┐
  │  Smallest change to make the authored tests pass. May NOT      │
  │  relax/skip/delete them; surfaces a conflict instead if one    │
  │  cannot be satisfied honestly. Runs `mise run check`, captures it. │
  │  Output: impl diff + captured green gate.                      │
  └───────────────────────────────────────────────────────────────┘
                     │
                     ▼
  ┌─ 3. REVIEWER (adversarial, different agent) ──────────────────┐
  │  Finds issues in the diff, then tries to refute each. Reports  │
  │  only survivors, with file:line. Checks: backward compat,      │
  │  memory ownership/leaks (Zig allocators), error paths, the     │
  │  tests actually constrain behaviour (not tautologies).         │
  │  Output: pass/fail + surviving findings.                       │
  └───────────────────────────────────────────────────────────────┘
                     │ findings → back to implementer; else ↓
                     ▼
  ┌─ 4. QA (different agent) ──────────────────────────────────────┐
  │  Runs `mise run check` (or check-release) clean AND walks the      │
  │  task's manual scenario against the built binary. Confirms the │
  │  acceptance criteria map 1:1 to evidence. Output: verdict +    │
  │  captured artifacts.                                           │
  └───────────────────────────────────────────────────────────────┘
```

Orchestrator (this session) drives the loop: assigns each role, carries the
artifact from one role to the next, marks the harness task `completed` only when
QA passes, and re-opens the task on any reviewer/QA failure.

---

## Subagent handover brief (template)

Every role gets exactly this, filled in. Keep it self-contained — the subagent
has no memory of this session.

```
TASK:        <Wn — one-sentence outcome>
ROLE:        <test-author | implementer | reviewer | qa>
REPO:        /Users/mish/projects/moo   (Zig 0.15.2 via `mise`; use `mise run`)
SURFACE:     <exact files + functions, with file:line from the plan>
CONTEXT:     <pointers/excerpts the role needs; nothing more>
CONTRACT:    <for implementer/reviewer/qa: the authored tests are fixed — do not weaken>
CONSTRAINTS: backward compatible (no workspace ⇒ identical to today);
             reuse paths.validateName for workspace names; match surrounding
             style; comments only where WHY is non-obvious; no unrelated edits.
GATE:        `mise run check`  (or `mise run check-release` for the final pass)
DELIVERABLE: <diff> + <captured command output with exit code> +
             <self-report mapping each acceptance criterion → file:line / evidence>
RETURN:      raw result only — your final message is data for the orchestrator,
             not a user-facing summary.
```

---

## Task DAG

```
W0 (gate+baseline, DONE) ─► W1 (paths resolution) ─► W2 (CLI flag/env) ─► W3 (daemon env export)
                                                            └─────────────► W4 (moo ws cmd) ─► W5 (help/docs)
W6 (Phase-2 UI aggregate view) depends on W2; ship after W1–W5 land.
```

Implement in ID order. W3 and W4 can run in parallel once W2 lands. W6 is a
separate phase gated behind the open UI-default decision above.

---

### W0 — Verification gate + green baseline  ✅ done in this session
- **Goal:** a single reproducible "linted, formatted, tested" command, and a
  proven-green starting point so every later gate is meaningful.
- **Done:** added `fmt-check`, `fmt`, `check`, `check-release` recipes to
  `mise.toml`; baseline captured green (156/156 unit, fmt clean, integration green).
- **Verification:** `mise tasks ls` shows the recipes; baseline output archived.

### W1 — Workspace-aware socket directory resolution
- **Goal:** `paths.socketDir` returns the base dir when no workspace is active and
  `<base>/ws/<name>` (created 0700) when one is, validating the name; the `ws/`
  container is invisible to the default workspace's `listSessions`.
- **Surface:** `src/paths.zig` — `socketDir` (23), `socketDirFrom` (40-68),
  `listSessions` (158-180), reuse `validateName` (10). Add a workspace parameter
  threaded through; keep a no-workspace overload for existing callers.
- **Acceptance criteria:**
  1. `socketDir(alloc, workspace=null)` == today's path, byte-for-byte.
  2. workspace `"proj"` ⇒ `<base>/ws/proj`, directory created with mode 0700.
  3. invalid workspace name (`validateName` fails, e.g. `"../x"`, `""`, leading
     `-`) ⇒ error, no directory created.
  4. `listSessions(<base>)` ignores the `ws/` subdirectory (no `.sock` suffix).
  5. same session name may exist independently in two different workspaces.
- **Test contract (author writes first, in `src/paths.zig` tests):** unit tests
  for criteria 1–5 using `std.testing.tmpDir`, mirroring the existing
  `socketDirFrom` test style (paths.zig:244-311).
- **Verification:** `mise run fmt-check && mise run test` green; new tests fail on the
  unmodified tree first.

### W2 — `-w/--workspace` flag + `MOO_WORKSPACE` resolution in the CLI
- **Goal:** every command resolves an active workspace from flag → env → none and
  passes it into `socketDir`.
- **Surface:** `src/main.zig` — global arg parse / dispatch (88-100), `cmdNew`
  (240-271), `createSession` (273-338), `cmdLs` (463-536), `cmdKill` incl.
  `--all` (≈980-996), name resolution (146-173). A small `activeWorkspace()`
  helper (flag overrides `MOO_WORKSPACE`).
- **Acceptance criteria:**
  1. `moo new -w proj -d -- bash` creates a session under workspace `proj`.
  2. `moo ls -w proj` lists it; `moo ls` (default) does **not**.
  3. precedence: explicit `-w` overrides `MOO_WORKSPACE`; absent both ⇒ default.
  4. `moo kill -w proj --all` kills only `proj` sessions; default sessions survive.
  5. prefix/exact name resolution still works, scoped within the workspace dir.
- **Test contract:** unit test for `activeWorkspace()` precedence; integration
  tests in `test/integration.zig` for criteria 1, 2, 4 (drive the real binary,
  assert via `moo ls --json`).
- **Verification:** `mise run check` green; new integration tests red on the
  pre-W2 binary first.

### W3 — Daemon exports `MOO_WORKSPACE` into session env
- **Goal:** sessions created in a workspace carry `MOO_WORKSPACE=<name>` so nested
  orchestrators inherit the scope automatically.
- **Surface (preferred, minimal):** `createSession` in `src/main.zig` appends
  `["MOO_WORKSPACE", <name>]` to the `env_overrides` list it already builds; the
  daemon applies those after `MOO` (daemon.zig:585-588), so **no daemon change is
  needed**. Only fall back to threading a new `Options` field (daemon.zig:22-32)
  if env_overrides proves unsuitable.
- **Acceptance criteria:**
  1. inside a `proj` session, `$MOO_WORKSPACE` == `proj`.
  2. a default (unnamed-workspace) session has `MOO_WORKSPACE` unset/empty.
  3. `moo ls` run from inside a `proj` session lists only `proj` sessions.
- **Test contract:** integration test — create a workspace session running a
  shell, `moo send` a `printf "$MOO_WORKSPACE"`/`moo ls` probe, `moo peek` and
  assert the scoped result.
- **Verification:** `mise run check` green; new test red before the env export.

### W4 — `moo ws` command
- **Goal:** discover and report workspaces.
- **Surface:** new `cmdWs` in `src/main.zig` + dispatch entry (88-100); enumerate
  base + `ws/*`, count sessions per workspace via `listSessions`.
- **Acceptance criteria:**
  1. `moo ws` lists the default workspace plus every dir under `ws/` with a
     session count.
  2. `moo ws --json` emits `[{"workspace":"proj","sessions":2}, …]`.
  3. empty/absent `ws/` ⇒ just the default workspace, no error.
- **Test contract:** integration test — create sessions across two workspaces,
  assert `moo ws --json` shape and counts.
- **Verification:** `mise run check` green; new test red first.

### W5 — Help & docs
- **Goal:** `-w/--workspace`, `MOO_WORKSPACE`, and `moo ws` are documented.
- **Surface:** `src/help.zig` (per-command + overview), `README.md` (Usage /
  Automation).
- **Acceptance criteria:**
  1. `moo help ws` and `moo help new` mention the flag/command.
  2. README documents workspaces and the orchestrator-isolation property.
- **Verification:** `mise run fmt-check` clean; `mise run run -- help ws` renders;
  manual read-through (no behavioural test).

### W6 — Phase 2: UI aggregate view (separate phase)
- **Goal:** `moo ui` can show sessions grouped by workspace with section headers
  and a key to cycle the active-workspace filter; scoped-by-default.
- **Surface:** `src/ui.zig` — `refreshSessions` (1991) enumerates base + `ws/*`
  and tags each `Entry` (786) with its workspace; `composeSidebarCell` (2855)
  renders per-workspace section headers; new keybind in `handlePrefix` (1601) to
  cycle `active_workspace_filter`. Additive: the sidebar has no sectioning today.
- **Acceptance criteria:** (finalise after the UI-default decision)
  1. default view scoped to the active workspace.
  2. a keybind cycles all → each workspace → all, re-rendering headers.
  3. selection/browse/goto/scroll operate on the filtered list correctly.
- **Test contract:** integration test driving the UI PTY, asserting section
  headers appear and the toggle changes the visible set.
- **Verification:** `mise run check` green; new UI integration test red first.

---

## Progress tracking

Live status is in the harness task list (W1–W6 mirror the IDs here). The
orchestrator marks a task `completed` only after its QA role returns a pass with
captured `mise run check` output.
```
