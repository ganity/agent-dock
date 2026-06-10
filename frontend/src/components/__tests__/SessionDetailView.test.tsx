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
            { id: 1, eventType: "assistant.thinking.delta", payload: { text: "plan first" } },
            { id: 2, eventType: "assistant.message", payload: { text: "done" } },
            { id: 3, eventType: "file.change.reported", payload: { files: ["src/app.rs"] } },
          ],
        }}
        onBack={() => {}}
        onSend={() => {}}
      />,
    );

    expect(screen.getByText("Thinking")).toBeInTheDocument();
    expect(screen.getByText("done")).toBeInTheDocument();
    expect(screen.getByText("src/app.rs")).toBeInTheDocument();
  });
});
