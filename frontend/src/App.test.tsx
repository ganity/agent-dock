import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
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
    agentKind: "claude",
    events: [{ id: 1, eventType: "assistant.message", payload: { text: "attached" } }],
  }),
  login: vi.fn().mockResolvedValue(undefined),
  listRoots: vi.fn().mockResolvedValue([{ id: "workspace", label: "Workspace", path: "/tmp/workspace" }]),
  listSessions: vi.fn().mockResolvedValue([]),
  createSession: vi.fn().mockResolvedValue({
    id: "sess-1",
    agentKind: "codex",
    events: [{ id: 1, eventType: "assistant.message", payload: { text: "done" } }],
  }),
  fetchSessionSnapshot: vi.fn(),
  connectEventStream: vi.fn(() => liveSocket as unknown as WebSocket),
  sendSessionMessage: vi.fn().mockResolvedValue(undefined),
}));

import App from "./App";
import {
  attachSession,
  connectEventStream,
  createSession,
  listRoots,
  listSessions,
  login,
  sendSessionMessage,
} from "./api";

afterEach(() => {
  cleanup();
  vi.clearAllMocks();
  vi.mocked(listRoots).mockResolvedValue([{ id: "workspace", label: "Workspace", path: "/tmp/workspace" }]);
  vi.mocked(listSessions).mockResolvedValue([]);
  vi.mocked(createSession).mockResolvedValue({
    id: "sess-1",
    agentKind: "codex",
    events: [{ id: 1, eventType: "assistant.message", payload: { text: "done" } }],
  });
  vi.mocked(attachSession).mockResolvedValue({
    id: "sess-2",
    agentKind: "claude",
    events: [{ id: 1, eventType: "assistant.message", payload: { text: "attached" } }],
  });
  liveSocket.onmessage = null;
  liveSocket.onerror = null;
});

describe("App", () => {
  it("logs in, loads sessions, and appends a created session", async () => {
    render(<App />);

    fireEvent.change(screen.getByLabelText("PIN"), { target: { value: "1234" } });
    fireEvent.click(screen.getByRole("button", { name: "Unlock" }));

    await waitFor(() => {
      expect(login).toHaveBeenCalledWith("1234");
      expect(listRoots).toHaveBeenCalledTimes(1);
      expect(listSessions).toHaveBeenCalledTimes(1);
    });

    expect(screen.queryByLabelText("Agent")).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "New session" }));
    fireEvent.change(screen.getByLabelText("Agent"), { target: { value: "codex" } });
    fireEvent.change(screen.getByLabelText("Path"), { target: { value: "apps/api" } });
    fireEvent.click(screen.getByRole("button", { name: "Create session" }));

    await waitFor(() => {
      expect(createSession).toHaveBeenCalledWith({
        rootId: "workspace",
        path: "apps/api",
        agentKind: "codex",
      });
    });

    expect(await screen.findByText("Session details")).toBeInTheDocument();
    expect(screen.getByText("codex")).toBeInTheDocument();
    expect(connectEventStream).toHaveBeenCalledWith("sess-1", 1);

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

    fireEvent.change(screen.getByLabelText("Message"), { target: { value: "next step" } });
    fireEvent.click(screen.getByRole("button", { name: "Send" }));

    await waitFor(() => {
      expect(sendSessionMessage).toHaveBeenCalledWith("sess-1", "next step");
    });
  });

  it("opens the attach form and attaches an existing session", async () => {
    render(<App />);

    fireEvent.change(screen.getByLabelText("PIN"), { target: { value: "1234" } });
    fireEvent.click(screen.getByRole("button", { name: "Unlock" }));

    await waitFor(() => {
      expect(login).toHaveBeenCalledWith("1234");
      expect(listRoots).toHaveBeenCalledTimes(1);
      expect(listSessions).toHaveBeenCalledTimes(1);
    });

    expect(screen.queryByLabelText("Runtime session ID")).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Attach session" }));

    fireEvent.change(screen.getByLabelText("Agent"), { target: { value: "claude" } });
    fireEvent.change(screen.getByLabelText("Runtime session ID"), { target: { value: "thread-abc" } });
    fireEvent.change(screen.getByLabelText("Path"), { target: { value: "apps/web" } });
    fireEvent.click(screen.getAllByRole("button", { name: "Attach session" })[1]!);

    await waitFor(() => {
      expect(attachSession).toHaveBeenCalledWith({
        rootId: "workspace",
        path: "apps/web",
        agentKind: "claude",
        runtimeSessionId: "thread-abc",
      });
    });

    expect(await screen.findByText("Session details")).toBeInTheDocument();
    expect(screen.getByText("claude")).toBeInTheDocument();
    expect(connectEventStream).toHaveBeenCalledWith("sess-2", 1);
  });
});
