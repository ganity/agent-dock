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
    <section className="activity-card panel stack">
      <div className="card-kicker">Activity</div>
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
    </section>
  );
}

export function StatusSummaryCard(props: { statuses: string[] }) {
  return (
    <section className="status-summary-card panel stack">
      <div className="card-kicker">Status</div>
      <p>{props.statuses.join(" → ")}</p>
    </section>
  );
}

export function FileChangeCard(props: { files: string[] }) {
  return (
    <section className="file-change-card panel stack">
      <div className="card-kicker">Files changed</div>
      <ul>
        {props.files.map((file) => (
          <li key={file}>{file}</li>
        ))}
      </ul>
    </section>
  );
}

export function AttachedSessionCard(props: { runtimeSessionId: string }) {
  return (
    <section className="attached-card panel stack">
      <div className="card-kicker">Attached session</div>
      <p>{props.runtimeSessionId}</p>
    </section>
  );
}
