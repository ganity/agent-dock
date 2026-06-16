import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { AttachSessionView } from "../AttachSessionView";

const loadDirectories = vi.fn().mockResolvedValue({
  currentPath: "/tmp/workspace",
  parentPath: "/tmp",
  directories: [],
});

describe("AttachSessionView", () => {
  afterEach(() => {
    cleanup();
  });

  it("renders a modal dialog and submits trimmed runtime session metadata", () => {
    const onSubmit = vi.fn();

    render(
      <AttachSessionView
        roots={[
          { id: "workspace", label: "Workspace", path: "/tmp/workspace" },
          { id: "alt", label: "Alt", path: "/tmp/alt" },
        ]}
        error={null}
        loadDirectories={loadDirectories}
        onCancel={vi.fn()}
        onSubmit={onSubmit}
      />,
    );

    const dialog = screen.getByRole("dialog", { name: "Attach session" });
    expect(document.querySelector(".session-modal-backdrop")).not.toBeNull();
    expect(dialog).toHaveClass("session-modal");

    fireEvent.change(screen.getByLabelText("Workspace"), { target: { value: "alt" } });
    fireEvent.change(screen.getByLabelText("Path"), { target: { value: "  apps/api  " } });
    fireEvent.change(screen.getByLabelText("Agent"), { target: { value: "claude" } });
    fireEvent.change(screen.getByLabelText("Runtime session ID"), {
      target: { value: "  thread-abc  " },
    });
    fireEvent.click(screen.getByRole("button", { name: "Attach session" }));

    expect(onSubmit).toHaveBeenCalledWith({
      rootId: "alt",
      path: "apps/api",
      agentKind: "claude",
      runtimeSessionId: "thread-abc",
    });
  });

  it("hides workspace for a single root and submits the default root", () => {
    const onSubmit = vi.fn();

    render(
      <AttachSessionView
        roots={[{ id: "workspace", label: "Workspace", path: "/tmp/workspace" }]}
        error={null}
        loadDirectories={loadDirectories}
        onCancel={vi.fn()}
        onSubmit={onSubmit}
      />,
    );

    expect(screen.queryByLabelText("Workspace")).not.toBeInTheDocument();
    expect(screen.queryByText("Attaches in /tmp/workspace")).not.toBeInTheDocument();

    fireEvent.change(screen.getByLabelText("Runtime session ID"), { target: { value: "thread-abc" } });
    fireEvent.change(screen.getByLabelText("Path"), { target: { value: "repo" } });
    fireEvent.click(screen.getByRole("button", { name: "Attach session" }));

    expect(onSubmit).toHaveBeenCalledWith({
      rootId: "workspace",
      path: "repo",
      agentKind: "codex",
      runtimeSessionId: "thread-abc",
    });
  });

  it("blocks submission when required values are missing", () => {
    const onSubmit = vi.fn();

    render(
      <AttachSessionView
        roots={[{ id: "workspace", label: "Workspace", path: "/tmp/workspace" }]}
        error={null}
        loadDirectories={loadDirectories}
        onCancel={vi.fn()}
        onSubmit={onSubmit}
      />,
    );

    const runtimeSessionIdInput = screen.getByLabelText("Runtime session ID");
    const pathInput = screen.getByLabelText("Path");
    const button = screen.getByRole("button", { name: "Attach session" });

    expect(screen.queryByText("Runtime session ID is required.")).not.toBeInTheDocument();
    expect(screen.queryByText("Path is required.")).not.toBeInTheDocument();
    expect(runtimeSessionIdInput).not.toHaveAttribute("aria-invalid");
    expect(pathInput).toHaveAttribute("aria-invalid", "false");
    expect(runtimeSessionIdInput).not.toHaveAttribute("aria-describedby");
    expect(pathInput).not.toHaveAttribute("aria-describedby");

    expect(button).toBeDisabled();
    fireEvent.blur(runtimeSessionIdInput);
    const runtimeSessionIdError = screen.getByText("Runtime session ID is required.");
    expect(runtimeSessionIdError).toHaveAttribute("role", "alert");
    expect(runtimeSessionIdError).toHaveAttribute("id", "attach-session-runtime-session-id-error");
    expect(runtimeSessionIdInput).toHaveAttribute("aria-invalid", "true");
    expect(runtimeSessionIdInput).toHaveAttribute(
      "aria-describedby",
      "attach-session-runtime-session-id-error",
    );

    fireEvent.change(pathInput, { target: { value: "   " } });

    const pathError = screen.getByText("Path is required.");
    expect(pathError).toHaveAttribute("role", "alert");
    expect(pathError).toHaveAttribute("id", "attach-session-path-error");
    expect(pathInput).toHaveAttribute("aria-invalid", "true");
    expect(pathInput).toHaveAttribute("aria-describedby", "attach-session-path-error");

    fireEvent.submit(button.closest("form")!);

    expect(onSubmit).not.toHaveBeenCalled();

    fireEvent.change(runtimeSessionIdInput, { target: { value: "thread-abc" } });
    fireEvent.change(pathInput, { target: { value: "repo" } });

    expect(screen.queryByText("Runtime session ID is required.")).not.toBeInTheDocument();
    expect(screen.queryByText("Path is required.")).not.toBeInTheDocument();
    expect(runtimeSessionIdInput).toHaveAttribute("aria-invalid", "false");
    expect(pathInput).toHaveAttribute("aria-invalid", "false");
    expect(runtimeSessionIdInput).not.toHaveAttribute("aria-describedby");
    expect(pathInput).not.toHaveAttribute("aria-describedby");
  });

  it("blocks submission when roots are empty and shows the provided error", () => {
    const onSubmit = vi.fn();

    render(
      <AttachSessionView
        roots={[]}
        error="No workspace roots available."
        loadDirectories={loadDirectories}
        onCancel={vi.fn()}
        onSubmit={onSubmit}
      />,
    );

    expect(screen.getByText("No workspace roots available.")).toHaveAttribute("role", "alert");

    const button = screen.getByRole("button", { name: "Attach session" });
    expect(button).toBeDisabled();

    fireEvent.click(button);

    expect(onSubmit).not.toHaveBeenCalled();
  });

  it("lets the user pick an existing session candidate instead of typing the runtime session id", () => {
    const onSubmit = vi.fn();

    render(
      <AttachSessionView
        roots={[{ id: "workspace", label: "Workspace", path: "/tmp/workspace" }]}
        sessionCandidates={[
          {
            id: "sess-2",
            title: "API Fixes",
            agentKind: "codex",
            sourceKind: "managed",
            runtimeSessionId: "thread-xyz",
            workspacePath: "/tmp/workspace/apps/api",
            status: "running",
          },
        ]}
        error={null}
        loadDirectories={loadDirectories}
        onCancel={vi.fn()}
        onSubmit={onSubmit}
      />,
    );

    fireEvent.click(screen.getByRole("button", { name: /Use API Fixes/i }));

    expect(screen.getByLabelText("Runtime session ID")).toHaveValue("thread-xyz");
    expect(screen.getByLabelText("Path")).toHaveValue("/tmp/workspace/apps/api");
    expect(screen.getByLabelText("Agent")).toHaveValue("codex");

    fireEvent.click(screen.getByRole("button", { name: "Attach session" }));

    expect(onSubmit).toHaveBeenCalledWith({
      rootId: "workspace",
      path: "/tmp/workspace/apps/api",
      agentKind: "codex",
      runtimeSessionId: "thread-xyz",
    });
  });
});
