# HANDOFF — orchestrating the moo workspaces delivery

## ACTIVATION

When the user points you at this file, **you are the orchestrator** for the moo
workspaces feature. Do this, proactively and to completion:

1. Read `GOAL.md` (what done means) and `PLAN.md` (per-task specs, the gate, the
   loop). The design is settled — do not re-derive or re-propose it.
2. Run the **Resume protocol** (below) to sync to reality: harness `TaskList`,
   `git status`, and a fresh `just check` to confirm the baseline is green.
3. Drive the pending W-tasks through the **Per-task loop** in dependency order,
   dispatching subagents. Keep going across tasks without waiting for the user.
4. Stop only at a **Checkpoint** (listed below). Otherwise proceed autonomously.
5. Report each task's completion with captured evidence (exit code + test counts).

"Proactively" means: do not ask permission between tasks; advance W1→W5 (and W6
per the open decision), self-verifying at each step. Ask only at a real Checkpoint.

## Current state (snapshot 2026-06-17 — DELIVERED, W6 deferred)

- ✅ W0/W0.1: gate recipes + hermetic harness (baseline was 228/228 green).
- ✅ W1: `paths.socketDirFor`/`socketDirFromFor` resolve `<base>/ws/<name>` (0700),
  validate the name; the no-workspace path is byte-identical to before.
- ✅ W2: `-w/--workspace` flag + `MOO_WORKSPACE` resolution (`paths.resolveWorkspace`
  + `main.activeWorkspace`) threaded through all 10 commands.
- ✅ W3: `createSession` exports `MOO_WORKSPACE` into each workspace session via the
  existing `env_overrides` plumbing (no daemon change needed).
- ✅ W4: `moo ws` (lists the default + every `ws/*` with a session count; `--json`,
  default workspace reported as the empty string `""`).
- ✅ W5: help (`-w/--workspace` on every session command, enriched `ws` page, new
  `moo help workspaces` topic, overview + env block) + README Workspaces section.
- ✅ W7 (added after W2 review): an invalid workspace name now yields a clean
  `moo: invalid workspace name '<name>'` usage error (exit 2) via a `workspaceDir`
  helper, instead of a raw `error: InvalidSessionName`.
- ⏸️ W6: DEFERRED by user decision (2026-06-17). Design settled (scoped-by-default +
  a `C-a w` toggle to a grouped all-workspaces view); it is a larger UI refactor
  (per-entry workspace dirs + sidebar row-index/mouse math) — see the W6 task notes.
- FINAL GATE GREEN: `just check-release` exit 0, **246/246** (162 unit + 84
  integration), fmt clean, no flake, first attempt.
- Every task ran the full role-separated loop (test-author → implementer →
  adversarial reviewer → QA, all different agents).
- Uncommitted on `main`: `src/paths.zig`, `src/main.zig`, `src/help.zig`,
  `test/integration.zig`, `README.md`. Nothing committed/pushed (awaiting user go).
- Operational note for re-runs: never run two `just check`/`check-release` builds
  concurrently — parallel ReleaseSafe builds collide on the zig cache and get
  SIGTERM-killed (exit ~143/144). Use one solo builder at a time.

## Dependency / parallelism plan

```
W1 ─► W2 ─► W3 ┐
            └─► W4 ┴─► W5
W6 (Phase 2) depends on W2; deferred behind the UI-default decision.
```

- W1 first (everything resolves through `socketDir`).
- After W2 lands, **run W3 and W4 in parallel** (independent surfaces).
- W5 (docs) after W3 + W4 so docs match shipped behaviour.
- W6 only after the user settles the UI default (or proceed scoped-by-default).

## Per-task loop (roles are DIFFERENT agents)

Full spec in `PLAN.md` ("The loop"). Execution per task:

1. **Test author** (subagent): reads the real interfaces, writes the failing
   test(s) that encode the task's acceptance criteria, runs them, captures RED.
   Returns the test diff + the failing output. The tests are now a fixed contract.
2. **Implementer** (different subagent): smallest change to make the authored
   tests pass. May NOT weaken/skip/delete them — surfaces a conflict instead.
   Runs `just check`, captures it. Returns impl diff + captured green gate.
3. **Reviewer** (different subagent): adversarial find-then-refute on the diff,
   pass/fail rubric separating correctness from style. Memory ownership (Zig
   allocators), error paths, backward compat, tests-actually-constrain-behaviour.
   On surviving findings → back to the implementer.
4. **QA** (orchestrator or a fresh subagent): run `just check` green AND walk the
   task's manual scenario against the built binary; map each acceptance criterion
   to evidence. Only then mark the harness task `completed`.

Scale to risk: W1 (pure unit) can use a lighter single-reviewer pass; W2/W3
(daemon/CLI behaviour) warrant a stricter adversarial review. W5 (docs) may
collapse to implement → review-for-accuracy → render-check.

Use the **handover brief template in `PLAN.md`** to brief every subagent — it is
self-contained (the subagent has no memory of the session).

## The verification gate (definition of done per task)

Toolchain is **Zig 0.15.2 via `nix develop`** (host Zig 0.16 is rejected). Use
`just` (it wraps `nix develop --command zig`). Never run bare `zig`.

| Gate | Command |
|------|---------|
| Format / lint | `just fmt-check` |
| Build (compiler analysis) | `just build` |
| Unit + PTY integration | `just test-all` |
| Everything in one shot | `just check` |
| Final pre-merge (ReleaseSafe) | `just check-release` |

A task is done only when: the authored test was observed RED before and GREEN
after; `just check` is fully green (228+ tests); the reviewer passed; and you have
the **captured exit code + test-count line** as the artifact (not "it compiled").

## Subagent dispatch — fill these in

Spawn with the Agent tool. Default `subagent_type: general-purpose` for
author/implement/review (they need read + bash + edit). Use `Explore` for
read-only recon if needed. Run independent dispatches (e.g. W3 ∥ W4) in one
message so they run concurrently.

```
TASK:        <Wn — one-sentence outcome from PLAN.md>
ROLE:        <test-author | implementer | reviewer | qa>
REPO:        /Users/mish/projects/moo  (Zig 0.15.2 via `nix develop`; use `just`, never bare zig)
SURFACE:     <files + functions with file:line from PLAN.md — but LOCATE BY SYMBOL; line numbers drift>
CONTRACT:    <implementer/reviewer/qa: the authored tests are fixed — do not weaken>
CONSTRAINTS: backward compatible (no workspace ⇒ identical to today); reuse
             paths.validateName for workspace names; match surrounding style;
             comments only where WHY is non-obvious; no unrelated edits.
GATE:        `just check`  (capture the exit code explicitly — see Gotchas)
DELIVERABLE: diff + captured command output WITH exit code + a self-report
             mapping each acceptance criterion → file:line / evidence.
RETURN:      raw result only — your final message is data for the orchestrator.
```

## Checkpoints (stop and ask the user only here)

- The **W6 UI-default decision** (scoped vs show-all-grouped) — unless already told.
- Before **committing/pushing** anything (global rule: only on explicit request;
  branch off `main`, never push to `main` unless told).
- A task uncovers a **real product bug or design fork** needing a human call.
- `just check` goes red for a reason **not** attributable to the current task.

Everything else: proceed without asking.

## Resume protocol (cold start)

1. Read `GOAL.md`, this file, then `PLAN.md`.
2. `TaskList` → see W1–W7 status and `blockedBy`. Pick the lowest-ID pending,
   unblocked task.
3. `git -C /Users/mish/projects/moo status --short && git diff --stat` → see
   uncommitted work and which task it belongs to.
4. `cd /Users/mish/projects/moo && just check > /tmp/moo_gate.log 2>&1; echo "EXIT=$?"`
   → confirm the baseline is green before building on it (read the EXIT line, not
   the notification — see Gotchas).
5. Resume the loop at the chosen task.

## Gotchas (learned the hard way this session — heed them)

- **Background-task "exit 0" notifications LIE.** The harness reports the exit of
  the LAST pipe stage, so `cmd | tail` always looks like 0. ALWAYS capture the
  real code yourself with no masking pipe: `cmd > log 2>&1; echo "EXIT=$?"`, then
  read that file. This masked a genuine test failure three times here.
- **`zig build`/`test-all` is slow** (~50s for integration; it builds the real
  binary and drives PTYs). Run it with `run_in_background: true` and capture the
  exit explicitly; don't foreground-block.
- **Toolchain:** bare `zig` is 0.16 and is rejected by ghostty. Use `just` /
  `nix develop --command zig`.
- **`MOO` env hygiene:** if you run moo manually from inside a moo session, `$MOO`
  sets the UI's `host_name`. The integration harness is now hermetic, but keep
  this in mind when reasoning about any UI behaviour. Don't reintroduce env leaks.
- **Line numbers drift.** PLAN.md anchors are approximate; locate by symbol
  (`grep -n 'fn createSession'`) not by absolute line.
- **Re-read before edit** if `zig fmt`/codegen may have rewritten a file since you
  last read it; a stale Edit is rejected.
- **macOS install** needs ad-hoc re-signing (`just install` handles it); not
  relevant to tests but is why a copied binary can get "Killed: 9".

## Commit / PR policy

Do not commit or push until the user asks. When asked: branch off `main`
(never commit straight to `main` unless explicitly told), run `just check-release`
green first, and end any PR body with the Claude Code attribution line.
