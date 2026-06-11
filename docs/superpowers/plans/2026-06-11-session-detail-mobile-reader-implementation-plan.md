# Session Detail Mobile Reader Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the session detail page into a mobile-first readable transcript that groups operational noise and preserves existing agent/session behavior.

**Architecture:** This slice keeps runtime behavior unchanged. The daemon only gains missing session metadata in the existing detail DTO so the frontend can render a real summary. The frontend then projects raw events into reader-oriented timeline items, renders a mobile-first detail shell, and styles it with the industrial-reader visual direction from the approved spec.

**Tech Stack:** Rust, Axum, React 19, TypeScript, Vite, Vitest, Testing Library, CSS

---

## File Structure

- Modify: `daemon/src/http/dto.rs`
  - Add `workspacePath` and `status` to `SessionSnapshotDto`.
- Modify: `daemon/src/http/routes.rs`
  - Populate the new detail DTO fields from `SessionSnapshot.session`.
- Modify: `daemon/tests/session_detail_api_test.rs`
  - Verify the detail API returns workspace and status metadata.
- Modify: `frontend/src/types.ts`
  - Add `workspacePath` and `status` to `SessionDetail`.
- Modify: `frontend/src/timeline.ts`
  - Change event projection so tool/status noise becomes compact summary items and reasoning stays collapsed by default.
- Modify: `frontend/src/timeline.test.ts`
  - Cover grouped activity summaries, collapsed reasoning behavior, and status compression.
- Modify: `frontend/src/components/SessionDetailView.tsx`
  - Replace the current uniform stacked-card rendering with a mobile reader shell.
- Modify: `frontend/src/components/TimelineCards.tsx`
  - Replace generic cards with role-specific reader cards.
- Modify: `frontend/src/components/Composer.tsx`
  - Keep send behavior the same while adding detail-page class hooks and touch-sized controls.
- Modify: `frontend/src/components/__tests__/SessionDetailView.test.tsx`
  - Verify the new detail structure and grouped display rules.
- Modify: `frontend/src/styles.css`
  - Add mobile-first detail layout tokens and styles without breaking other screens.

### Task 1: Return detail metadata from the daemon

**Files:**
- Modify: `daemon/tests/session_detail_api_test.rs`
- Modify: `daemon/src/http/dto.rs`
- Modify: `daemon/src/http/routes.rs`
- Modify: `frontend/src/types.ts`

- [ ] **Step 1: Write the failing daemon test**

In `daemon/tests/session_detail_api_test.rs`, add these assertions at the end of `get_session_detail_returns_snapshot_events`:

```rust
    assert!(text.contains("\"workspacePath\":\"repo\""));
    assert!(text.contains("\"status\":\"created\""));
```

The end of the test should read:

```rust
    assert_eq!(detail.status(), StatusCode::OK);
    let body = to_bytes(detail.into_body(), usize::MAX).await.unwrap();
    let text = String::from_utf8(body.to_vec()).unwrap();
    assert!(text.contains("\"eventType\":\"session.created\""));
    assert!(text.contains("\"agentKind\":\"claude\""));
    assert!(text.contains("\"workspacePath\":\"repo\""));
    assert!(text.contains("\"status\":\"created\""));
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
cargo test -p agent-workspace-daemon get_session_detail_returns_snapshot_events
```

Expected: FAIL because the detail response does not include `workspacePath` or `status`.

- [ ] **Step 3: Add metadata fields to the detail DTO**

Update `daemon/src/http/dto.rs` so `SessionSnapshotDto` includes `workspacePath` and `status`:

```rust
#[derive(Serialize)]
pub struct SessionSnapshotDto {
    pub id: String,
    #[serde(rename = "agentKind")]
    pub agent_kind: String,
    #[serde(rename = "sourceKind")]
    pub source_kind: String,
    #[serde(rename = "runtimeSessionId")]
    pub runtime_session_id: Option<String>,
    #[serde(rename = "workspacePath")]
    pub workspace_path: String,
    pub status: String,
    pub events: Vec<SessionEventDto>,
}
```

Update `snapshot_to_dto` in `daemon/src/http/routes.rs`:

```rust
fn snapshot_to_dto(snapshot: crate::session::model::SessionSnapshot) -> SessionSnapshotDto {
    SessionSnapshotDto {
        id: snapshot.session.id,
        agent_kind: snapshot.session.agent_kind,
        source_kind: snapshot.session.source_kind,
        runtime_session_id: snapshot.session.runtime_session_id,
        workspace_path: snapshot.session.workspace_path,
        status: snapshot.session.status,
        events: snapshot
            .events
            .into_iter()
            .map(|event| SessionEventDto {
                id: event.id,
                event_type: event.event_type,
                payload: serde_json::from_str(&event.payload_json).unwrap(),
            })
            .collect(),
    }
}
```

Update `frontend/src/types.ts` so `SessionDetail` includes the same metadata:

```ts
export interface SessionDetail {
  id: string;
  agentKind: string;
  sourceKind?: string;
  runtimeSessionId?: string;
  workspacePath?: string;
  status?: string;
  events: SessionEvent[];
}
```

- [ ] **Step 4: Run test to verify it passes**

Run:

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
cargo test -p agent-workspace-daemon get_session_detail_returns_snapshot_events
```

Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
git add daemon/tests/session_detail_api_test.rs daemon/src/http/dto.rs daemon/src/http/routes.rs frontend/src/types.ts
git commit -m "feat: include session metadata in detail response"
```

### Task 2: Rework timeline projection for grouped activity

**Files:**
- Modify: `frontend/src/timeline.ts`
- Modify: `frontend/src/timeline.test.ts`

- [ ] **Step 1: Write the failing timeline tests**

Replace `frontend/src/timeline.test.ts` with:

```ts
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
      { id: "user:1", kind: "user", text: "hello" },
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
});
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace/frontend
npm test -- --run src/timeline.test.ts
```

Expected: FAIL because `projectTimelineEvents` does not yet return `activity`, `status_summary`, or `collapsed` reasoning items.

- [ ] **Step 3: Implement grouped timeline items**

Replace `frontend/src/timeline.ts` with this full file. This uses a single pending segment state so consecutive status events group together, consecutive tool events group together, and interleaved status/tool segments keep their original order:

```ts
import type { SessionEvent } from "./types";

export type TimelineItem =
  | { id: string; kind: "user"; text: string }
  | { id: string; kind: "thinking"; text: string; collapsed: true }
  | { id: string; kind: "assistant"; text: string }
  | { id: string; kind: "file_change"; files: string[] }
  | { id: string; kind: "attached"; runtimeSessionId: string }
  | { id: string; kind: "status_summary"; statuses: string[] }
  | {
      id: string;
      kind: "activity";
      groups: Array<{ label: string; status: "started" | "completed"; count: number }>;
    };

type PendingSegment =
  | { kind: "none" }
  | { kind: "activity"; firstEventId: number; groups: ActivityGroup[] }
  | { kind: "status"; firstEventId: number; statuses: string[] };

type ActivityGroup = {
  label: string;
  status: "started" | "completed";
  count: number;
};

export function projectTimelineEvents(events: SessionEvent[]): TimelineItem[] {
  const items: TimelineItem[] = [];
  let pending: PendingSegment = { kind: "none" };

  const flushPending = () => {
    if (pending.kind === "activity") {
      items.push({
        id: `activity:${pending.firstEventId}`,
        kind: "activity",
        groups: pending.groups,
      });
    }

    if (pending.kind === "status") {
      items.push({
        id: `status:${pending.firstEventId}`,
        kind: "status_summary",
        statuses: pending.statuses,
      });
    }

    pending = { kind: "none" };
  };

  for (const event of events) {
    if (event.eventType === "user.message") {
      flushPending();
      items.push({
        id: `user:${event.id}`,
        kind: "user",
        text: String(event.payload.text ?? ""),
      });
      continue;
    }

    if (event.eventType === "assistant.thinking.delta") {
      flushPending();
      const text = String(event.payload.text ?? "");
      const last = items.at(-1);
      if (last?.kind === "thinking") {
        last.text += text;
      } else {
        items.push({
          id: `thinking:${event.id}`,
          kind: "thinking",
          text,
          collapsed: true,
        });
      }
      continue;
    }

    if (event.eventType === "assistant.message") {
      flushPending();
      const text = String(event.payload.text ?? "");
      const last = items.at(-1);
      if (last?.kind === "assistant") {
        last.text += text;
      } else {
        items.push({
          id: `assistant:${event.id}`,
          kind: "assistant",
          text,
        });
      }
      continue;
    }

    if (event.eventType === "file.change.reported") {
      flushPending();
      const files = Array.isArray(event.payload.files)
        ? event.payload.files.map((value) => String(value))
        : [];
      items.push({
        id: `file:${event.id}`,
        kind: "file_change",
        files,
      });
      continue;
    }

    if (event.eventType === "session.attached") {
      flushPending();
      items.push({
        id: `attached:${event.id}`,
        kind: "attached",
        runtimeSessionId: String(event.payload.runtimeSessionId ?? ""),
      });
      continue;
    }

    if (event.eventType === "session.status.changed") {
      if (pending.kind !== "status") {
        flushPending();
        pending = { kind: "status", firstEventId: event.id, statuses: [] };
      }
      pending.statuses.push(readStatus(event.payload.status));
      continue;
    }

    if (event.eventType === "tool.call.started" || event.eventType === "tool.call.completed") {
      if (pending.kind !== "activity") {
        flushPending();
        pending = { kind: "activity", firstEventId: event.id, groups: [] };
      }
      const item = asObject(event.payload.item);
      const label = String(item.type ?? "tool");
      const status = event.eventType === "tool.call.started" ? "started" : "completed";
      const existing = pending.groups.find(
        (group) => group.label === label && group.status === status,
      );
      if (existing) {
        existing.count += 1;
      } else {
        pending.groups.push({ label, status, count: 1 });
      }
      continue;
    }

    flushPending();
  }

  flushPending();
  return items;
}

function asObject(value: unknown): Record<string, unknown> {
  return typeof value === "object" && value !== null ? (value as Record<string, unknown>) : {};
}

function readStatus(value: unknown): string {
  if (typeof value === "string") return value;

  if (typeof value === "object" && value !== null && "type" in value) {
    return String((value as Record<string, unknown>).type);
  }

  return String(value ?? "");
}
```

- [ ] **Step 4: Run test to verify it passes**

Run:

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace/frontend
npm test -- --run src/timeline.test.ts
```

Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
git add frontend/src/timeline.ts frontend/src/timeline.test.ts
git commit -m "feat: group activity in session timeline"
```

### Task 3: Render the mobile reader detail structure

**Files:**
- Modify: `frontend/src/components/SessionDetailView.tsx`
- Modify: `frontend/src/components/TimelineCards.tsx`
- Modify: `frontend/src/components/__tests__/SessionDetailView.test.tsx`

- [ ] **Step 1: Write the failing component test**

Replace `frontend/src/components/__tests__/SessionDetailView.test.tsx` with:

```tsx
import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

import { SessionDetailView } from "../SessionDetailView";

describe("SessionDetailView", () => {
  it("renders a mobile-reader transcript with grouped activity and collapsed reasoning", () => {
    const onSend = vi.fn();

    render(
      <SessionDetailView
        session={{
          id: "sess-1",
          agentKind: "codex",
          sourceKind: "managed",
          runtimeSessionId: "thread-abc-123",
          workspacePath: "/tmp/workspace",
          status: "running",
          events: [
            { id: 1, eventType: "user.message", payload: { text: "hello" } },
            { id: 2, eventType: "assistant.message", payload: { text: "done" } },
            { id: 3, eventType: "assistant.thinking.delta", payload: { text: "plan first" } },
            {
              id: 4,
              eventType: "tool.call.completed",
              payload: { item: { id: "tool-1", type: "commandExecution" } },
            },
            {
              id: 5,
              eventType: "tool.call.completed",
              payload: { item: { id: "tool-2", type: "commandExecution" } },
            },
            { id: 6, eventType: "session.status.changed", payload: { status: "running" } },
          ],
        }}
        onBack={() => {}}
        onSend={onSend}
      />,
    );

    expect(screen.getByRole("button", { name: "Back" })).toBeInTheDocument();
    expect(screen.getByText("codex")).toBeInTheDocument();
    expect(screen.getByText("/tmp/workspace")).toBeInTheDocument();
    expect(screen.getByText("source: managed")).toBeInTheDocument();
    expect(screen.getByText("runtime: thread-abc-123")).toBeInTheDocument();
    expect(screen.getByText("hello")).toBeInTheDocument();
    expect(screen.getByText("done")).toBeInTheDocument();
    expect(screen.getByText("Activity")).toBeInTheDocument();
    expect(screen.getByText("commandExecution")).toBeInTheDocument();
    expect(screen.getByText("completed × 2")).toBeInTheDocument();

    const reasoning = screen.getByText("Reasoning").closest("details");
    expect(reasoning).not.toHaveAttribute("open");

    fireEvent.change(screen.getByLabelText("Message"), { target: { value: "Ship it" } });
    fireEvent.click(screen.getByRole("button", { name: "Send" }));

    expect(onSend).toHaveBeenCalledWith("Ship it");
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace/frontend
npm test -- --run src/components/__tests__/SessionDetailView.test.tsx
```

Expected: FAIL because the current detail view renders generic `Tool activity` cards and no reader summary card.

- [ ] **Step 3: Implement reader cards**

Replace `frontend/src/components/TimelineCards.tsx` with:

```tsx
export function SessionSummaryCard(props: {
  workspacePath?: string;
  sourceKind?: string;
  runtimeSessionId?: string;
  status?: string;
}) {
  return (
    <section className="session-summary-card">
      <div className="session-summary-row">
        <div>
          <p className="eyebrow">Workspace</p>
          <p className="session-path">{props.workspacePath ?? "Session root unavailable"}</p>
        </div>
        {props.status ? <span className="status-pill">{props.status}</span> : null}
      </div>
      <div className="session-meta-chips">
        {props.sourceKind ? <span className="meta-chip">source: {props.sourceKind}</span> : null}
        {props.runtimeSessionId ? (
          <span className="meta-chip">runtime: {props.runtimeSessionId}</span>
        ) : null}
      </div>
    </section>
  );
}

export function ThinkingCard(props: { text: string }) {
  return (
    <details className="reasoning-card">
      <summary>Reasoning</summary>
      <pre>{props.text}</pre>
    </details>
  );
}

export function UserCard(props: { text: string }) {
  return (
    <section className="user-card">
      <div className="card-kicker">You</div>
      <p>{props.text}</p>
    </section>
  );
}

export function AssistantCard(props: { text: string }) {
  return (
    <section className="assistant-card">
      <div className="card-kicker">Assistant</div>
      <p className="assistant-copy">{props.text}</p>
    </section>
  );
}

export function FileChangeCard(props: { files: string[] }) {
  return (
    <section className="activity-card">
      <strong>Files changed</strong>
      <ul className="activity-list">
        {props.files.map((file) => (
          <li key={file}>
            <span>{file}</span>
          </li>
        ))}
      </ul>
    </section>
  );
}

export function AttachedSessionCard(props: { runtimeSessionId: string }) {
  return (
    <section className="activity-card">
      <strong>Attached session</strong>
      <p className="technical-text">{props.runtimeSessionId}</p>
    </section>
  );
}

export function ActivitySummaryCard(props: {
  groups: Array<{ label: string; status: string; count: number }>;
}) {
  return (
    <details className="activity-card">
      <summary>Activity</summary>
      <ul className="activity-list">
        {props.groups.map((group) => (
          <li key={`${group.label}:${group.status}`}>
            <span>{group.label}</span>
            <strong>
              {group.status} × {group.count}
            </strong>
          </li>
        ))}
      </ul>
    </details>
  );
}

export function StatusSummaryCard(props: { statuses: string[] }) {
  return (
    <details className="activity-card">
      <summary>Status</summary>
      <p>{props.statuses.join(" → ")}</p>
    </details>
  );
}
```

Replace `frontend/src/components/SessionDetailView.tsx` with:

```tsx
import type { SessionDetail } from "../types";
import { projectTimelineEvents } from "../timeline";
import { Composer } from "./Composer";
import {
  ActivitySummaryCard,
  AssistantCard,
  AttachedSessionCard,
  FileChangeCard,
  SessionSummaryCard,
  StatusSummaryCard,
  ThinkingCard,
  UserCard,
} from "./TimelineCards";

export function SessionDetailView(props: {
  session: SessionDetail;
  onBack: () => void;
  onSend: (message: string) => void;
}) {
  const items = projectTimelineEvents(props.session.events ?? []);
  const latestStatusSummary = [...items]
    .reverse()
    .find((item) => item.kind === "status_summary");
  const latestStatus =
    latestStatusSummary?.kind === "status_summary"
      ? latestStatusSummary.statuses.at(-1)
      : props.session.status;

  return (
    <section className="session-detail">
      <header className="session-detail-topbar">
        <button className="button back-button" type="button" onClick={props.onBack}>
          Back
        </button>
        <div className="session-title">
          <h1>{props.session.agentKind}</h1>
          <p className="muted">
            {[latestStatus, props.session.sourceKind].filter(Boolean).join(" · ")}
          </p>
        </div>
      </header>

      <SessionSummaryCard
        workspacePath={props.session.workspacePath}
        sourceKind={props.session.sourceKind}
        runtimeSessionId={props.session.runtimeSessionId}
        status={latestStatus}
      />

      <section className="session-transcript">
        {items.map((item) => {
          if (item.kind === "user") return <UserCard key={item.id} text={item.text} />;
          if (item.kind === "assistant") return <AssistantCard key={item.id} text={item.text} />;
          if (item.kind === "thinking") return <ThinkingCard key={item.id} text={item.text} />;
          if (item.kind === "activity") {
            return <ActivitySummaryCard key={item.id} groups={item.groups} />;
          }
          if (item.kind === "status_summary") {
            return <StatusSummaryCard key={item.id} statuses={item.statuses} />;
          }
          if (item.kind === "file_change") {
            return <FileChangeCard key={item.id} files={item.files} />;
          }
          if (item.kind === "attached") {
            return <AttachedSessionCard key={item.id} runtimeSessionId={item.runtimeSessionId} />;
          }
          return null;
        })}
      </section>

      <Composer onSend={props.onSend} />
    </section>
  );
}
```

- [ ] **Step 4: Run test to verify it passes**

Run:

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace/frontend
npm test -- --run src/components/__tests__/SessionDetailView.test.tsx
```

Expected: PASS

- [ ] **Step 5: Commit**

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
git add frontend/src/components/SessionDetailView.tsx frontend/src/components/TimelineCards.tsx frontend/src/components/__tests__/SessionDetailView.test.tsx
git commit -m "feat: render mobile reader session detail"
```

### Task 4: Apply mobile-first visual styling

**Files:**
- Modify: `frontend/src/components/Composer.tsx`
- Modify: `frontend/src/styles.css`
- Modify: `frontend/src/components/__tests__/SessionDetailView.test.tsx`

- [ ] **Step 1: Add style hook assertions to the component test**

Add these assertions inside the existing test in `frontend/src/components/__tests__/SessionDetailView.test.tsx`:

```tsx
    expect(screen.getByRole("button", { name: "Back" })).toHaveClass("back-button");
    expect(screen.getByRole("button", { name: "Send" })).toHaveClass("composer-send");
    expect(screen.getByLabelText("Message")).toHaveClass("composer-input");
    expect(document.querySelector(".session-detail")).not.toBeNull();
    expect(document.querySelector(".session-summary-card")).not.toBeNull();
    expect(document.querySelector(".assistant-card")).not.toBeNull();
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace/frontend
npm test -- --run src/components/__tests__/SessionDetailView.test.tsx
```

Expected: FAIL because `Composer` does not yet expose `composer-input` or `composer-send`.

- [ ] **Step 3: Update Composer class hooks**

Replace `frontend/src/components/Composer.tsx` with:

```tsx
import { useState } from "react";

export function Composer(props: { onSend: (message: string) => void }) {
  const [value, setValue] = useState("");

  return (
    <form
      className="composer"
      onSubmit={(event) => {
        event.preventDefault();
        if (value.trim().length === 0) return;
        props.onSend(value);
        setValue("");
      }}
    >
      <label className="field composer-field">
        <span>Message</span>
        <textarea
          aria-label="Message"
          className="input composer-input"
          value={value}
          onChange={(event) => setValue(event.target.value)}
        />
      </label>
      <button className="button composer-send" type="submit">
        Send
      </button>
    </form>
  );
}
```

- [ ] **Step 4: Add mobile-reader CSS**

Append this CSS to `frontend/src/styles.css`:

```css
:root {
  --shell-bg: #05080d;
  --panel-bg: rgba(10, 19, 35, 0.92);
  --panel-bg-strong: #0f1e31;
  --assistant-bg: #f1eadc;
  --assistant-ink: #141a22;
  --muted-ink: #8fa1bd;
  --run-green: #22c55e;
  --run-green-soft: #a7f3d0;
  --font-ui: "Atkinson Hyperlegible", "Aptos", "Segoe UI", sans-serif;
  --font-mono: "JetBrains Mono", "SFMono-Regular", "Cascadia Code", monospace;
  font-family: var(--font-ui);
}

.session-detail {
  display: grid;
  gap: 12px;
  max-width: 720px;
  margin: 0 auto;
  font-family: var(--font-ui);
}

.session-detail-topbar {
  position: sticky;
  top: 0;
  z-index: 2;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  padding-bottom: 12px;
  background: linear-gradient(180deg, rgba(5, 8, 13, 0.96) 72%, rgba(5, 8, 13, 0));
}

.session-title {
  min-width: 0;
  text-align: right;
}

.session-title h1,
.session-title p {
  margin: 0;
}

.session-summary-card,
.user-card,
.activity-card,
.reasoning-card,
.composer {
  border: 1px solid rgba(148, 163, 184, 0.18);
  border-radius: 22px;
  background: rgba(10, 19, 35, 0.92);
  padding: 16px;
}

.session-summary-row {
  display: flex;
  justify-content: space-between;
  gap: 12px;
}

.eyebrow,
.card-kicker {
  margin: 0 0 8px;
  color: var(--muted-ink);
  font-size: 0.72rem;
  font-weight: 800;
  letter-spacing: 0.08em;
  text-transform: uppercase;
}

.session-path,
.technical-text,
.meta-chip,
.activity-list span {
  overflow-wrap: anywhere;
}

.technical-text,
.meta-chip,
.activity-list span {
  font-family: var(--font-mono);
}

.session-path {
  margin: 0;
  font-weight: 800;
}

.status-pill,
.meta-chip {
  border-radius: 999px;
  padding: 5px 9px;
  font-size: 0.72rem;
  font-weight: 800;
}

.status-pill {
  align-self: start;
  border: 1px solid rgba(34, 197, 94, 0.36);
  background: #11351f;
  color: var(--run-green-soft);
}

.session-meta-chips {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  margin-top: 12px;
}

.meta-chip {
  border: 1px solid rgba(148, 163, 184, 0.18);
  background: #101c2d;
  color: #aebbd1;
}

.user-card p {
  margin: 0;
  line-height: 1.5;
}

.assistant-card {
  border: 1px solid rgba(255, 255, 255, 0.2);
  border-radius: 24px;
  background: var(--assistant-bg);
  color: var(--assistant-ink);
  padding: 18px;
  box-shadow: 0 22px 64px rgba(0, 0, 0, 0.34);
}

.assistant-copy {
  margin: 0;
  font-size: 1rem;
  font-weight: 650;
  letter-spacing: -0.01em;
  line-height: 1.62;
}

.session-transcript {
  display: grid;
  gap: 12px;
}

.activity-card summary,
.reasoning-card summary {
  min-height: 28px;
  cursor: pointer;
  font-weight: 800;
}

.activity-list {
  display: grid;
  gap: 8px;
  list-style: none;
  margin: 12px 0 0;
  padding: 0;
}

.activity-list li {
  display: flex;
  justify-content: space-between;
  gap: 12px;
  padding: 10px 11px;
  border-radius: 14px;
  background: var(--panel-bg-strong);
}

.activity-list strong {
  color: var(--run-green-soft);
  white-space: nowrap;
}

.reasoning-card pre {
  margin: 12px 0 0;
  color: #9fb0ca;
  font-family: var(--font-mono);
  font-size: 0.78rem;
  line-height: 1.55;
  overflow-wrap: anywhere;
  white-space: pre-wrap;
}

.composer {
  position: sticky;
  bottom: 0;
  display: grid;
  gap: 10px;
  background: linear-gradient(180deg, rgba(5, 8, 13, 0.55), rgba(5, 8, 13, 1));
}

.composer-input {
  min-height: 76px;
}

.composer-send,
.back-button {
  min-height: 44px;
}

.button:focus-visible,
.input:focus-visible,
summary:focus-visible {
  outline: 2px solid var(--run-green);
  outline-offset: 3px;
}

@media (min-width: 768px) {
  .session-detail {
    max-width: 1080px;
  }

  .session-transcript {
    max-width: 760px;
  }
}
```

- [ ] **Step 5: Run targeted frontend verification**

Run:

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace/frontend
npm test -- --run src/components/__tests__/SessionDetailView.test.tsx src/timeline.test.ts
npm run build
```

Expected:

- Vitest PASS for both files
- Vite build PASS

- [ ] **Step 6: Commit**

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
git add frontend/src/components/Composer.tsx frontend/src/styles.css frontend/src/components/__tests__/SessionDetailView.test.tsx
git commit -m "feat: style session detail for mobile reader"
```

### Task 5: Final verification

**Files:**
- Modify: none
- Test: existing daemon and frontend suites

- [ ] **Step 1: Run daemon tests**

Run:

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
cargo test -p agent-workspace-daemon
```

Expected: PASS

- [ ] **Step 2: Run frontend tests**

Run:

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace/frontend
npm test
```

Expected: PASS

- [ ] **Step 3: Run frontend production build**

Run:

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace/frontend
npm run build
```

Expected: PASS

- [ ] **Step 4: Manual browser verification**

Check the running app at the active Vite address. If no app server is running, start it with the existing local daemon and Vite proxy setup used during review.

Verify:

- 375px width: no horizontal scroll.
- Assistant answer is visibly easier to read than before.
- Grouped activity appears as one compact section instead of repeated cards.
- Reasoning is collapsed by default.
- Back and Send are at least 44px high.
- Desktop width does not collapse the transcript back into a narrow column.

- [ ] **Step 5: Confirm clean working tree**

Run:

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
git status --short --branch
```

Expected:

```text
## foundation-shell
```
