import { describe, expect, test } from "bun:test";

import { MooApiClient, MooApiError, sessionPath, transcriptPath, workspacePath } from "../src/api.js";

describe("path helpers", () => {
  test("maps default workspace to @default", () => {
    expect(workspacePath("")).toBe("/v1/workspaces/@default");
    expect(workspacePath("@default")).toBe("/v1/workspaces/@default");
  });

  test("encodes workspace and session path segments", () => {
    expect(sessionPath("proj.a", "build/one")).toBe("/v1/workspaces/proj.a/sessions/build%2Fone");
  });

  test("adds transcript query options for MCP parity", () => {
    expect(transcriptPath("proj", "bot", { agent: "codex", history: true, current: false }))
      .toBe("/v1/workspaces/proj/sessions/bot/transcript?agent=codex&history=true&current=false");
  });
});

describe("MooApiClient", () => {
  test("adds bearer auth and JSON body", async () => {
    const calls: Request[] = [];
    const client = new MooApiClient({
      baseUrl: "http://127.0.0.1:8765",
      token: "secret",
      fetchImpl: async (request, init) => {
        calls.push(request instanceof Request ? new Request(request, init) : new Request(request, init));
        return new Response(JSON.stringify({ ok: true }), { status: 200 });
      },
    });
    await client.request("POST", "/v1/workspaces/@default/sessions", { name: "build" });
    expect(calls).toHaveLength(1);
    expect(calls[0].headers.get("Authorization")).toBe("Bearer secret");
    expect(calls[0].headers.get("Content-Type")).toBe("application/json");
    expect(await calls[0].text()).toBe('{"name":"build"}');
  });

  test("throws structured API errors", async () => {
    const client = new MooApiClient({
      baseUrl: "http://127.0.0.1:8765",
      fetchImpl: async () => new Response(
        JSON.stringify({ error: { code: "not_found", message: "session not found" } }),
        { status: 404 },
      ),
    });
    await expect(client.request("GET", "/missing")).rejects.toEqual(
      new MooApiError(404, "not_found", "session not found"),
    );
  });
});
