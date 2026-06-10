import type { SessionSummary } from "../types";

export function SessionListView(props: {
  sessions: SessionSummary[];
  onCreate: () => void;
  onAttach: () => void;
  onSelect: (sessionId: string) => void;
}) {
  return (
    <section className="panel stack">
      <div className="stack">
        <h1>Sessions</h1>
        <p className="muted">Structured managed sessions backed by the local daemon.</p>
      </div>
      <div className="stack">
        <button className="button" type="button" onClick={props.onCreate}>
          New session
        </button>
        <button className="button" type="button" onClick={props.onAttach}>
          Attach session
        </button>
      </div>
      <ul>
        {props.sessions.map((session) => (
          <li key={session.id} className="panel stack">
            <strong>{session.agentKind}</strong>
            {session.status ? <p>{session.status}</p> : null}
            {session.workspacePath ? <p>{session.workspacePath}</p> : null}
            <button className="button" type="button" onClick={() => props.onSelect(session.id)}>
              {`Open ${session.agentKind}`}
            </button>
          </li>
        ))}
      </ul>
    </section>
  );
}
