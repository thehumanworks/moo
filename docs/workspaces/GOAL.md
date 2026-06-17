# GOAL — moo workspaces

One-line objective: add a **workspace** concept to moo so the UI can be scoped to
one project and an agent orchestrator can create/kill sessions inside its own
workspace without ever touching sessions in other projects.

This file is the north star (what "done" means). The companion files:
- `HANDOFF.md` — how to execute: orchestrate subagents through the loop. **Start there** when told to deliver this.
- `PLAN.md` — the per-task specs: surface (file:line), acceptance criteria, test contracts, the gate, the loop.

## Why

1. **UI scoping.** `moo ui` can stay organised and scoped to a single workspace
   when the user wants, instead of listing every session on the machine.
2. **Orchestrator isolation.** When agent orchestration runs inside a project, it
   stays confined to that project's workspace — it creates agents/panes there and
   cannot see or kill work in other projects.

## Design in brief (settled — do not re-litigate)

A workspace is a **named socket subdirectory**. The socket directory is already
moo's unit of isolation (everything keys off `paths.socketDir`), so a workspace
reuses that boundary rather than adding a filter to every call site.

```
$MOO_DIR (base = default workspace)
├── work.sock                 ← unnamed sessions: unchanged, today's behaviour
└── ws/<name>/                ← one dir per named workspace (mode 0700)
    └── fix.sock
```

Active workspace resolves: `-w/--workspace <name>` flag → `MOO_WORKSPACE` env →
none (base dir). The daemon exports `MOO_WORKSPACE` into each session's env, so an
orchestrator running inside a workspace session inherits it and is **physically
confined** to that directory — `ls`, `kill --all`, and `new` all scope for free
because they funnel through `listSessions(dir)`. That structural guarantee (not a
convention) is the whole point; the rejected soft-label alternative is in `PLAN.md`.

## Deliverables (detail in PLAN.md)

| ID | Outcome | Status |
|----|---------|--------|
| W0   | `just check` gate recipes + proven-green baseline | ✅ done |
| W0.1 | Hermetic integration harness (clears leaked `MOO*`) | ✅ done |
| W1   | `paths.socketDirFor` resolves `<base>/ws/<name>`; validates name | ✅ done |
| W2   | `-w/--workspace` flag + `MOO_WORKSPACE` resolution across commands | ✅ done |
| W3   | Daemon exports `MOO_WORKSPACE` into session env (via `env_overrides`) | ✅ done |
| W4   | `moo ws` command (list workspaces + counts, `--json`) | ✅ done |
| W5   | Help + README docs for `-w`, `MOO_WORKSPACE`, `moo ws` | ✅ done |
| W7   | Clean `moo: invalid workspace name` usage error (added after W2 review) | ✅ done |
| W6   | Phase 2: UI aggregate workspace view (sections + filter toggle) | ⏸️ deferred (user decision; design settled scoped+toggle) |

## Product acceptance (the behaviours that prove success)

- `moo new -w proj -d -- bash` then `moo ls -w proj` shows the session; plain
  `moo ls` does NOT. Same session name may exist in two workspaces independently.
- `moo kill -w proj --all` kills only `proj` sessions; default + other workspaces survive.
- Inside a `proj` session, `$MOO_WORKSPACE == proj`, and `moo ls`/`moo kill --all`
  run there are confined to `proj` (verified: cannot enumerate or kill other workspaces).
- `moo ws --json` lists the default workspace plus each `ws/*` with session counts.
- No-workspace behaviour is byte-for-byte unchanged (full backward compatibility).
- `moo help` documents all of the above.
- (W6) `moo ui` scopes to the active workspace and can toggle to a grouped all-view.

## Definition of done (whole effort)

- W1–W5 each delivered through the full loop (test contract → implement → adversarial
  review by a different agent → QA), tracked in the harness task list.
- `just check-release` green (fmt + build + unit + PTY integration under ReleaseSafe),
  all 228+ tests passing, with the captured exit code as evidence.
- W6 either delivered or explicitly deferred pending the decision below.
- Nothing committed/pushed until the user asks (see HANDOFF.md commit policy).

## Open decision (gates W6 only) — RESOLVED 2026-06-17

Default for `moo ui` with no `-w`: **scoped to the active workspace** + a toggle to a
grouped all-workspaces view. Decided by the user. W6 itself was then **deferred** to a
focused follow-up (the grouped view is a larger UI refactor than the plan implied —
per-entry workspace dirs + sidebar row-index/mouse math); W1–W5 + W7 shipped without it.

## Non-goals / constraints

- Do not change unnamed-session behaviour. Backward compatibility is a hard requirement.
- Workspace names reuse `paths.validateName` (same safe charset).
- No new cross-cutting "filter" dimension — isolation comes from the directory.
- Zig 0.15.2 via `nix develop` only (host Zig 0.16 is rejected). Use the `just` recipes.
