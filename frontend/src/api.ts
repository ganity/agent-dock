import type {
  AttachSessionInput,
  CreateSessionInput,
  SessionDetail,
  SessionSummary,
  WorkspaceDirectoryListing,
  WorkspaceRoot,
} from "./types";

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

export async function restoreSession(): Promise<void> {
  const response = await fetch("/api/auth/session");
  if (!response.ok) {
    throw new Error("UNAUTHORIZED");
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

export async function listDirectories(path: string): Promise<WorkspaceDirectoryListing> {
  const response = await fetch(`/api/workspaces/directories?path=${encodeURIComponent(path)}`);
  if (!response.ok) {
    throw new Error("Failed to load directories");
  }

  return (await response.json()) as WorkspaceDirectoryListing;
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

export async function attachSession(input: AttachSessionInput): Promise<SessionDetail> {
  const response = await fetch("/api/sessions/attach", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(input),
  });

  if (!response.ok) {
    throw new Error("Failed to attach session");
  }

  return (await response.json()) as SessionDetail;
}

export async function fetchSessionSnapshot(
  id: string,
  options?: { limit?: number; before?: number },
): Promise<SessionDetail> {
  const search = new URLSearchParams();
  if (options?.limit) {
    search.set("limit", String(options.limit));
  }
  if (options?.before) {
    search.set("before", String(options.before));
  }

  const suffix = search.size > 0 ? `?${search.toString()}` : "";
  const response = await fetch(`/api/sessions/${id}${suffix}`);
  if (!response.ok) {
    throw new Error("Failed to load session");
  }

  return (await response.json()) as SessionDetail;
}

export async function deleteSession(id: string): Promise<void> {
  const response = await fetch(`/api/sessions/${id}`, {
    method: "DELETE",
  });

  if (!response.ok) {
    throw new Error("Failed to delete session");
  }
}

export function connectSessionEvents(id: string, after: number): WebSocket {
  const protocol = window.location.protocol === "https:" ? "wss" : "ws";
  return new WebSocket(`${protocol}://${window.location.host}/ws/sessions/${id}/events?after=${after}`);
}

export function connectVoiceInput(): WebSocket {
  const protocol = window.location.protocol === "https:" ? "wss" : "ws";
  return new WebSocket(`${protocol}://${window.location.host}/ws/voice-input`);
}

export function sessionAttachmentUrl(sessionId: string, imagePath: string): string | null {
  const attachmentName = imagePath.split(/[/\\]/).pop()?.trim();
  if (!attachmentName) {
    return null;
  }

  return `/api/sessions/${sessionId}/attachments/${encodeURIComponent(attachmentName)}`;
}

export async function uploadSessionAttachment(sessionId: string, file: File): Promise<string> {
  const response = await fetch(
    `/api/sessions/${sessionId}/attachments?filename=${encodeURIComponent(file.name)}`,
    {
      method: "POST",
      headers: { "content-type": file.type || "application/octet-stream" },
      body: file,
    },
  );

  if (!response.ok) {
    throw new Error("Failed to upload attachment");
  }

  const data = (await response.json()) as { path: string };
  return data.path;
}

export async function sendSessionMessage(
  sessionId: string,
  message: string,
  imagePaths: string[] = [],
): Promise<void> {
  const response = await fetch(`/api/sessions/${sessionId}/messages`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ message, imagePaths }),
  });

  if (!response.ok) {
    throw new Error("Failed to send message");
  }
}
