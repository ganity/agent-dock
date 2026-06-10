# Agent Workspace Recovery And Attach Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add durable on-disk persistence, restart recovery, best-effort attach support for existing `codex`/`claude` conversations, and mobile-specific UI polish to `agent-workspace`.

**Architecture:** This slice converts the daemon from an in-memory prototype into a restart-safe local service. The Rust daemon will load configuration from a file, persist its SQLite database to disk, recover existing sessions on restart, and support creating local session records that bind to pre-existing `codex` threads or `claude` session ids. The frontend will keep the same core layout but add small-screen refinements for the now-persistent session list and detail experience.

**Tech Stack:** Rust, Tokio, Axum, Serde, SQLx with SQLite, React, TypeScript, Vite, Vitest, Testing Library

---

## File Structure

### Rust daemon

- Modify: `agent-workspace/daemon.example.toml`
- Modify: `agent-workspace/daemon/src/config.rs`
- Modify: `agent-workspace/daemon/src/app.rs`
- Modify: `agent-workspace/daemon/src/main.rs`
- Modify: `agent-workspace/daemon/src/http/dto.rs`
- Modify: `agent-workspace/daemon/src/http/routes.rs`
- Modify: `agent-workspace/daemon/src/session/model.rs`
- Modify: `agent-workspace/daemon/src/session/store.rs`
- Modify: `agent-workspace/daemon/src/session/service.rs`
- Modify: `agent-workspace/daemon/src/adapters/codex_protocol.rs`

### Rust tests

- Create: `agent-workspace/daemon/tests/persistence_recovery_test.rs`
- Create: `agent-workspace/daemon/tests/attach_session_api_test.rs`
- Modify: `agent-workspace/daemon/tests/managed_runtime_test.rs`
- Modify: `agent-workspace/daemon/tests/session_stream_test.rs`

### Browser UI

- Modify: `agent-workspace/frontend/src/App.tsx`
- Modify: `agent-workspace/frontend/src/api.ts`
- Modify: `agent-workspace/frontend/src/types.ts`
- Modify: `agent-workspace/frontend/src/styles.css`
- Modify: `agent-workspace/frontend/src/components/SessionListView.tsx`
- Modify: `agent-workspace/frontend/src/components/SessionDetailView.tsx`
- Modify: `agent-workspace/frontend/src/components/CreateSessionView.tsx`
- Create: `agent-workspace/frontend/src/components/AttachSessionView.tsx`
- Create: `agent-workspace/frontend/src/components/__tests__/AttachSessionView.test.tsx`
- Modify: `agent-workspace/frontend/src/App.test.tsx`

## Task 1: Move The Daemon To Durable File-Backed Persistence

**Files:**
- Modify: `agent-workspace/daemon.example.toml`
- Modify: `agent-workspace/daemon/src/config.rs`
- Modify: `agent-workspace/daemon/src/app.rs`
- Modify: `agent-workspace/daemon/src/main.rs`
- Modify: `agent-workspace/daemon/src/session/store.rs`
- Create: `agent-workspace/daemon/tests/persistence_recovery_test.rs`

- [ ] **Step 1: Write the failing persistence recovery test**

```rust
// agent-workspace/daemon/tests/persistence_recovery_test.rs
use tempfile::tempdir;

use agent_workspace_daemon::session::store::SqliteSessionStore;

#[tokio::test]
async fn file_backed_store_recovers_sessions_and_events_after_reopen() {
    let dir = tempdir().unwrap();
    let db_path = dir.path().join("agent-workspace.sqlite3");

    let store = SqliteSessionStore::from_path(&db_path).await.unwrap();
    let session_id = store
        .create_session("workspace".into(), "repo".into(), "managed".into(), "codex".into())
        .await
        .unwrap();
    store
        .append_event(&session_id, "session.created", r#"{"status":"created"}"#)
        .await
        .unwrap();

    drop(store);

    let reopened = SqliteSessionStore::from_path(&db_path).await.unwrap();
    let snapshot = reopened.load_snapshot(&session_id).await.unwrap();

    assert_eq!(snapshot.session.id, session_id);
    assert_eq!(snapshot.events.len(), 1);
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
cargo test -p agent-workspace-daemon file_backed_store_recovers_sessions_and_events_after_reopen
```

Expected:

```text
error[E0599]: no function or associated item named `from_path`
```

- [ ] **Step 3: Implement file-backed SQLite configuration**

```toml
# agent-workspace/daemon.example.toml
listen = "127.0.0.1:4123"
pin = "1234"
database_path = "./daemon-data/agent-workspace.sqlite3"
```

```rust
// agent-workspace/daemon/src/config.rs
#[derive(Clone)]
pub struct AppConfig {
    pub listen: String,
    pub pin: String,
    pub database_path: String,
    pub roots: Vec<WorkspaceRoot>,
}
```

```rust
// agent-workspace/daemon/src/session/store.rs
pub async fn from_path(path: &std::path::Path) -> anyhow::Result<Self> {
    if let Some(parent) = path.parent() {
        tokio::fs::create_dir_all(parent).await?;
    }

    let url = format!("sqlite://{}", path.display());
    let pool = SqlitePool::connect(&url).await?;
    sqlx::migrate!("./migrations").run(&pool).await?;
    Ok(Self { pool })
}
```

```rust
// agent-workspace/daemon/src/app.rs
let store = SqliteSessionStore::from_path(std::path::Path::new(&config.database_path))
    .await
    .unwrap();
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
cargo test -p agent-workspace-daemon file_backed_store_recovers_sessions_and_events_after_reopen
```

Expected:

```text
test file_backed_store_recovers_sessions_and_events_after_reopen ... ok
```

- [ ] **Step 5: Commit the persistence move**

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
git add daemon.example.toml daemon/src/config.rs daemon/src/app.rs daemon/src/main.rs daemon/src/session/store.rs daemon/tests/persistence_recovery_test.rs
git commit -m "feat: persist daemon state to disk"
```

## Task 2: Recover Sessions After Daemon Restart

**Files:**
- Modify: `agent-workspace/daemon/src/session/model.rs`
- Modify: `agent-workspace/daemon/src/session/service.rs`
- Modify: `agent-workspace/daemon/src/http/routes.rs`
- Modify: `agent-workspace/daemon/tests/persistence_recovery_test.rs`

- [ ] **Step 1: Write the failing recovery-on-start test**

```rust
// agent-workspace/daemon/tests/persistence_recovery_test.rs
#[tokio::test]
async fn session_service_lists_recovered_sessions_from_store() {
    let dir = tempdir().unwrap();
    let db_path = dir.path().join("agent-workspace.sqlite3");

    let store = SqliteSessionStore::from_path(&db_path).await.unwrap();
    store
        .create_session("workspace".into(), "repo".into(), "managed".into(), "codex".into())
        .await
        .unwrap();
    drop(store);

    let reopened = SqliteSessionStore::from_path(&db_path).await.unwrap();
    let service = SessionService::new(reopened);

    let sessions = service.list_sessions().await.unwrap();

    assert_eq!(sessions.len(), 1);
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
cargo test -p agent-workspace-daemon session_service_lists_recovered_sessions_from_store
```

Expected:

```text
assertion `left == right` failed
```

- [ ] **Step 3: Implement recovery-friendly session state**

```rust
// agent-workspace/daemon/src/session/model.rs
pub struct SessionSummary {
    pub id: String,
    pub workspace_path: String,
    pub source_kind: String,
    pub agent_kind: String,
    pub runtime_session_id: Option<String>,
    pub status: String,
}
```

```rust
// agent-workspace/daemon/src/session/store.rs
// include runtime_session_id in list_sessions query
```

```rust
// agent-workspace/daemon/src/session/service.rs
// list_sessions should return store-backed summaries without requiring any live runtime map
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
cargo test -p agent-workspace-daemon session_service_lists_recovered_sessions_from_store
```

Expected:

```text
test session_service_lists_recovered_sessions_from_store ... ok
```

- [ ] **Step 5: Commit the session recovery support**

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
git add daemon/src/session/model.rs daemon/src/session/service.rs daemon/src/http/routes.rs daemon/tests/persistence_recovery_test.rs
git commit -m "feat: recover session summaries after restart"
```

## Task 3: Add Best-Effort Attach Support For Existing Claude/Codex Conversations

**Files:**
- Modify: `agent-workspace/daemon/src/http/dto.rs`
- Modify: `agent-workspace/daemon/src/http/routes.rs`
- Modify: `agent-workspace/daemon/src/session/service.rs`
- Create: `agent-workspace/daemon/tests/attach_session_api_test.rs`

- [ ] **Step 1: Write the failing attach-session API test**

```rust
// agent-workspace/daemon/tests/attach_session_api_test.rs
use axum::body::{to_bytes, Body};
use axum::http::{Request, StatusCode};
use tower::ServiceExt;

use agent_workspace_daemon::app::build_test_router;

#[tokio::test]
async fn attach_session_creates_local_record_bound_to_existing_runtime_id() {
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

    let attach = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/sessions/attach")
                .header("content-type", "application/json")
                .header("cookie", cookie)
                .body(Body::from(
                    r#"{"rootId":"workspace","path":"repo","agentKind":"claude","runtimeSessionId":"thread-abc"}"#,
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(attach.status(), StatusCode::OK);
    let body = to_bytes(attach.into_body(), usize::MAX).await.unwrap();
    assert!(String::from_utf8(body.to_vec()).unwrap().contains("\"agentKind\":\"claude\""));
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
cargo test -p agent-workspace-daemon attach_session_creates_local_record_bound_to_existing_runtime_id
```

Expected:

```text
assertion `left == right` failed
```

- [ ] **Step 3: Implement attach-session inputs and persistence**

```rust
// agent-workspace/daemon/src/http/dto.rs
#[derive(Deserialize)]
pub struct AttachSessionRequest {
    #[serde(rename = "rootId")]
    pub root_id: String,
    pub path: String,
    #[serde(rename = "agentKind")]
    pub agent_kind: String,
    #[serde(rename = "runtimeSessionId")]
    pub runtime_session_id: String,
}
```

```rust
// agent-workspace/daemon/src/session/service.rs
pub async fn attach_existing_session(
    &self,
    root_id: String,
    workspace_path: String,
    agent_kind: String,
    runtime_session_id: String,
) -> anyhow::Result<String> {
    let session_id = self
        .store
        .create_session(root_id, workspace_path, "attached".into(), agent_kind)
        .await?;
    self.store
        .update_runtime_session_id(&session_id, &runtime_session_id)
        .await?;
    self.store
        .append_event(&session_id, "session.attached", &serde_json::json!({
            "runtimeSessionId": runtime_session_id
        }).to_string())
        .await?;
    Ok(session_id)
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
cargo test -p agent-workspace-daemon attach_session_creates_local_record_bound_to_existing_runtime_id
```

Expected:

```text
test attach_session_creates_local_record_bound_to_existing_runtime_id ... ok
```

- [ ] **Step 5: Commit attach support**

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
git add daemon/src/http/dto.rs daemon/src/http/routes.rs daemon/src/session/service.rs daemon/tests/attach_session_api_test.rs
git commit -m "feat: add attached session records"
```

## Task 4: Add Mobile-Specific UI Polish And Attach Entry Point

**Files:**
- Modify: `agent-workspace/frontend/src/App.tsx`
- Modify: `agent-workspace/frontend/src/api.ts`
- Modify: `agent-workspace/frontend/src/types.ts`
- Modify: `agent-workspace/frontend/src/styles.css`
- Modify: `agent-workspace/frontend/src/components/CreateSessionView.tsx`
- Create: `agent-workspace/frontend/src/components/AttachSessionView.tsx`
- Create: `agent-workspace/frontend/src/components/__tests__/AttachSessionView.test.tsx`

- [ ] **Step 1: Write the failing attach-session UI test**

```tsx
// agent-workspace/frontend/src/components/__tests__/AttachSessionView.test.tsx
import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

import { AttachSessionView } from "../AttachSessionView";

describe("AttachSessionView", () => {
  it("submits runtime session metadata", () => {
    const onSubmit = vi.fn();

    render(<AttachSessionView onSubmit={onSubmit} />);

    fireEvent.change(screen.getByLabelText("Agent"), { target: { value: "claude" } });
    fireEvent.change(screen.getByLabelText("Runtime session ID"), { target: { value: "thread-abc" } });
    fireEvent.change(screen.getByLabelText("Path"), { target: { value: "apps/api" } });
    fireEvent.click(screen.getByRole("button", { name: "Attach session" }));

    expect(onSubmit).toHaveBeenCalledWith({
      agentKind: "claude",
      runtimeSessionId: "thread-abc",
      path: "apps/api",
    });
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace/frontend
npm test -- --run AttachSessionView
```

Expected:

```text
Failed to resolve import "../AttachSessionView"
```

- [ ] **Step 3: Implement attach view and mobile polish**

```tsx
// agent-workspace/frontend/src/components/AttachSessionView.tsx
// form for agent, runtime session id, root, and path
```

```ts
// agent-workspace/frontend/src/api.ts
export async function attachSession(input: AttachSessionInput): Promise<SessionDetail> {
  const response = await fetch("/api/sessions/attach", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(input),
  });
  if (!response.ok) throw new Error("Failed to attach session");
  return (await response.json()) as SessionDetail;
}
```

```css
/* agent-workspace/frontend/src/styles.css */
@media (max-width: 720px) {
  .shell {
    padding: 16px;
  }

  .panel {
    padding: 16px;
    border-radius: 16px;
  }
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

- [ ] **Step 5: Commit the attach UI and mobile polish**

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
git add frontend/src/App.tsx frontend/src/api.ts frontend/src/types.ts frontend/src/styles.css frontend/src/components/CreateSessionView.tsx frontend/src/components/AttachSessionView.tsx frontend/src/components/__tests__/AttachSessionView.test.tsx
git commit -m "feat: add attach-session ui and mobile polish"
```

## Task 5: Verify Recovery And Attach End To End

**Files:**
- Modify: `agent-workspace/README.md`
- Test: `agent-workspace/daemon/tests/persistence_recovery_test.rs`
- Test: `agent-workspace/daemon/tests/attach_session_api_test.rs`
- Test: `agent-workspace/frontend/src/components/__tests__/AttachSessionView.test.tsx`

- [ ] **Step 1: Add restart recovery and attach notes to the README**

```markdown
## Recovery And Attach

This slice adds:

- file-backed SQLite persistence
- daemon restart recovery
- attached session records for pre-existing Claude/Codex conversations
- mobile polish for the browser UI
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

- [ ] **Step 5: Commit the verified recovery/attach slice**

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
git add README.md
git commit -m "docs: document recovery and attach support"
```

## Self-Review Notes

- Spec coverage for this slice:
  - durable persistence: covered by Tasks 1-2
  - attach support: covered by Tasks 3-4
  - mobile polish: covered by Task 4
  - full verification: covered by Task 5
- Intentional omissions:
  - this plan does not introduce a full diff viewer or editor
  - attach remains best-effort and metadata-driven, not a deep external process adoption layer
- Type consistency:
  - `runtimeSessionId` in frontend DTOs maps to `runtime_session_id` in daemon storage
  - `attached` is the only new `source_kind` introduced here

## Execution Handoff

Plan complete and saved to `agent-workspace/docs/plans/2026-06-10-agent-workspace-recovery-and-attach-implementation-plan.md`.

Two execution options:

1. **Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration
2. **Inline Execution** - Execute tasks in this session using `executing-plans`, batch execution with checkpoints

Which approach?
