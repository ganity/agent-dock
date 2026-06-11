import type { SessionEvent } from "./types";

export type TimelineItem =
  | { id: string; kind: "user"; text: string }
  | { id: string; kind: "thinking"; text: string; collapsed: true }
  | { id: string; kind: "assistant"; text: string }
  | { id: string; kind: "file_change"; files: string[] }
  | { id: string; kind: "attached"; runtimeSessionId: string }
  | { id: string; kind: "status_summary"; statuses: string[] }
  | {
      id: string;
      kind: "activity";
      groups: Array<{ label: string; status: "started" | "completed"; count: number }>;
    };

type PendingSegment =
  | { kind: "none" }
  | { kind: "activity"; firstEventId: number; groups: ActivityGroup[] }
  | { kind: "status"; firstEventId: number; statuses: string[] };

type ActivityGroup = {
  label: string;
  status: "started" | "completed";
  count: number;
};

export function projectTimelineEvents(events: SessionEvent[]): TimelineItem[] {
  const items: TimelineItem[] = [];
  let pending: PendingSegment = { kind: "none" };

  const flushPending = () => {
    if (pending.kind === "activity") {
      items.push({
        id: `activity:${pending.firstEventId}`,
        kind: "activity",
        groups: pending.groups,
      });
    }

    if (pending.kind === "status") {
      items.push({
        id: `status:${pending.firstEventId}`,
        kind: "status_summary",
        statuses: pending.statuses,
      });
    }

    pending = { kind: "none" };
  };

  for (const event of events) {
    if (event.eventType === "user.message") {
      flushPending();
      items.push({
        id: `user:${event.id}`,
        kind: "user",
        text: String(event.payload.text ?? ""),
      });
      continue;
    }

    if (event.eventType === "assistant.thinking.delta") {
      flushPending();
      const text = String(event.payload.text ?? "");
      const last = items.at(-1);
      if (last?.kind === "thinking") {
        last.text += text;
      } else {
        items.push({
          id: `thinking:${event.id}`,
          kind: "thinking",
          text,
          collapsed: true,
        });
      }
      continue;
    }

    if (event.eventType === "assistant.message") {
      flushPending();
      const text = String(event.payload.text ?? "");
      const last = items.at(-1);
      if (last?.kind === "assistant") {
        last.text += text;
      } else {
        items.push({
          id: `assistant:${event.id}`,
          kind: "assistant",
          text,
        });
      }
      continue;
    }

    if (event.eventType === "file.change.reported") {
      flushPending();
      const files = Array.isArray(event.payload.files)
        ? event.payload.files.map((value) => String(value))
        : [];
      items.push({
        id: `file:${event.id}`,
        kind: "file_change",
        files,
      });
      continue;
    }

    if (event.eventType === "session.attached") {
      flushPending();
      items.push({
        id: `attached:${event.id}`,
        kind: "attached",
        runtimeSessionId: String(event.payload.runtimeSessionId ?? ""),
      });
      continue;
    }

    if (event.eventType === "session.status.changed") {
      if (pending.kind !== "status") {
        flushPending();
        pending = { kind: "status", firstEventId: event.id, statuses: [] };
      }
      pending.statuses.push(readStatus(event.payload.status));
      continue;
    }

    if (event.eventType === "tool.call.started" || event.eventType === "tool.call.completed") {
      if (pending.kind !== "activity") {
        flushPending();
        pending = { kind: "activity", firstEventId: event.id, groups: [] };
      }
      const item = asObject(event.payload.item);
      const label = String(item.type ?? "tool");
      const status = event.eventType === "tool.call.started" ? "started" : "completed";
      const existing = pending.groups.find(
        (group) => group.label === label && group.status === status,
      );
      if (existing) {
        existing.count += 1;
      } else {
        pending.groups.push({ label, status, count: 1 });
      }
      continue;
    }

    flushPending();
  }

  flushPending();
  return items;
}

function asObject(value: unknown): Record<string, unknown> {
  return typeof value === "object" && value !== null ? (value as Record<string, unknown>) : {};
}

function readStatus(value: unknown): string {
  if (typeof value === "string") return value;

  if (typeof value === "object" && value !== null && "type" in value) {
    return String((value as Record<string, unknown>).type);
  }

  return String(value ?? "");
}
