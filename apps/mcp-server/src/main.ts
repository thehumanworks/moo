import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";

import { ensureApiServer } from "./api-server.js";
import { registerMooTools } from "./tools.js";

async function main(): Promise<void> {
  const api = await ensureApiServer();
  const server = new McpServer({
    name: "moo-mcp-server",
    version: "0.5.20",
  });
  registerMooTools(server, api.client);

  let stopping = false;
  const shutdown = async (code: number) => {
    if (stopping) return;
    stopping = true;
    await server.close();
    await api.stop();
    process.exit(code);
  };
  process.once("SIGINT", () => {
    void shutdown(130);
  });
  process.once("SIGTERM", () => {
    void shutdown(143);
  });
  process.stdin.once("close", () => void shutdown(0));
  process.stdin.once("end", () => void shutdown(0));

  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch((error) => {
  const message = error instanceof Error ? error.stack ?? error.message : String(error);
  process.stderr.write(`moo-mcp-server: ${message}\n`);
  process.exit(1);
});
