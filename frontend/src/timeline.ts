import type { SessionEvent } from "./types";

export type TimelineItem =
  | { id: string; kind: "user"; text: string; imagePaths: string[] }
  | { id: string; kind: "thinking"; text: string; collapsed: true }
  | { id: string; kind: "assistant"; text: string }
  | { id: string; kind: "session_error"; message: string; willRetry: boolean }
  | { id: string; kind: "file_change"; files: string[]; summary: string; diffs?: string[]; status?: string }
  | {
      id: string;
      kind: "tool_call";
      toolName: string;
      label: string;
      summary: string;
      output?: string;
      status?: string;
      command?: string;
      cwd?: string;
      exitCode?: number;
      durationMs?: number;
    }
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
  const lifecycleItemIndexes = new Map<string, number>();
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
        imagePaths: Array.isArray(event.payload.imagePaths)
          ? event.payload.imagePaths.map((value) => String(value))
          : [],
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
      if (isInternalAssistantText(text)) {
        continue;
      }
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

    if (event.eventType === "session.error") {
      flushPending();
      items.push({
        id: `error:${event.id}`,
        kind: "session_error",
        message: String(event.payload.message ?? ""),
        willRetry: Boolean(event.payload.willRetry),
      });
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
        summary: fileChangeSummary(files),
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
      pending.statuses.push(readStatusFromPayload(event.payload));
      continue;
    }

    if (event.eventType === "tool.call.started" || event.eventType === "tool.call.completed") {
      const detailedItem = projectDetailedToolEvent(event);
      if (detailedItem) {
        flushPending();
        const lifecycleKey = detailedToolLifecycleKey(event);
        if (lifecycleKey) {
          const existingIndex = lifecycleItemIndexes.get(lifecycleKey);
          if (existingIndex !== undefined) {
            items[existingIndex] = mergeLifecycleItems(items[existingIndex], detailedItem);
          } else {
            lifecycleItemIndexes.set(lifecycleKey, items.length);
            items.push(detailedItem);
          }
        } else {
          items.push(detailedItem);
        }
        continue;
      }

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

function projectDetailedToolEvent(event: SessionEvent): TimelineItem | null {
  const item = asObject(event.payload.item);
  const itemType = String(item.type ?? "");
  const fallbackStatus = event.eventType === "tool.call.started" ? "started" : "completed";
  const itemId = readString(item.id) ?? String(event.id);

  if (itemType === "commandExecution" && hasCommandDetails(item)) {
    const label = commandExecutionLabel(item);
    return {
      id: `tool:${itemId}`,
      kind: "tool_call",
      toolName: "shell",
      label,
      summary: commandExecutionSummary(label),
      ...optionalString("output", displayToolOutput(readString(item.aggregatedOutput))),
      ...optionalString("status", readString(item.status) ?? fallbackStatus),
      ...optionalString("command", readString(item.command)),
      ...optionalString("cwd", readString(item.cwd)),
      ...optionalNumber("exitCode", item.exitCode),
      ...optionalNumber("durationMs", item.durationMs),
    };
  }

  if (itemType === "fileChange" && Array.isArray(item.changes)) {
    const changes = item.changes.map(asObject);
    const files = changes
      .map((change) => readString(change.path))
      .filter((path): path is string => path !== null);
    const diffs = changes.flatMap((change) => {
      const diff = trimEnd(readString(change.diff));
      return diff ? [diff] : [];
    });

    if (files.length === 0 && diffs.length === 0) {
      return null;
    }

    return {
      id: `file:${itemId}`,
      kind: "file_change",
      files,
      summary: fileChangeSummary(files),
      ...(diffs.length > 0 ? { diffs } : {}),
      ...optionalString("status", readString(item.status) ?? fallbackStatus),
    };
  }

  return null;
}

function detailedToolLifecycleKey(event: SessionEvent): string | null {
  const item = asObject(event.payload.item);
  const itemType = readString(item.type);
  const itemId = readString(item.id);
  return itemType && itemId ? `${itemType}:${itemId}` : null;
}

function mergeLifecycleItems(existing: TimelineItem, next: TimelineItem): TimelineItem {
  if (existing.kind !== next.kind) {
    return next;
  }

  if (existing.kind === "tool_call" && next.kind === "tool_call") {
    return { ...existing, ...next };
  }

  if (existing.kind === "file_change" && next.kind === "file_change") {
    const files = next.files.length > 0 ? next.files : existing.files;
    return {
      ...existing,
      ...next,
      files,
      summary: fileChangeSummary(files),
      diffs: next.diffs ?? existing.diffs,
    };
  }

  return next;
}

function hasCommandDetails(item: Record<string, unknown>): boolean {
  return (
    readString(item.command) !== null ||
    readString(item.cwd) !== null ||
    readString(item.aggregatedOutput) !== null ||
    typeof item.exitCode === "number" ||
    typeof item.durationMs === "number" ||
    Array.isArray(item.commandActions)
  );
}

function commandExecutionLabel(item: Record<string, unknown>): string {
  const actions = Array.isArray(item.commandActions) ? item.commandActions : [];
  const commands = actions
    .map(asObject)
    .map((action) => readString(action.command))
    .filter((command): command is string => command !== null);

  return commands.length > 0 ? commands.join(" && ") : compactShellCommand(readString(item.command)) ?? "shell";
}

function compactShellCommand(command: string | null): string | null {
  const value = command?.trim();
  if (!value) {
    return null;
  }

  const shellMatch = value.match(/^(?:\/\S+\/)?(?:ba|z|fi)?sh\s+-lc\s+(.+)$/);
  if (!shellMatch) {
    return value;
  }

  return stripWrappingQuotes(shellMatch[1].trim()) || value;
}

function stripWrappingQuotes(value: string): string {
  if (value.length < 2) {
    return value;
  }

  const first = value.at(0);
  const last = value.at(-1);
  if ((first === "'" && last === "'") || (first === '"' && last === '"')) {
    return value.slice(1, -1);
  }

  return value;
}

function commandExecutionSummary(label: string): string {
  const normalized = label.trim();
  if (!normalized || normalized === "shell") {
    return "Ran shell command";
  }

  if (normalized === "apply_patch") {
    return "Applied patch";
  }

  if (/diagnostics?/i.test(normalized)) {
    return "Checked diagnostics";
  }

  return `Ran ${normalized}`;
}

function fileChangeSummary(files: string[]): string {
  if (files.length === 0) {
    return "Edited files";
  }

  if (files.length === 1) {
    return `Edited ${files[0]}`;
  }

  return `Edited ${files.length} files`;
}

function displayToolOutput(output: string | null): string | undefined {
  const trimmed = trimEnd(output);
  if (!trimmed) {
    return undefined;
  }

  return extractUnifiedDiff(trimmed) ?? trimmed;
}

function extractUnifiedDiff(text: string): string | undefined {
  const lines = text.split("\n");
  const startIndex = lines.findIndex(
    (line) => line.startsWith("diff --git ") || line.startsWith("--- ") || line.startsWith("@@"),
  );

  if (startIndex === -1) {
    return undefined;
  }

  let endIndex = lines.length;
  for (let index = startIndex + 1; index < lines.length; index += 1) {
    const line = lines[index];
    const isDiffLine =
      line.startsWith("diff --git ") ||
      line.startsWith("index ") ||
      line.startsWith("--- ") ||
      line.startsWith("+++ ") ||
      line.startsWith("@@") ||
      line.startsWith("+") ||
      line.startsWith("-") ||
      line.startsWith(" ");

    if (!isDiffLine && line.trim() !== "") {
      endIndex = index;
      break;
    }
  }

  return trimEnd(lines.slice(startIndex, endIndex).join("\n"));
}

function isInternalAssistantText(text: string): boolean {
  const trimmed = text.trim();
  return (
    trimmed.startsWith("You are Codex, a coding agent") ||
    trimmed.startsWith("You are Claude Code") ||
    trimmed.startsWith("<environment_context>") ||
    trimmed.startsWith("<system-reminder>") ||
    trimmed.startsWith("# AGENTS.md") ||
    trimmed.startsWith("<INSTRUCTIONS>") ||
    trimmed.startsWith("<claude-mem-context>")
  );
}

function readString(value: unknown): string | null {
  return typeof value === "string" ? value : null;
}

function readStatusFromPayload(payload: Record<string, unknown>): string {
  const turn = asObject(payload.turn);
  const error = asObject(turn.error);
  const errorMessage = readString(error.message)?.trim();
  if (errorMessage) {
    return errorMessage;
  }

  const status = asObject(payload.status);
  const statusMessage = readString(status.message)?.trim();
  if (statusMessage) {
    return statusMessage;
  }

  return readStatus(payload.status);
}

function trimEnd(value: string | null): string | undefined {
  return value?.trimEnd();
}

function optionalString<K extends string>(key: K, value: string | null | undefined): Record<K, string> | {} {
  return value ? { [key]: value } as Record<K, string> : {};
}

function optionalNumber<K extends string>(key: K, value: unknown): Record<K, number> | {} {
  return typeof value === "number" ? { [key]: value } as Record<K, number> : {};
}

function readStatus(value: unknown): string {
  if (typeof value === "string") return value;

  if (typeof value === "object" && value !== null && "type" in value) {
    return String((value as Record<string, unknown>).type);
  }

  return String(value ?? "");
}
