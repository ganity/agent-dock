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
  login: vi.fn().mockResolvedValue(undefined),
  listSessions: vi.fn().mockResolvedValue([]),
  createSession: vi.fn().mockResolvedValue({
    id: "sess-1",
    agentKind: "claude",
    events: [{ id: 1, eventType: "assistant.message", payload: { text: "done" } }],
  }),
  fetchSessionSnapshot: vi.fn(),
  connectEventStream: vi.fn(() => liveSocket as unknown as WebSocket),
}));

import App from "./App";
import { connectEventStream, createSession, listSessions, login } from "./api";

afterEach(() => {
  cleanup();
  vi.clearAllMocks();
  vi.mocked(listSessions).mockResolvedValue([]);
  vi.mocked(createSession).mockResolvedValue({
    id: "sess-1",
    agentKind: "claude",
    events: [{ id: 1, eventType: "assistant.message", payload: { text: "done" } }],
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
      expect(listSessions).toHaveBeenCalledTimes(1);
    });

    fireEvent.click(screen.getByRole("button", { name: "Create Claude session" }));

    await waitFor(() => {
      expect(createSession).toHaveBeenCalledWith({
        rootId: "workspace",
        path: "repo",
        agentKind: "claude",
      });
    });

    expect(await screen.findByText("Session details")).toBeInTheDocument();
    expect(screen.getByText("claude")).toBeInTheDocument();
    expect(connectEventStream).toHaveBeenCalledWith("sess-1", 1);

    liveSocket.onmessage?.({
      data: JSON.stringify({
        id: 2,
        eventType: "assistant.message",
        payload: { text: "live" },
      }),
    });

    expect(await screen.findByText("live")).toBeInTheDocument();
  });
});
