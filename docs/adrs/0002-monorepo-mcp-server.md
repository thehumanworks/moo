# ADR 0002: Monorepo TypeScript MCP Server

Date: 2026-06-24

## Context

moo now exposes a localhost-first HTTP API over existing session daemons. The
next integration target is a stdio MCP server that exposes that API as tools and
can be launched by `moo mcp`.

The project was still laid out as a single Zig package with source at the
repository root.

## Decision

Reshape the repository as a monorepo:

- Keep the Zig CLI as `packages/moo-cli`.
- Add the TypeScript MCP app as `apps/mcp-server`.
- Build the MCP server with `bun build --compile` into a single executable named
  `moo-mcp-server`.
- Install that executable next to `moo` during the root Zig build.
- Make `moo mcp` locate and run the bundled `moo-mcp-server` with inherited
  stdio.

The MCP server uses `@modelcontextprotocol/sdk` and exposes the HTTP API
endpoints as tools. It reuses an existing API process when `MOO_API_URL` is set;
otherwise it starts `moo serve --addr 127.0.0.1:0` and stops that child when the
MCP process exits.

## Consequences

- CLI release artifacts need both `moo` and `moo-mcp-server`.
- Local builds now require Bun as well as Zig.
- `moo mcp` remains a local stdio MCP entrypoint, while the HTTP API remains the
  network boundary.

## Alternatives Considered

- Implement MCP directly in Zig. Rejected because the user required the
  TypeScript SDK.
- Expose only a remote HTTP MCP server. Rejected because the requested MCP
  transport is stdio.
- Start a new API server for every tool call. Rejected because a single child API
  process per MCP server is simpler and avoids port churn.
