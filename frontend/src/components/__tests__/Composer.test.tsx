import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { Composer } from "../Composer";

class FakeScriptProcessorNode {
  onaudioprocess:
    | ((event: { inputBuffer: { getChannelData: (channel: number) => Float32Array } }) => void)
    | null = null;

  connect = vi.fn();
  disconnect = vi.fn();
}

class FakeMediaStreamAudioSourceNode {
  connect = vi.fn();
  disconnect = vi.fn();
}

class FakeAudioContext {
  sampleRate = 48_000;
  destination = {};

  constructor(
    private readonly sourceNode: FakeMediaStreamAudioSourceNode,
    private readonly processorNode: FakeScriptProcessorNode,
  ) {}

  createMediaStreamSource = vi.fn(() => this.sourceNode);
  createScriptProcessor = vi.fn(() => this.processorNode);
  close = vi.fn().mockResolvedValue(undefined);
}

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

describe("Composer", () => {
  it("streams voice transcripts into the message input and sends them after stop", async () => {
    const onSend = vi.fn();
    const onUploadImage = vi.fn().mockResolvedValue("/tmp/workspace/screenshot.png");
    const stream = {
      getTracks: () => [{ stop: vi.fn() }],
    } as unknown as MediaStream;
    const sourceNode = new FakeMediaStreamAudioSourceNode();
    const processorNode = new FakeScriptProcessorNode();
    const audioContext = new FakeAudioContext(sourceNode, processorNode);
    const socket = {
      send: vi.fn(),
      close: vi.fn(),
      readyState: WebSocket.OPEN,
      onmessage: null as ((event: { data: string }) => void) | null,
      onerror: null as ((event: Event) => void) | null,
      onclose: null as ((event: CloseEvent) => void) | null,
    };

    vi.stubGlobal("AudioContext", vi.fn(() => audioContext));
    vi.stubGlobal("navigator", {
      mediaDevices: {
        getUserMedia: vi.fn().mockResolvedValue(stream),
      },
    });

    render(
      <Composer
        onSend={onSend}
        onUploadImage={onUploadImage}
        onConnectVoiceInput={() => socket as unknown as WebSocket}
      />,
    );

    fireEvent.click(screen.getByRole("button", { name: "Voice input" }));

    await waitFor(() => {
      expect(navigator.mediaDevices.getUserMedia).toHaveBeenCalledWith({ audio: true });
    });

    socket.onmessage?.({ data: JSON.stringify({ type: "ready" }) });

    processorNode.onaudioprocess?.({
      inputBuffer: {
        getChannelData: () => new Float32Array([0.25, -0.25, 0.5, -0.5]),
      },
    });

    expect(socket.send).toHaveBeenCalled();

    socket.onmessage?.({ data: JSON.stringify({ type: "transcript", text: "你好，帮我总结一下" }) });

    await waitFor(() => {
      expect(screen.getByLabelText("Message")).toHaveValue("你好，帮我总结一下");
    });

    fireEvent.click(screen.getByRole("button", { name: "Stop voice input" }));

    expect(socket.send).toHaveBeenCalledWith(JSON.stringify({ type: "stop" }));

    socket.onmessage?.({ data: JSON.stringify({ type: "stopped" }) });

    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Send" })).not.toBeDisabled();
    });
    fireEvent.submit(screen.getByRole("button", { name: "Send" }).closest("form")!);

    await waitFor(() => {
      expect(onSend).toHaveBeenCalledWith("你好，帮我总结一下", []);
    });
  });
});
