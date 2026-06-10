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
  return [];
}

export async function createSession(_input: CreateSessionInput): Promise<SessionSummary> {
  return {
    id: "placeholder",
    agentKind: "placeholder",
  };
}
