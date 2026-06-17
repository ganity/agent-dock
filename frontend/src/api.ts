import type {
  AdminUser,
  AttachSessionInput,
  CurrentUser,
  CreateSessionInput,
  ResumeCandidate,
  SessionDetail,
  SessionSummary,
  WorkspaceDirectoryListing,
  WorkspaceRoot,
} from "./types";

export async function login(username: string, password: string): Promise<CurrentUser> {
  const response = await fetch("/api/auth/login", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ username, password }),
  });

  if (!response.ok) {
    throw new Error("Login failed");
  }

  const data = (await response.json()) as { user: CurrentUser };
  return data.user;
}

export async function restoreSession(): Promise<CurrentUser> {
  const response = await fetch("/api/auth/session");
  if (!response.ok) {
    throw new Error("UNAUTHORIZED");
  }

  const data = (await response.json()) as { user: CurrentUser };
  return data.user;
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

export async function listResumeCandidates(input: {
  rootId: string;
  agentKind: string;
  path: string;
}): Promise<ResumeCandidate[]> {
  const search = new URLSearchParams({
    rootId: input.rootId,
    agentKind: input.agentKind,
    path: input.path,
  });
  const response = await fetch(`/api/sessions/resume-candidates?${search.toString()}`);
  if (!response.ok) {
    throw new Error("Failed to load resume candidates");
  }

  const data = (await response.json()) as { candidates: ResumeCandidate[] };
  return data.candidates;
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

export async function resumeSession(id: string): Promise<SessionDetail> {
  const response = await fetch(`/api/sessions/${id}/resume`, {
    method: "POST",
  });

  if (!response.ok) {
    throw new Error("Failed to resume session");
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

export async function listUsers(): Promise<AdminUser[]> {
  const response = await fetch("/api/admin/users");
  if (!response.ok) {
    throw new Error("Failed to load users");
  }
  const data = (await response.json()) as { users: AdminUser[] };
  return data.users;
}

export async function createUser(input: {
  username: string;
  password: string;
  isAdmin: boolean;
}): Promise<AdminUser> {
  const response = await fetch("/api/admin/users", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(input),
  });
  if (!response.ok) {
    throw new Error("Failed to create user");
  }
  const data = (await response.json()) as { user: AdminUser };
  return data.user;
}

export async function resetUserPassword(userId: string, password: string): Promise<void> {
  const response = await fetch(`/api/admin/users/${userId}/password`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ password }),
  });
  if (!response.ok) {
    throw new Error("Failed to reset password");
  }
}

export async function deleteUser(userId: string): Promise<void> {
  const response = await fetch(`/api/admin/users/${userId}`, {
    method: "DELETE",
  });
  if (!response.ok) {
    throw new Error("Failed to delete user");
  }
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
