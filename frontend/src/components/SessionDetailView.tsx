import type { SessionDetail } from "../types";
import { projectTimelineEvents } from "../timeline";
import { Composer } from "./Composer";
import {
  ActivitySummaryCard,
  AssistantCard,
  AttachedSessionCard,
  FileChangeCard,
  SessionSummaryCard,
  StatusSummaryCard,
  ThinkingCard,
  UserCard,
} from "./TimelineCards";

export function SessionDetailView(props: {
  session: SessionDetail;
  onBack: () => void;
  onSend: (message: string) => void;
}) {
  const items = projectTimelineEvents(props.session.events ?? []);

  return (
    <section className="session-detail-view">
      <header className="detail-topbar">
        <button className="button" type="button" onClick={props.onBack}>
          Back
        </button>
        <div className="detail-heading">
          <p className="eyebrow">Session</p>
          <h1>{props.session.agentKind}</h1>
        </div>
      </header>

      <SessionSummaryCard
        workspacePath={props.session.workspacePath}
        sourceKind={props.session.sourceKind}
        runtimeSessionId={props.session.runtimeSessionId}
        status={props.session.status}
      />

      <section className="detail-transcript">
        {items.map((item) => {
          if (item.kind === "user") {
            return <UserCard key={item.id} text={item.text} />;
          }
          if (item.kind === "thinking") {
            return <ThinkingCard key={item.id} text={item.text} />;
          }
          if (item.kind === "assistant") {
            return <AssistantCard key={item.id} text={item.text} />;
          }
          if (item.kind === "file_change") {
            return <FileChangeCard key={item.id} files={item.files} />;
          }
          if (item.kind === "attached") {
            return <AttachedSessionCard key={item.id} runtimeSessionId={item.runtimeSessionId} />;
          }
          if (item.kind === "activity") {
            return <ActivitySummaryCard key={item.id} groups={item.groups} />;
          }
          if (item.kind === "status_summary") {
            return <StatusSummaryCard key={item.id} statuses={item.statuses} />;
          }
          return null;
        })}
      </section>

      <Composer onSend={props.onSend} />
    </section>
  );
}
