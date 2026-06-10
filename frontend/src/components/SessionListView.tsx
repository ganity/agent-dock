import type { SessionSummary } from "../types";

export function SessionListView(props: {
  sessions: SessionSummary[];
  onCreate: () => void;
}) {
  return (
    <section className="panel stack">
      <div className="stack">
        <h1>Sessions</h1>
        <p className="muted">Foundation shell with placeholder sessions.</p>
      </div>
      <button className="button" type="button" onClick={props.onCreate}>
        New session
      </button>
      <ul>
        {props.sessions.map((session) => (
          <li key={session.id}>{session.agentKind}</li>
        ))}
      </ul>
    </section>
  );
}
