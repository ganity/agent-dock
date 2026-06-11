export interface SessionSummary {
  id: string;
  agentKind: string;
  sourceKind?: string;
  runtimeSessionId?: string;
  status?: string;
  workspacePath?: string;
}

export interface WorkspaceRoot {
  id: string;
  label: string;
  path: string;
}

export interface CreateSessionInput {
  rootId: string;
  path: string;
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
  agentKind: string;
  sourceKind?: string;
  runtimeSessionId?: string;
  workspacePath?: string;
  status?: string;
  events: SessionEvent[];
}
