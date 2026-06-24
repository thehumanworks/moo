# ADR 0001: HTTP API Gateway Over Session Daemons

Date: 2026-06-24

## Context

moo already owns terminal state inside one daemon per session. The CLI creates
detached sessions, sends input, waits, peeks at libghostty-rendered screen
state, reads live agent transcripts, and kills sessions over local Unix sockets.

The HTTP goal asks for remote-first, stateless coordination without replacing
the libghostty backend or using SSH as the interaction protocol.

## Decision

Add `moo serve` as a central HTTP REST gateway over the existing session daemon
model. The server speaks TCP HTTP, resolves workspaces and sessions with the
same filesystem/socket rules as the CLI, and uses daemon control commands for
input, screen snapshots, resize, lifecycle, transcript state, and event cursors.

The API is localhost-first. Any non-loopback bind requires bearer-token auth
configured through `--token-env`.

## Consequences

- libghostty terminal ownership stays inside session daemons.
- HTTP clients can coordinate sessions without attaching to or stealing a TTY.
- The first async interface is long-poll event cursors, not WebSocket or SSE.
- The gateway shares current daemon control protocol limits, including NUL input
  rejection until the Unix-socket command protocol grows a binary-safe input
  frame.

## Alternatives Considered

- Put an HTTP listener in every session daemon. Rejected because discovery,
  auth, and bind policy belong in one process.
- Replace daemon control with SSH. Rejected because the goal is HTTP-native
  coordination.
- Make WebSocket/SSE mandatory in v1. Rejected because long-polling is enough
  for stateless AI-agent coordination and simpler to test.
