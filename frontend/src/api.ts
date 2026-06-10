import type { CreateSessionInput, SessionDetail, SessionSummary, WorkspaceRoot } from "./types";

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

export async function createSession(input: CreateSessionInput): Promise<SessionDetail> {
  const response = await fetch("/api/sessions", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(input),
  });

  if (!response.ok) {
    throw new Error("Failed to create session");
  }

  return (await response.json()) as SessionDetail;
}

export async function fetchSessionSnapshot(id: string): Promise<SessionDetail> {
  const response = await fetch(`/api/sessions/${id}`);
  if (!response.ok) {
    throw new Error("Failed to load session");
  }

  return (await response.json()) as SessionDetail;
}

export function connectEventStream(id: string, after: number): WebSocket {
  const protocol = window.location.protocol === "https:" ? "wss" : "ws";
  return new WebSocket(`${protocol}://${window.location.host}/ws/sessions/${id}/events?after=${after}`);
}

export async function sendSessionMessage(sessionId: string, message: string): Promise<void> {
  const response = await fetch(`/api/sessions/${sessionId}/messages`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ message }),
  });

  if (!response.ok) {
    throw new Error("Failed to send message");
  }
}
