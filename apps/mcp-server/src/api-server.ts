import { spawn, type ChildProcessByStdio } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import type { Readable } from "node:stream";

import { MooApiClient } from "./api.js";

type ApiChild = ChildProcessByStdio<null, Readable, Readable>;

export type ApiServerHandle = {
  client: MooApiClient;
  baseUrl: string;
  stop(): Promise<void>;
};

export async function ensureApiServer(): Promise<ApiServerHandle> {
  const configured = process.env.MOO_API_URL;
  const token = process.env.MOO_API_TOKEN;
  if (configured) {
    const client = new MooApiClient({ baseUrl: configured, token });
    await client.request("GET", "/v1/health");
    return { client, baseUrl: configured, stop: async () => {} };
  }

  const mooBin = resolveMooBinary();
  const child = spawn(mooBin, ["serve", "--addr", "127.0.0.1:0"], {
    env: process.env,
    stdio: ["ignore", "pipe", "pipe"],
  });
  child.stderr.on("data", (chunk) => {
    process.stderr.write(chunk);
  });
  const baseUrl = await readReadyUrl(child);
  const client = new MooApiClient({ baseUrl });
  return {
    client,
    baseUrl,
    stop: () => stopChild(child),
  };
}

export function resolveMooBinary(): string {
  if (process.env.MOO_BIN) return process.env.MOO_BIN;
  const sibling = join(dirname(process.execPath), "moo");
  if (existsExecutable(sibling)) return sibling;
  const dev = join(process.cwd(), "zig-out", "bin", "moo");
  if (existsExecutable(dev)) return dev;
  return "moo";
}

function existsExecutable(path: string): boolean {
  return existsSync(path);
}

async function readReadyUrl(child: ApiChild): Promise<string> {
  const deadline = setTimeout(() => {
    child.kill("SIGKILL");
  }, 10_000);
  try {
    let buffered = "";
    for await (const chunk of child.stdout) {
      buffered += chunk.toString("utf8");
      const newline = buffered.indexOf("\n");
      if (newline === -1) continue;
      const line = buffered.slice(0, newline).trim();
      const match = /^moo serve (http:\/\/.+)$/.exec(line);
      if (!match) throw new Error(`unexpected moo serve readiness line: ${line}`);
      return match[1];
    }
    throw new Error("moo serve exited before reporting readiness");
  } finally {
    clearTimeout(deadline);
  }
}

function stopChild(child: ApiChild): Promise<void> {
  return new Promise((resolve) => {
    if (child.exitCode !== null || child.signalCode !== null) {
      resolve();
      return;
    }
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
    }, 2_000);
    child.once("exit", () => {
      clearTimeout(timer);
      resolve();
    });
    child.kill("SIGTERM");
  });
}
