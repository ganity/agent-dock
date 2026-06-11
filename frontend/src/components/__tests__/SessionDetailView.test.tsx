import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { SessionDetailView } from "../SessionDetailView";

const styles = readFileSync(resolve(process.cwd(), "src/styles.css"), "utf8");

afterEach(() => {
  cleanup();
});

describe("SessionDetailView", () => {
  it("scopes mobile-reader stylesheet hooks to the session detail surface", () => {
    const mobileReaderRoot = styles.match(/:root\s*{[^}]*--font-ui:[^}]*}/)?.[0] ?? "";

    expect(mobileReaderRoot).toContain("--font-ui");
    expect(mobileReaderRoot).not.toContain("font-family:");
    expect(styles).toContain(".session-detail .button:focus-visible");
    expect(styles).toContain(".session-detail .input:focus-visible");
    expect(styles).toContain(".session-detail summary:focus-visible");
    expect(styles).toContain(".session-detail .panel");
    expect(styles).toContain(".session-detail .composer");
    expect(styles).toContain(".session-detail .activity-card");
    expect(styles).toContain(".session-detail .eyebrow");
    expect(styles).toContain(".session-detail .meta-chip");
    expect(styles).toContain(".session-detail .activity-list span");
    expect(styles).not.toMatch(/^\.(button|input):focus-visible/m);
    expect(styles).not.toMatch(/^summary:focus-visible/m);
    expect(styles).not.toMatch(/^\.composer\s*{/m);
    expect(styles).not.toMatch(/^\.activity-card\s*{/m);
    expect(styles).not.toMatch(/^\.eyebrow\s*{/m);
    expect(styles).not.toMatch(/^\.meta-chip\s*{/m);
    expect(styles).toContain(".session-detail .activity-row span:last-child");
    expect(styles).not.toContain(".activity-list strong");
  });

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
    const sessionDetail = document.querySelector(".session-detail");
    expect(backButton).toBeInTheDocument();
    expect(backButton).toHaveClass("back-button");
    expect(screen.getByRole("button", { name: "Send" })).toHaveClass("composer-send");
    expect(screen.getByLabelText("Message")).toHaveClass("composer-input");
    expect(sessionDetail).toBeInTheDocument();
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

  it("keeps the summary status and skips blank status cards for empty status payloads", () => {
    render(
      <SessionDetailView
        session={{
          id: "sess-empty-status",
          agentKind: "codex",
          status: "created",
          events: [{ id: 1, eventType: "session.status.changed", payload: {} }],
        }}
        onBack={() => {}}
        onSend={() => {}}
      />,
    );

    expect(document.querySelector(".session-summary-card .status-pill")).toHaveTextContent(
      "created",
    );
    expect(screen.queryByText("Status")).not.toBeInTheDocument();
  });

  it("preserves the latest non-empty timeline status across separated blank status segments", () => {
    render(
      <SessionDetailView
        session={{
          id: "sess-separated-status",
          agentKind: "codex",
          status: "created",
          events: [
            { id: 1, eventType: "session.status.changed", payload: { status: "running" } },
            { id: 2, eventType: "assistant.message", payload: { text: "still working" } },
            { id: 3, eventType: "session.status.changed", payload: {} },
          ],
        }}
        onBack={() => {}}
        onSend={() => {}}
      />,
    );

    expect(document.querySelector(".session-summary-card .status-pill")).toHaveTextContent(
      "running",
    );
    expect(screen.getByText("still working")).toBeInTheDocument();
    expect(screen.getByText("Status")).toBeInTheDocument();
    expect(screen.getByText("running", { selector: "p" })).toBeInTheDocument();
    expect(screen.queryByText("created")).not.toBeInTheDocument();
  });
});
