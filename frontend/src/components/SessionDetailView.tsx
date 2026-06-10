import type { SessionDetail } from "../types";
import { Composer } from "./Composer";
import { FileChangeCard, MessageCard, StatusCard, ThinkingCard, UserCard } from "./TimelineCards";

export function SessionDetailView(props: {
  session: SessionDetail;
  onBack: () => void;
  onSend: (message: string) => void;
}) {
  const events = props.session.events ?? [];

  return (
    <section className="stack">
      <section className="panel stack">
        <button className="button" type="button" onClick={props.onBack}>
          Back
        </button>
        <h1>{props.session.agentKind}</h1>
        <p className="muted">Session details</p>
      </section>
      {events.map((event) => {
        if (event.eventType === "user.message") {
          return <UserCard key={event.id} text={String(event.payload.text ?? "")} />;
        }
        if (event.eventType === "assistant.thinking.delta") {
          return <ThinkingCard key={event.id} text={String(event.payload.text ?? "")} />;
        }
        if (event.eventType === "assistant.message") {
          return <MessageCard key={event.id} text={String(event.payload.text ?? "")} />;
        }
        if (event.eventType === "file.change.reported") {
          const files = Array.isArray(event.payload.files)
            ? event.payload.files.map((value) => String(value))
            : [];
          return <FileChangeCard key={event.id} files={files} />;
        }
        if (event.eventType === "session.status.changed") {
          return <StatusCard key={event.id} status={String(event.payload.status ?? "")} />;
        }
        return null;
      })}
      <Composer onSend={props.onSend} />
    </section>
  );
}
