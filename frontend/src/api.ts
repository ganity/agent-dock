import type { CreateSessionInput, SessionSummary, WorkspaceRoot } from "./types";

export async function login(pin: string): Promise<void> {
  const response = await fetch("/api/auth/login", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ pin }),
  });

  if (!response.ok) {
    throw new Error("Login failed");
  }
}

export async function listRoots(): Promise<WorkspaceRoot[]> {
  const response = await fetch("/api/workspaces/roots");
  if (!response.ok) {
    throw new Error("Failed to load roots");
  }

  const data = (await response.json()) as { roots: WorkspaceRoot[] };
  return data.roots;
}

export async function listSessions(): Promise<SessionSummary[]> {
  const response = await fetch("/api/sessions");
  if (!response.ok) {
    throw new Error("Failed to load sessions");
  }

  const data = (await response.json()) as { sessions: SessionSummary[] };
  return data.sessions;
}

export async function createSession(input: CreateSessionInput): Promise<SessionSummary> {
  const response = await fetch("/api/sessions", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(input),
  });

  if (!response.ok) {
    throw new Error("Failed to create session");
  }

  const data = (await response.json()) as SessionSummary;
  return {
    id: data.id,
    agentKind: data.agentKind,
  };
}
