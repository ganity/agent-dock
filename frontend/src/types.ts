export interface SessionSummary {
  id: string;
  agentKind: string;
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
