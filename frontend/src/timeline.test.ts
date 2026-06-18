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

  it("projects completed command execution details with terminal output", () => {
    const events: SessionEvent[] = [
      {
        id: 1,
        eventType: "tool.call.completed",
        payload: {
          item: {
            id: "cmd-1",
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
    ];

    expect(projectTimelineEvents(events)).toEqual([
      {
        id: "tool:cmd-1",
        kind: "tool_call",
        toolName: "shell",
        label: "npm test",
        summary: "Ran npm test",
        output: "PASS src/app.test.ts",
        status: "completed",
        command: "/bin/zsh -lc npm test",
        cwd: "/tmp/workspace",
        exitCode: 0,
        durationMs: 42,
      },
    ]);
  });

  it("updates a command execution lifecycle item instead of rendering started and completed separately", () => {
    const events: SessionEvent[] = [
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
            exitCode: 0,
          },
        },
      },
    ];

    expect(projectTimelineEvents(events)).toEqual([
      {
        id: "tool:cmd-1",
        kind: "tool_call",
        toolName: "shell",
        label: "npm test",
        summary: "Ran npm test",
        output: "PASS",
        status: "completed",
        command: "/bin/zsh -lc npm test",
        exitCode: 0,
      },
    ]);
  });

  it("filters internal system prompt and context assistant messages", () => {
    const events: SessionEvent[] = [
      {
        id: 1,
        eventType: "assistant.message",
        payload: { text: "You are Codex, a coding agent based on GPT-5." },
      },
      {
        id: 2,
        eventType: "assistant.message",
        payload: { text: "<environment_context>\n  <cwd>/tmp/workspace</cwd>\n</environment_context>" },
      },
      { id: 3, eventType: "assistant.message", payload: { text: "Visible reply" } },
    ];

    expect(projectTimelineEvents(events)).toEqual([
      { id: "assistant:3", kind: "assistant", text: "Visible reply" },
    ]);
  });

  it("keeps only diff hunks from verbose tool output when a patch is present", () => {
    const events: SessionEvent[] = [
      {
        id: 1,
        eventType: "tool.call.completed",
        payload: {
          item: {
            id: "cmd-1",
            type: "commandExecution",
            command: "/bin/zsh -lc apply_patch",
            status: "completed",
            aggregatedOutput: [
              "Reading full file content...",
              "diff --git a/src/app.ts b/src/app.ts",
              "@@",
              "-old",
              "+new",
              "Full file content that should not be shown",
            ].join("\n"),
          },
        },
      },
    ];

    expect(projectTimelineEvents(events)).toEqual([
      {
        id: "tool:cmd-1",
        kind: "tool_call",
        toolName: "shell",
        label: "apply_patch",
        summary: "Applied patch",
        output: "diff --git a/src/app.ts b/src/app.ts\n@@\n-old\n+new",
        status: "completed",
        command: "/bin/zsh -lc apply_patch",
      },
    ]);
  });

  it("projects completed file changes with patch diffs", () => {
    const events: SessionEvent[] = [
      {
        id: 1,
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
    ];

    expect(projectTimelineEvents(events)).toEqual([
      {
        id: "file:patch-1",
        kind: "file_change",
        files: ["src/app.ts"],
        summary: "Edited src/app.ts",
        diffs: ["@@\n-old\n+new"],
        status: "completed",
      },
    ]);
  });

  it("updates a file change lifecycle item instead of rendering started and completed separately", () => {
    const events: SessionEvent[] = [
      {
        id: 1,
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
        id: 2,
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
    ];

    expect(projectTimelineEvents(events)).toEqual([
      {
        id: "file:patch-1",
        kind: "file_change",
        files: ["src/app.ts"],
        summary: "Edited src/app.ts",
        diffs: ["@@\n-old\n+new"],
        status: "completed",
      },
    ]);
  });

  it("summarizes reported file changes without acceptance wording", () => {
    const events: SessionEvent[] = [
      {
        id: 1,
        eventType: "file.change.reported",
        payload: { files: ["src/app.ts", "src/theme.css", "README.md"] },
      },
    ];

    expect(projectTimelineEvents(events)).toEqual([
      {
        id: "file:1",
        kind: "file_change",
        files: ["src/app.ts", "src/theme.css", "README.md"],
        summary: "Edited 3 files",
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

  it("projects Codex turn error messages instead of opaque system error statuses", () => {
    const events: SessionEvent[] = [
      {
        id: 1,
        eventType: "session.status.changed",
        payload: { status: { type: "systemError" } },
      },
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
    ];

    expect(projectTimelineEvents(events)).toEqual([
      {
        id: "status:1",
        kind: "status_summary",
        statuses: [
          "systemError",
          "Selected model is at capacity. Please try a different model.",
        ],
      },
    ]);
  });

  it("projects failed status messages when turn error details are missing", () => {
    const events: SessionEvent[] = [
      {
        id: 1,
        eventType: "session.status.changed",
        payload: {
          status: {
            type: "failed",
            message: "Error running remote compact task: unexpected status 502 Bad Gateway",
          },
        },
      },
    ];

    expect(projectTimelineEvents(events)).toEqual([
      {
        id: "status:1",
        kind: "status_summary",
        statuses: ["Error running remote compact task: unexpected status 502 Bad Gateway"],
      },
    ]);
  });

  it("projects session.error events into visible timeline items", () => {
    const events: SessionEvent[] = [
      {
        id: 1,
        eventType: "session.error",
        payload: { message: "temporary reconnect", willRetry: true },
      },
    ];

    expect(projectTimelineEvents(events)).toEqual([
      {
        id: "error:1",
        kind: "session_error",
        message: "temporary reconnect",
        willRetry: true,
      },
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
      { id: "user:1", kind: "user", text: "hello", imagePaths: [] },
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

  it("preserves user image attachments on timeline items", () => {
    const events: SessionEvent[] = [
      {
        id: 1,
        eventType: "user.message",
        payload: {
          text: "look at this",
          imagePaths: ["/tmp/attachments/sess-1/screenshot.png"],
        },
      },
    ];

    expect(projectTimelineEvents(events)).toEqual([
      {
        id: "user:1",
        kind: "user",
        text: "look at this",
        imagePaths: ["/tmp/attachments/sess-1/screenshot.png"],
      },
    ]);
  });
});
