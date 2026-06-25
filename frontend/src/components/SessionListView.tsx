import { useState } from "react";

import { getSessionTitle } from "../sessionDisplay";
import type { AdminUser, CurrentUser, SessionSummary } from "../types";

export function SessionListView(props: {
  currentUser: CurrentUser | null;
  hasRoots: boolean;
  sessions: SessionSummary[];
  users: AdminUser[];
  onCreateUser: (input: { username: string; password: string; isAdmin: boolean }) => Promise<void>;
  onResetPassword: (userId: string, password: string) => Promise<void>;
  onDeleteUser: (userId: string) => Promise<void>;
  onCreate: () => void;
  onAttach: () => void;
  onSelect: (sessionId: string) => void;
  onBrowseFiles?: (sessionId: string) => void;
  onDelete: (sessionId: string) => void;
  deletingSessionId?: string | null;
}) {
  const [menuSessionId, setMenuSessionId] = useState<string | null>(null);
  const [newUsername, setNewUsername] = useState("");
  const [newPassword, setNewPassword] = useState("");
  const [adminActionError, setAdminActionError] = useState<string | null>(null);

  return (
    <section className="session-home">
      <header className="session-home-header">
        <p className="eyebrow">Local control surface</p>
        <h1>Sessions</h1>
        {props.currentUser?.isAdmin ? (
          <a className="session-home-admin-link" href="#user-management">
            User management
          </a>
        ) : null}
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

      {props.currentUser?.isAdmin ? (
        <section className="session-empty-card" id="user-management" aria-label="User management">
          <h2>User management</h2>
          <p>Manage daemon users from the web client.</p>
          <div className="stack">
            <label className="field">
              <span>Username</span>
              <input
                aria-label="New username"
                className="input"
                value={newUsername}
                onChange={(event) => setNewUsername(event.target.value)}
              />
            </label>
            <label className="field">
              <span>Password</span>
              <input
                aria-label="New password"
                className="input"
                type="password"
                value={newPassword}
                onChange={(event) => setNewPassword(event.target.value)}
              />
            </label>
            <button
              className="button"
              type="button"
              onClick={() => {
                const username = newUsername.trim();
                const password = newPassword.trim();

                if (!username) {
                  setAdminActionError("Username is required");
                  return;
                }

                if (!password) {
                  setAdminActionError("Password is required");
                  return;
                }

                setAdminActionError(null);
                void props
                  .onCreateUser({
                    username,
                    password,
                    isAdmin: false,
                  })
                  .then(() => {
                    setNewUsername("");
                    setNewPassword("");
                  })
                  .catch((error) => {
                    setAdminActionError(error instanceof Error ? error.message : String(error));
                  });
              }}
            >
              Create user
            </button>
          </div>
          {adminActionError ? <p className="form-error" role="alert">{adminActionError}</p> : null}
          <ul aria-label="Users" className="session-card-list">
            {props.users.map((user) => (
              <li key={user.id}>
                <div className="session-card-shell">
                  <div className="session-card">
                    <span className="session-card-main">
                      <span className="session-card-title-row">
                        <span className="session-card-title">{user.displayName}</span>
                        {user.isAdmin ? <span className="session-chip session-chip-status">admin</span> : null}
                      </span>
                      <span className="session-card-path">{user.username}</span>
                    </span>
                  </div>
                  <button
                    className="session-card-menu-item"
                    type="button"
                    onClick={() => {
                      const nextPassword = window.prompt(`New password for ${user.username}`, "");
                      if (!nextPassword?.trim()) {
                        return;
                      }

                      setAdminActionError(null);
                      void props.onResetPassword(user.id, nextPassword.trim()).catch((error) => {
                        setAdminActionError(error instanceof Error ? error.message : String(error));
                      });
                    }}
                  >
                    Reset password
                  </button>
                  <button
                    className="session-card-menu-item"
                    type="button"
                    onClick={() => {
                      setAdminActionError(null);
                      void props.onDeleteUser(user.id).catch((error) => {
                        setAdminActionError(error instanceof Error ? error.message : String(error));
                      });
                    }}
                  >
                    Delete user
                  </button>
                </div>
              </li>
            ))}
          </ul>
        </section>
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
                      {props.onBrowseFiles ? (
                        <button
                          aria-label={`Browse files for ${title}`}
                          className="session-card-menu-item"
                          disabled={props.deletingSessionId === session.id}
                          type="button"
                          onClick={() => {
                            setMenuSessionId(null);
                            props.onBrowseFiles?.(session.id);
                          }}
                        >
                          Files
                        </button>
                      ) : null}
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
