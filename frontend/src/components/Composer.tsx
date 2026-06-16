import { useEffect, useRef, useState } from "react";

interface ImageAttachment {
  name: string;
  path: string;
}

interface CommandSuggestion {
  command: string;
  description: string;
}

type VoiceState = "idle" | "connecting" | "listening" | "stopping";

const COMMAND_SUGGESTIONS: CommandSuggestion[] = [
  { command: "/resume", description: "Resume an existing session" },
  { command: "/model", description: "Pick a model for the next turn" },
  { command: "$skills", description: "Show available skills" },
];

export function Composer(props: {
  onSend: (message: string, imagePaths: string[]) => void;
  onUploadImage: (file: File) => Promise<string>;
  onConnectVoiceInput: () => WebSocket;
}) {
  const [value, setValue] = useState("");
  const [attachments, setAttachments] = useState<ImageAttachment[]>([]);
  const [uploading, setUploading] = useState(false);
  const [uploadError, setUploadError] = useState<string | null>(null);
  const [voiceError, setVoiceError] = useState<string | null>(null);
  const [voiceState, setVoiceState] = useState<VoiceState>("idle");
  const [activeSuggestionIndex, setActiveSuggestionIndex] = useState(0);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const voiceSocketRef = useRef<WebSocket | null>(null);
  const voiceStreamRef = useRef<MediaStream | null>(null);
  const audioContextRef = useRef<AudioContext | null>(null);
  const audioSourceRef = useRef<MediaStreamAudioSourceNode | null>(null);
  const audioProcessorRef = useRef<ScriptProcessorNode | null>(null);
  const voiceBaseValueRef = useRef("");
  const voiceStateRef = useRef<VoiceState>("idle");

  const canSend = (value.trim().length > 0 || attachments.length > 0) && !uploading && voiceState === "idle";
  const normalizedValue = value.trimStart();
  const showSuggestions = normalizedValue.startsWith("/") || normalizedValue.startsWith("$");
  const suggestions = COMMAND_SUGGESTIONS.filter((suggestion) =>
    suggestion.command.startsWith(normalizedValue || "/"),
  );
  const voiceStatus =
    voiceState === "connecting"
      ? "Connecting microphone..."
      : voiceState === "listening"
        ? "Listening..."
        : voiceState === "stopping"
          ? "Finishing transcript..."
          : null;

  useEffect(() => {
    return () => {
      stopVoiceCapture();
      voiceSocketRef.current?.close();
      voiceSocketRef.current = null;
    };
  }, []);

  function applySuggestion(suggestion: CommandSuggestion): void {
    setValue(`${suggestion.command} `);
    setActiveSuggestionIndex(0);
  }

  function updateVoiceState(nextState: VoiceState) {
    voiceStateRef.current = nextState;
    setVoiceState(nextState);
  }

  function stopVoiceCapture() {
    audioProcessorRef.current?.disconnect();
    audioSourceRef.current?.disconnect();
    const audioContext = audioContextRef.current;
    if (audioContext) {
      void audioContext.close().catch(() => {});
    }
    voiceStreamRef.current?.getTracks().forEach((track) => track.stop());
    audioProcessorRef.current = null;
    audioSourceRef.current = null;
    audioContextRef.current = null;
    voiceStreamRef.current = null;
  }

  function finishVoiceInput() {
    stopVoiceCapture();
    voiceSocketRef.current?.close();
    voiceSocketRef.current = null;
    updateVoiceState("idle");
  }

  function handleVoiceMessage(rawData: string) {
    const message = parseVoiceMessage(rawData);
    if (!message) {
      return;
    }

    if (message.type === "ready") {
      beginVoiceCapture();
      return;
    }

    if (message.type === "transcript" && typeof message.text === "string") {
      setValue(mergeVoiceTranscript(voiceBaseValueRef.current, message.text));
      return;
    }

    if (message.type === "stopped") {
      finishVoiceInput();
      return;
    }

    if (message.type === "error") {
      stopVoiceCapture();
      voiceSocketRef.current?.close();
      voiceSocketRef.current = null;
      updateVoiceState("idle");
      setVoiceError(
        typeof message.message === "string" && message.message.length > 0
          ? message.message
          : "Voice input failed",
      );
    }
  }

  function beginVoiceCapture() {
    const AudioContextClass = resolveAudioContext();
    const stream = voiceStreamRef.current;
    const socket = voiceSocketRef.current;
    if (!AudioContextClass || !stream || !socket) {
      setVoiceError("Voice input is unavailable in this browser");
      finishVoiceInput();
      return;
    }

    const audioContext = new AudioContextClass();
    const source = audioContext.createMediaStreamSource(stream);
    const processor = audioContext.createScriptProcessor(4096, 1, 1);

    processor.onaudioprocess = (event) => {
      if (voiceStateRef.current !== "listening") {
        return;
      }

      const currentSocket = voiceSocketRef.current;
      if (!currentSocket || currentSocket.readyState !== WebSocket.OPEN) {
        return;
      }

      const pcm = downsampleBuffer(event.inputBuffer.getChannelData(0), audioContext.sampleRate, 16_000);
      if (pcm.byteLength === 0) {
        return;
      }

      currentSocket.send(pcm.buffer.slice(pcm.byteOffset, pcm.byteOffset + pcm.byteLength));
    };

    source.connect(processor);
    processor.connect(audioContext.destination);

    audioContextRef.current = audioContext;
    audioSourceRef.current = source;
    audioProcessorRef.current = processor;
    updateVoiceState("listening");
  }

  async function startVoiceInput() {
    const AudioContextClass = resolveAudioContext();
    if (!navigator.mediaDevices?.getUserMedia || !AudioContextClass) {
      setVoiceError("Voice input is unavailable in this browser");
      return;
    }

    setVoiceError(null);
    updateVoiceState("connecting");
    voiceBaseValueRef.current = value;

    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      const socket = props.onConnectVoiceInput();
      voiceStreamRef.current = stream;
      voiceSocketRef.current = socket;
      socket.onmessage = (event) => {
        if (typeof event.data === "string") {
          handleVoiceMessage(event.data);
        }
      };
      socket.onerror = () => {
        stopVoiceCapture();
        voiceSocketRef.current = null;
        updateVoiceState("idle");
        setVoiceError("Voice input failed");
      };
      socket.onclose = () => {
        stopVoiceCapture();
        voiceSocketRef.current = null;
        updateVoiceState("idle");
      };
    } catch {
      stopVoiceCapture();
      voiceSocketRef.current?.close();
      voiceSocketRef.current = null;
      updateVoiceState("idle");
      setVoiceError("Microphone access failed");
    }
  }

  function stopVoiceInput() {
    stopVoiceCapture();
    const socket = voiceSocketRef.current;
    if (!socket || socket.readyState !== WebSocket.OPEN) {
      finishVoiceInput();
      return;
    }

    updateVoiceState("stopping");
    socket.send(JSON.stringify({ type: "stop" }));
  }

  return (
    <form
      className="composer"
      onSubmit={(event) => {
        event.preventDefault();
        if (!canSend) return;
        props.onSend(
          value,
          attachments.map((attachment) => attachment.path),
        );
        setValue("");
        setAttachments([]);
      }}
    >
      <input
        ref={fileInputRef}
        aria-label="Image attachments"
        className="composer-file-input"
        type="file"
        accept="image/*"
        onChange={(event) => {
          const file = event.currentTarget.files?.[0];
          event.currentTarget.value = "";
          if (!file) return;

          setUploading(true);
          setUploadError(null);
          void props
            .onUploadImage(file)
            .then((path) => {
              setAttachments((current) => [...current, { name: file.name, path }]);
            })
            .catch(() => {
              setUploadError("Image upload failed");
            })
            .finally(() => {
              setUploading(false);
            });
        }}
      />
      <button
        className="composer-icon-button"
        type="button"
        aria-label="Attach file"
        onClick={() => fileInputRef.current?.click()}
      >
        <svg aria-hidden="true" viewBox="0 0 24 24">
          <path d="M12 5v14" />
          <path d="M5 12h14" />
        </svg>
      </button>
      <div className="composer-main">
        {attachments.length > 0 ? (
          <ul className="composer-attachments" aria-label="Selected image attachments">
            {attachments.map((attachment) => (
              <li key={attachment.path}>{attachment.name}</li>
            ))}
          </ul>
        ) : null}
        {uploading ? <p className="composer-uploading">Uploading image...</p> : null}
        {uploadError ? <p className="composer-uploading">{uploadError}</p> : null}
        {voiceStatus ? <p className="composer-uploading">{voiceStatus}</p> : null}
        {voiceError ? <p className="composer-uploading">{voiceError}</p> : null}
        <textarea
          aria-label="Message"
          className="input composer-input"
          placeholder="提问或描述任务..."
          rows={1}
          readOnly={voiceState !== "idle"}
          value={value}
          onChange={(event) => {
            setValue(event.target.value);
            setActiveSuggestionIndex(0);
          }}
          onKeyDown={(event) => {
            if (!showSuggestions || suggestions.length === 0) {
              return;
            }

            if (event.key === "ArrowDown") {
              event.preventDefault();
              setActiveSuggestionIndex((current) => (current + 1) % suggestions.length);
              return;
            }

            if (event.key === "ArrowUp") {
              event.preventDefault();
              setActiveSuggestionIndex((current) => (current - 1 + suggestions.length) % suggestions.length);
              return;
            }

            if (event.key === "Enter") {
              event.preventDefault();
              applySuggestion(suggestions[activeSuggestionIndex] ?? suggestions[0]);
            }
          }}
        />
        {showSuggestions && suggestions.length > 0 ? (
          <ul aria-label="Command suggestions" className="composer-suggestions" role="listbox">
            {suggestions.map((suggestion, index) => (
              <li
                key={suggestion.command}
                aria-selected={index === activeSuggestionIndex}
                className="composer-suggestion"
                role="option"
              >
                <button
                  className="composer-suggestion-button"
                  type="button"
                  onClick={() => applySuggestion(suggestion)}
                >
                  <span>{suggestion.command}</span>
                  <span>{suggestion.description}</span>
                </button>
              </li>
            ))}
          </ul>
        ) : null}
      </div>
      <button
        className={`composer-icon-button${voiceState === "listening" ? " is-active" : ""}`}
        type="button"
        aria-label={voiceState === "idle" ? "Voice input" : "Stop voice input"}
        onClick={() => {
          if (voiceState === "idle") {
            void startVoiceInput();
          } else {
            stopVoiceInput();
          }
        }}
      >
        <svg aria-hidden="true" viewBox="0 0 24 24">
          <rect x="9" y="3.5" width="6" height="11" rx="3" />
          <path d="M5.8 11.5a6.2 6.2 0 0 0 12.4 0" />
          <path d="M12 18v3" />
          <path d="M8.6 21h6.8" />
        </svg>
      </button>
      <button className="composer-send" type="submit" aria-label="Send" disabled={!canSend}>
        <svg aria-hidden="true" viewBox="0 0 24 24">
          <path d="M12 19V5" />
          <path d="M6.5 10.5 12 5l5.5 5.5" />
        </svg>
      </button>
    </form>
  );
}

function resolveAudioContext(): (new () => AudioContext) | undefined {
  if (typeof window === "undefined") {
    return undefined;
  }

  return (
    window.AudioContext ??
    (window as Window & { webkitAudioContext?: new () => AudioContext }).webkitAudioContext
  );
}

function parseVoiceMessage(data: string): Record<string, unknown> | null {
  try {
    return JSON.parse(data) as Record<string, unknown>;
  } catch {
    return null;
  }
}

function mergeVoiceTranscript(prefix: string, transcript: string): string {
  if (!prefix.trim()) {
    return transcript;
  }

  return /\s$/.test(prefix) ? `${prefix}${transcript}` : `${prefix} ${transcript}`;
}

function downsampleBuffer(input: Float32Array, inputRate: number, outputRate: number): Int16Array {
  if (input.length === 0) {
    return new Int16Array();
  }

  const ratio = inputRate / outputRate;
  const outputLength = Math.max(1, Math.round(input.length / ratio));
  const output = new Int16Array(outputLength);
  let inputOffset = 0;

  for (let outputIndex = 0; outputIndex < outputLength; outputIndex += 1) {
    const nextInputOffset = Math.min(input.length, Math.round((outputIndex + 1) * ratio));
    let sum = 0;
    let count = 0;

    for (let index = inputOffset; index < nextInputOffset; index += 1) {
      sum += input[index];
      count += 1;
    }

    const sample = count === 0 ? input[inputOffset] ?? 0 : sum / count;
    const clamped = Math.max(-1, Math.min(1, sample));
    output[outputIndex] = clamped < 0 ? clamped * 0x8000 : clamped * 0x7fff;
    inputOffset = nextInputOffset;
  }

  return output;
}
