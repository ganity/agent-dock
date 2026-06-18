import { sessionAttachmentUrl } from "../api";
import { MarkdownContent } from "./MarkdownContent";

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

export function UserCard(props: { sessionId: string; text: string; imagePaths: string[] }) {
  const attachments = props.imagePaths
    .map((imagePath) => {
      const src = sessionAttachmentUrl(props.sessionId, imagePath);
      if (!src) {
        return null;
      }

      return {
        src,
        name: imagePath.split(/[/\\]/).pop() ?? "attachment",
      };
    })
    .filter((attachment): attachment is { src: string; name: string } => attachment !== null);

  return (
    <div className="user-message-row">
      <section className="user-bubble">
        {attachments.length > 0 ? (
          <div className="user-attachments">
            {attachments.map((attachment) => (
              <img
                key={attachment.src}
                className="user-attachment-image"
                src={attachment.src}
                alt={attachment.name}
              />
            ))}
          </div>
        ) : null}
        {props.text ? <p>{props.text}</p> : null}
      </section>
    </div>
  );
}

export function AssistantCard(props: { text: string }) {
  return (
    <article className="assistant-document">
      <MarkdownContent text={props.text} />
    </article>
  );
}

export function SessionErrorCard(props: { message: string; willRetry: boolean }) {
  return (
    <section className="activity-card panel stack" role="status">
      <div className="card-kicker">Runtime error</div>
      <p>{props.message}</p>
      {props.willRetry ? <p className="technical-text">Retrying</p> : null}
    </section>
  );
}

export function ActivitySummaryCard(props: {
  groups: Array<{ label: string; status: string; count: number }>;
}) {
  return (
    <details className="activity-disclosure">
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

export function FileChangeCard(props: {
  files: string[];
  summary: string;
  diffs?: string[];
  status?: string;
}) {
  return (
    <details className="activity-card activity-compact-card collapsible-output-card panel stack">
      <summary>
        <ActivityIcon status={props.status} icon="E" />
        <span className="activity-summary-text">{props.summary}</span>
        {props.status ? <span className="tool-status-pill">{props.status}</span> : null}
      </summary>
      {props.files.length > 0 ? (
        <div className="activity-detail-section">
          <p className="card-kicker">Files changed</p>
          <ul className="activity-list">
            {props.files.map((file) => (
              <li key={file}>
                <span>{file}</span>
              </li>
            ))}
          </ul>
        </div>
      ) : null}
      {props.diffs?.length ? (
        <div className="tool-output-list">
          {props.diffs.map((diff, index) => (
            <pre key={index} className="tool-output-block">{diff}</pre>
          ))}
        </div>
      ) : null}
    </details>
  );
}

export function ToolCallCard(props: {
  toolName: string;
  label: string;
  summary: string;
  output?: string;
  status?: string;
  command?: string;
  cwd?: string;
  exitCode?: number;
  durationMs?: number;
}) {
  return (
    <details className="activity-card activity-compact-card collapsible-output-card panel stack">
      <summary className="tool-call-header">
        <ActivityIcon status={props.status} icon="$" />
        <span className="activity-summary-main">
          <span className="activity-summary-text">{props.summary}</span>
          <span className="activity-summary-meta technical-text">{props.toolName}</span>
        </span>
        {props.status ? <span className="tool-status-pill">{props.status}</span> : null}
      </summary>
      <p className="tool-meta technical-text">command: {props.label}</p>
      {props.cwd ? <p className="tool-meta technical-text">cwd: {props.cwd}</p> : null}
      {props.output ? <pre className="tool-output-block">{props.output}</pre> : null}
      {props.exitCode !== undefined || props.durationMs !== undefined ? (
        <p className="tool-meta technical-text">
          {props.exitCode !== undefined ? `exit ${props.exitCode}` : ""}
          {props.exitCode !== undefined && props.durationMs !== undefined ? " · " : ""}
          {props.durationMs !== undefined ? `${props.durationMs}ms` : ""}
        </p>
      ) : null}
    </details>
  );
}

function ActivityIcon(props: { status?: string; icon: string }) {
  const status = props.status?.toLowerCase();
  const className = [
    "activity-icon",
    status === "completed" ? "activity-icon-completed" : "",
    status === "failed" || status === "error" ? "activity-icon-failed" : "",
  ].filter(Boolean).join(" ");

  return <span className={className} aria-hidden="true">{props.icon}</span>;
}

export function AttachedSessionCard(props: { runtimeSessionId: string }) {
  return (
    <section className="activity-card panel stack">
      <div className="card-kicker">Attached session</div>
      <p className="technical-text">Attached to an existing runtime.</p>
    </section>
  );
}
