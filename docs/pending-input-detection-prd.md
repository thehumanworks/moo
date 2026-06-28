# PRD: Pending input detection for agent harness sessions

**Status:** Draft → implementation  
**Date:** 2026-06-25  
**Owner:** moo CLI / HTTP / MCP

## Problem

When moo sends text or slash commands with Enter appended (`moo send --text …`, `moo slash …`, HTTP `/input`, MCP `moo_send_slash_command`), bytes are injected into the session PTY with no preflight check. If the agent harness already has **unsubmitted draft text** on its input line, the new bytes merge with that draft instead of replacing it. This caused a real failure: `/compact` was sent while `push it and open a PR` sat on Claude Code's `❯` line — moo reported success but Claude never ran `/compact`.

## Goal

Before any send path that **appends Enter**, detect high-confidence unsubmitted prompt text in agent harness sessions and **refuse** unless the caller passes **`--force`** (CLI) or **`"force": true`** (HTTP/MCP).

## Non-goals

- Detecting draft input in generic shells (`bash`, `zsh`, `raw`) or non-agent programs
- Transcript-based detection (draft text never reaches JSONL)
- Blocking `--no-enter`, key-only sends (except Enter), or stdin pipe without implicit Enter
- Auto-clearing user drafts (no silent `C-u`); callers may clear explicitly

## Permissive policy (required)

> If detection fails, the sidecar is missing, peek is malformed, or the prompt UI layout is **unrecognized or changed**, moo **must not warn** and **must send** — identical to today's behavior.

Only **`confidence: high`** detections block. Medium/low/internal ambiguity → pass through.

## Scope

| Surface | Gate when |
|---------|-----------|
| `moo send --text` | Enter appended (default) |
| `moo send --key Enter` | always |
| `moo slash` | always (slash always appends Enter) |
| `POST …/input` | `enter` true (default when `text` present) |
| `POST …/slash` | always |
| MCP `moo_send_input` / `moo_send_slash_command` | same as HTTP |

**Agents:** `claude`, `codex`, `pi` only (sidecar present).

## Detection strategy by agent

### Claude Code — peek-based (high confidence)

**Fingerprint:** bottom horizontal separator sandwich (`─` × width) enclosing a `❯` (U+276F) + NBSP (U+00A0) prompt line.

| State | Screen pattern |
|-------|----------------|
| Empty | `❯` + NBSP only on prompt row |
| Pending | Non-whitespace after prefix, or multiline continuation rows (`  text`) in prompt zone |
| No detection | No separator sandwich (working, menus, permission UI) |

### Pi — peek-based (high confidence)

**Fingerprint:** cwd footer (`~/path (branch)`), stats line (`%/` context), `─` bordered editor box.

| State | Screen pattern |
|-------|----------------|
| Empty | Content row between borders is whitespace only |
| Pending | Trimmed non-empty content between borders |
| No detection | Slash autocomplete (`→` rows), missing footer/borders |

### Codex — send ledger (high confidence for moo-initiated drafts)

Peek cannot distinguish empty composer (random placeholder text) from user draft.

**Ledger:** When moo sends `--text` without Enter, record draft in `<session>.send-ledger.json`. Clear on Enter send or `--key Enter`. Block subsequent enter-appends while ledger non-empty.

Manual typing in an attached Codex session without going through moo → **no detection** (permissive).

## User-visible behavior

### CLI blocked

```text
moo: unsubmitted prompt text in session 'bot' (claude): "fix the bu"
moo: re-run with --force to send anyway
```

Exit code **5** (`exit_pending_input`).

### HTTP/MCP blocked — 409

```json
{
  "error": {
    "code": "pending_input",
    "message": "unsubmitted prompt text detected; pass force=true to send anyway",
    "pending": {
      "agent": "claude",
      "preview": "fix the bu",
      "reason": "claude_prompt_zone_nonempty"
    }
  }
}
```

### Override

- CLI: `--force` on `send` and `slash`
- HTTP/MCP: `"force": true`

## Architecture

```
cmdSend / cmdSlash / handleInput / handleSlash
        → gatePendingInput(force, append_enter)
        → read sidecar agent
        → peek screen (if claude/pi)
        → read send ledger (if codex)
        → detect → null? send : 409/exit 5
        → on successful send: update ledger
```

New module: `packages/moo-cli/src/pending_input.zig`  
Fixtures: `packages/moo-cli/src/testdata/peek/*.txt`  
Policy: this PRD + `docs/http-api.md` update

## Verification

1. Unit tests: embedded peek fixtures (empty, draft, menu, wrong agent)
2. Ledger tests: text without enter → block slash; Enter clears
3. `mise run test` + `mise run test-all` green
4. Live MCP: claude session with `--no-enter` draft → `moo_send_slash_command` blocked; `--force` succeeds; empty prompt allows slash

## Success criteria

- [ ] Claude draft on `❯` line blocks slash/send-with-enter without `--force`
- [ ] Empty Claude prompt allows slash
- [ ] Unrecognized screen layout never blocks
- [ ] Codex ledger blocks after `send --text --no-enter`
- [ ] HTTP 409 + MCP force flag documented and working
