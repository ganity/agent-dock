import { useEffect, useState } from "react";

import type { CreateSessionInput, WorkspaceDirectoryListing, WorkspaceRoot } from "../types";
import { PathPicker } from "./PathPicker";
import { SessionModal } from "./SessionModal";

export function CreateSessionView(props: {
  roots: WorkspaceRoot[];
  error: string | null;
  loadDirectories: (path: string) => Promise<WorkspaceDirectoryListing>;
  onCancel: () => void;
  onSubmit: (input: CreateSessionInput) => void;
}) {
  const titleErrorId = "create-session-title-error";
  const pathErrorId = "create-session-path-error";
  const [title, setTitle] = useState("");
  const [rootId, setRootId] = useState(props.roots[0]?.id ?? "");
  const [path, setPath] = useState(props.roots[0]?.path ?? "");
  const [agentKind, setAgentKind] = useState("codex");
  const [didSubmit, setDidSubmit] = useState(false);
  const [titleTouched, setTitleTouched] = useState(false);
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
  const trimmedTitle = title.trim();
  const trimmedPath = path.trim();
  const titleError = trimmedTitle === "" ? "Session name is required." : null;
  const pathError = trimmedPath === "" ? "Path is required." : null;
  const showTitleError = titleError !== null && (titleTouched || didSubmit);
  const showPathError = pathError !== null && (pathTouched || didSubmit);
  const canSubmit = trimmedTitle !== "" && trimmedPath !== "" && selectedRoot !== null;

  return (
    <SessionModal
      description="Create a new managed session in a workspace root."
      onClose={props.onCancel}
      title="New session"
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
            title: trimmedTitle,
            rootId: selectedRoot.id,
            path: trimmedPath,
            agentKind,
          });
        }}
      >
        <label className="field">
          <span>Session name</span>
          <input
            aria-label="Session name"
            aria-describedby={showTitleError ? titleErrorId : undefined}
            aria-invalid={titleTouched || didSubmit ? (titleError ? "true" : "false") : undefined}
            className="input"
            value={title}
            onBlur={() => setTitleTouched(true)}
            onChange={(event) => {
              setTitleTouched(true);
              setTitle(event.target.value);
            }}
          />
        </label>
        {showTitleError ? (
          <p className="field-error" id={titleErrorId} role="alert">
            {titleError}
          </p>
        ) : null}
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
        {selectedRoot ? <p className="modal-root-hint">Creates in {selectedRoot.path}</p> : null}
        {props.error ? <p className="form-error" role="alert">{props.error}</p> : null}
        <footer className="session-modal-actions">
          <button className="button button-quiet" onClick={props.onCancel} type="button">
            Cancel
          </button>
          <button className="button" disabled={!canSubmit} type="submit">
            Create session
          </button>
        </footer>
      </form>
    </SessionModal>
  );
}
