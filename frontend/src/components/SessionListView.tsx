import { useState } from "react";

import { getSessionTitle } from "../sessionDisplay";
import type { SessionSummary } from "../types";

export function SessionListView(props: {
  hasRoots: boolean;
  sessions: SessionSummary[];
  onCreate: () => void;
  onAttach: () => void;
  onSelect: (sessionId: string) => void;
  onDelete: (sessionId: string) => void;
  deletingSessionId?: string | null;
}) {
  const [menuSessionId, setMenuSessionId] = useState<string | null>(null);

  return (
    <section className="session-home">
      <header className="session-home-header">
        <p className="eyebrow">Local control surface</p>
        <h1>Sessions</h1>
      </header>

      <div className="session-action-grid">
        <button
          className="session-action-card session-action-card-primary"
          type="button"
          disabled={!props.hasRoots}
          onClick={props.onCreate}
        >
          <span aria-hidden="true" className="action-icon">
            +
          </span>
          <span>
            <strong>New</strong>
          </span>
        </button>
        <button className="session-action-card" type="button" disabled={!props.hasRoots} onClick={props.onAttach}>
          <span aria-hidden="true" className="action-icon">
            ↗
          </span>
          <span>
            <strong>Attach</strong>
          </span>
        </button>
      </div>

      {!props.hasRoots ? (
        <p className="session-root-warning">Add a workspace root before creating or attaching sessions.</p>
      ) : null}

      {props.sessions.length === 0 ? (
        <section className="session-empty-card">
          <h2>No sessions yet</h2>
          <p>Create a managed session or attach an existing runtime to get started.</p>
        </section>
      ) : (
        <ul aria-label="Sessions" className="session-card-list">
          {props.sessions.map((session) => {
            const title = getSessionTitle(session);
            const statusId = session.status ? `${session.id}-description-status` : undefined;
            const pathId = session.workspacePath ? `${session.id}-description-path` : undefined;
            const agentId = `${session.id}-description-agent`;
            const sourceId = session.sourceKind ? `${session.id}-description-source` : undefined;
            const describedBy = [statusId, pathId, agentId, sourceId].filter(Boolean).join(" ");

            return (
              <li key={session.id}>
                <div className="session-card-shell">
                  <button
                    aria-label={`Open ${title}`}
                    aria-describedby={describedBy || undefined}
                    className="session-card"
                    disabled={props.deletingSessionId === session.id}
                    type="button"
                    onClick={() => props.onSelect(session.id)}
                  >
                    <span className="session-card-main">
                      <span className="session-card-title-row">
                        <span className="session-card-title">{title}</span>
                        {session.status ? (
                          <span className="session-chip session-chip-status">
                            {session.status}
                          </span>
                        ) : null}
                      </span>
                      {session.workspacePath ? (
                        <span className="session-card-path">{session.workspacePath}</span>
                      ) : null}
                      <span className="session-chip-row">
                        <span className="session-chip">{session.agentKind}</span>
                        {session.sourceKind ? <span className="session-chip">{session.sourceKind}</span> : null}
                      </span>
                    </span>
                  </button>
                  <details
                    className="session-card-menu"
                    open={menuSessionId === session.id}
                    onToggle={(event) => {
                      const nextOpen = (event.currentTarget as HTMLDetailsElement).open;
                      setMenuSessionId(nextOpen ? session.id : null);
                    }}
                  >
                    <summary
                      aria-label={`More actions for ${title}`}
                      className="session-card-menu-button"
                      role="button"
                    >
                      <svg aria-hidden="true" viewBox="0 0 24 24">
                        <circle cx="12" cy="5" r="1.6" />
                        <circle cx="12" cy="12" r="1.6" />
                        <circle cx="12" cy="19" r="1.6" />
                      </svg>
                    </summary>
                    <div className="session-card-menu-panel">
                      <button
                        aria-label={`Delete ${title}`}
                        className="session-card-menu-item"
                        disabled={props.deletingSessionId === session.id}
                        type="button"
                        onClick={() => {
                          setMenuSessionId(null);
                          props.onDelete(session.id);
                        }}
                      >
                        {props.deletingSessionId === session.id ? "Deleting" : "Delete"}
                      </button>
                    </div>
                  </details>
                </div>
                <span hidden={true} id={agentId}>
                  Agent: {session.agentKind}
                </span>
                {session.status ? (
                  <span hidden={true} id={statusId}>
                    Status: {session.status}
                  </span>
                ) : null}
                {session.workspacePath ? (
                  <span hidden={true} id={pathId}>
                    Workspace: {session.workspacePath}
                  </span>
                ) : null}
                {session.sourceKind ? (
                  <span hidden={true} id={sourceId}>
                    Source: {session.sourceKind}
                  </span>
                ) : null}
              </li>
            );
          })}
        </ul>
      )}
    </section>
  );
}
