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
  it("scopes chat-workbench stylesheet hooks to the session detail surface", () => {
    const mobileReaderRoot = styles.match(/:root\s*{[^}]*--font-ui:[^}]*}/)?.[0] ?? "";

    expect(mobileReaderRoot).toContain("--font-ui");
    expect(mobileReaderRoot).not.toContain("font-family:");
    expect(styles).toContain(".session-detail :is(");
    expect(styles).toContain(".session-detail .input:focus-visible");
    expect(styles).toContain(".session-detail summary:focus-visible");
    expect(styles).toContain(".session-chat-workbench");
    expect(styles).toContain(".session-workbench-header");
    expect(styles).toContain(".session-menu-panel");
    expect(styles).toContain(".user-bubble");
    expect(styles).toContain(".user-attachments");
    expect(styles).toContain(".user-attachment-image");
    expect(styles).toContain(".assistant-document");
    expect(styles).toContain(".markdown-content");
    expect(styles).toContain(".session-detail .composer");
    expect(styles).toContain(".session-detail .composer-file-input");
    expect(styles).toContain("clip: rect(0 0 0 0);");
    expect(styles).toContain(".session-detail .activity-disclosure");
    expect(styles).toContain(".session-detail .activity-compact-card summary");
    expect(styles).toContain(".session-detail .activity-icon");
    expect(styles).toContain(".session-detail .activity-summary-text");
    expect(styles).toContain("justify-self: start;");
    expect(styles).toContain("min-height: 32px;");
    expect(styles).toContain(".session-detail .activity-list span");
    expect(styles).not.toMatch(/^\.(button|input):focus-visible/m);
    expect(styles).not.toMatch(/^summary:focus-visible/m);
    expect(styles).not.toMatch(/^\.composer\s*{/m);
    expect(styles).not.toMatch(/^\.activity-card\s*{/m);
    expect(styles).toContain(".session-detail .activity-row span:last-child");
    expect(styles).not.toContain(".activity-list strong");
  });

  it("renders a chat workbench with header metadata, user bubble, document output, and compact composer", async () => {
    const onSend = vi.fn();
    const onUploadImage = vi.fn().mockResolvedValue("/tmp/workspace/screenshot.png");

    render(
      <SessionDetailView
        session={{
          id: "sess-1",
          title: "Launch Pad",
          agentKind: "codex",
          sourceKind: "managed",
          runtimeSessionId: "thread-abc-123",
          workspacePath: "/tmp/workspace",
          status: "created",
          events: [
            {
              id: 1,
              eventType: "user.message",
              payload: {
                text: "hello",
                imagePaths: ["/tmp/workspace/attachments/screenshot.png"],
              },
            },
            {
              id: 2,
              eventType: "assistant.message",
              payload: { text: "## Done\n\n- Render markdown\n- Keep `code` readable" },
            },
            { id: 3, eventType: "assistant.thinking.delta", payload: { text: "plan first" } },
            {
              id: 4,
              eventType: "tool.call.completed",
              payload: {
                item: {
                  id: "tool-1",
                  type: "commandExecution",
                  command: "/bin/zsh -lc npm test",
                  cwd: "/tmp/workspace",
                  status: "completed",
                  commandActions: [{ type: "runCommand", command: "npm test", path: null }],
                  aggregatedOutput: "PASS src/app.test.ts\n",
                  exitCode: 0,
                  durationMs: 42,
                },
              },
            },
            {
              id: 5,
              eventType: "tool.call.completed",
              payload: { item: { id: "tool-2", type: "commandExecution" } },
            },
            {
              id: 6,
              eventType: "tool.call.completed",
              payload: {
                item: {
                  id: "patch-1",
                  type: "fileChange",
                  status: "completed",
                  changes: [
                    {
                      path: "src/app.rs",
                      kind: { type: "update", move_path: null },
                      diff: "@@\n-old\n+new\n",
                    },
                  ],
                },
              },
            },
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
        onUploadImage={onUploadImage}
        onConnectVoiceInput={() => ({ close() {} } as WebSocket)}
        onLoadOlder={async () => {}}
        loadingHistory={false}
      />,
    );

    const backButton = screen.getByRole("button", { name: "Back" });
    const sessionDetail = document.querySelector(".session-detail");
    expect(backButton).toBeInTheDocument();
    expect(backButton).toHaveClass("session-back-button");
    expect(screen.getByRole("button", { name: "Session details" })).toHaveClass(
      "session-menu-button",
    );
    expect(screen.getByText("Launch Pad")).toHaveClass("session-heading-title");
    expect(document.querySelector(".session-status-pill")).toHaveTextContent("idle");
    expect(screen.getByRole("button", { name: "Send" })).toHaveClass("composer-send");
    expect(screen.getByRole("button", { name: "Attach file" })).toBeInTheDocument();
    expect(screen.getByLabelText("Image attachments")).toHaveAttribute("accept", "image/*");
    expect(screen.getByRole("button", { name: "Voice input" })).toBeInTheDocument();
    expect(screen.getByLabelText("Message")).toHaveClass("composer-input");
    expect(screen.queryByText("Message")).not.toBeInTheDocument();
    expect(sessionDetail).toBeInTheDocument();
    expect(sessionDetail).toHaveClass("session-chat-workbench");
    expect(document.querySelector(".session-transcript")).toBeInTheDocument();
    expect(document.querySelector(".session-summary-card")).toBeNull();
    expect(document.querySelector(".assistant-document")).toBeInTheDocument();
    expect(screen.getByText("Workspace")).toBeInTheDocument();
    expect(screen.getByText("/tmp/workspace")).toBeInTheDocument();
    expect(screen.getByText("source: managed")).toBeInTheDocument();
    expect(screen.queryByText("runtime: thread-abc-123")).not.toBeInTheDocument();
    expect(document.querySelector(".user-bubble")).toHaveTextContent("hello");
    expect(screen.getByRole("img", { name: "screenshot.png" })).toHaveAttribute(
      "src",
      "/api/sessions/sess-1/attachments/screenshot.png",
    );
    expect(screen.getByRole("heading", { level: 2, name: "Done" })).toBeInTheDocument();
    expect(screen.getByText("Render markdown")).toBeInTheDocument();
    expect(screen.getByText("code")).toBeInTheDocument();
    expect(screen.getByText("Activity")).toBeInTheDocument();
    expect(screen.getByText("Activity").closest("details")).toHaveClass("activity-disclosure");
    expect(screen.getByText("Activity").closest("details")).not.toHaveClass("panel");
    expect(screen.getByText("Activity").closest("details")).not.toHaveClass("stack");
    expect(screen.getByText("commandExecution")).toBeInTheDocument();
    expect(screen.getByText("completed × 1")).toBeInTheDocument();
    expect(screen.getByText("Ran npm test")).toBeInTheDocument();
    expect(screen.getByText("command: npm test")).toBeInTheDocument();
    expect(screen.getByText("PASS src/app.test.ts")).toBeInTheDocument();
    expect(screen.getByText("Edited src/app.rs")).toBeInTheDocument();
    expect(screen.getByText("src/app.rs")).toBeInTheDocument();
    expect(screen.getByText(/-old/)).toBeInTheDocument();
    expect(screen.getByText(/\+new/)).toBeInTheDocument();
    expect(screen.queryByText(/Accepted/)).not.toBeInTheDocument();
    expect(screen.getByText("Ran npm test").closest("details")).not.toHaveAttribute("open");
    expect(screen.getByText("Edited src/app.rs").closest("details")).not.toHaveAttribute("open");
    expect(screen.queryByText("thread-abc")).not.toBeInTheDocument();
    expect(screen.queryByText("running → idle")).not.toBeInTheDocument();
    expect(screen.getByText("Activity").closest("details")).not.toBeNull();
    expect(screen.getByText("Edited src/app.rs").closest(".activity-card")).not.toBeNull();
    expect(screen.getByText("Attached session").closest(".activity-card")).not.toBeNull();
    expect(screen.queryByText("thread-abc")).not.toBeInTheDocument();

    const reasoning = screen.getByText("Reasoning").closest("details");
    expect(reasoning).not.toHaveAttribute("open");

    const file = new File(["image"], "screenshot.png", { type: "image/png" });
    fireEvent.change(screen.getByLabelText("Image attachments"), {
      target: { files: [file] },
    });
    expect(onUploadImage).toHaveBeenCalledWith(file);
    expect(await screen.findByText("screenshot.png")).toBeInTheDocument();

    fireEvent.change(screen.getByLabelText("Message"), { target: { value: "Ship it" } });
    fireEvent.click(screen.getByRole("button", { name: "Send" }));

    expect(onSend).toHaveBeenCalledWith("Ship it", ["/tmp/workspace/screenshot.png"]);
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
        onUploadImage={async () => ""}
        onConnectVoiceInput={() => ({ close() {} } as WebSocket)}
        onLoadOlder={async () => {}}
        loadingHistory={false}
      />,
    );

    expect(document.querySelector(".session-status-pill")).toHaveTextContent("created");
    expect(screen.queryByText("Status")).not.toBeInTheDocument();
  });

  it("renders one lifecycle card per tool item with the final status", () => {
    render(
      <SessionDetailView
        session={{
          id: "sess-lifecycle",
          agentKind: "codex",
          status: "running",
          events: [
            {
              id: 1,
              eventType: "tool.call.started",
              payload: {
                item: {
                  id: "cmd-1",
                  type: "commandExecution",
                  command: "/bin/zsh -lc npm test",
                  status: "inProgress",
                },
              },
            },
            {
              id: 2,
              eventType: "tool.call.completed",
              payload: {
                item: {
                  id: "cmd-1",
                  type: "commandExecution",
                  command: "/bin/zsh -lc npm test",
                  status: "completed",
                  aggregatedOutput: "PASS\n",
                },
              },
            },
            {
              id: 3,
              eventType: "tool.call.started",
              payload: {
                item: {
                  id: "patch-1",
                  type: "fileChange",
                  status: "inProgress",
                  changes: [{ path: "src/app.ts", kind: { type: "update", move_path: null }, diff: "" }],
                },
              },
            },
            {
              id: 4,
              eventType: "tool.call.completed",
              payload: {
                item: {
                  id: "patch-1",
                  type: "fileChange",
                  status: "completed",
                  changes: [
                    {
                      path: "src/app.ts",
                      kind: { type: "update", move_path: null },
                      diff: "@@\n-old\n+new\n",
                    },
                  ],
                },
              },
            },
          ],
        }}
        onBack={() => {}}
        onSend={() => {}}
        onUploadImage={async () => ""}
        onConnectVoiceInput={() => ({ close() {} } as WebSocket)}
        onLoadOlder={async () => {}}
        loadingHistory={false}
      />,
    );

    expect(screen.getAllByText("Ran npm test")).toHaveLength(1);
    expect(screen.getAllByText("Edited src/app.ts")).toHaveLength(1);
    expect(screen.getAllByText("completed")).toHaveLength(2);
    expect(screen.queryByText("inProgress")).not.toBeInTheDocument();
    expect(screen.queryByText(/Accepted/)).not.toBeInTheDocument();
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
        onUploadImage={async () => ""}
        onConnectVoiceInput={() => ({ close() {} } as WebSocket)}
        onLoadOlder={async () => {}}
        loadingHistory={false}
      />,
    );

    expect(document.querySelector(".session-status-pill")).toHaveTextContent("running");
    expect(screen.getByText("still working")).toBeInTheDocument();
    expect(screen.queryByText("Status")).not.toBeInTheDocument();
    expect(screen.queryByText("created")).not.toBeInTheDocument();
  });

  it("shows the latest turn error message in the status pill when the current session status is not more specific", () => {
    render(
      <SessionDetailView
        session={{
          id: "sess-turn-error",
          agentKind: "codex",
          status: "failed",
          events: [
            { id: 1, eventType: "session.status.changed", payload: { status: { type: "systemError" } } },
            {
              id: 2,
              eventType: "session.status.changed",
              payload: {
                turn: {
                  status: "failed",
                  error: {
                    message: "Selected model is at capacity. Please try a different model.",
                    codexErrorInfo: "serverOverloaded",
                  },
                },
              },
            },
          ],
        }}
        onBack={() => {}}
        onSend={() => {}}
        onUploadImage={async () => ""}
        onConnectVoiceInput={() => ({ close() {} } as WebSocket)}
        onLoadOlder={async () => {}}
        loadingHistory={false}
      />,
    );

    expect(document.querySelector(".session-status-pill")).toHaveTextContent(
      "Selected model is at capacity. Please try a different model.",
    );
  });

  it("prefers the current session status over older timeline error text", () => {
    render(
      <SessionDetailView
        session={{
          id: "sess-recovered",
          agentKind: "codex",
          status: "idle",
          events: [
            {
              id: 1,
              eventType: "session.status.changed",
              payload: {
                turn: {
                  status: "failed",
                  error: {
                    message: "Selected model is at capacity. Please try a different model.",
                  },
                },
              },
            },
          ],
        }}
        onBack={() => {}}
        onSend={() => {}}
        onUploadImage={async () => ""}
        onConnectVoiceInput={() => ({ close() {} } as WebSocket)}
        onLoadOlder={async () => {}}
        loadingHistory={false}
      />,
    );

    expect(document.querySelector(".session-status-pill")).toHaveTextContent("idle");
  });

  it("shows slash-command suggestions and inserts the selected command into the composer", () => {
    const onSend = vi.fn();

    render(
      <SessionDetailView
        session={{
          id: "sess-commands",
          title: "Launch Pad",
          agentKind: "codex",
          sourceKind: "managed",
          workspacePath: "/tmp/workspace",
          status: "running",
          events: [],
        }}
        onBack={() => {}}
        onSend={onSend}
        onUploadImage={async () => ""}
        onConnectVoiceInput={() => ({ close() {} } as WebSocket)}
        onLoadOlder={async () => {}}
        loadingHistory={false}
      />,
    );

    const input = screen.getByLabelText("Message");
    fireEvent.change(input, { target: { value: "/" } });

    expect(screen.getByRole("listbox", { name: "Command suggestions" })).toBeInTheDocument();
    expect(screen.getByRole("option", { name: "/resume Resume an existing session" })).toBeInTheDocument();

    fireEvent.keyDown(input, { key: "ArrowDown" });
    fireEvent.keyDown(input, { key: "Enter" });

    expect(screen.getByLabelText("Message")).toHaveValue("/model ");
  });

  it("requests older history when the transcript is scrolled near the top", () => {
    const onLoadOlder = vi.fn();

    render(
      <SessionDetailView
        session={{
          id: "sess-history",
          title: "Launch Pad",
          agentKind: "codex",
          sourceKind: "managed",
          workspacePath: "/tmp/workspace",
          status: "running",
          hasMoreHistory: true,
          events: [
            { id: 51, eventType: "user.message", payload: { text: "older" } },
            { id: 52, eventType: "assistant.message", payload: { text: "newer" } },
          ],
        }}
        onBack={() => {}}
        onSend={() => {}}
        onUploadImage={async () => ""}
        onConnectVoiceInput={() => ({ close() {} } as WebSocket)}
        onLoadOlder={onLoadOlder}
        loadingHistory={false}
      />,
    );

    const transcript = document.querySelector(".session-transcript") as HTMLElement;
    Object.defineProperty(transcript, "scrollTop", { value: 20, configurable: true, writable: true });
    Object.defineProperty(transcript, "scrollHeight", { value: 900, configurable: true });
    Object.defineProperty(transcript, "clientHeight", { value: 300, configurable: true });

    fireEvent.scroll(transcript);

    expect(onLoadOlder).toHaveBeenCalledTimes(1);
  });

  it("only auto-follows new events when the transcript is already near the bottom", () => {
    const { rerender } = render(
      <SessionDetailView
        session={{
          id: "sess-follow",
          title: "Launch Pad",
          agentKind: "codex",
          status: "running",
          hasMoreHistory: false,
          events: [{ id: 1, eventType: "assistant.message", payload: { text: "first" } }],
        }}
        onBack={() => {}}
        onSend={() => {}}
        onUploadImage={async () => ""}
        onConnectVoiceInput={() => ({ close() {} } as WebSocket)}
        onLoadOlder={async () => {}}
        loadingHistory={false}
      />,
    );

    const transcript = document.querySelector(".session-transcript") as HTMLElement;
    Object.defineProperty(transcript, "scrollHeight", { value: 1000, configurable: true });
    Object.defineProperty(transcript, "clientHeight", { value: 300, configurable: true });
    Object.defineProperty(transcript, "scrollTop", { value: 660, configurable: true, writable: true });
    fireEvent.scroll(transcript);

    rerender(
      <SessionDetailView
        session={{
          id: "sess-follow",
          title: "Launch Pad",
          agentKind: "codex",
          status: "running",
          hasMoreHistory: false,
          events: [
            { id: 1, eventType: "assistant.message", payload: { text: "first" } },
            { id: 2, eventType: "assistant.message", payload: { text: "second" } },
          ],
        }}
        onBack={() => {}}
        onSend={() => {}}
        onUploadImage={async () => ""}
        onConnectVoiceInput={() => ({ close() {} } as WebSocket)}
        onLoadOlder={async () => {}}
        loadingHistory={false}
      />,
    );

    expect(transcript.scrollTop).toBe(1000);

    Object.defineProperty(transcript, "scrollTop", { value: 200, configurable: true, writable: true });
    fireEvent.scroll(transcript);

    rerender(
      <SessionDetailView
        session={{
          id: "sess-follow",
          title: "Launch Pad",
          agentKind: "codex",
          status: "running",
          hasMoreHistory: false,
          events: [
            { id: 1, eventType: "assistant.message", payload: { text: "first" } },
            { id: 2, eventType: "assistant.message", payload: { text: "second" } },
            { id: 3, eventType: "assistant.message", payload: { text: "third" } },
          ],
        }}
        onBack={() => {}}
        onSend={() => {}}
        onUploadImage={async () => ""}
        onConnectVoiceInput={() => ({ close() {} } as WebSocket)}
        onLoadOlder={async () => {}}
        loadingHistory={false}
      />,
    );

    expect(transcript.scrollTop).toBe(200);
  });
});
