import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { SessionListView } from "../SessionListView";

afterEach(() => {
  cleanup();
});

describe("SessionListView", () => {
  it("renders launcher structure with clickable session cards and chip metadata", () => {
    const onCreate = vi.fn();
    const onAttach = vi.fn();
    const onSelect = vi.fn();
    const onDelete = vi.fn();

    render(
      <SessionListView
        hasRoots
        sessions={[
          {
            id: "sess-1",
            title: "Launch Pad",
            agentKind: "codex",
            sourceKind: "attached",
            status: "running",
            workspacePath: "apps/api",
            runtimeSessionId: "thread-abc",
          },
        ]}
        currentUser={null}
        users={[]}
        onCreateUser={vi.fn().mockResolvedValue(undefined)}
        onResetPassword={vi.fn().mockResolvedValue(undefined)}
        onDeleteUser={vi.fn().mockResolvedValue(undefined)}
        onCreate={onCreate}
        onAttach={onAttach}
        onSelect={onSelect}
        onDelete={onDelete}
      />,
    );

    const launcher = screen.getByRole("heading", { level: 1, name: "Sessions" }).closest("section");
    expect(launcher).toHaveClass("session-home");

    const header = screen.getByRole("heading", { level: 1, name: "Sessions" }).closest("header");
    expect(header).toHaveClass("session-home-header");
    expect(screen.getByText("Local control surface")).toHaveClass("eyebrow");
    expect(
      screen.queryByText("Recent agent workspaces on this machine, ready to resume."),
    ).not.toBeInTheDocument();

    const newSessionButton = screen.getByRole("button", { name: /^New$/i });
    expect(newSessionButton).toHaveClass("session-action-card", "session-action-card-primary");
    expect(newSessionButton.querySelector("strong")).toHaveTextContent("New");
    expect(newSessionButton.querySelector("small")).toBeNull();

    const attachSessionButton = screen.getByRole("button", { name: /^Attach$/i });
    expect(attachSessionButton).toHaveClass("session-action-card");
    expect(attachSessionButton.querySelector("strong")).toHaveTextContent("Attach");
    expect(attachSessionButton.querySelector("small")).toBeNull();

    fireEvent.click(newSessionButton);
    expect(onCreate).toHaveBeenCalledTimes(1);

    fireEvent.click(attachSessionButton);
    expect(onAttach).toHaveBeenCalledTimes(1);

    expect(screen.getByRole("list", { name: "Sessions" })).toHaveClass("session-card-list");

    const sessionCard = screen.getByRole("button", { name: "Open Launch Pad" });
    const menuButton = screen.getByRole("button", { name: "More actions for Launch Pad" });
    expect(sessionCard).toHaveClass("session-card");
    expect(sessionCard.querySelector(".session-card-main")).not.toBeNull();
    expect(sessionCard.querySelector(".session-card-title-row")).not.toBeNull();
    expect(sessionCard.querySelector("h2")).toBeNull();
    expect(sessionCard.querySelector(".session-card-title")).toHaveTextContent("Launch Pad");
    expect(sessionCard).toHaveAccessibleDescription(
      "Status: running Workspace: apps/api Agent: codex Source: attached",
    );

    expect(sessionCard.querySelector(".session-chip-status")).toHaveTextContent("running");
    expect(sessionCard.querySelector(".session-chip-status")?.tagName).toBe("SPAN");
    expect(sessionCard.querySelector(".session-card-path")).toHaveTextContent("apps/api");
    expect(sessionCard.querySelector(".session-chip-row")).not.toBeNull();

    const metadataChips = Array.from(sessionCard.querySelectorAll(".session-chip-row .session-chip"));
    expect(metadataChips).toHaveLength(2);
    expect(metadataChips[0]).toHaveTextContent("codex");
    expect(metadataChips[1]).toHaveTextContent("attached");

    expect(sessionCard.querySelector(".session-runtime-id")).toBeNull();
    expect(sessionCard.querySelector(".session-card-arrow")).toBeNull();

    fireEvent.click(sessionCard);
    expect(onSelect).toHaveBeenCalledWith("sess-1");

    fireEvent.click(menuButton);
    const deleteButton = screen.getByRole("button", { name: "Delete Launch Pad" });
    fireEvent.click(deleteButton);
    expect(onDelete).toHaveBeenCalledWith("sess-1");
  });

  it("uses fallback titles and renders the empty/root warning structure when roots are unavailable", () => {
    const onCreate = vi.fn();
    const onAttach = vi.fn();
    const onSelect = vi.fn();
    const onDelete = vi.fn();

    const { rerender } = render(
      <SessionListView
        hasRoots
        sessions={[
          {
            id: "sess-2",
            agentKind: "claude",
            workspacePath: "apps/web",
          },
        ]}
        currentUser={null}
        users={[]}
        onCreateUser={vi.fn().mockResolvedValue(undefined)}
        onResetPassword={vi.fn().mockResolvedValue(undefined)}
        onDeleteUser={vi.fn().mockResolvedValue(undefined)}
        onCreate={onCreate}
        onAttach={onAttach}
        onSelect={onSelect}
        onDelete={onDelete}
      />,
    );

    const fallbackCard = screen.getByRole("button", { name: "Open web" });
    expect(fallbackCard.querySelector("h2")).toBeNull();
    expect(fallbackCard.querySelector(".session-card-title")).toHaveTextContent("web");
    expect(fallbackCard.querySelector(".session-card-path")).toHaveTextContent("apps/web");
    expect(fallbackCard).toHaveAccessibleDescription("Workspace: apps/web Agent: claude");

    const fallbackChips = Array.from(fallbackCard.querySelectorAll(".session-chip-row .session-chip"));
    expect(fallbackChips).toHaveLength(1);
    expect(fallbackChips[0]).toHaveTextContent("claude");
    expect(fallbackCard.querySelector(".session-chip-status")).toBeNull();
    expect(fallbackCard.querySelector(".session-runtime-id")).toBeNull();

    rerender(
      <SessionListView
        currentUser={null}
        hasRoots={false}
        sessions={[]}
        users={[]}
        onCreateUser={vi.fn().mockResolvedValue(undefined)}
        onResetPassword={vi.fn().mockResolvedValue(undefined)}
        onDeleteUser={vi.fn().mockResolvedValue(undefined)}
        onCreate={onCreate}
        onAttach={onAttach}
        onSelect={onSelect}
        onDelete={onDelete}
      />,
    );

    const emptyState = screen.getByText("No sessions yet").closest("section");
    expect(emptyState).toHaveClass("session-empty-card");
    expect(
      screen.getByText("Create a managed session or attach an existing runtime to get started."),
    ).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /^New$/i })).toBeDisabled();
    expect(screen.getByRole("button", { name: /^Attach$/i })).toBeDisabled();
    expect(
      screen.getByText("Add a workspace root before creating or attaching sessions."),
    ).toHaveClass("session-root-warning");
  });

  it("prompts for a replacement password before resetting an admin-managed user", () => {
    const onResetPassword = vi.fn();
    const promptSpy = vi.spyOn(window, "prompt").mockReturnValue("fresh-secret");

    render(
      <SessionListView
        currentUser={{ id: "usr_workspace", displayName: "Agent Dock", isAdmin: true }}
        hasRoots
        sessions={[]}
        users={[
          {
            id: "usr_alice",
            username: "alice",
            displayName: "Alice",
            isAdmin: false,
          },
        ]}
        onCreateUser={vi.fn().mockResolvedValue(undefined)}
        onResetPassword={onResetPassword.mockResolvedValue(undefined)}
        onDeleteUser={vi.fn().mockResolvedValue(undefined)}
        onCreate={vi.fn()}
        onAttach={vi.fn()}
        onSelect={vi.fn()}
        onDelete={vi.fn()}
      />,
    );

    fireEvent.click(screen.getByRole("button", { name: "Reset password" }));

    expect(promptSpy).toHaveBeenCalledWith("New password for alice", "");
    expect(onResetPassword).toHaveBeenCalledWith("usr_alice", "fresh-secret");

    promptSpy.mockRestore();
  });

  it("shows a user management link for admins only", () => {
    const { rerender } = render(
      <SessionListView
        currentUser={{ id: "usr_workspace", displayName: "Agent Dock", isAdmin: true }}
        hasRoots
        sessions={[]}
        users={[]}
        onCreateUser={vi.fn().mockResolvedValue(undefined)}
        onResetPassword={vi.fn().mockResolvedValue(undefined)}
        onDeleteUser={vi.fn().mockResolvedValue(undefined)}
        onCreate={vi.fn()}
        onAttach={vi.fn()}
        onSelect={vi.fn()}
        onDelete={vi.fn()}
      />,
    );

    expect(screen.getByRole("link", { name: "User management" })).toHaveAttribute(
      "href",
      "#user-management",
    );
    expect(screen.getByRole("region", { name: "User management" })).toHaveAttribute(
      "id",
      "user-management",
    );

    rerender(
      <SessionListView
        currentUser={{ id: "usr_alice", displayName: "Alice", isAdmin: false }}
        hasRoots
        sessions={[]}
        users={[]}
        onCreateUser={vi.fn().mockResolvedValue(undefined)}
        onResetPassword={vi.fn().mockResolvedValue(undefined)}
        onDeleteUser={vi.fn().mockResolvedValue(undefined)}
        onCreate={vi.fn()}
        onAttach={vi.fn()}
        onSelect={vi.fn()}
        onDelete={vi.fn()}
      />,
    );

    expect(screen.queryByRole("link", { name: "User management" })).not.toBeInTheDocument();
  });


  it("shows an inline error when the new username is blank", async () => {
    const onCreateUser = vi.fn().mockResolvedValue(undefined);

    render(
      <SessionListView
        currentUser={{ id: "usr_workspace", displayName: "Agent Dock", isAdmin: true }}
        hasRoots
        sessions={[]}
        users={[]}
        onCreateUser={onCreateUser}
        onResetPassword={vi.fn().mockResolvedValue(undefined)}
        onDeleteUser={vi.fn().mockResolvedValue(undefined)}
        onCreate={vi.fn()}
        onAttach={vi.fn()}
        onSelect={vi.fn()}
        onDelete={vi.fn()}
      />,
    );

    fireEvent.change(screen.getByLabelText("New username"), { target: { value: "   " } });
    fireEvent.change(screen.getByLabelText("New password"), { target: { value: "alice123" } });
    fireEvent.click(screen.getByRole("button", { name: "Create user" }));

    expect(await screen.findByRole("alert")).toHaveTextContent("Username is required");
    expect(onCreateUser).not.toHaveBeenCalled();
  });

  it("shows an inline error when the new password is blank", async () => {
    const onCreateUser = vi.fn().mockResolvedValue(undefined);

    render(
      <SessionListView
        currentUser={{ id: "usr_workspace", displayName: "Agent Dock", isAdmin: true }}
        hasRoots
        sessions={[]}
        users={[]}
        onCreateUser={onCreateUser}
        onResetPassword={vi.fn().mockResolvedValue(undefined)}
        onDeleteUser={vi.fn().mockResolvedValue(undefined)}
        onCreate={vi.fn()}
        onAttach={vi.fn()}
        onSelect={vi.fn()}
        onDelete={vi.fn()}
      />,
    );

    fireEvent.change(screen.getByLabelText("New username"), { target: { value: "alice" } });
    fireEvent.change(screen.getByLabelText("New password"), { target: { value: "   " } });
    fireEvent.click(screen.getByRole("button", { name: "Create user" }));

    expect(await screen.findByRole("alert")).toHaveTextContent("Password is required");
    expect(onCreateUser).not.toHaveBeenCalled();
  });

  it("shows an inline error when creating a user fails", async () => {
    render(
      <SessionListView
        currentUser={{ id: "usr_workspace", displayName: "Agent Dock", isAdmin: true }}
        hasRoots
        sessions={[]}
        users={[]}
        onCreateUser={vi.fn().mockRejectedValue(new Error("Username already taken"))}
        onResetPassword={vi.fn().mockResolvedValue(undefined)}
        onDeleteUser={vi.fn().mockResolvedValue(undefined)}
        onCreate={vi.fn()}
        onAttach={vi.fn()}
        onSelect={vi.fn()}
        onDelete={vi.fn()}
      />,
    );

    fireEvent.change(screen.getByLabelText("New username"), { target: { value: "alice" } });
    fireEvent.change(screen.getByLabelText("New password"), { target: { value: "alice123" } });
    fireEvent.click(screen.getByRole("button", { name: "Create user" }));

    expect(await screen.findByRole("alert")).toHaveTextContent("Username already taken");
  });

  it("shows an inline error when resetting a password fails", async () => {
    const promptSpy = vi.spyOn(window, "prompt").mockReturnValue("fresh-secret");

    render(
      <SessionListView
        currentUser={{ id: "usr_workspace", displayName: "Agent Dock", isAdmin: true }}
        hasRoots
        sessions={[]}
        users={[
          {
            id: "usr_alice",
            username: "alice",
            displayName: "Alice",
            isAdmin: false,
          },
        ]}
        onCreateUser={vi.fn().mockResolvedValue(undefined)}
        onResetPassword={vi.fn().mockRejectedValue(new Error("Password reset failed"))}
        onDeleteUser={vi.fn().mockResolvedValue(undefined)}
        onCreate={vi.fn()}
        onAttach={vi.fn()}
        onSelect={vi.fn()}
        onDelete={vi.fn()}
      />,
    );

    fireEvent.click(screen.getByRole("button", { name: "Reset password" }));

    expect(await screen.findByRole("alert")).toHaveTextContent("Password reset failed");
    promptSpy.mockRestore();
  });
});
