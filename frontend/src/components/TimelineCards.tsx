export function SessionSummaryCard(props: {
  workspacePath?: string;
  sourceKind?: string;
  runtimeSessionId?: string;
  status?: string;
}) {
  return (
    <section className="session-summary-card panel stack">
      <div className="session-summary-row">
        <div>
          <p className="eyebrow">Workspace</p>
          <p className="session-path">{props.workspacePath ?? "Session root unavailable"}</p>
        </div>
        {props.status ? <span className="status-pill">{props.status}</span> : null}
      </div>
      <div className="session-meta-chips">
        {props.sourceKind ? <span className="meta-chip">source: {props.sourceKind}</span> : null}
        {props.runtimeSessionId ? (
          <span className="meta-chip">runtime: {props.runtimeSessionId}</span>
        ) : null}
      </div>
    </section>
  );
}

export function ThinkingCard(props: { text: string }) {
  return (
    <details className="reasoning-card panel stack">
      <summary>Reasoning</summary>
      <pre>{props.text}</pre>
    </details>
  );
}

export function UserCard(props: { text: string }) {
  return (
    <section className="user-card panel stack">
      <div className="card-kicker">You</div>
      <p>{props.text}</p>
    </section>
  );
}

export function AssistantCard(props: { text: string }) {
  return (
    <article className="assistant-card panel stack">
      <div className="card-kicker">Assistant</div>
      <p className="assistant-copy">{props.text}</p>
    </article>
  );
}

export function ActivitySummaryCard(props: {
  groups: Array<{ label: string; status: string; count: number }>;
}) {
  return (
    <details className="activity-card panel stack">
      <summary>Activity</summary>
      <ul className="activity-list">
        {props.groups.map((group) => (
          <li key={`${group.label}-${group.status}`} className="activity-row">
            <span>{group.label}</span>
            <span>
              {group.status} × {group.count}
            </span>
          </li>
        ))}
      </ul>
    </details>
  );
}

export function StatusSummaryCard(props: { statuses: string[] }) {
  return (
    <details className="activity-card panel stack">
      <summary>Status</summary>
      <p>{props.statuses.join(" → ")}</p>
    </details>
  );
}

export function FileChangeCard(props: { files: string[] }) {
  return (
    <section className="activity-card panel stack">
      <div className="card-kicker">Files changed</div>
      <ul className="activity-list">
        {props.files.map((file) => (
          <li key={file}>
            <span>{file}</span>
          </li>
        ))}
      </ul>
    </section>
  );
}

export function AttachedSessionCard(props: { runtimeSessionId: string }) {
  return (
    <section className="activity-card panel stack">
      <div className="card-kicker">Attached session</div>
      <p className="technical-text">{props.runtimeSessionId}</p>
    </section>
  );
}
