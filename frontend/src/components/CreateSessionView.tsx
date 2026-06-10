import { useState } from "react";

import type { CreateSessionInput, WorkspaceRoot } from "../types";

export function CreateSessionView(props: {
  roots: WorkspaceRoot[];
  onSubmit: (input: CreateSessionInput) => void;
}) {
  const [rootId, setRootId] = useState(props.roots[0]?.id ?? "");
  const [path, setPath] = useState("repo");
  const [agentKind, setAgentKind] = useState("codex");

  return (
    <form
      className="panel stack"
      onSubmit={(event) => {
        event.preventDefault();
        props.onSubmit({
          rootId,
          path,
          agentKind,
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
      <label className="field">
        <span>Path</span>
        <input
          aria-label="Path"
          className="input"
          value={path}
          onChange={(event) => setPath(event.target.value)}
        />
      </label>
      <button className="button" type="submit">
        Create session
      </button>
    </form>
  );
}
