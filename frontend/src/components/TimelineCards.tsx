export function ThinkingCard(props: { text: string }) {
  return (
    <details className="panel stack">
      <summary>Thinking</summary>
      <pre>{props.text}</pre>
    </details>
  );
}

export function UserCard(props: { text: string }) {
  return (
    <section className="panel stack">
      <strong>You</strong>
      <p>{props.text}</p>
    </section>
  );
}

export function MessageCard(props: { text: string }) {
  return (
    <section className="panel stack">
      <p>{props.text}</p>
    </section>
  );
}

export function FileChangeCard(props: { files: string[] }) {
  return (
    <section className="panel stack">
      <h3>Files changed</h3>
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
    <section className="panel stack">
      <strong>Attached session</strong>
      <p>{props.runtimeSessionId}</p>
    </section>
  );
}

export function StatusCard(props: { status: string }) {
  return (
    <section className="panel stack">
      <strong>Status</strong>
      <p>{props.status}</p>
    </section>
  );
}

export function ToolCard(props: { label: string; status: string }) {
  return (
    <section className="panel stack">
      <strong>Tool activity</strong>
      <p>{props.label}</p>
      <p>{props.status}</p>
    </section>
  );
}
