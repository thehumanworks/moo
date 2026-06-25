# Agent Instructions

- Proactively resolve blockers when a concrete next action is available.
- If a blocker cannot be resolved from local context and available tools, ask the user for the specific help, permission, or output needed.
- Do not end a turn in a blocked state without resolving the blocker or giving the user a concrete request that unlocks the next action.
- Use the repo-pinned toolchain for verification: prefer `just` targets and `nix develop --command zig` rather than host Zig. `just check` includes `zig build test-all`; if it exits `143` or reports signal 15, treat that as a timeout/interruption and rerun the affected suite with enough timeout before calling it pass or fail.
