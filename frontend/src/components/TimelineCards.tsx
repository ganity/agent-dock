export function ThinkingCard(props: { text: string }) {
  return (
    <details className="panel stack">
      <summary>Thinking</summary>
      <pre>{props.text}</pre>
    </details>
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
