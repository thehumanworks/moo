# moo HTTP API

`moo serve` exposes a v1 REST API for stateless coordination of existing moo
sessions. The API is a control plane over the same per-session daemons used by
the CLI; terminal state still comes from libghostty.

## Start The Server

```sh
moo serve --addr 127.0.0.1:8765
MOO_API_TOKEN=secret moo serve --addr 0.0.0.0:8765 --token-env MOO_API_TOKEN
```

The server prints its effective URL on stdout:

```text
moo serve http://127.0.0.1:8765
```

`--addr` defaults to `127.0.0.1:0`, which binds an available loopback port.
Binding any non-loopback address requires `--token-env`.

## Auth

When `--token-env <name>` is configured, every endpoint except
`GET /v1/health` requires:

```http
Authorization: Bearer <token>
```

Unauthorized requests return `401` before workspace or session state is read or
changed. Non-loopback binds without token auth fail at startup.

## Workspace IDs

Workspace path segments use the existing moo workspace name rules.

| ID | Meaning |
| --- | --- |
| `@default` | Default unnamed workspace |
| `<name>` | Named workspace, using `letters digits . _ -` |

## Endpoints

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/v1/health` | Health check |
| `GET` | `/v1/workspaces` | List workspaces and session counts |
| `POST` | `/v1/workspaces/{workspace}` | Create a workspace without creating a session |
| `DELETE` | `/v1/workspaces/{workspace}` | Terminate sessions and remove one workspace |
| `DELETE` | `/v1/workspaces?all=true` | Terminate sessions and remove every workspace |
| `GET` | `/v1/workspaces/{workspace}/sessions` | List live sessions in a workspace |
| `POST` | `/v1/workspaces/{workspace}/sessions` | Create a detached session |
| `GET` | `/v1/workspaces/{workspace}/sessions/{session}` | Inspect one session |
| `PATCH` | `/v1/workspaces/{workspace}/sessions/{session}` | Rename one session |
| `DELETE` | `/v1/workspaces/{workspace}/sessions/{session}` | Terminate one session |
| `POST` | `/v1/workspaces/{workspace}/sessions/{session}/input` | Send input |
| `POST` | `/v1/workspaces/{workspace}/sessions/{session}/slash` | Send agent harness slash command |
| `GET` | `/v1/workspaces/{workspace}/sessions/{session}/screen` | Read rendered screen |
| `POST` | `/v1/workspaces/{workspace}/sessions/{session}/wait` | Wait for text or idle |
| `POST` | `/v1/workspaces/{workspace}/sessions/{session}/resize` | Resize the PTY |
| `GET` | `/v1/workspaces/{workspace}/sessions/{session}/transcript` | Read live agent transcript JSON |
| `GET` | `/v1/workspaces/{workspace}/sessions/{session}/events` | Long-poll session event cursor |

## Schemas

Create workspace:

```http
POST /v1/workspaces/proj
```

Returns `201`:

```json
{"id":"proj","workspace":"proj","created":true}
```

Remove workspace:

```http
DELETE /v1/workspaces/proj
DELETE /v1/workspaces?all=true
```

Responses include the number of sessions that were terminated:

```json
{"workspace":"proj","removed":true,"sessions":2}
```

For `?all=true`, the response contains one entry per workspace. Named workspace
directories are removed; the default runtime directory remains.

Create session:

```json
{
  "name": "build",
  "agent": "claude",
  "command": ["bash", "-lc", "make test"],
  "rows": 24,
  "cols": 80
}
```

`agent`, `command`, `rows`, and `cols` are optional. `argv` is accepted as an
alias for `command`. Create returns `201`:

```json
{"session":"build","workspace":"proj","created":true}
```

Session object:

```json
{
  "name": "build",
  "attached": false,
  "idle_ms": 1234,
  "out_idle_ms": 1000,
  "title": "bash",
  "cursor": 4
}
```

Input request:

```json
{"text":"make test","enter":true}
```

Also accepted: `{"key":"C-c"}`, `{"keys":["Up","Enter"]}`, and
`{"base64":"...","enter":true}`. NUL bytes are rejected because the current
daemon control protocol uses NUL-separated argv payloads.

Slash request:

```json
{"command":"compact","prompt":"focus on tests"}
```

Commands:

| `command` | Body | Typed line |
| --- | --- | --- |
| `compact` | optional `"prompt"` | `/compact` or `/compact <prompt>` |
| `clear` | none | `/clear` |
| `goal` | `"prompt":"<text>"` | `/goal <text>` |
| `goal` | `"clear":true` | `/goal clear` |

Enter is always appended. Response:

```json
{"sent":true,"command":"compact","line":"/compact focus on tests"}
```

Screen response:

```json
{
  "session": "build",
  "title": "bash",
  "rows": 24,
  "cols": 80,
  "cursor": {"row": 3, "col": 1},
  "screen": "..."
}
```

Use `?scrollback=true` to include scrollback.

Wait request:

```json
{"text":"PASS","timeout":"30s"}
```

or:

```json
{"idle":true,"timeout":"10s"}
```

Timeout returns `408`.

Resize request:

```json
{"rows":40,"cols":120}
```

Transcript responses match live `moo read <session> --json` semantics. Optional
query parameters mirror the CLI: `agent=claude|codex|pi`, `history=true|false`,
and `current=true|false`.

```json
{
  "session": "bot",
  "agent": "claude",
  "state": "unknown",
  "messages": 0,
  "transcript": [],
  "runs": [
    {
      "agent": "claude",
      "source": "sidecar",
      "state": "unknown",
      "confidence": "exact",
      "messages": 0,
      "transcript": []
    }
  ],
  "warnings": []
}
```

Saved transcript file reads are intentionally not exposed by HTTP v1.

## Event Cursor

`GET /v1/workspaces/{workspace}/sessions/{session}/events?since=<cursor>&timeout=30s`
long-polls daemon state. Responses include a monotonic per-session `cursor`.

```json
{"cursor":5,"events":[{"type":"session_state","cursor":5,"title":"bash"}]}
```

If no event arrives before the timeout:

```json
{"cursor":5,"events":[],"timed_out":true}
```

If `since` is newer than the daemon's retained cursor, the response includes
`"stale": true`.

## Status Codes

| Code | Meaning |
| --- | --- |
| `200` | Request succeeded |
| `201` | Session created |
| `400` | Invalid request, JSON, input, name, key, or timeout |
| `401` | Missing or invalid bearer token |
| `404` | Unknown endpoint or missing session |
| `408` | Wait timed out |
| `409` | Session exists, ambiguous session prefix, or rename conflict |
| `500` | Internal or daemon response error |

Error body:

```json
{"error":{"code":"not_found","message":"session not found"}}
```

## Curl Examples

```sh
API=http://127.0.0.1:8765

curl "$API/v1/workspaces"

curl -sS -X POST "$API/v1/workspaces/proj"

curl -sS -X POST "$API/v1/workspaces/proj/sessions" \
  -H 'Content-Type: application/json' \
  -d '{"name":"build","command":["bash"],"rows":24,"cols":80}'

curl -sS -X POST "$API/v1/workspaces/proj/sessions/build/input" \
  -H 'Content-Type: application/json' \
  -d '{"text":"echo READY","enter":true}'

curl -sS -X POST "$API/v1/workspaces/proj/sessions/build/slash" \
  -H 'Content-Type: application/json' \
  -d '{"command":"goal","prompt":"fix the build"}'

curl -sS -X POST "$API/v1/workspaces/proj/sessions/build/wait" \
  -H 'Content-Type: application/json' \
  -d '{"text":"READY","timeout":"10s"}'

curl "$API/v1/workspaces/proj/sessions/build/screen"

curl "$API/v1/workspaces/proj/sessions/build/events?since=0&timeout=5s"

curl "$API/v1/workspaces/proj/sessions/build/transcript"

curl -sS -X DELETE "$API/v1/workspaces/proj/sessions/build"

curl -sS -X DELETE "$API/v1/workspaces/proj"

curl -sS -X DELETE "$API/v1/workspaces?all=true"
```

With auth:

```sh
curl -H "Authorization: Bearer $MOO_API_TOKEN" "$API/v1/workspaces"
```

## Non-goals

- SSH transport, tunneling, or host login.
- Splits, tabs, or tmux-compatible layout management.
- WebSocket or SSE streaming in v1.
- HTTP access to arbitrary saved transcript files.
- Multi-client shared attachment semantics. Snapshot/input APIs do not attach
  to sessions; `moo attach` keeps its existing steal behavior.
