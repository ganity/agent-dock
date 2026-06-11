import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

import { SessionDetailView } from "../SessionDetailView";

describe("SessionDetailView", () => {
  it("renders a mobile-reader transcript with grouped activity and collapsed reasoning", () => {
    const onSend = vi.fn();

    render(
      <SessionDetailView
        session={{
          id: "sess-1",
          agentKind: "codex",
          sourceKind: "managed",
          runtimeSessionId: "thread-abc-123",
          workspacePath: "/tmp/workspace",
          status: "created",
          events: [
            { id: 1, eventType: "user.message", payload: { text: "hello" } },
            { id: 2, eventType: "assistant.message", payload: { text: "done" } },
            { id: 3, eventType: "assistant.thinking.delta", payload: { text: "plan first" } },
            {
              id: 4,
              eventType: "tool.call.completed",
              payload: { item: { id: "tool-1", type: "commandExecution" } },
            },
            {
              id: 5,
              eventType: "tool.call.completed",
              payload: { item: { id: "tool-2", type: "commandExecution" } },
            },
            { id: 6, eventType: "file.change.reported", payload: { files: ["src/app.rs"] } },
            {
              id: 7,
              eventType: "session.attached",
              payload: { runtimeSessionId: "thread-abc" },
            },
            { id: 8, eventType: "session.status.changed", payload: { status: "running" } },
            { id: 9, eventType: "session.status.changed", payload: { status: "idle" } },
          ],
        }}
        onBack={() => {}}
        onSend={onSend}
      />,
    );

    const backButton = screen.getByRole("button", { name: "Back" });
    expect(backButton).toBeInTheDocument();
    expect(backButton).toHaveClass("back-button");
    expect(screen.getByRole("button", { name: "Back" })).toHaveClass("back-button");
    expect(screen.getByRole("button", { name: "Send" })).toHaveClass("composer-send");
    expect(screen.getByLabelText("Message")).toHaveClass("composer-input");
    expect(document.querySelector(".session-detail")).toBeInTheDocument();
    expect(document.querySelector(".session-detail")).not.toBeNull();
    expect(document.querySelector(".session-transcript")).toBeInTheDocument();
    expect(document.querySelector(".session-summary-card")).not.toBeNull();
    expect(document.querySelector(".assistant-card")).not.toBeNull();
    expect(screen.getByText("codex")).toBeInTheDocument();
    expect(screen.getByText("/tmp/workspace")).toBeInTheDocument();
    expect(screen.getByText("source: managed")).toBeInTheDocument();
    expect(screen.getByText("runtime: thread-abc-123")).toBeInTheDocument();
    expect(document.querySelector(".session-summary-card .status-pill")).toHaveTextContent("idle");
    expect(screen.getByText("hello")).toBeInTheDocument();
    expect(screen.getByText("done")).toBeInTheDocument();
    expect(document.querySelector(".assistant-copy")).toBeInTheDocument();
    expect(screen.getByText("Activity")).toBeInTheDocument();
    expect(screen.getByText("commandExecution")).toBeInTheDocument();
    expect(screen.getByText("completed × 2")).toBeInTheDocument();
    expect(screen.getByText("src/app.rs")).toBeInTheDocument();
    expect(screen.getByText("thread-abc")).toBeInTheDocument();
    expect(screen.getByText("running → idle")).toBeInTheDocument();
    expect(screen.getByText("Activity").closest("details")).not.toBeNull();
    expect(screen.getByText("Status").closest("details")).not.toBeNull();
    expect(screen.getByText("Files changed").closest(".activity-card")).not.toBeNull();
    expect(screen.getByText("Attached session").closest(".activity-card")).not.toBeNull();

    const reasoning = screen.getByText("Reasoning").closest("details");
    expect(reasoning).not.toHaveAttribute("open");

    fireEvent.change(screen.getByLabelText("Message"), { target: { value: "Ship it" } });
    fireEvent.click(screen.getByRole("button", { name: "Send" }));

    expect(onSend).toHaveBeenCalledWith("Ship it");
  });
});
