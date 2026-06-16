import { useState } from "react";

import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { CreateSessionView } from "../CreateSessionView";

describe("CreateSessionView", () => {
  afterEach(() => {
    cleanup();
  });

  it("renders a modal dialog and submits trimmed session metadata", () => {
    const onCancel = vi.fn();
    const onSubmit = vi.fn();

    render(
      <CreateSessionView
        roots={[
          { id: "workspace", label: "Workspace", path: "/tmp/workspace" },
          { id: "alt", label: "Alt", path: "/tmp/alt" },
        ]}
        error={null}
        loadDirectories={vi.fn()}
        onCancel={onCancel}
        onSubmit={onSubmit}
      />,
    );

    const dialog = screen.getByRole("dialog", { name: "New session" });
    expect(document.querySelector(".session-modal-backdrop")).not.toBeNull();
    expect(dialog).toHaveClass("session-modal");

    fireEvent.change(screen.getByLabelText("Session name"), { target: { value: "  Launch Pad  " } });
    fireEvent.change(screen.getByLabelText("Workspace"), { target: { value: "alt" } });
    fireEvent.change(screen.getByLabelText("Path"), { target: { value: "  apps/api  " } });
    fireEvent.change(screen.getByLabelText("Agent"), { target: { value: "codex" } });
    fireEvent.click(screen.getByRole("button", { name: "Create session" }));

    expect(onSubmit).toHaveBeenCalledWith({
      title: "Launch Pad",
      rootId: "alt",
      path: "apps/api",
      agentKind: "codex",
    });
  });

  it("hides workspace for a single root and submits the default root", () => {
    const onSubmit = vi.fn();

    render(
      <CreateSessionView
        roots={[{ id: "workspace", label: "Workspace", path: "/tmp/workspace" }]}
        error={null}
        loadDirectories={vi.fn()}
        onCancel={vi.fn()}
        onSubmit={onSubmit}
      />,
    );

    expect(screen.queryByLabelText("Workspace")).not.toBeInTheDocument();
    expect(screen.getByText("Creates in /tmp/workspace")).toBeInTheDocument();

    fireEvent.change(screen.getByLabelText("Session name"), { target: { value: "Launch Pad" } });
    fireEvent.change(screen.getByLabelText("Path"), { target: { value: "repo" } });
    fireEvent.click(screen.getByRole("button", { name: "Create session" }));

    expect(onSubmit).toHaveBeenCalledWith({
      title: "Launch Pad",
      rootId: "workspace",
      path: "repo",
      agentKind: "codex",
    });
  });

  it("blocks submission when required values are missing", () => {
    const onSubmit = vi.fn();

    render(
      <CreateSessionView
        roots={[{ id: "workspace", label: "Workspace", path: "/tmp/workspace" }]}
        error={null}
        loadDirectories={vi.fn()}
        onCancel={vi.fn()}
        onSubmit={onSubmit}
      />,
    );

    const titleInput = screen.getByLabelText("Session name");
    const pathInput = screen.getByLabelText("Path");
    const button = screen.getByRole("button", { name: "Create session" });

    expect(screen.queryByText("Session name is required.")).not.toBeInTheDocument();
    expect(screen.queryByText("Path is required.")).not.toBeInTheDocument();
    expect(titleInput).not.toHaveAttribute("aria-invalid");
    expect(pathInput).toHaveAttribute("aria-invalid", "false");
    expect(titleInput).not.toHaveAttribute("aria-describedby");
    expect(pathInput).not.toHaveAttribute("aria-describedby");

    expect(button).toBeDisabled();
    fireEvent.blur(titleInput);
    const titleError = screen.getByText("Session name is required.");
    expect(titleError).toHaveAttribute("role", "alert");
    expect(titleError).toHaveAttribute("id", "create-session-title-error");
    expect(titleInput).toHaveAttribute("aria-invalid", "true");
    expect(titleInput).toHaveAttribute("aria-describedby", "create-session-title-error");

    fireEvent.change(pathInput, { target: { value: "   " } });
    fireEvent.submit(button.closest("form")!);

    const pathError = screen.getByText("Path is required.");
    expect(pathError).toHaveAttribute("role", "alert");
    expect(pathError).toHaveAttribute("id", "create-session-path-error");
    expect(pathInput).toHaveAttribute("aria-invalid", "true");
    expect(pathInput).toHaveAttribute("aria-describedby", "create-session-path-error");

    fireEvent.click(button);

    expect(onSubmit).not.toHaveBeenCalled();

    fireEvent.change(titleInput, { target: { value: "Launch Pad" } });
    fireEvent.change(pathInput, { target: { value: "repo" } });

    expect(screen.queryByText("Session name is required.")).not.toBeInTheDocument();
    expect(screen.queryByText("Path is required.")).not.toBeInTheDocument();
    expect(titleInput).toHaveAttribute("aria-invalid", "false");
    expect(pathInput).toHaveAttribute("aria-invalid", "false");
    expect(titleInput).not.toHaveAttribute("aria-describedby");
    expect(pathInput).not.toHaveAttribute("aria-describedby");
  });

  it("moves focus into the modal, traps tab navigation, and restores focus on close", () => {
    function Harness() {
      const [open, setOpen] = useState(false);

      return (
        <>
          <button onClick={() => setOpen(true)} type="button">
            Open modal
          </button>
          <button type="button">Background action</button>
          {open ? (
            <CreateSessionView
              roots={[{ id: "workspace", label: "Workspace", path: "/tmp/workspace" }]}
              error={null}
              loadDirectories={vi.fn()}
              onCancel={() => setOpen(false)}
              onSubmit={() => undefined}
            />
          ) : null}
        </>
      );
    }

    render(<Harness />);

    const openButton = screen.getByRole("button", { name: "Open modal" });
    openButton.focus();

    fireEvent.click(openButton);

    const dialog = screen.getByRole("dialog", { name: "New session" });
    const nameInput = screen.getByLabelText("Session name");
    const cancelButton = screen.getByRole("button", { name: "Cancel" });
    fireEvent.change(screen.getByLabelText("Session name"), { target: { value: "Launch Pad" } });
    const createButton = screen.getByRole("button", { name: "Create session" });

    expect(dialog.contains(document.activeElement)).toBe(true);

    createButton.focus();
    fireEvent.keyDown(createButton, { key: "Tab" });
    expect(nameInput).toHaveFocus();

    fireEvent.keyDown(nameInput, { key: "Tab", shiftKey: true });
    expect(createButton).toHaveFocus();

    fireEvent.click(cancelButton);
    expect(openButton).toHaveFocus();
  });

  it("keeps focus on the active field when the parent rerenders with a new error", () => {
    function Harness() {
      const [error, setError] = useState<string | null>(null);

      return (
        <>
          <button onClick={() => setError("Create exploded")} type="button">
            Trigger error
          </button>
          <CreateSessionView
            roots={[{ id: "workspace", label: "Workspace", path: "/tmp/workspace" }]}
            error={error}
            loadDirectories={vi.fn()}
            onCancel={() => {}}
            onSubmit={() => undefined}
          />
        </>
      );
    }

    render(<Harness />);

    const titleInput = screen.getByLabelText("Session name");
    titleInput.focus();
    expect(titleInput).toHaveFocus();

    fireEvent.click(screen.getByRole("button", { name: "Trigger error" }));

    expect(titleInput).toHaveFocus();
    expect(screen.getByText("Create exploded")).toBeInTheDocument();
  });

  it("blocks submission when roots are empty and shows the provided error", () => {
    const onSubmit = vi.fn();

    render(
      <CreateSessionView
        roots={[]}
        error="No workspace roots available."
        loadDirectories={vi.fn()}
        onCancel={vi.fn()}
        onSubmit={onSubmit}
      />,
    );

    expect(screen.getByText("No workspace roots available.")).toHaveAttribute("role", "alert");

    const button = screen.getByRole("button", { name: "Create session" });
    expect(button).toBeDisabled();

    fireEvent.click(button);

    expect(onSubmit).not.toHaveBeenCalled();
  });
});
