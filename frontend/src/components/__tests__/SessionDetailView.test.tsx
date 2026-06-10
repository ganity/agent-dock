import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { SessionDetailView } from "../SessionDetailView";

describe("SessionDetailView", () => {
  it("renders thinking, message, and file-change cards", () => {
    render(
      <SessionDetailView
        session={{
          id: "sess-1",
          agentKind: "claude",
          events: [
            { id: 0, eventType: "user.message", payload: { text: "hello" } },
            { id: 1, eventType: "assistant.thinking.delta", payload: { text: "plan first" } },
            { id: 2, eventType: "assistant.message", payload: { text: "done" } },
            { id: 3, eventType: "file.change.reported", payload: { files: ["src/app.rs"] } },
            { id: 4, eventType: "session.status.changed", payload: { status: "running" } },
          ],
        }}
        onBack={() => {}}
        onSend={() => {}}
      />,
    );

    expect(screen.getByText("hello")).toBeInTheDocument();
    expect(screen.getByText("Thinking")).toBeInTheDocument();
    expect(screen.getByText("done")).toBeInTheDocument();
    expect(screen.getByText("src/app.rs")).toBeInTheDocument();
    expect(screen.getByText("running")).toBeInTheDocument();
  });
});
