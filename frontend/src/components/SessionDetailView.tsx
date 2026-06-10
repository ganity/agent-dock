import type { SessionDetail } from "../types";
import { projectTimelineEvents } from "../timeline";
import { Composer } from "./Composer";
import {
  AttachedSessionCard,
  FileChangeCard,
  MessageCard,
  StatusCard,
  ThinkingCard,
  ToolCard,
  UserCard,
} from "./TimelineCards";

export function SessionDetailView(props: {
  session: SessionDetail;
  onBack: () => void;
  onSend: (message: string) => void;
}) {
  const items = projectTimelineEvents(props.session.events ?? []);

  return (
    <section className="stack">
      <section className="panel stack">
        <button className="button" type="button" onClick={props.onBack}>
          Back
        </button>
        <h1>{props.session.agentKind}</h1>
        <p className="muted">Session details</p>
        {props.session.sourceKind ? <p>{props.session.sourceKind}</p> : null}
        {props.session.runtimeSessionId ? <p>{props.session.runtimeSessionId}</p> : null}
      </section>
      {items.map((item) => {
        if (item.kind === "user") {
          return <UserCard key={item.id} text={item.text} />;
        }
        if (item.kind === "thinking") {
          return <ThinkingCard key={item.id} text={item.text} />;
        }
        if (item.kind === "assistant") {
          return <MessageCard key={item.id} text={item.text} />;
        }
        if (item.kind === "file_change") {
          return <FileChangeCard key={item.id} files={item.files} />;
        }
        if (item.kind === "attached") {
          return <AttachedSessionCard key={item.id} runtimeSessionId={item.runtimeSessionId} />;
        }
        if (item.kind === "tool") {
          return <ToolCard key={item.id} label={item.label} status={item.status} />;
        }
        if (item.kind === "status") {
          return <StatusCard key={item.id} status={item.status} />;
        }
        return null;
      })}
      <Composer onSend={props.onSend} />
    </section>
  );
}
