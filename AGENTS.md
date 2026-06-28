# Agent Instructions

- Proactively resolve blockers when a concrete next action is available.
- If a blocker cannot be resolved from local context and available tools, ask the user for the specific help, permission, or output needed.
- Do not end a turn in a blocked state without resolving the blocker or giving the user a concrete request that unlocks the next action.
- Use the repo-pinned mise toolchain for verification: run `mise bootstrap` when bootstrap packages are missing, run `mise install` after checkout, and prefer `mise run <task>` rather than host Zig/Bun. `mise run check` includes `mise run test-all`; if it exits `143` or reports signal 15, treat that as a timeout/interruption and rerun the affected suite with enough timeout before calling it pass or fail.
- Pending-input handling must follow `docs/pending-input-detection-prd.md`: high-confidence pending composer text blocks send/slash actions that append Enter unless `--force` or `force: true` is set; CLI blocks exit 5; HTTP/MCP blocks return 409 `pending_input`; unknown layouts pass through.
