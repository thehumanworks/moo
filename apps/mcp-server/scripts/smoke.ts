import { spawn } from "node:child_process";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

type RpcMessage = {
  jsonrpc: "2.0";
  id?: number;
  method?: string;
  params?: unknown;
  result?: unknown;
  error?: unknown;
};

const repoRoot = new URL("../../..", import.meta.url).pathname;
const mooBin = join(repoRoot, "zig-out", "bin", "moo");
const runtimeDir = await mkdtemp(join(tmpdir(), "moo-mcp-smoke-"));
await mkdir(runtimeDir, { recursive: true });

const child = spawn(mooBin, ["mcp"], {
  cwd: repoRoot,
  env: {
    ...process.env,
    MOO_DIR: runtimeDir,
  },
  stdio: ["pipe", "pipe", "inherit"],
});

try {
  const reader = makeReader(child.stdout);
  send(1, "initialize", {
    protocolVersion: "2025-06-18",
    capabilities: {},
    clientInfo: { name: "moo-mcp-smoke", version: "0.0.0" },
  });
  await expectResult(reader, 1);
  notify("notifications/initialized", {});

  send(2, "tools/list", {});
  const listed = await expectResult(reader, 2) as { tools?: Array<{ name: string }> };
  const names = new Set((listed.tools ?? []).map((tool) => tool.name));
  for (const required of ["moo_api_health", "moo_create_session", "moo_send_input", "moo_poll_events"]) {
    if (!names.has(required)) throw new Error(`missing tool: ${required}`);
  }

  send(3, "tools/call", { name: "moo_api_health", arguments: {} });
  const health = await expectResult(reader, 3) as { structuredContent?: { ok?: boolean } };
  if (health.structuredContent?.ok !== true) {
    throw new Error(`unexpected health result: ${JSON.stringify(health)}`);
  }
  child.stdin.end();
  await waitForExit(child);
} finally {
  if (child.exitCode === null && child.signalCode === null) child.kill("SIGTERM");
  await rm(runtimeDir, { recursive: true, force: true });
}

function send(id: number, method: string, params: unknown): void {
  child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
}

function notify(method: string, params: unknown): void {
  child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method, params })}\n`);
}

function makeReader(stream: NodeJS.ReadableStream): () => Promise<RpcMessage> {
  const messages: RpcMessage[] = [];
  const waiters: Array<(message: RpcMessage) => void> = [];
  let buffered = "";
  stream.on("data", (chunk) => {
    buffered += chunk.toString("utf8");
    while (true) {
      const newline = buffered.indexOf("\n");
      if (newline === -1) break;
      const line = buffered.slice(0, newline).trim();
      buffered = buffered.slice(newline + 1);
      if (line.length === 0) continue;
      const message = JSON.parse(line) as RpcMessage;
      const waiter = waiters.shift();
      if (waiter) waiter(message);
      else messages.push(message);
    }
  });
  return () => new Promise((resolve, reject) => {
    const message = messages.shift();
    if (message) {
      resolve(message);
      return;
    }
    const timer = setTimeout(() => reject(new Error("timed out waiting for MCP response")), 10_000);
    waiters.push((next) => {
      clearTimeout(timer);
      resolve(next);
    });
  });
}

async function expectResult(reader: () => Promise<RpcMessage>, id: number): Promise<unknown> {
  while (true) {
    const message = await reader();
    if (message.id !== id) continue;
    if (message.error) throw new Error(`MCP error for ${id}: ${JSON.stringify(message.error)}`);
    return message.result;
  }
}

function waitForExit(child: ReturnType<typeof spawn>): Promise<void> {
  return new Promise((resolve, reject) => {
    if (child.exitCode !== null || child.signalCode !== null) {
      resolve();
      return;
    }
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new Error("timed out waiting for moo mcp to exit"));
    }, 5_000);
    child.once("exit", (code) => {
      clearTimeout(timer);
      if (code === 0) resolve();
      else reject(new Error(`moo mcp exited with ${code}`));
    });
  });
}
