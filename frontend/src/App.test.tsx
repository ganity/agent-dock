import { cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";

const liveSocket = vi.hoisted(() => {
  const socket = {
    onmessage: null as ((event: { data: string }) => void) | null,
    onerror: null as ((event: Event) => void) | null,
    close: vi.fn(),
  };

  return socket;
});

vi.mock("./api", () => ({
  attachSession: vi.fn().mockResolvedValue({
    id: "sess-2",
    title: null,
    agentKind: "claude",
    sourceKind: "attached",
    runtimeSessionId: "thread-abc",
    workspacePath: "apps/web",
    status: "running",
    events: [{ id: 1, eventType: "assistant.message", payload: { text: "attached" } }],
  }),
  listDirectories: vi.fn().mockResolvedValue({
    currentPath: "/tmp/workspace",
    parentPath: "/tmp",
    directories: [
      { name: "apps", path: "/tmp/workspace/apps" },
      { name: "repo", path: "/tmp/workspace/repo" },
    ],
  }),
  listResumeCandidates: vi.fn().mockResolvedValue([]),
  resumeSession: vi.fn().mockResolvedValue({
    id: "sess-1",
    title: "Launch Pad",
    agentKind: "codex",
    sourceKind: "managed",
    workspacePath: "apps/api",
    status: "running",
    hasMoreHistory: false,
    events: [{ id: 1, eventType: "session.status.changed", payload: { status: "running" } }],
  }),
  restoreSession: vi.fn().mockRejectedValue(new Error("UNAUTHORIZED")),
  login: vi.fn().mockResolvedValue({ id: "usr_workspace", displayName: "Agent Dock", isAdmin: true }),
  listRoots: vi.fn().mockResolvedValue([{ id: "workspace", label: "Workspace", path: "/tmp/workspace" }]),
  listSessions: vi.fn().mockResolvedValue([]),
  listUsers: vi.fn().mockResolvedValue([
    { id: "usr_workspace", username: "admin", displayName: "Agent Dock", isAdmin: true },
  ]),
  createUser: vi.fn().mockResolvedValue({
    id: "usr_alice",
    username: "alice",
    displayName: "Alice",
    isAdmin: false,
  }),
  resetUserPassword: vi.fn().mockResolvedValue(undefined),
  deleteUser: vi.fn().mockResolvedValue(undefined),
  deleteSession: vi.fn().mockResolvedValue(undefined),
  connectVoiceInput: vi.fn(),
  createSession: vi.fn().mockResolvedValue({
    id: "sess-1",
    title: "Launch Pad",
    agentKind: "codex",
    hasMoreHistory: false,
    events: [{ id: 1, eventType: "assistant.message", payload: { text: "done" } }],
  }),
  fetchSessionSnapshot: vi.fn().mockResolvedValue({
    id: "sess-1",
    title: "Launch Pad",
    agentKind: "codex",
    sourceKind: "managed",
    workspacePath: "apps/api",
    status: "running",
    hasMoreHistory: true,
    events: [
      { id: 101, eventType: "user.message", payload: { text: "older" } },
      { id: 102, eventType: "assistant.message", payload: { text: "newest" } },
    ],
  }),
  connectSessionEvents: vi.fn(() => liveSocket as unknown as WebSocket),
  sendSessionMessage: vi.fn().mockResolvedValue(undefined),
  uploadSessionAttachment: vi.fn().mockResolvedValue("/tmp/workspace/screenshot.png"),
}));

import App from "./App";
import {
  attachSession,
  connectSessionEvents,
  connectVoiceInput,
  createSession,
  createUser,
  deleteSession,
  deleteUser,
  fetchSessionSnapshot,
  listDirectories,
  listResumeCandidates,
  listRoots,
  listSessions,
  listUsers,
  login,
  resetUserPassword,
  resumeSession,
  restoreSession,
  sendSessionMessage,
  uploadSessionAttachment,
} from "./api";

afterEach(() => {
  cleanup();
  vi.clearAllMocks();
  vi.mocked(restoreSession).mockRejectedValue(new Error("UNAUTHORIZED"));
  vi.mocked(login).mockResolvedValue({ id: "usr_workspace", displayName: "Agent Dock", isAdmin: true });
  vi.mocked(listRoots).mockResolvedValue([{ id: "workspace", label: "Workspace", path: "/tmp/workspace" }]);
  vi.mocked(listSessions).mockResolvedValue([]);
  vi.mocked(listUsers).mockResolvedValue([
    { id: "usr_workspace", username: "admin", displayName: "Agent Dock", isAdmin: true },
  ]);
  vi.mocked(deleteSession).mockResolvedValue(undefined);
  vi.mocked(createUser).mockResolvedValue({
    id: "usr_alice",
    username: "alice",
    displayName: "Alice",
    isAdmin: false,
  });
  vi.mocked(resetUserPassword).mockResolvedValue(undefined);
  vi.mocked(deleteUser).mockResolvedValue(undefined);
  vi.mocked(connectVoiceInput).mockReturnValue({ close: vi.fn() } as unknown as WebSocket);
  vi.mocked(createSession).mockResolvedValue({
    id: "sess-1",
    title: "Launch Pad",
    agentKind: "codex",
    hasMoreHistory: false,
    events: [{ id: 1, eventType: "assistant.message", payload: { text: "done" } }],
  });
  vi.mocked(fetchSessionSnapshot).mockResolvedValue({
    id: "sess-1",
    title: "Launch Pad",
    agentKind: "codex",
    sourceKind: "managed",
    workspacePath: "apps/api",
    status: "running",
    hasMoreHistory: true,
    events: [
      { id: 101, eventType: "user.message", payload: { text: "older" } },
      { id: 102, eventType: "assistant.message", payload: { text: "newest" } },
    ],
  });
  vi.mocked(attachSession).mockResolvedValue({
    id: "sess-2",
    title: null,
    agentKind: "claude",
    sourceKind: "attached",
    runtimeSessionId: "thread-abc",
    workspacePath: "apps/web",
    status: "running",
    events: [{ id: 1, eventType: "assistant.message", payload: { text: "attached" } }],
  });
  vi.mocked(listDirectories).mockResolvedValue({
    currentPath: "/tmp/workspace",
    parentPath: "/tmp",
    directories: [
      { name: "apps", path: "/tmp/workspace/apps" },
      { name: "repo", path: "/tmp/workspace/repo" },
    ],
  });
  vi.mocked(listResumeCandidates).mockResolvedValue([]);
  vi.mocked(resumeSession).mockResolvedValue({
    id: "sess-1",
    title: "Launch Pad",
    agentKind: "codex",
    sourceKind: "managed",
    workspacePath: "apps/api",
    status: "running",
    hasMoreHistory: false,
    events: [{ id: 1, eventType: "session.status.changed", payload: { status: "running" } }],
  });
  vi.mocked(uploadSessionAttachment).mockResolvedValue("/tmp/workspace/screenshot.png");
  liveSocket.onmessage = null;
  liveSocket.onerror = null;
});

describe("App", () => {
  it("restores an existing authenticated session on first render", async () => {
    vi.mocked(restoreSession).mockResolvedValueOnce({
      id: "usr_workspace",
      displayName: "Agent Dock",
      isAdmin: true,
    });
    vi.mocked(listSessions).mockResolvedValueOnce([
      {
        id: "sess-1",
        title: "Launch Pad",
        agentKind: "codex",
        sourceKind: "managed",
        workspacePath: "apps/api",
        status: "running",
      },
    ]);

    render(<App />);

    await waitFor(() => {
      expect(restoreSession).toHaveBeenCalledTimes(1);
      expect(listRoots).toHaveBeenCalledTimes(1);
      expect(listSessions).toHaveBeenCalledTimes(1);
    });

    expect(login).not.toHaveBeenCalled();
    expect(screen.queryByRole("button", { name: "Sign in" })).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Open Launch Pad" })).toBeInTheDocument();
    expect(screen.getByRole("region", { name: "User management" })).toBeInTheDocument();
  });

  it("deletes a session from the list after confirmation", async () => {
    const confirmSpy = vi.spyOn(window, "confirm").mockReturnValue(true);
    const alertSpy = vi.spyOn(window, "alert").mockImplementation(() => {});
    vi.mocked(listSessions).mockResolvedValueOnce([
      {
        id: "sess-1",
        title: "Launch Pad",
        agentKind: "codex",
        sourceKind: "managed",
        workspacePath: "apps/api",
        status: "running",
      },
    ]);

    render(<App />);

    fireEvent.change(await screen.findByLabelText("Username"), { target: { value: "admin" } });
    fireEvent.change(screen.getByLabelText("Password"), { target: { value: "1234" } });
    fireEvent.click(screen.getByRole("button", { name: "Sign in" }));

    await waitFor(() => {
      expect(login).toHaveBeenCalledWith("admin", "1234");
      expect(listSessions).toHaveBeenCalledTimes(1);
    });

    fireEvent.click(screen.getByRole("button", { name: "More actions for Launch Pad" }));
    fireEvent.click(screen.getByRole("button", { name: "Delete Launch Pad" }));

    await waitFor(() => {
      expect(deleteSession).toHaveBeenCalledWith("sess-1");
    });
    await waitFor(() => {
      expect(screen.queryByRole("button", { name: "Open Launch Pad" })).not.toBeInTheDocument();
    });

    confirmSpy.mockRestore();
    alertSpy.mockRestore();
  });

  it("logs in, loads sessions, and appends a created session", async () => {
    render(<App />);

    fireEvent.change(await screen.findByLabelText("Username"), { target: { value: "admin" } });
    fireEvent.change(screen.getByLabelText("Password"), { target: { value: "1234" } });
    fireEvent.click(screen.getByRole("button", { name: "Sign in" }));

    await waitFor(() => {
      expect(login).toHaveBeenCalledWith("admin", "1234");
      expect(listRoots).toHaveBeenCalledTimes(1);
      expect(listSessions).toHaveBeenCalledTimes(1);
      expect(listUsers).toHaveBeenCalledTimes(1);
    });

    expect(screen.queryByLabelText("Agent")).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: /^New$/i }));
    const dialog = screen.getByRole("dialog", { name: "New session" });

    fireEvent.click(within(dialog).getByRole("button", { name: "Browse directories" }));

    await waitFor(() => {
      expect(listDirectories).toHaveBeenCalledWith("/tmp/workspace");
    });

    fireEvent.click(within(dialog).getByRole("button", { name: "repo" }));

    fireEvent.change(within(dialog).getByLabelText("Session name"), { target: { value: "Launch Pad" } });
    fireEvent.change(within(dialog).getByLabelText("Agent"), { target: { value: "codex" } });
    fireEvent.change(within(dialog).getByLabelText("Path"), { target: { value: "/tmp/workspace/apps/api" } });
    fireEvent.click(within(dialog).getByRole("button", { name: "Create session" }));

    await waitFor(() => {
      expect(createSession).toHaveBeenCalledWith({
        title: "Launch Pad",
        rootId: "workspace",
        path: "/tmp/workspace/apps/api",
        agentKind: "codex",
      });
    });

    expect(await screen.findByRole("button", { name: "Session details" })).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Launch Pad" })).toBeInTheDocument();
    expect(connectSessionEvents).toHaveBeenCalledWith("sess-1", 1);

    liveSocket.onmessage?.({
      data: JSON.stringify({
        id: 2,
        eventType: "assistant.message",
        payload: { text: "live" },
      }),
    });

    await waitFor(() => {
      expect(screen.getAllByText("donelive")).not.toHaveLength(0);
    });

    liveSocket.onmessage?.({
      data: JSON.stringify({
        id: 3,
        eventType: "session.status.changed",
        payload: { status: "suspended" },
      }),
    });

    await waitFor(() => {
      expect(document.querySelector(".session-status-pill")).toHaveTextContent("suspended");
    });

    fireEvent.change(screen.getByLabelText("Message"), { target: { value: "next step" } });
    fireEvent.click(screen.getByRole("button", { name: "Send" }));

    await waitFor(() => {
      expect(sendSessionMessage).toHaveBeenCalledWith("sess-1", "next step", []);
    });
  });

  it("loads only the latest detail window when opening a session", async () => {
    vi.mocked(listSessions).mockResolvedValueOnce([
      {
        id: "sess-1",
        title: "Launch Pad",
        agentKind: "codex",
        sourceKind: "managed",
        workspacePath: "apps/api",
        status: "running",
      },
    ]);

    render(<App />);

    fireEvent.change(await screen.findByLabelText("Username"), { target: { value: "admin" } });
    fireEvent.change(screen.getByLabelText("Password"), { target: { value: "1234" } });
    fireEvent.click(screen.getByRole("button", { name: "Sign in" }));

    await waitFor(() => {
      expect(listSessions).toHaveBeenCalledTimes(1);
    });

    fireEvent.click(screen.getByRole("button", { name: "Open Launch Pad" }));

    await waitFor(() => {
      expect(fetchSessionSnapshot).toHaveBeenCalledWith("sess-1", { limit: 50 });
    });
  });

  it("resumes a suspended session before opening details", async () => {
    vi.mocked(listSessions).mockResolvedValueOnce([
      {
        id: "sess-1",
        title: "Launch Pad",
        agentKind: "codex",
        sourceKind: "managed",
        workspacePath: "apps/api",
        runtimeSessionId: "thread-1",
        status: "suspended",
      },
    ]);
    vi.mocked(resumeSession).mockResolvedValueOnce({
      id: "sess-1",
      title: "Launch Pad",
      agentKind: "codex",
      sourceKind: "managed",
      workspacePath: "apps/api",
      runtimeSessionId: "thread-1",
      status: "running",
      hasMoreHistory: false,
      events: [{ id: 7, eventType: "session.status.changed", payload: { status: "running" } }],
    });

    render(<App />);

    fireEvent.change(await screen.findByLabelText("Username"), { target: { value: "admin" } });
    fireEvent.change(screen.getByLabelText("Password"), { target: { value: "1234" } });
    fireEvent.click(screen.getByRole("button", { name: "Sign in" }));

    await waitFor(() => {
      expect(listSessions).toHaveBeenCalledTimes(1);
    });

    fireEvent.click(screen.getByRole("button", { name: "Open Launch Pad" }));

    await waitFor(() => {
      expect(resumeSession).toHaveBeenCalledWith("sess-1");
    });
    expect(fetchSessionSnapshot).not.toHaveBeenCalledWith("sess-1", { limit: 50 });
    expect(await screen.findByRole("button", { name: "Session details" })).toBeInTheDocument();
    expect(connectSessionEvents).toHaveBeenCalledWith("sess-1", 7);
  });

  it("refreshes the session list when returning from a session detail", async () => {
    vi.mocked(listSessions)
      .mockResolvedValueOnce([
        {
          id: "sess-1",
          title: "Launch Pad",
          agentKind: "codex",
          sourceKind: "managed",
          workspacePath: "apps/api",
          status: "running",
        },
      ])
      .mockResolvedValueOnce([
        {
          id: "sess-1",
          title: "Launch Pad",
          agentKind: "codex",
          sourceKind: "managed",
          workspacePath: "apps/api",
          status: "idle",
        },
        {
          id: "sess-2",
          title: "Fresh Session",
          agentKind: "claude",
          sourceKind: "attached",
          workspacePath: "apps/web",
          status: "running",
        },
      ]);

    render(<App />);

    fireEvent.change(await screen.findByLabelText("Username"), { target: { value: "admin" } });
    fireEvent.change(screen.getByLabelText("Password"), { target: { value: "1234" } });
    fireEvent.click(screen.getByRole("button", { name: "Sign in" }));

    await waitFor(() => {
      expect(listSessions).toHaveBeenCalledTimes(1);
    });

    fireEvent.click(screen.getByRole("button", { name: "Open Launch Pad" }));
    expect(await screen.findByRole("button", { name: "Session details" })).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Back" }));

    await waitFor(() => {
      expect(listSessions).toHaveBeenCalledTimes(2);
    });
    expect(await screen.findByRole("button", { name: "Open Fresh Session" })).toBeInTheDocument();
    expect(screen.getByText("idle")).toBeInTheDocument();
  });

  it("loads resume candidates from the agent when requested in the attach menu", async () => {
    vi.mocked(listResumeCandidates).mockResolvedValueOnce([
      {
        title: "Fresh Session",
        agentKind: "claude",
        runtimeSessionId: "thread-fresh",
        workspacePath: "/tmp/workspace/apps/fresh",
        status: "idle",
      },
    ]);
    render(<App />);

    fireEvent.change(await screen.findByLabelText("Username"), { target: { value: "admin" } });
    fireEvent.change(screen.getByLabelText("Password"), { target: { value: "1234" } });
    fireEvent.click(screen.getByRole("button", { name: "Sign in" }));

    await waitFor(() => {
      expect(listSessions).toHaveBeenCalledTimes(1);
    });

    fireEvent.click(screen.getByRole("button", { name: /^Attach$/i }));
    fireEvent.change(screen.getByLabelText("Agent"), { target: { value: "claude" } });
    fireEvent.change(screen.getByLabelText("Path"), { target: { value: "/tmp/workspace/apps/fresh" } });
    fireEvent.click(screen.getByRole("button", { name: "Load resume sessions" }));

    await waitFor(() => {
      expect(listResumeCandidates).toHaveBeenCalledWith({
        rootId: "workspace",
        agentKind: "claude",
        path: "/tmp/workspace/apps/fresh",
      });
    });
    expect(await screen.findByRole("button", { name: "Use Fresh Session" })).toBeInTheDocument();
  });

  it("refreshes workspace roots when opening the create menu", async () => {
    vi.mocked(listRoots)
      .mockResolvedValueOnce([{ id: "workspace", label: "Workspace", path: "/tmp/workspace" }])
      .mockResolvedValueOnce([
        { id: "workspace", label: "Workspace", path: "/tmp/workspace" },
        { id: "fresh", label: "Fresh Workspace", path: "/tmp/fresh" },
      ]);

    render(<App />);

    fireEvent.change(await screen.findByLabelText("Username"), { target: { value: "admin" } });
    fireEvent.change(screen.getByLabelText("Password"), { target: { value: "1234" } });
    fireEvent.click(screen.getByRole("button", { name: "Sign in" }));

    await waitFor(() => {
      expect(listRoots).toHaveBeenCalledTimes(1);
    });

    fireEvent.click(screen.getByRole("button", { name: /^New$/i }));

    await waitFor(() => {
      expect(listRoots).toHaveBeenCalledTimes(2);
    });
    expect(await screen.findByRole("option", { name: "Fresh Workspace" })).toBeInTheDocument();
  });

  it("keeps the attach menu open and reports background refresh failures", async () => {
    const alertSpy = vi.spyOn(window, "alert").mockImplementation(() => {});
    vi.mocked(listSessions).mockResolvedValueOnce([]).mockRejectedValueOnce(new Error("Refresh exploded"));

    render(<App />);

    fireEvent.change(await screen.findByLabelText("Username"), { target: { value: "admin" } });
    fireEvent.change(screen.getByLabelText("Password"), { target: { value: "1234" } });
    fireEvent.click(screen.getByRole("button", { name: "Sign in" }));

    await waitFor(() => {
      expect(listSessions).toHaveBeenCalledTimes(1);
    });

    fireEvent.click(screen.getByRole("button", { name: /^Attach$/i }));

    expect(screen.getByRole("dialog", { name: "Attach session" })).toBeInTheDocument();
    await waitFor(() => {
      expect(alertSpy).toHaveBeenCalledWith("Refresh exploded");
    });

    alertSpy.mockRestore();
  });

  it("uploads selected images and sends returned image paths with the message", async () => {
    render(<App />);

    fireEvent.change(await screen.findByLabelText("Username"), { target: { value: "admin" } });
    fireEvent.change(screen.getByLabelText("Password"), { target: { value: "1234" } });
    fireEvent.click(screen.getByRole("button", { name: "Sign in" }));

    await waitFor(() => {
      expect(login).toHaveBeenCalledWith("admin", "1234");
    });

    fireEvent.click(screen.getByRole("button", { name: /^New$/i }));
    fireEvent.change(screen.getByLabelText("Session name"), { target: { value: "Launch Pad" } });
    fireEvent.click(screen.getByRole("button", { name: "Create session" }));

    await screen.findByRole("button", { name: "Session details" });

    const file = new File(["image"], "screenshot.png", { type: "image/png" });
    vi.mocked(uploadSessionAttachment).mockResolvedValue("/tmp/workspace/uploaded-screenshot.png");

    fireEvent.change(screen.getByLabelText("Image attachments"), {
      target: { files: [file] },
    });

    await waitFor(() => {
      expect(uploadSessionAttachment).toHaveBeenCalledWith("sess-1", file);
    });
    expect(await screen.findByText("screenshot.png")).toBeInTheDocument();

    fireEvent.change(screen.getByLabelText("Message"), { target: { value: "explain this UI" } });
    fireEvent.click(screen.getByRole("button", { name: "Send" }));

    await waitFor(() => {
      expect(sendSessionMessage).toHaveBeenCalledWith("sess-1", "explain this UI", [
        "/tmp/workspace/uploaded-screenshot.png",
      ]);
    });
  });

  it("opens the attach form and attaches a selected real resume candidate", async () => {
    vi.mocked(listResumeCandidates).mockResolvedValueOnce([
      {
        title: null,
        agentKind: "claude",
        runtimeSessionId: "thread-abc",
        workspacePath: "apps/web",
        status: "idle",
      },
    ]);

    render(<App />);

    fireEvent.change(await screen.findByLabelText("Username"), { target: { value: "admin" } });
    fireEvent.change(screen.getByLabelText("Password"), { target: { value: "1234" } });
    fireEvent.click(screen.getByRole("button", { name: "Sign in" }));

    await waitFor(() => {
      expect(login).toHaveBeenCalledWith("admin", "1234");
      expect(listRoots).toHaveBeenCalledTimes(1);
      expect(listSessions).toHaveBeenCalledTimes(1);
    });

    expect(screen.queryByLabelText("Runtime session ID")).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: /^Attach$/i }));
    const dialog = screen.getByRole("dialog", { name: "Attach session" });

    fireEvent.change(within(dialog).getByLabelText("Agent"), { target: { value: "claude" } });
    fireEvent.change(within(dialog).getByLabelText("Path"), { target: { value: "apps/web" } });
    fireEvent.click(within(dialog).getByRole("button", { name: "Load resume sessions" }));
    fireEvent.click(await within(dialog).findByRole("button", { name: /Use web/i }));
    fireEvent.click(within(dialog).getByRole("button", { name: "Attach session" }));

    await waitFor(() => {
      expect(attachSession).toHaveBeenCalledWith({
        rootId: "workspace",
        path: "apps/web",
        agentKind: "claude",
        runtimeSessionId: "thread-abc",
      });
    });

    expect(await screen.findByRole("button", { name: "Session details" })).toBeInTheDocument();
    expect(screen.getByText("web")).toBeInTheDocument();
    expect(connectSessionEvents).toHaveBeenCalledWith("sess-2", 1);
  });

  it("keeps the create modal open and shows inline error text when create fails", async () => {
    vi.mocked(createSession).mockRejectedValueOnce(new Error("Create exploded"));

    render(<App />);

    fireEvent.change(await screen.findByLabelText("Username"), { target: { value: "admin" } });
    fireEvent.change(screen.getByLabelText("Password"), { target: { value: "1234" } });
    fireEvent.click(screen.getByRole("button", { name: "Sign in" }));

    await waitFor(() => {
      expect(login).toHaveBeenCalledWith("admin", "1234");
      expect(listRoots).toHaveBeenCalledTimes(1);
      expect(listSessions).toHaveBeenCalledTimes(1);
    });

    fireEvent.click(screen.getByRole("button", { name: /^New$/i }));
    const dialog = screen.getByRole("dialog", { name: "New session" });

    fireEvent.change(within(dialog).getByLabelText("Session name"), { target: { value: "Launch Pad" } });
    fireEvent.click(within(dialog).getByRole("button", { name: "Create session" }));

    await waitFor(() => {
      expect(createSession).toHaveBeenCalledWith({
        title: "Launch Pad",
        rootId: "workspace",
        path: "/tmp/workspace",
        agentKind: "codex",
      });
    });

    expect(await within(dialog).findByText("Create exploded")).toBeInTheDocument();
    expect(screen.getByRole("dialog", { name: "New session" })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Session details" })).not.toBeInTheDocument();
  });

  it("keeps the attach modal open and shows inline error text when attach fails", async () => {
    vi.mocked(attachSession).mockRejectedValueOnce(new Error("Attach exploded"));

    render(<App />);

    fireEvent.change(await screen.findByLabelText("Username"), { target: { value: "admin" } });
    fireEvent.change(screen.getByLabelText("Password"), { target: { value: "1234" } });
    fireEvent.click(screen.getByRole("button", { name: "Sign in" }));

    await waitFor(() => {
      expect(login).toHaveBeenCalledWith("admin", "1234");
      expect(listRoots).toHaveBeenCalledTimes(1);
      expect(listSessions).toHaveBeenCalledTimes(1);
    });

    fireEvent.click(screen.getByRole("button", { name: /^Attach$/i }));
    const dialog = screen.getByRole("dialog", { name: "Attach session" });

    fireEvent.change(within(dialog).getByLabelText("Runtime session ID"), {
      target: { value: "thread-abc" },
    });
    fireEvent.change(within(dialog).getByLabelText("Path"), { target: { value: "apps/web" } });
    fireEvent.click(within(dialog).getByRole("button", { name: "Attach session" }));

    await waitFor(() => {
      expect(attachSession).toHaveBeenCalledWith({
        rootId: "workspace",
        path: "apps/web",
        agentKind: "codex",
        runtimeSessionId: "thread-abc",
      });
    });

    expect(await within(dialog).findByText("Attach exploded")).toBeInTheDocument();
    expect(screen.getByRole("dialog", { name: "Attach session" })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Session details" })).not.toBeInTheDocument();
  });

  it("clears stale create errors when switching to the attach modal", async () => {
    vi.mocked(createSession).mockRejectedValueOnce(new Error("Create exploded"));

    render(<App />);

    fireEvent.change(await screen.findByLabelText("Username"), { target: { value: "admin" } });
    fireEvent.change(screen.getByLabelText("Password"), { target: { value: "1234" } });
    fireEvent.click(screen.getByRole("button", { name: "Sign in" }));

    await waitFor(() => {
      expect(login).toHaveBeenCalledWith("admin", "1234");
    });

    fireEvent.click(screen.getByRole("button", { name: /^New$/i }));
    const createDialog = screen.getByRole("dialog", { name: "New session" });
    fireEvent.change(within(createDialog).getByLabelText("Session name"), {
      target: { value: "Launch Pad" },
    });
    fireEvent.click(within(createDialog).getByRole("button", { name: "Create session" }));
    expect(await within(createDialog).findByText("Create exploded")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: /^Attach$/i }));
    const attachDialog = screen.getByRole("dialog", { name: "Attach session" });

    expect(within(attachDialog).queryByText("Create exploded")).not.toBeInTheDocument();
    expect(screen.queryByRole("dialog", { name: "New session" })).not.toBeInTheDocument();
  });

  it("shows the admin-only user management panel after an admin login", async () => {
    render(<App />);

    fireEvent.change(await screen.findByLabelText("Username"), { target: { value: "admin" } });
    fireEvent.change(screen.getByLabelText("Password"), { target: { value: "1234" } });
    fireEvent.click(screen.getByRole("button", { name: "Sign in" }));

    await waitFor(() => {
      expect(login).toHaveBeenCalledWith("admin", "1234");
      expect(listUsers).toHaveBeenCalledTimes(1);
    });

    expect(await screen.findByRole("region", { name: "User management" })).toBeInTheDocument();
    expect(screen.getByText("Agent Dock")).toBeInTheDocument();
    expect(screen.getAllByText("admin").length).toBeGreaterThan(0);
  });
});
