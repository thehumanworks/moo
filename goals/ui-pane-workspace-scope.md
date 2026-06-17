---
goal_id: "ui-pane-workspace-scope"
title: "Scope UI pane creation to workspace"
status: "active"            # active | blocked | exited | done
confidence_floor: 90        # a Task below this CANNOT be ticked done
created: "2026-06-17"
updated: "2026-06-17"
---

# Goal: `C-a c` inside `moo ui` creates the new pane in the UI's resolved workspace; default is used only when default is the resolved scope or no workspace is scoped.

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

- User report, 2026-06-17 — creating a new pane from `moo ui` scoped by workspace creates it in the default workspace instead of the UI's scoped workspace. Correct behavior is to create in the same resolved workspace; default is correct only when the scoped workspace is default or no workspace has been scoped.
- `src/main.zig` — `cmdUi` resolves `-w/--workspace` and `$MOO_WORKSPACE` into a socket dir, then calls `ui.run(alloc, dir)` without preserving the workspace name for child session creation.
- `src/paths.zig` — `resolveWorkspace` and `socketDirFor` define how workspace names map to socket directories.
- `src/ui.zig` — `Ui.dir` scopes sidebar refresh/attach/rename/kill, while `Ui.createSession` currently shells out as `moo new -d`; this is the suspected bug path.
- `test/integration.zig` — PTY UI harness, workspace helpers, and existing `ui: create and kill sessions from the ui` test provide the integration-test shape.

---

## 3. Definition of Done · INVARIANT

Each item is **atomic** (one verifiable assertion per checkbox), tagged with a
stable id that Tasks reference via **Closes:**, and carries a concrete `verify by:`.

Tick a `DoD-N` box only when its own `verify by:` has been run and passed (not merely
because a closing Task is ticked). Log the command and its outcome as an Evidence bullet
under the Task that **Closes:** it. DONE requires every DoD box ticked.

- [ ] **DoD-1** — A new pane created with `C-a c` from `moo ui -w proj` increases workspace `proj`'s live session count by exactly 1. — *verify by:* `just test-all`, including a named integration test such as `ui: create from -w workspace stays in that workspace`.
- [ ] **DoD-2** — The same `moo ui -w proj` create action leaves the default workspace live session count unchanged. — *verify by:* `just test-all`, including `ui: create from -w workspace stays in that workspace` and before/after parsed count assertions.
- [ ] **DoD-3** — The same `moo ui -w proj` create action leaves an unrelated named workspace live session count unchanged. — *verify by:* `just test-all`, including `ui: create from -w workspace stays in that workspace` and before/after parsed count assertions.
- [ ] **DoD-4** — A new pane created with `C-a c` from `MOO_WORKSPACE=proj moo ui` increases workspace `proj`'s live session count by exactly 1. — *verify by:* `just test-all`, including a named integration test such as `ui: create from MOO_WORKSPACE stays in that workspace`.
- [ ] **DoD-5** — The same `MOO_WORKSPACE=proj moo ui` create action leaves the default workspace live session count unchanged. — *verify by:* `just test-all`, including `ui: create from MOO_WORKSPACE stays in that workspace` and before/after parsed count assertions.
- [ ] **DoD-6** — The same `MOO_WORKSPACE=proj moo ui` create action leaves an unrelated named workspace live session count unchanged. — *verify by:* `just test-all`, including `ui: create from MOO_WORKSPACE stays in that workspace` and before/after parsed count assertions.
- [ ] **DoD-7** — `moo ui` with neither `-w` nor `MOO_WORKSPACE` keeps its existing create behavior in the current default workspace. — *verify by:* `just test-all`, including the existing `ui: create and kill sessions from the ui` coverage or an equivalent assertion that unscoped UI creation changes the default workspace count.

---

## 4. Exit Conditions

The goal terminates when **any** condition holds. On exit, state which fired —
explicitly — in the response to the user.

- **`DONE`** — all §3 items ticked and all §5 tasks ≥ confidence floor. *(primary)*
- **`BLOCKED-DEP`** — Zig 0.15.2 / the pinned Nix development shell or the PTY integration harness is unavailable after one direct retry. Exit without the blocked step; name it explicitly.
- **`SCOPE-CHANGE`** — work cannot complete without changing scope. Record the
  proposal in §6 and exit to the user.
- **`CONFIDENCE-STALL`** — a task cannot reach the floor after two honest implementation attempts. Exit, report the task and the gap.
- **`BUDGET`** — two focused implementation passes are exhausted without a passing scoped-UI-create integration test. Exit and report progress.

---

## 5. Tasks · INVARIANT

Ordered, dependency-aware units of work that together satisfy the DoD. Tick the
trailing `[ ]` only when the Verification Contract passes and Confidence ≥ floor.

---

### T1 · Add a red integration test for scoped UI creation · [ ]

**Steps**
- [ ] Add or reuse a JSON session-count helper that can count sessions for `ls --json` with arbitrary workspace args.
- [ ] Make PTY UI spawns workspace-hermetic by default: clear ambient `MOO_WORKSPACE` alongside the existing `MOO`/`MOO_FOREGROUND`/`MOO_LOG` cleanup, and add an explicit helper such as `PtyClient.spawnWithEnv` for tests that need `MOO_WORKSPACE=proj`.
- [ ] Add `ui: create from -w workspace stays in that workspace`: seed default and an unrelated workspace with live sessions, launch `moo ui -w proj`, send `\x01c`, wait for the UI to observe the created pane, and assert before/after parsed counts for `proj`, default, and the unrelated workspace.
- [ ] Add `ui: create from MOO_WORKSPACE stays in that workspace`: seed default and an unrelated workspace with live sessions, launch `moo ui` with only `MOO_WORKSPACE=proj`, send `\x01c`, wait for the UI to observe the created pane, and assert before/after parsed counts for `proj`, default, and the unrelated workspace.
- [ ] Confirm the scoped tests fail before the fix in the expected way: the created session appears outside `proj`, or `proj` does not increase.

**Verification Contract**
- *Check:* The new test fails against the current implementation for the scoped-create bug, not due to harness setup or timing.
- *Method:* `nix develop --command zig build test-integration --summary all`
- *Expected:* Non-zero exit before the implementation fix, with failure showing `proj` count did not increase or a non-target workspace count changed.
- *BDD scenarios covered:* Given `moo ui -w proj` is open with no sessions in `proj`, when the user presses `C-a c`, then the new session must be created in `proj` and not in default. Given `MOO_WORKSPACE=proj moo ui` is open, when the user presses `C-a c`, then the new session must be created in `proj` and not in default. Given no workspace is scoped, when the user presses `C-a c`, then the new session must be created in default.

**Confidence:** 0 / 90 · **Depends on:** none · **Closes:** none

**Evidence (required before tick; append-only)**
- *(none yet — when setting Confidence ≥ floor, append a bullet with all three: date + command/check run + outcome (exit code / test counts / artifact path))*

---

### T2 · Thread the resolved UI workspace into pane creation · [ ]

**Steps**
- [ ] Change the `cmdUi`/`ui.run` boundary so the UI receives both the resolved socket dir and the resolved workspace name, or an equivalent scoped-create option.
- [ ] Use one source of truth: compute the active workspace once through the existing `activeWorkspace` / `workspaceDir` path, then pass that same resolved workspace value into `ui.run` alongside the already resolved dir.
- [ ] Update `Ui.createSession` so its child `moo new -d` call creates in the UI's resolved workspace when one is active, preferably by passing `-w <workspace>` explicitly instead of relying on ambient environment.
- [ ] Preserve the no-workspace path: unscoped UI still calls the equivalent of `moo new -d` and does not require a workspace flag.

**Verification Contract**
- *Check:* Both named scoped-create integration tests from T1 pass, and a code read shows `Ui.createSession` no longer loses explicit `-w` or `$MOO_WORKSPACE` resolved workspace scope.
- *Method:* `nix develop --command zig build test-integration --summary all`
- *Expected:* Exit 0 for the integration suite, including `ui: create from -w workspace stays in that workspace` and `ui: create from MOO_WORKSPACE stays in that workspace`.
- *BDD scenarios covered:* Given `moo ui -w proj`, when `C-a c` creates a pane, then the child `moo new` receives `proj` scope and the running UI can see/focus the new pane. Given `MOO_WORKSPACE=proj moo ui`, when `C-a c` creates a pane, then the same resolved scope is preserved. Given no workspace is scoped, when `C-a c` creates a pane, then the default resolved scope is preserved.

**Confidence:** 0 / 90 · **Depends on:** T1 · **Closes:** DoD-1, DoD-2, DoD-3, DoD-4, DoD-5, DoD-6

**Evidence (required before tick; append-only)**
- *(none yet)*

---

### T3 · Re-check unscoped UI create behavior · [ ]

**Steps**
- [ ] Ensure the existing unscoped UI create/kill test still exercises `C-a c` from `moo ui` without `-w`.
- [ ] If the existing assertion is not precise enough after the implementation, strengthen it to compare default workspace session counts before and after create.
- [ ] Run the relevant integration tests after T2 and inspect failures for accidental workspace-default behavior changes.

**Verification Contract**
- *Check:* Unscoped UI creation still creates in the current default workspace and can be killed by the UI.
- *Method:* `nix develop --command zig build test-integration --summary all`
- *Expected:* Exit 0, including `ui: create and kill sessions from the ui`.
- *BDD scenarios covered:* Given `moo ui` runs with neither `-w` nor `MOO_WORKSPACE`, when the user presses `C-a c`, then the new pane appears in the default workspace and existing kill/focus behavior still works.

**Confidence:** 0 / 90 · **Depends on:** T2 · **Closes:** DoD-7

**Evidence (required before tick; append-only)**
- *(none yet)*

---

### T4 · Final validation and cleanup · [ ]

**Steps**
- [ ] Run `zig build test` for unit coverage around workspace resolution and any changed signatures.
- [ ] Run `zig build test-integration --summary all` for the full PTY behavior contract.
- [ ] Run `zig fmt --check build.zig build.zig.zon src test` and inspect `git diff --stat` for scoped changes only.

**Verification Contract**
- *Check:* The full local validation set relevant to this bug passes and the diff is limited to implementation/tests needed for scoped UI create.
- *Method:* `just test && nix develop --command zig build test-integration --summary all && just fmt-check && git diff --stat`
- *Expected:* All commands exit 0; implementation/test diff contains only `src/main.zig`, `src/ui.zig`, and `test/integration.zig` unless a directly related helper/doc update is justified in §6. The goal artifact itself may remain in `goals/ui-pane-workspace-scope.md`.
- *BDD scenarios covered:* Regression sweep for workspace resolution, scoped UI create, and unscoped UI create.

**Confidence:** 0 / 90 · **Depends on:** T3 · **Closes:** none

---

## 6. Decisions · LIVE (append-only)

Meaningful choices/concessions needing visibility. Scope impact must be `none`.

- 2026-06-17 — Scope is intentionally limited to pane creation from an already workspace-scoped UI. This goal does not implement the separate product direction that plain `moo ui` should default to all workspaces, and it does not rename or migrate the default workspace. Scope impact: none.
- 2026-06-17 — Adversarial review used `spawn_agents_on_csv` with two reviewers. Reviewers required env-scoped UI coverage and PTY harness control for `MOO_WORKSPACE`; the goal was revised to cover both `-w` and `$MOO_WORKSPACE` scoped entry points and to make ambient workspace leakage part of T1. Scope impact: none.
- 2026-06-17 — Second adversarial review found one non-atomic DoD and asymmetric non-target checks. The goal was revised to split default-vs-unrelated workspace assertions and require unrelated-workspace unchanged checks for both `-w` and `$MOO_WORKSPACE` scoped UI creation. Scope impact: none.
- 2026-06-17 — User corrected the wording: the invariant is not "never default" absolutely, but "create in the same resolved workspace"; default is valid when default is explicitly resolved or when no workspace is scoped. The north star, report reference, and BDD wording were updated to reflect that. Scope impact: none.

---

## 7. Learnings · LIVE (append-only)

Flash cards: trigger → wrong action → revision → correct action, with impact `1–5`.
When an attempt failed and the fix is not yet known, log the **open form** —
trigger → wrong action → *(open: revision/correct not yet found)* → pointer to the raw
failure (log path or commit) — still impact-tagged, so a dead-end is recorded before a
fresh context re-treads it.

*(none yet)*

---

## 8. Skills · LIVE (append-only)

Reusable workflows created via the **skill-creator** skill while working this goal.

*(none yet)*
