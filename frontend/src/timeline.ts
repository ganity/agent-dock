import type { SessionEvent } from "./types";

export type TimelineItem =
  | { id: string; kind: "user"; text: string }
  | { id: string; kind: "thinking"; text: string }
  | { id: string; kind: "assistant"; text: string }
  | { id: string; kind: "file_change"; files: string[] }
  | { id: string; kind: "status"; status: string }
  | { id: string; kind: "tool"; label: string; status: "started" | "completed" };

export function projectTimelineEvents(events: SessionEvent[]): TimelineItem[] {
  const items: TimelineItem[] = [];

  for (const event of events) {
    if (event.eventType === "user.message") {
      items.push({
        id: `user:${event.id}`,
        kind: "user",
        text: String(event.payload.text ?? ""),
      });
      continue;
    }

    if (event.eventType === "assistant.thinking.delta") {
      const text = String(event.payload.text ?? "");
      const last = items.at(-1);
      if (last?.kind === "thinking") {
        last.text += text;
      } else {
        items.push({
          id: `thinking:${event.id}`,
          kind: "thinking",
          text,
        });
      }
      continue;
    }

    if (event.eventType === "assistant.message") {
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

    if (event.eventType === "session.status.changed") {
      items.push({
        id: `status:${event.id}`,
        kind: "status",
        status: readStatus(event.payload.status),
      });
      continue;
    }

    if (event.eventType === "tool.call.started" || event.eventType === "tool.call.completed") {
      const item = asObject(event.payload.item);
      const itemId = String(item.id ?? event.id);
      const label = String(item.type ?? "tool");
      const nextStatus = event.eventType === "tool.call.started" ? "started" : "completed";
      const last = items.at(-1);

      if (last?.kind === "tool" && last.id === `tool:${itemId}`) {
        last.status = nextStatus;
      } else {
        items.push({
          id: `tool:${itemId}`,
          kind: "tool",
          label,
          status: nextStatus,
        });
      }
    }
  }

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
