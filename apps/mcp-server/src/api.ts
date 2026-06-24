export type JsonValue =
  | null
  | boolean
  | number
  | string
  | JsonValue[]
  | { [key: string]: JsonValue };

export class MooApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "MooApiError";
  }
}

export type ApiClientOptions = {
  baseUrl: string;
  token?: string;
  fetchImpl?: FetchLike;
};

export class MooApiClient {
  private readonly baseUrl: URL;
  private readonly fetchImpl: FetchLike;
  private readonly token?: string;

  constructor(options: ApiClientOptions) {
    this.baseUrl = new URL(options.baseUrl);
    this.baseUrl.pathname = this.baseUrl.pathname.replace(/\/+$/, "");
    this.fetchImpl = options.fetchImpl ?? fetch;
    this.token = options.token;
  }

  async request(method: string, path: string, body?: JsonValue): Promise<JsonValue> {
    const url = new URL(path, this.baseUrl);
    const headers = new Headers();
    if (this.token) headers.set("Authorization", `Bearer ${this.token}`);
    let payload: string | undefined;
    if (body !== undefined) {
      headers.set("Content-Type", "application/json");
      payload = JSON.stringify(body);
    }
    const response = await this.fetchImpl(url, {
      method,
      headers,
      body: payload,
    });
    const text = await response.text();
    const data = text.length > 0 ? JSON.parse(text) as JsonValue : null;
    if (!response.ok) {
      const error = parseError(data);
      throw new MooApiError(response.status, error.code, error.message);
    }
    return data;
  }
}

export type FetchLike = (input: URL | RequestInfo, init?: RequestInit) => Promise<Response>;

function parseError(data: JsonValue): { code: string; message: string } {
  if (data && typeof data === "object" && !Array.isArray(data)) {
    const error = data.error;
    if (error && typeof error === "object" && !Array.isArray(error)) {
      const code = typeof error.code === "string" ? error.code : "api_error";
      const message = typeof error.message === "string" ? error.message : code;
      return { code, message };
    }
  }
  return { code: "api_error", message: "moo API request failed" };
}

export function workspacePath(workspace: string): string {
  return workspace === "" || workspace === "@default"
    ? "/v1/workspaces/@default"
    : `/v1/workspaces/${encodeURIComponent(workspace)}`;
}

export function sessionPath(workspace: string, session: string): string {
  return `${workspacePath(workspace)}/sessions/${encodeURIComponent(session)}`;
}

export function transcriptPath(
  workspace: string,
  session: string,
  options: { agent?: string; history?: boolean; current?: boolean } = {},
): string {
  const query = new URLSearchParams();
  if (options.agent !== undefined) query.set("agent", options.agent);
  if (options.history !== undefined) query.set("history", String(options.history));
  if (options.current !== undefined) query.set("current", String(options.current));
  const suffix = query.toString();
  return `${sessionPath(workspace, session)}/transcript${suffix.length > 0 ? `?${suffix}` : ""}`;
}
