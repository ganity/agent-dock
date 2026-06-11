import { describe, expect, it } from "vitest";

import { projectTimelineEvents } from "./timeline";
import type { SessionEvent } from "./types";

describe("projectTimelineEvents", () => {
  it("coalesces adjacent assistant message deltas into one item", () => {
    const events: SessionEvent[] = [
      { id: 1, eventType: "assistant.message", payload: { text: "Checking" } },
      { id: 2, eventType: "assistant.message", payload: { text: " the" } },
      { id: 3, eventType: "assistant.message", payload: { text: " plan." } },
    ];

    expect(projectTimelineEvents(events)).toEqual([
      { id: "assistant:1", kind: "assistant", text: "Checking the plan." },
    ]);
  });

  it("coalesces adjacent thinking deltas into one collapsed reasoning item", () => {
    const events: SessionEvent[] = [
      { id: 1, eventType: "assistant.thinking.delta", payload: { text: "Look" } },
      { id: 2, eventType: "assistant.thinking.delta", payload: { text: " deeper" } },
    ];

    expect(projectTimelineEvents(events)).toEqual([
      { id: "thinking:1", kind: "thinking", text: "Look deeper", collapsed: true },
    ]);
  });

  it("groups repeated tool completions into one activity summary item", () => {
    const events: SessionEvent[] = [
      {
        id: 1,
        eventType: "tool.call.completed",
        payload: { item: { id: "tool-1", type: "commandExecution" } },
      },
      {
        id: 2,
        eventType: "tool.call.completed",
        payload: { item: { id: "tool-2", type: "commandExecution" } },
      },
      {
        id: 3,
        eventType: "tool.call.completed",
        payload: { item: { id: "tool-3", type: "reasoning" } },
      },
    ];

    expect(projectTimelineEvents(events)).toEqual([
      {
        id: "activity:1",
        kind: "activity",
        groups: [
          { label: "commandExecution", status: "completed", count: 2 },
          { label: "reasoning", status: "completed", count: 1 },
        ],
      },
    ]);
  });

  it("collapses status churn into one status summary item", () => {
    const events: SessionEvent[] = [
      { id: 1, eventType: "session.status.changed", payload: { status: "running" } },
      { id: 2, eventType: "session.status.changed", payload: { status: "active" } },
      { id: 3, eventType: "session.status.changed", payload: { status: "idle" } },
    ];

    expect(projectTimelineEvents(events)).toEqual([
      { id: "status:1", kind: "status_summary", statuses: ["running", "active", "idle"] },
    ]);
  });

  it("flushes activity summaries before later assistant messages", () => {
    const events: SessionEvent[] = [
      { id: 1, eventType: "user.message", payload: { text: "hello" } },
      {
        id: 2,
        eventType: "tool.call.completed",
        payload: { item: { id: "tool-1", type: "commandExecution" } },
      },
      { id: 3, eventType: "assistant.message", payload: { text: "done" } },
    ];

    expect(projectTimelineEvents(events)).toEqual([
      { id: "user:1", kind: "user", text: "hello" },
      {
        id: "activity:2",
        kind: "activity",
        groups: [{ label: "commandExecution", status: "completed", count: 1 }],
      },
      { id: "assistant:3", kind: "assistant", text: "done" },
    ]);
  });

  it("preserves order across status and activity segments", () => {
    const events: SessionEvent[] = [
      { id: 1, eventType: "session.status.changed", payload: { status: "running" } },
      {
        id: 2,
        eventType: "tool.call.completed",
        payload: { item: { id: "tool-1", type: "commandExecution" } },
      },
      { id: 3, eventType: "session.status.changed", payload: { status: "idle" } },
    ];

    expect(projectTimelineEvents(events)).toEqual([
      { id: "status:1", kind: "status_summary", statuses: ["running"] },
      {
        id: "activity:2",
        kind: "activity",
        groups: [{ label: "commandExecution", status: "completed", count: 1 }],
      },
      { id: "status:3", kind: "status_summary", statuses: ["idle"] },
    ]);
  });
});
