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

    const items = projectTimelineEvents(events);

    expect(items).toEqual([
      {
        id: "assistant:1",
        kind: "assistant",
        text: "Checking the plan.",
      },
    ]);
  });

  it("coalesces adjacent thinking deltas into one item", () => {
    const events: SessionEvent[] = [
      { id: 1, eventType: "assistant.thinking.delta", payload: { text: "Look" } },
      { id: 2, eventType: "assistant.thinking.delta", payload: { text: " deeper" } },
    ];

    const items = projectTimelineEvents(events);

    expect(items).toEqual([
      {
        id: "thinking:1",
        kind: "thinking",
        text: "Look deeper",
      },
    ]);
  });

  it("merges tool start and completion for the same item into one card", () => {
    const events: SessionEvent[] = [
      {
        id: 1,
        eventType: "tool.call.started",
        payload: { item: { id: "item-1", type: "reasoning" } },
      },
      {
        id: 2,
        eventType: "tool.call.completed",
        payload: { item: { id: "item-1", type: "reasoning" } },
      },
    ];

    const items = projectTimelineEvents(events);

    expect(items).toEqual([
      {
        id: "tool:item-1",
        kind: "tool",
        label: "reasoning",
        status: "completed",
      },
    ]);
  });

  it("preserves order across mixed item kinds", () => {
    const events: SessionEvent[] = [
      { id: 1, eventType: "user.message", payload: { text: "hello" } },
      { id: 2, eventType: "assistant.message", payload: { text: "done" } },
      { id: 3, eventType: "session.status.changed", payload: { status: "running" } },
    ];

    const items = projectTimelineEvents(events);

    expect(items).toEqual([
      { id: "user:1", kind: "user", text: "hello" },
      { id: "assistant:2", kind: "assistant", text: "done" },
      { id: "status:3", kind: "status", status: "running" },
    ]);
  });
});
