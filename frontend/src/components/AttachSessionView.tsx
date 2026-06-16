import { useEffect, useState } from "react";

import type {
  AttachSessionInput,
  SessionSummary,
  WorkspaceDirectoryListing,
  WorkspaceRoot,
} from "../types";
import { getSessionTitle } from "../sessionDisplay";
import { PathPicker } from "./PathPicker";
import { SessionModal } from "./SessionModal";

export function AttachSessionView(props: {
  roots: WorkspaceRoot[];
  error: string | null;
  loadDirectories: (path: string) => Promise<WorkspaceDirectoryListing>;
  sessionCandidates?: SessionSummary[];
  onCancel: () => void;
  onSubmit: (input: AttachSessionInput) => void;
}) {
  const runtimeSessionIdErrorId = "attach-session-runtime-session-id-error";
  const pathErrorId = "attach-session-path-error";
  const [rootId, setRootId] = useState(props.roots[0]?.id ?? "");
  const [path, setPath] = useState(props.roots[0]?.path ?? "");
  const [agentKind, setAgentKind] = useState("codex");
  const [runtimeSessionId, setRuntimeSessionId] = useState("");
  const [didSubmit, setDidSubmit] = useState(false);
  const [runtimeSessionIdTouched, setRuntimeSessionIdTouched] = useState(false);
  const [pathTouched, setPathTouched] = useState(false);

  useEffect(() => {
    if (props.roots.length === 0) {
      if (rootId !== "") {
        setRootId("");
      }
      return;
    }

    const hasSelectedRoot = props.roots.some((root) => root.id === rootId);
    if (!hasSelectedRoot) {
      setRootId(props.roots[0].id);
    }
  }, [props.roots, rootId]);

  useEffect(() => {
    const nextRoot = props.roots.find((root) => root.id === rootId) ?? props.roots[0];
    if (!nextRoot) {
      return;
    }

    if (path === "") {
      setPath(nextRoot.path);
    }
  }, [path, props.roots, rootId]);

  const selectedRoot = props.roots.find((root) => root.id === rootId) ?? null;
  const trimmedPath = path.trim();
  const trimmedRuntimeSessionId = runtimeSessionId.trim();
  const runtimeSessionIdError =
    trimmedRuntimeSessionId === "" ? "Runtime session ID is required." : null;
  const pathError = trimmedPath === "" ? "Path is required." : null;
  const showRuntimeSessionIdError =
    runtimeSessionIdError !== null && (runtimeSessionIdTouched || didSubmit);
  const showPathError = pathError !== null && (pathTouched || didSubmit);
  const canSubmit = trimmedPath !== "" && trimmedRuntimeSessionId !== "" && selectedRoot !== null;

  return (
    <SessionModal
      description="Attach an existing runtime session to a workspace root."
      onClose={props.onCancel}
      title="Attach session"
    >
      <form
        className="stack"
        onSubmit={(event) => {
          event.preventDefault();
          setDidSubmit(true);
          if (!canSubmit || !selectedRoot) {
            return;
          }

          props.onSubmit({
            rootId: selectedRoot.id,
            path: trimmedPath,
            agentKind,
            runtimeSessionId: trimmedRuntimeSessionId,
          });
        }}
      >
        <label className="field">
          <span>Agent</span>
          <select
            aria-label="Agent"
            className="input"
            value={agentKind}
            onChange={(event) => setAgentKind(event.target.value)}
          >
            <option value="codex">codex</option>
            <option value="claude">claude</option>
          </select>
        </label>
        {props.roots.length > 1 ? (
          <label className="field">
            <span>Workspace</span>
            <select
              aria-label="Workspace"
              className="input"
              value={rootId}
              onChange={(event) => setRootId(event.target.value)}
            >
              {props.roots.map((root) => (
                <option key={root.id} value={root.id}>
                  {root.label}
                </option>
              ))}
            </select>
          </label>
        ) : null}
        {props.sessionCandidates?.length ? (
          <section className="attach-candidate-list">
            <p className="modal-root-hint">Recent sessions</p>
            <div className="path-picker-list">
              {props.sessionCandidates
                .filter((session) => session.runtimeSessionId)
                .map((session) => {
                  const title = getSessionTitle(session);
                  return (
                    <button
                      key={session.id}
                      className="button button-quiet"
                      type="button"
                      onClick={() => {
                        setAgentKind(session.agentKind);
                        setRuntimeSessionId(session.runtimeSessionId ?? "");
                        setRuntimeSessionIdTouched(true);
                        setPath(session.workspacePath ?? "");
                        setPathTouched(true);
                      }}
                    >
                      {`Use ${title}`}
                    </button>
                  );
                })}
            </div>
          </section>
        ) : null}
        <label className="field">
          <span>Runtime session ID</span>
          <input
            aria-label="Runtime session ID"
            aria-describedby={showRuntimeSessionIdError ? runtimeSessionIdErrorId : undefined}
            aria-invalid={
              runtimeSessionIdTouched || didSubmit ? (runtimeSessionIdError ? "true" : "false") : undefined
            }
            className="input"
            value={runtimeSessionId}
            onBlur={() => setRuntimeSessionIdTouched(true)}
            onChange={(event) => {
              setRuntimeSessionIdTouched(true);
              setRuntimeSessionId(event.target.value);
            }}
          />
        </label>
        {showRuntimeSessionIdError ? (
          <p className="field-error" id={runtimeSessionIdErrorId} role="alert">
            {runtimeSessionIdError}
          </p>
        ) : null}
        <PathPicker
          errorId={showPathError ? pathErrorId : undefined}
          invalid={pathTouched || didSubmit ? Boolean(pathError) : false}
          loadDirectories={props.loadDirectories}
          path={path}
          rootPath={selectedRoot?.path}
          onBlur={() => setPathTouched(true)}
          onChange={(nextPath) => {
            setPathTouched(true);
            setPath(nextPath);
          }}
        />
        {showPathError ? (
          <p className="field-error" id={pathErrorId} role="alert">
            {pathError}
          </p>
        ) : null}
        {props.error ? <p className="form-error" role="alert">{props.error}</p> : null}
        <footer className="session-modal-actions">
          <button className="button button-quiet" onClick={props.onCancel} type="button">
            Cancel
          </button>
          <button className="button" disabled={!canSubmit} type="submit">
            Attach session
          </button>
        </footer>
      </form>
    </SessionModal>
  );
}
