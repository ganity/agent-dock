export interface SessionSummary {
  id: string;
  title?: string | null;
  agentKind: string;
  sourceKind?: string;
  runtimeSessionId?: string;
  status?: string;
  workspacePath?: string;
}

export interface ResumeCandidate {
  runtimeSessionId: string;
  title?: string | null;
  agentKind: string;
  workspacePath: string;
  updatedAt?: string | null;
  status?: string | null;
}

export interface CurrentUser {
  id: string;
  displayName: string;
  isAdmin?: boolean;
}

export interface AdminUser {
  id: string;
  username: string;
  displayName: string;
  isAdmin: boolean;
}

export interface WorkspaceRoot {
  id: string;
  label: string;
  path: string;
}

export interface WorkspaceDirectory {
  name: string;
  path: string;
}

export interface WorkspaceDirectoryListing {
  currentPath: string;
  parentPath?: string | null;
  directories: WorkspaceDirectory[];
}

export interface CreateSessionInput {
  rootId: string;
  path: string;
  title: string;
  agentKind: string;
}

export interface AttachSessionInput {
  rootId: string;
  path: string;
  agentKind: string;
  runtimeSessionId: string;
}

export interface SessionEvent {
  id: number;
  eventType: string;
  payload: Record<string, unknown>;
}

export interface SessionDetail {
  id: string;
  title?: string | null;
  agentKind: string;
  sourceKind?: string;
  runtimeSessionId?: string;
  workspacePath?: string;
  status?: string;
  hasMoreHistory?: boolean;
  events: SessionEvent[];
}
