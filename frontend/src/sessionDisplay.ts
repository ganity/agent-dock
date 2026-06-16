type DisplayableSession = {
  id?: string;
  title?: string | null;
  agentKind: string;
  workspacePath?: string | null;
};

export function getSessionTitle(session: DisplayableSession): string {
  const explicitTitle = session.title?.trim();
  if (explicitTitle) {
    return explicitTitle;
  }

  const workspacePath = session.workspacePath?.trim().replace(/[\\/]+$/, "");
  const pathSegment = workspacePath?.split(/[\\/]/).filter(Boolean).at(-1);
  if (pathSegment) {
    return pathSegment;
  }

  return session.agentKind;
}
