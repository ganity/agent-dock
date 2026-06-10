# Agent Workspace Managed Sessions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add real managed `Claude` and `Codex` sessions to `agent-workspace`, including unified structured event storage, live WebSocket event streaming, session listing/detail APIs, and a structured timeline UI with a working composer.

**Architecture:** This slice keeps the foundation shell intact and layers managed-session capabilities on top of it. The Rust daemon gains a unified event model, adapter traits, runtime orchestration, and live event streaming; the React frontend switches from placeholder local state to real session fetch/create/detail flows and renders timeline cards from structured events.

**Tech Stack:** Rust, Tokio, Axum, Serde, SQLx with SQLite, React, TypeScript, Vite, Vitest, Testing Library

---

## File Structure

### Rust daemon

- Modify: `agent-workspace/daemon/src/session/model.rs`
- Modify: `agent-workspace/daemon/src/session/store.rs`
- Modify: `agent-workspace/daemon/src/session/service.rs`
- Modify: `agent-workspace/daemon/src/http/dto.rs`
- Modify: `agent-workspace/daemon/src/http/routes.rs`
- Modify: `agent-workspace/daemon/src/app.rs`
- Modify: `agent-workspace/daemon/src/lib.rs`
- Create: `agent-workspace/daemon/src/http/ws.rs`
- Create: `agent-workspace/daemon/src/adapters/mod.rs`
- Create: `agent-workspace/daemon/src/adapters/process.rs`
- Create: `agent-workspace/daemon/src/adapters/claude.rs`
- Create: `agent-workspace/daemon/src/adapters/codex.rs`

### Rust tests and fixtures

- Create: `agent-workspace/daemon/tests/event_store_test.rs`
- Create: `agent-workspace/daemon/tests/claude_adapter_test.rs`
- Create: `agent-workspace/daemon/tests/codex_adapter_test.rs`
- Create: `agent-workspace/daemon/tests/managed_session_api_test.rs`
- Create: `agent-workspace/daemon/tests/session_stream_test.rs`
- Create: `agent-workspace/daemon/tests/fixtures/claude_stream.jsonl`
- Create: `agent-workspace/daemon/tests/fixtures/codex_rpc.jsonl`

### Browser UI

- Modify: `agent-workspace/frontend/src/App.tsx`
- Modify: `agent-workspace/frontend/src/api.ts`
- Modify: `agent-workspace/frontend/src/types.ts`
- Modify: `agent-workspace/frontend/src/styles.css`
- Modify: `agent-workspace/frontend/src/components/CreateSessionView.tsx`
- Modify: `agent-workspace/frontend/src/components/SessionListView.tsx`
- Create: `agent-workspace/frontend/src/components/SessionDetailView.tsx`
- Create: `agent-workspace/frontend/src/components/TimelineCards.tsx`
- Create: `agent-workspace/frontend/src/components/Composer.tsx`
- Create: `agent-workspace/frontend/src/components/__tests__/SessionDetailView.test.tsx`
- Modify: `agent-workspace/frontend/src/components/__tests__/SessionListView.test.tsx`

## Task 1: Extend The Event Store For Managed Sessions

**Files:**
- Create: `agent-workspace/daemon/tests/event_store_test.rs`
- Modify: `agent-workspace/daemon/src/session/model.rs`
- Modify: `agent-workspace/daemon/src/session/store.rs`

- [ ] **Step 1: Write the failing event-store test**

```rust
// agent-workspace/daemon/tests/event_store_test.rs
use agent_workspace_daemon::session::store::SqliteSessionStore;

#[tokio::test]
async fn store_lists_sessions_and_events_after_cursor() {
    let store = SqliteSessionStore::in_memory().await.unwrap();
    let first = store
        .create_session("workspace".into(), "repo-a".into(), "managed".into(), "claude".into())
        .await
        .unwrap();
    let second = store
        .create_session("workspace".into(), "repo-b".into(), "managed".into(), "codex".into())
        .await
        .unwrap();

    store
        .append_event(&first, "session.created", r#"{"status":"created"}"#)
        .await
        .unwrap();
    store
        .append_event(&first, "assistant.message", r#"{"text":"hello"}"#)
        .await
        .unwrap();
    store
        .append_event(&second, "session.created", r#"{"status":"created"}"#)
        .await
        .unwrap();

    let sessions = store.list_sessions().await.unwrap();
    let after_first = store.events_after(&first, 1).await.unwrap();

    assert_eq!(sessions.len(), 2);
    assert_eq!(after_first.len(), 1);
    assert_eq!(after_first[0].event_type, "assistant.message");
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
cargo test -p agent-workspace-daemon store_lists_sessions_and_events_after_cursor
```

Expected:

```text
error[E0599]: no method named `list_sessions` found
```

- [ ] **Step 3: Implement session summaries and cursor queries**

```rust
// agent-workspace/daemon/src/session/model.rs
#[derive(Clone, Debug, PartialEq)]
pub struct SessionSummary {
    pub id: String,
    pub workspace_path: String,
    pub source_kind: String,
    pub agent_kind: String,
    pub status: String,
}
```

```rust
// agent-workspace/daemon/src/session/store.rs
pub async fn list_sessions(&self) -> anyhow::Result<Vec<SessionSummary>> {
    let rows = sqlx::query(
        "select id, workspace_path, source_kind, agent_kind, status
         from sessions
         order by updated_at desc, id desc",
    )
    .fetch_all(&self.pool)
    .await?;

    Ok(rows
        .into_iter()
        .map(|row| SessionSummary {
            id: row.get("id"),
            workspace_path: row.get("workspace_path"),
            source_kind: row.get("source_kind"),
            agent_kind: row.get("agent_kind"),
            status: row.get("status"),
        })
        .collect())
}

pub async fn events_after(&self, session_id: &str, cursor: i64) -> anyhow::Result<Vec<StoredEvent>> {
    let rows = sqlx::query(
        "select id, event_type, payload_json
         from session_events
         where session_id = ?1 and id > ?2
         order by id asc",
    )
    .bind(session_id)
    .bind(cursor)
    .fetch_all(&self.pool)
    .await?;

    Ok(rows
        .into_iter()
        .map(|row| StoredEvent {
            id: row.get("id"),
            event_type: row.get("event_type"),
            payload_json: row.get("payload_json"),
        })
        .collect())
}

pub async fn update_session_status(&self, session_id: &str, status: &str) -> anyhow::Result<()> {
    sqlx::query("update sessions set status = ?2, updated_at = datetime('now') where id = ?1")
        .bind(session_id)
        .bind(status)
        .execute(&self.pool)
        .await?;
    Ok(())
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run:

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
cargo test -p agent-workspace-daemon store_lists_sessions_and_events_after_cursor
```

Expected:

```text
test store_lists_sessions_and_events_after_cursor ... ok
```

- [ ] **Step 5: Commit the event-store extensions**

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
git add daemon/src/session/model.rs daemon/src/session/store.rs daemon/tests/event_store_test.rs
git commit -m "feat: extend event store for managed sessions"
```

## Task 2: Add The Claude Adapter And Unified Event Mapping

**Files:**
- Create: `agent-workspace/daemon/src/adapters/mod.rs`
- Create: `agent-workspace/daemon/src/adapters/process.rs`
- Create: `agent-workspace/daemon/src/adapters/claude.rs`
- Create: `agent-workspace/daemon/tests/claude_adapter_test.rs`
- Create: `agent-workspace/daemon/tests/fixtures/claude_stream.jsonl`
- Modify: `agent-workspace/daemon/src/lib.rs`

- [ ] **Step 1: Write the failing Claude adapter test**

```rust
// agent-workspace/daemon/tests/claude_adapter_test.rs
use agent_workspace_daemon::adapters::claude::parse_claude_stream_line;

#[test]
fn claude_stream_maps_assistant_and_thinking_events() {
    let thinking = r#"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"plan first"}]}}"#;
    let message = r#"{"type":"assistant","message":{"content":[{"type":"text","text":"done"}]}}"#;

    let thinking_event = parse_claude_stream_line(thinking).unwrap().unwrap();
    let message_event = parse_claude_stream_line(message).unwrap().unwrap();

    assert_eq!(thinking_event.event_type, "assistant.thinking.delta");
    assert_eq!(message_event.event_type, "assistant.message");
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
cargo test -p agent-workspace-daemon claude_stream_maps_assistant_and_thinking_events
```

Expected:

```text
error[E0433]: could not find `adapters`
```

- [ ] **Step 3: Implement the Claude parser and launch contract**

```rust
// agent-workspace/daemon/src/adapters/mod.rs
pub mod claude;
pub mod process;
```

```rust
// agent-workspace/daemon/src/adapters/process.rs
pub struct LaunchCommand {
    pub program: String,
    pub args: Vec<String>,
}

pub fn claude_managed_launch() -> LaunchCommand {
    LaunchCommand {
        program: "claude".into(),
        args: vec![
            "--print".into(),
            "--verbose".into(),
            "--output-format".into(),
            "stream-json".into(),
            "--input-format".into(),
            "stream-json".into(),
        ],
    }
}
```

```rust
// agent-workspace/daemon/src/adapters/claude.rs
use serde::Deserialize;

use crate::session::model::StoredEvent;

#[derive(Deserialize)]
struct ClaudeContentBlock {
    #[serde(rename = "type")]
    kind: String,
    text: Option<String>,
    thinking: Option<String>,
}

#[derive(Deserialize)]
struct ClaudeMessage {
    content: Vec<ClaudeContentBlock>,
}

#[derive(Deserialize)]
struct ClaudeEnvelope {
    #[serde(rename = "type")]
    kind: String,
    message: Option<ClaudeMessage>,
}

pub fn parse_claude_stream_line(line: &str) -> anyhow::Result<Option<StoredEvent>> {
    let envelope: ClaudeEnvelope = serde_json::from_str(line)?;

    if envelope.kind != "assistant" {
        return Ok(None);
    }

    let block = match envelope.message.and_then(|message| message.content.into_iter().next()) {
        Some(value) => value,
        None => return Ok(None),
    };

    let (event_type, payload_json) = match block.kind.as_str() {
        "thinking" => (
            "assistant.thinking.delta",
            serde_json::json!({ "text": block.thinking.unwrap_or_default() }).to_string(),
        ),
        "text" => (
            "assistant.message",
            serde_json::json!({ "text": block.text.unwrap_or_default() }).to_string(),
        ),
        _ => return Ok(None),
    };

    Ok(Some(StoredEvent {
        id: 0,
        event_type: event_type.to_string(),
        payload_json,
    }))
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
cargo test -p agent-workspace-daemon claude_stream_maps_assistant_and_thinking_events
```

Expected:

```text
test claude_stream_maps_assistant_and_thinking_events ... ok
```

- [ ] **Step 5: Commit the Claude adapter**

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
git add daemon/src/lib.rs daemon/src/adapters/mod.rs daemon/src/adapters/process.rs daemon/src/adapters/claude.rs daemon/tests/claude_adapter_test.rs daemon/tests/fixtures/claude_stream.jsonl
git commit -m "feat: add claude managed-session adapter"
```

## Task 3: Add The Codex Adapter Against The App-Server Protocol

**Files:**
- Create: `agent-workspace/daemon/src/adapters/codex.rs`
- Modify: `agent-workspace/daemon/src/adapters/mod.rs`
- Modify: `agent-workspace/daemon/src/adapters/process.rs`
- Create: `agent-workspace/daemon/tests/codex_adapter_test.rs`
- Create: `agent-workspace/daemon/tests/fixtures/codex_rpc.jsonl`

- [ ] **Step 1: Write the failing Codex adapter test**

```rust
// agent-workspace/daemon/tests/codex_adapter_test.rs
use agent_workspace_daemon::adapters::codex::parse_codex_rpc_line;

#[test]
fn codex_rpc_maps_message_and_file_change_events() {
    let message = r#"{"jsonrpc":"2.0","method":"session/message","params":{"text":"applied fix"}}"#;
    let file_change = r#"{"jsonrpc":"2.0","method":"session/fileChangeReported","params":{"files":["src/app.rs"]}}"#;

    let message_event = parse_codex_rpc_line(message).unwrap().unwrap();
    let change_event = parse_codex_rpc_line(file_change).unwrap().unwrap();

    assert_eq!(message_event.event_type, "assistant.message");
    assert_eq!(change_event.event_type, "file.change.reported");
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
cargo test -p agent-workspace-daemon codex_rpc_maps_message_and_file_change_events
```

Expected:

```text
error[E0433]: unresolved import `agent_workspace_daemon::adapters::codex`
```

- [ ] **Step 3: Implement the Codex RPC parser and app-server launch**

```rust
// agent-workspace/daemon/src/adapters/process.rs
pub fn codex_managed_launch() -> LaunchCommand {
    LaunchCommand {
        program: "codex".into(),
        args: vec!["app-server".into(), "--stdio".into()],
    }
}
```

```rust
// agent-workspace/daemon/src/adapters/mod.rs
pub mod claude;
pub mod codex;
pub mod process;
```

```rust
// agent-workspace/daemon/src/adapters/codex.rs
use serde::Deserialize;

use crate::session::model::StoredEvent;

#[derive(Deserialize)]
struct RpcEnvelope {
    method: Option<String>,
    params: Option<serde_json::Value>,
}

pub fn parse_codex_rpc_line(line: &str) -> anyhow::Result<Option<StoredEvent>> {
    let envelope: RpcEnvelope = serde_json::from_str(line)?;

    let event_type = match envelope.method.as_deref() {
        Some("session/message") => "assistant.message",
        Some("session/thinking") => "assistant.thinking.delta",
        Some("session/fileChangeReported") => "file.change.reported",
        Some("tool/callStarted") => "tool.call.started",
        Some("tool/callCompleted") => "tool.call.completed",
        _ => return Ok(None),
    };

    Ok(Some(StoredEvent {
        id: 0,
        event_type: event_type.to_string(),
        payload_json: envelope.params.unwrap_or_default().to_string(),
    }))
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
cargo test -p agent-workspace-daemon codex_rpc_maps_message_and_file_change_events
```

Expected:

```text
test codex_rpc_maps_message_and_file_change_events ... ok
```

- [ ] **Step 5: Commit the Codex adapter**

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
git add daemon/src/adapters/mod.rs daemon/src/adapters/process.rs daemon/src/adapters/codex.rs daemon/tests/codex_adapter_test.rs daemon/tests/fixtures/codex_rpc.jsonl
git commit -m "feat: add codex managed-session adapter"
```

## Task 4: Add Managed Session APIs And WebSocket Event Streaming

**Files:**
- Create: `agent-workspace/daemon/src/http/ws.rs`
- Modify: `agent-workspace/daemon/src/session/service.rs`
- Modify: `agent-workspace/daemon/src/http/dto.rs`
- Modify: `agent-workspace/daemon/src/http/routes.rs`
- Modify: `agent-workspace/daemon/src/app.rs`
- Create: `agent-workspace/daemon/tests/managed_session_api_test.rs`
- Create: `agent-workspace/daemon/tests/session_stream_test.rs`

- [ ] **Step 1: Write the failing managed-session API test**

```rust
// agent-workspace/daemon/tests/managed_session_api_test.rs
use axum::body::{to_bytes, Body};
use axum::http::{Request, StatusCode};
use tower::ServiceExt;

use agent_workspace_daemon::app::build_test_router;

#[tokio::test]
async fn list_sessions_returns_managed_session_summary() {
    let app = build_test_router().await;

    let login = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/auth/login")
                .header("content-type", "application/json")
                .body(Body::from(r#"{"pin":"1234"}"#))
                .unwrap(),
        )
        .await
        .unwrap();

    let cookie = login.headers().get("set-cookie").unwrap().to_str().unwrap().to_string();

    app.clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/sessions")
                .header("content-type", "application/json")
                .header("cookie", cookie.clone())
                .body(Body::from(r#"{"rootId":"workspace","path":"repo","agentKind":"claude"}"#))
                .unwrap(),
        )
        .await
        .unwrap();

    let list = app
        .oneshot(
            Request::builder()
                .uri("/api/sessions")
                .header("cookie", cookie)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(list.status(), StatusCode::OK);
    let body = to_bytes(list.into_body(), usize::MAX).await.unwrap();
    assert!(String::from_utf8(body.to_vec()).unwrap().contains("\"agentKind\":\"claude\""));
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
cargo test -p agent-workspace-daemon list_sessions_returns_managed_session_summary
```

Expected:

```text
assertion `left == right` failed
```

- [ ] **Step 3: Implement session listing, detail fetch, and stream registration**

```rust
// agent-workspace/daemon/src/http/dto.rs
#[derive(Serialize)]
pub struct SessionSummaryDto {
    pub id: String,
    #[serde(rename = "agentKind")]
    pub agent_kind: String,
    pub status: String,
    #[serde(rename = "workspacePath")]
    pub workspace_path: String,
}
```

```rust
// agent-workspace/daemon/src/session/service.rs
pub async fn list_sessions(&self) -> anyhow::Result<Vec<crate::session::model::SessionSummary>> {
    self.store.list_sessions().await
}
```

```rust
// agent-workspace/daemon/src/http/routes.rs
.route("/api/sessions", post(create_session).get(list_sessions))
```

```rust
// agent-workspace/daemon/src/http/ws.rs
use axum::extract::ws::{Message, WebSocket};

pub async fn send_snapshot(socket: &mut WebSocket, payload: String) -> anyhow::Result<()> {
    socket.send(Message::Text(payload.into())).await?;
    Ok(())
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
cargo test -p agent-workspace-daemon list_sessions_returns_managed_session_summary
```

Expected:

```text
test list_sessions_returns_managed_session_summary ... ok
```

- [ ] **Step 5: Commit the managed-session APIs**

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
git add daemon/src/app.rs daemon/src/http/dto.rs daemon/src/http/routes.rs daemon/src/http/ws.rs daemon/src/session/service.rs daemon/tests/managed_session_api_test.rs daemon/tests/session_stream_test.rs
git commit -m "feat: add managed session listing and stream shell"
```

## Task 5: Replace The Placeholder Frontend With Real Session Flows

**Files:**
- Modify: `agent-workspace/frontend/src/api.ts`
- Modify: `agent-workspace/frontend/src/types.ts`
- Modify: `agent-workspace/frontend/src/App.tsx`
- Modify: `agent-workspace/frontend/src/components/CreateSessionView.tsx`
- Modify: `agent-workspace/frontend/src/components/SessionListView.tsx`
- Modify: `agent-workspace/frontend/src/styles.css`
- Create: `agent-workspace/frontend/src/components/SessionDetailView.tsx`
- Create: `agent-workspace/frontend/src/components/TimelineCards.tsx`
- Create: `agent-workspace/frontend/src/components/Composer.tsx`
- Create: `agent-workspace/frontend/src/components/__tests__/SessionDetailView.test.tsx`
- Modify: `agent-workspace/frontend/src/components/__tests__/SessionListView.test.tsx`

- [ ] **Step 1: Write the failing session-detail UI test**

```tsx
// agent-workspace/frontend/src/components/__tests__/SessionDetailView.test.tsx
import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { SessionDetailView } from "../SessionDetailView";

describe("SessionDetailView", () => {
  it("renders thinking, message, and file-change cards", () => {
    render(
      <SessionDetailView
        session={{
          id: "sess-1",
          agentKind: "claude",
          events: [
            { id: 1, eventType: "assistant.thinking.delta", payload: { text: "plan first" } },
            { id: 2, eventType: "assistant.message", payload: { text: "done" } },
            { id: 3, eventType: "file.change.reported", payload: { files: ["src/app.rs"] } },
          ],
        }}
        onSend={() => {}}
      />,
    );

    expect(screen.getByText("Thinking")).toBeInTheDocument();
    expect(screen.getByText("done")).toBeInTheDocument();
    expect(screen.getByText("src/app.rs")).toBeInTheDocument();
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace/frontend
npm test -- --run SessionDetailView
```

Expected:

```text
Failed to resolve import "../SessionDetailView"
```

- [ ] **Step 3: Implement real session fetch/create/detail flows and timeline cards**

```ts
// agent-workspace/frontend/src/api.ts
export interface SessionEvent {
  id: number;
  eventType: string;
  payload: Record<string, unknown>;
}

export async function listSessions(): Promise<SessionSummary[]> {
  const response = await fetch("/api/sessions");
  if (!response.ok) throw new Error("Failed to load sessions");
  const data = (await response.json()) as { sessions: SessionSummary[] };
  return data.sessions;
}

export async function createSession(input: CreateSessionInput): Promise<SessionDetail> {
  const response = await fetch("/api/sessions", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(input),
  });
  if (!response.ok) throw new Error("Failed to create session");
  return (await response.json()) as SessionDetail;
}
```

```tsx
// agent-workspace/frontend/src/components/TimelineCards.tsx
export function ThinkingCard(props: { text: string }) {
  return (
    <details>
      <summary>Thinking</summary>
      <pre>{props.text}</pre>
    </details>
  );
}

export function MessageCard(props: { text: string }) {
  return <section><p>{props.text}</p></section>;
}

export function FileChangeCard(props: { files: string[] }) {
  return (
    <section>
      <h3>Files changed</h3>
      <ul>{props.files.map((file) => <li key={file}>{file}</li>)}</ul>
    </section>
  );
}
```

```tsx
// agent-workspace/frontend/src/components/Composer.tsx
import { useState } from "react";

export function Composer(props: { onSend: (message: string) => void }) {
  const [value, setValue] = useState("");

  return (
    <form
      onSubmit={(event) => {
        event.preventDefault();
        props.onSend(value);
        setValue("");
      }}
    >
      <textarea aria-label="Message" value={value} onChange={(event) => setValue(event.target.value)} />
      <button type="submit">Send</button>
    </form>
  );
}
```

- [ ] **Step 4: Run the frontend tests to verify they pass**

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace/frontend
npm test
```

Expected:

```text
Test Files  ... passed
```

- [ ] **Step 5: Commit the structured timeline UI**

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
git add frontend/src/api.ts frontend/src/types.ts frontend/src/App.tsx frontend/src/styles.css frontend/src/components/CreateSessionView.tsx frontend/src/components/SessionListView.tsx frontend/src/components/SessionDetailView.tsx frontend/src/components/TimelineCards.tsx frontend/src/components/Composer.tsx frontend/src/components/__tests__/SessionDetailView.test.tsx frontend/src/components/__tests__/SessionListView.test.tsx
git commit -m "feat: add managed session timeline ui"
```

## Task 6: Verify The Managed Sessions Slice

**Files:**
- Modify: `agent-workspace/README.md`
- Test: `agent-workspace/daemon/tests/event_store_test.rs`
- Test: `agent-workspace/daemon/tests/claude_adapter_test.rs`
- Test: `agent-workspace/daemon/tests/codex_adapter_test.rs`
- Test: `agent-workspace/daemon/tests/managed_session_api_test.rs`
- Test: `agent-workspace/daemon/tests/session_stream_test.rs`
- Test: `agent-workspace/frontend/src/components/__tests__/SessionDetailView.test.tsx`
- Test: `agent-workspace/frontend/src/components/__tests__/SessionListView.test.tsx`

- [ ] **Step 1: Add a managed-sessions section to the README**

```markdown
## Managed Sessions

This slice adds:

- managed `Claude` launch contract
- managed `Codex` app-server contract
- unified structured event mapping
- session list/detail flows in the browser UI
```

- [ ] **Step 2: Run the daemon test suite**

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
cargo test -p agent-workspace-daemon
```

Expected:

```text
test result: ok
```

- [ ] **Step 3: Run the frontend test suite**

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace/frontend
npm test
```

Expected:

```text
Test Files  ... passed
```

- [ ] **Step 4: Run both builds**

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
cargo build -p agent-workspace-daemon
cd /home/jhz/tools/agent-terminal-platform/agent-workspace/frontend
npm run build
```

Expected:

```text
Finished `dev` profile ...
vite ... built in ...
```

- [ ] **Step 5: Commit the verified managed-sessions slice**

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
git add README.md
git commit -m "docs: document managed sessions slice"
```

## Self-Review Notes

- Spec coverage for this slice:
  - managed `Codex` and `Claude` adapters: covered by Tasks 2-3
  - unified event mapping: covered by Tasks 1-4
  - structured timeline UI: covered by Task 5
  - event streaming shell: covered by Task 4
- Intentional omissions:
  - best-effort attach is deferred to the next plan
  - persistent replay after daemon restart is deferred to the next plan
  - mobile polish beyond responsive browser shell is deferred to the next plan
- Type consistency:
  - Rust store uses `event_type`
  - browser DTOs use `eventType`
  - `placeholder` remains only a foundation bootstrap agent kind

## Execution Handoff

Plan complete and saved to `agent-workspace/docs/plans/2026-06-10-agent-workspace-managed-sessions-implementation-plan.md`.

Two execution options:

1. **Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration
2. **Inline Execution** - Execute tasks in this session using `executing-plans`, batch execution with checkpoints

Which approach?
