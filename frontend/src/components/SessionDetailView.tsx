import { useEffect, useLayoutEffect, useRef } from "react";

import type { SessionDetail } from "../types";
import { getSessionTitle } from "../sessionDisplay";
import { projectTimelineEvents } from "../timeline";
import { Composer } from "./Composer";
import {
  ActivitySummaryCard,
  AssistantCard,
  AttachedSessionCard,
  FileChangeCard,
  SessionErrorCard,
  ThinkingCard,
  ToolCallCard,
  UserCard,
} from "./TimelineCards";

export function SessionDetailView(props: {
  session: SessionDetail;
  onBack: () => void;
  onSend: (message: string, imagePaths: string[]) => void;
  onUploadImage: (file: File) => Promise<string>;
  onConnectVoiceInput: () => WebSocket;
  onLoadOlder: () => void | Promise<void>;
  loadingHistory: boolean;
}) {
  const transcriptRef = useRef<HTMLElement | null>(null);
  const shouldStickToBottomRef = useRef(true);
  const lastSessionIdRef = useRef<string | null>(null);
  const lastEventCountRef = useRef(0);
  const prependAnchorRef = useRef<{ scrollHeight: number; scrollTop: number } | null>(null);
  const wasNearBottomRef = useRef(true);
  const autoLoadSignatureRef = useRef<string | null>(null);

  const items = projectTimelineEvents(props.session.events ?? []);
  const displayTitle = getSessionTitle(props.session);
  const latestStatus = resolveDisplayedStatus(props.session.status, items);

  useLayoutEffect(() => {
    const transcript = transcriptRef.current;
    if (!transcript) {
      return;
    }

    if (lastSessionIdRef.current !== props.session.id) {
      lastSessionIdRef.current = props.session.id;
      lastEventCountRef.current = props.session.events.length;
      autoLoadSignatureRef.current = null;
      shouldStickToBottomRef.current = true;
      transcript.scrollTop = transcript.scrollHeight;
      return;
    }

    const previousCount = lastEventCountRef.current;
    lastEventCountRef.current = props.session.events.length;
    if (props.session.events.length <= previousCount) {
      return;
    }

    if (wasNearBottomRef.current) {
      transcript.scrollTop = transcript.scrollHeight;
    }
  }, [props.session.id, props.session.events]);

  useLayoutEffect(() => {
    const transcript = transcriptRef.current;
    const anchor = prependAnchorRef.current;
    if (!transcript || !anchor) {
      return;
    }

    const nextScrollTop = transcript.scrollHeight - anchor.scrollHeight + anchor.scrollTop;
    transcript.scrollTop = nextScrollTop;
    prependAnchorRef.current = null;
  }, [props.session.events]);

  useLayoutEffect(() => {
    const transcript = transcriptRef.current;
    if (
      !transcript ||
      !props.session.hasMoreHistory ||
      props.loadingHistory ||
      lastSessionIdRef.current !== props.session.id
    ) {
      return;
    }

    const signature = `${props.session.id}:${props.session.events[0]?.id ?? 0}:${props.session.events.length}`;
    if (
      transcript.scrollHeight > 0 &&
      transcript.clientHeight > 0 &&
      transcript.scrollHeight <= transcript.clientHeight
    ) {
      if (autoLoadSignatureRef.current === signature) {
        return;
      }
      autoLoadSignatureRef.current = signature;
      prependAnchorRef.current = {
        scrollHeight: transcript.scrollHeight,
        scrollTop: transcript.scrollTop,
      };
      props.onLoadOlder();
    }
  }, [props.loadingHistory, props.onLoadOlder, props.session.events, props.session.hasMoreHistory, props.session.id]);

  function isNearBottom(element: HTMLElement): boolean {
    return element.scrollHeight - element.scrollTop - element.clientHeight <= 48;
  }

  function handleTranscriptScroll(event: React.UIEvent<HTMLElement>): void {
    const transcript = event.currentTarget;
    const nearBottom = isNearBottom(transcript);
    shouldStickToBottomRef.current = nearBottom;
    wasNearBottomRef.current = nearBottom;

    if (
      transcript.scrollTop <= 120 &&
      props.session.hasMoreHistory &&
      !props.loadingHistory
    ) {
      prependAnchorRef.current = {
        scrollHeight: transcript.scrollHeight,
        scrollTop: transcript.scrollTop,
      };
      props.onLoadOlder();
    }
  }

  return (
    <section className="session-detail session-chat-workbench">
      <header className="session-workbench-header">
        <button
          aria-label="Back"
          className="session-back-button"
          type="button"
          onClick={props.onBack}
        >
          <span aria-hidden="true">&lt;</span>
        </button>
        <h1 className="session-heading-title">{displayTitle}</h1>
        {latestStatus ? <span className="session-status-pill">{latestStatus}</span> : null}
        <details className="session-menu">
          <summary className="session-menu-button" aria-label="Session details" role="button">
            <span aria-hidden="true">⋮</span>
          </summary>
          <div className="session-menu-panel">
            <p className="session-menu-title">Details</p>
            <dl className="session-menu-list">
              <div>
                <dt>Workspace</dt>
                <dd>{props.session.workspacePath ?? "Session root unavailable"}</dd>
              </div>
              {props.session.sourceKind ? (
                <div>
                  <dt>Source</dt>
                  <dd>source: {props.session.sourceKind}</dd>
                </div>
              ) : null}
            </dl>
          </div>
        </details>
      </header>

      <section
        ref={transcriptRef}
        className="session-transcript detail-transcript"
        onScroll={handleTranscriptScroll}
      >
        {items.map((item) => {
          if (item.kind === "user") {
            return (
              <UserCard
                key={item.id}
                sessionId={props.session.id}
                text={item.text}
                imagePaths={item.imagePaths}
              />
            );
          }
          if (item.kind === "thinking") {
            return <ThinkingCard key={item.id} text={item.text} />;
          }
          if (item.kind === "assistant") {
            return <AssistantCard key={item.id} text={item.text} />;
          }
          if (item.kind === "session_error") {
            return (
              <SessionErrorCard
                key={item.id}
                message={item.message}
                willRetry={item.willRetry}
              />
            );
          }
          if (item.kind === "tool_call") {
            return (
              <ToolCallCard
                key={item.id}
                toolName={item.toolName}
                label={item.label}
                summary={item.summary}
                output={item.output}
                status={item.status}
                command={item.command}
                cwd={item.cwd}
                exitCode={item.exitCode}
                durationMs={item.durationMs}
              />
            );
          }
          if (item.kind === "file_change") {
            return (
              <FileChangeCard
                key={item.id}
                files={item.files}
                summary={item.summary}
                diffs={item.diffs}
                status={item.status}
              />
            );
          }
          if (item.kind === "attached") {
            return <AttachedSessionCard key={item.id} runtimeSessionId={item.runtimeSessionId} />;
          }
          if (item.kind === "activity") {
            return <ActivitySummaryCard key={item.id} groups={item.groups} />;
          }
          if (item.kind === "status_summary") {
            return null;
          }
          return null;
        })}
      </section>

      <Composer
        onSend={props.onSend}
        onUploadImage={props.onUploadImage}
        onConnectVoiceInput={props.onConnectVoiceInput}
      />
    </section>
  );
}

function normalizeStatus(status?: string): string | undefined {
  const value = status?.trim();
  return value ? value : undefined;
}

function shouldPreferSessionStatus(status?: string): boolean {
  return matchesCurrentStatusKind(normalizeStatus(status));
}

function matchesCurrentStatusKind(status?: string): boolean {
  return status === "running" || status === "active" || status === "idle" || status === "suspended";
}

function resolveDisplayedStatus(
  sessionStatus: string | undefined,
  items: ReturnType<typeof projectTimelineEvents>,
): string | undefined {
  const normalizedSessionStatus = normalizeStatus(sessionStatus);
  if (shouldPreferSessionStatus(normalizedSessionStatus)) {
    return normalizedSessionStatus;
  }
  return findLatestNonEmptyStatus(items) ?? normalizedSessionStatus ?? sessionStatus;
}

function findLatestNonEmptyStatus(items: ReturnType<typeof projectTimelineEvents>): string | undefined {
  for (let itemIndex = items.length - 1; itemIndex >= 0; itemIndex -= 1) {
    const item = items[itemIndex];
    if (item.kind !== "status_summary") {
      continue;
    }

    for (let statusIndex = item.statuses.length - 1; statusIndex >= 0; statusIndex -= 1) {
      const status = normalizeStatus(item.statuses[statusIndex]);
      if (status) {
        return status;
      }
    }
  }

  return undefined;
}
