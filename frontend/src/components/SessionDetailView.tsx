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
  const latestStatusSummary = [...items].reverse().find((item) => item.kind === "status_summary");
  const latestStatus =
    latestStatusSummary?.kind === "status_summary"
      ? latestStatusSummary.statuses.at(-1) ?? props.session.status
      : props.session.status;

  return (
    <section className="session-detail session-detail-view stack">
      <header className="session-detail-topbar detail-topbar panel">
        <button className="button back-button" type="button" onClick={props.onBack}>
          Back
        </button>
        <div className="session-title detail-heading stack">
          <p className="eyebrow">Session</p>
          <h1>{props.session.agentKind}</h1>
          <p className="muted">Session details</p>
        </div>
      </header>

      <SessionSummaryCard
        workspacePath={props.session.workspacePath}
        sourceKind={props.session.sourceKind}
        runtimeSessionId={props.session.runtimeSessionId}
        status={latestStatus}
      />

      <section className="session-transcript detail-transcript stack">
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
