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
  const latestStatus =
    findLatestNonEmptyStatus(items) ?? normalizeStatus(props.session.status) ?? props.session.status;

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
            const statuses = item.statuses.map(normalizeStatus).filter(isDefinedStatus);
            if (statuses.length === 0) {
              return null;
            }
            return <StatusSummaryCard key={item.id} statuses={statuses} />;
          }
          return null;
        })}
      </section>

      <Composer onSend={props.onSend} />
    </section>
  );
}

function normalizeStatus(status?: string): string | undefined {
  const value = status?.trim();
  return value ? value : undefined;
}

function isDefinedStatus(status: string | undefined): status is string {
  return status !== undefined;
}

function findLatestNonEmptyStatus(items: ReturnType<typeof projectTimelineEvents>): string | undefined {
  for (let itemIndex = items.length - 1; itemIndex >= 0; itemIndex -= 1) {
    const item = items[itemIndex];
    if (item.kind !== "status_summary") {
      continue;
    }

    for (let statusIndex = item.statuses.length - 1; statusIndex >= 0; statusIndex -= 1) {
      const status = normalizeStatus(item.statuses[statusIndex]);
      if (status) {
        return status;
      }
    }
  }

  return undefined;
}
