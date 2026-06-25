import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";

import type { JsonValue, MooApiClient } from "./api.js";
import { sessionPath, transcriptPath, workspacePath } from "./api.js";

type ToolResult = {
  content: Array<{ type: "text"; text: string }>;
  structuredContent?: Record<string, unknown>;
};

const workspaceSchema = z.object({
  workspace: z.string().default("@default").describe("Workspace id, or @default for the default workspace"),
});

const requiredWorkspaceSchema = z.object({
  workspace: z.string().describe("Workspace id, or @default for the default workspace"),
});

const sessionSchema = workspaceSchema.extend({
  session: z.string().describe("Session name or unique prefix"),
});

export function registerMooTools(server: McpServer, client: MooApiClient): void {
  server.registerTool(
    "moo_api_health",
    {
      title: "Moo API Health",
      description: "Check that the moo HTTP API is reachable.",
      inputSchema: z.object({}),
    },
    async () => result(await client.request("GET", "/v1/health")),
  );

  server.registerTool(
    "moo_list_workspaces",
    {
      title: "List Moo Workspaces",
      description: "List moo workspaces and their live session counts.",
      inputSchema: z.object({}),
    },
    async () => result(await client.request("GET", "/v1/workspaces")),
  );

  server.registerTool(
    "moo_create_workspace",
    {
      title: "Create Moo Workspace",
      description: "Create a moo workspace without creating a session.",
      inputSchema: requiredWorkspaceSchema.extend({
        cwd: z.string().optional().describe("Working directory for all sessions in this workspace"),
      }),
    },
    async ({ workspace, cwd }) => result(await client.request("POST", workspacePath(workspace), compact({ cwd }))),
  );

  server.registerTool(
    "moo_remove_workspace",
    {
      title: "Remove Moo Workspace",
      description: "Terminate sessions and remove one moo workspace.",
      inputSchema: requiredWorkspaceSchema,
    },
    async ({ workspace }) => result(await client.request("DELETE", workspacePath(workspace))),
  );

  server.registerTool(
    "moo_remove_all_workspaces",
    {
      title: "Remove All Moo Workspaces",
      description: "Terminate every session and remove every named moo workspace.",
      inputSchema: z.object({}),
    },
    async () => result(await client.request("DELETE", "/v1/workspaces?all=true")),
  );

  server.registerTool(
    "moo_list_sessions",
    {
      title: "List Moo Sessions",
      description: "List live sessions in a workspace.",
      inputSchema: workspaceSchema,
    },
    async ({ workspace }) => result(await client.request("GET", `${workspacePath(workspace)}/sessions`)),
  );

  server.registerTool(
    "moo_create_session",
    {
      title: "Create Moo Session",
      description: "Create a detached moo session.",
      inputSchema: workspaceSchema.extend({
        name: z.string().optional(),
        agent: z.enum(["claude", "codex", "pi", "raw", "bash", "zsh"]).optional(),
        command: z.array(z.string()).optional(),
        rows: z.number().int().min(1).max(65535).optional(),
        cols: z.number().int().min(1).max(65535).optional(),
      }),
    },
    async ({ workspace, ...body }) => result(await client.request("POST", `${workspacePath(workspace)}/sessions`, body)),
  );

  server.registerTool(
    "moo_get_session",
    {
      title: "Get Moo Session",
      description: "Inspect one moo session.",
      inputSchema: sessionSchema,
    },
    async ({ workspace, session }) => result(await client.request("GET", sessionPath(workspace, session))),
  );

  server.registerTool(
    "moo_rename_session",
    {
      title: "Rename Moo Session",
      description: "Rename one moo session.",
      inputSchema: sessionSchema.extend({
        name: z.string().describe("New session name"),
      }),
    },
    async ({ workspace, session, name }) => result(await client.request("PATCH", sessionPath(workspace, session), { name })),
  );

  server.registerTool(
    "moo_delete_session",
    {
      title: "Delete Moo Session",
      description: "Terminate one moo session.",
      inputSchema: sessionSchema,
    },
    async ({ workspace, session }) => result(await client.request("DELETE", sessionPath(workspace, session))),
  );

  server.registerTool(
    "moo_send_input",
    {
      title: "Send Input To Moo Session",
      description: "Send text, keys, or base64 bytes to a moo session.",
      inputSchema: sessionSchema.extend({
        text: z.string().optional(),
        key: z.string().optional(),
        keys: z.array(z.string()).optional(),
        base64: z.string().optional(),
        enter: z.boolean().optional(),
      }),
    },
    async ({ workspace, session, ...body }) => result(await client.request("POST", `${sessionPath(workspace, session)}/input`, body)),
  );

  server.registerTool(
    "moo_get_screen",
    {
      title: "Get Moo Screen",
      description: "Read a libghostty-rendered screen snapshot from a session.",
      inputSchema: sessionSchema.extend({
        scrollback: z.boolean().optional(),
      }),
    },
    async ({ workspace, session, scrollback }) => {
      const suffix = scrollback ? "?scrollback=true" : "";
      return result(await client.request("GET", `${sessionPath(workspace, session)}/screen${suffix}`));
    },
  );

  server.registerTool(
    "moo_wait_session",
    {
      title: "Wait For Moo Session",
      description: "Wait for visible text or idle output in a session.",
      inputSchema: sessionSchema.extend({
        text: z.string().optional(),
        idle: z.boolean().optional(),
        timeout: z.string().optional(),
      }),
    },
    async ({ workspace, session, text, idle, timeout }) => result(
      await client.request("POST", `${sessionPath(workspace, session)}/wait`, compact({ text, idle, timeout })),
    ),
  );

  server.registerTool(
    "moo_resize_session",
    {
      title: "Resize Moo Session",
      description: "Resize the session PTY.",
      inputSchema: sessionSchema.extend({
        rows: z.number().int().min(1).max(65535),
        cols: z.number().int().min(1).max(65535),
      }),
    },
    async ({ workspace, session, rows, cols }) => result(
      await client.request("POST", `${sessionPath(workspace, session)}/resize`, { rows, cols }),
    ),
  );

  server.registerTool(
    "moo_get_transcript",
    {
      title: "Get Moo Agent Transcript",
      description: "Read live agent transcript JSON for a moo session.",
      inputSchema: sessionSchema.extend({
        agent: z.enum(["claude", "codex", "pi"]).optional(),
        history: z.boolean().optional(),
        current: z.boolean().optional(),
      }),
    },
    async ({ workspace, session, agent, history, current }) => result(
      await client.request("GET", transcriptPath(workspace, session, compact({ agent, history, current }) as {
        agent?: string;
        history?: boolean;
        current?: boolean;
      })),
    ),
  );

  server.registerTool(
    "moo_poll_events",
    {
      title: "Poll Moo Events",
      description: "Long-poll one session's monotonic event cursor.",
      inputSchema: sessionSchema.extend({
        since: z.number().int().min(0).default(0),
        timeout: z.string().default("30s"),
      }),
    },
    async ({ workspace, session, since, timeout }) => {
      const query = new URLSearchParams({ since: String(since), timeout });
      return result(await client.request("GET", `${sessionPath(workspace, session)}/events?${query}`));
    },
  );
}

function result(value: JsonValue): ToolResult {
  const structured = toStructured(value);
  return {
    content: [{ type: "text", text: JSON.stringify(value, null, 2) }],
    ...(structured ? { structuredContent: structured } : {}),
  };
}

function toStructured(value: JsonValue): Record<string, unknown> | null {
  if (value && typeof value === "object" && !Array.isArray(value)) {
    return value as Record<string, unknown>;
  }
  return null;
}

function compact(values: Record<string, JsonValue | undefined>): JsonValue {
  const out: Record<string, JsonValue> = {};
  for (const [key, value] of Object.entries(values)) {
    if (value !== undefined) out[key] = value;
  }
  return out;
}
