# Agent Workspace Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create the new `agent-workspace` repository, bootstrap the Rust daemon and browser shell, and ship a working foundation with login, workspace browsing, local session persistence, and a basic session list/create flow.

**Architecture:** This slice builds the product shell only. The Rust daemon exposes health, auth, workspace, and session snapshot APIs backed by SQLite; the browser UI handles login and shell navigation but does not yet run real managed `Codex` or `Claude` sessions. Structured event persistence is introduced now so later managed-session work can layer on the existing model instead of replacing it.

**Tech Stack:** Rust, Tokio, Axum, Serde, SQLx with SQLite, React, TypeScript, Vite, Vitest, Testing Library

---

## File Structure

### Repository root

- Create: `agent-workspace/.gitignore`
- Create: `agent-workspace/Cargo.toml`
- Create: `agent-workspace/rust-toolchain.toml`
- Create: `agent-workspace/README.md`
- Create: `agent-workspace/daemon.example.toml`

### Rust daemon

- Create: `agent-workspace/daemon/Cargo.toml`
- Create: `agent-workspace/daemon/src/lib.rs`
- Create: `agent-workspace/daemon/src/main.rs`
- Create: `agent-workspace/daemon/src/app.rs`
- Create: `agent-workspace/daemon/src/config.rs`
- Create: `agent-workspace/daemon/src/auth.rs`
- Create: `agent-workspace/daemon/src/workspace.rs`
- Create: `agent-workspace/daemon/src/http/mod.rs`
- Create: `agent-workspace/daemon/src/http/dto.rs`
- Create: `agent-workspace/daemon/src/http/routes.rs`
- Create: `agent-workspace/daemon/src/session/mod.rs`
- Create: `agent-workspace/daemon/src/session/model.rs`
- Create: `agent-workspace/daemon/src/session/store.rs`
- Create: `agent-workspace/daemon/src/session/service.rs`
- Create: `agent-workspace/daemon/migrations/0001_init.sql`

### Rust tests

- Create: `agent-workspace/daemon/tests/health_test.rs`
- Create: `agent-workspace/daemon/tests/auth_api_test.rs`
- Create: `agent-workspace/daemon/tests/store_test.rs`
- Create: `agent-workspace/daemon/tests/session_api_test.rs`

### Browser UI

- Create: `agent-workspace/frontend/package.json`
- Create: `agent-workspace/frontend/tsconfig.json`
- Create: `agent-workspace/frontend/vite.config.ts`
- Create: `agent-workspace/frontend/index.html`
- Create: `agent-workspace/frontend/src/main.tsx`
- Create: `agent-workspace/frontend/src/App.tsx`
- Create: `agent-workspace/frontend/src/api.ts`
- Create: `agent-workspace/frontend/src/types.ts`
- Create: `agent-workspace/frontend/src/styles.css`
- Create: `agent-workspace/frontend/src/test-setup.ts`
- Create: `agent-workspace/frontend/src/components/LoginView.tsx`
- Create: `agent-workspace/frontend/src/components/SessionListView.tsx`
- Create: `agent-workspace/frontend/src/components/CreateSessionView.tsx`
- Create: `agent-workspace/frontend/src/components/__tests__/LoginView.test.tsx`
- Create: `agent-workspace/frontend/src/components/__tests__/SessionListView.test.tsx`

## Task 1: Bootstrap The New Repository And Daemon Shell

**Files:**
- Create: `agent-workspace/.gitignore`
- Create: `agent-workspace/Cargo.toml`
- Create: `agent-workspace/rust-toolchain.toml`
- Create: `agent-workspace/README.md`
- Create: `agent-workspace/daemon/Cargo.toml`
- Create: `agent-workspace/daemon/src/lib.rs`
- Create: `agent-workspace/daemon/src/main.rs`
- Create: `agent-workspace/daemon/src/app.rs`
- Test: `agent-workspace/daemon/tests/health_test.rs`

- [ ] **Step 1: Write the failing daemon health test**

```rust
// agent-workspace/daemon/tests/health_test.rs
use axum::body::{to_bytes, Body};
use axum::http::{Request, StatusCode};
use tower::ServiceExt;

use agent_workspace_daemon::app::build_test_router;

#[tokio::test]
async fn health_endpoint_returns_ok_and_body() {
    let app = build_test_router().await;

    let response = app
        .oneshot(Request::builder().uri("/api/health").body(Body::empty()).unwrap())
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);

    let body = to_bytes(response.into_body(), usize::MAX).await.unwrap();
    assert_eq!(&body[..], br#"{"ok":true}"#);
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
cargo test -p agent-workspace-daemon health_endpoint_returns_ok_and_body
```

Expected:

```text
error: could not find `Cargo.toml`
```

- [ ] **Step 3: Create the workspace, daemon crate, and minimal router**

```toml
# agent-workspace/Cargo.toml
[workspace]
members = ["daemon"]
resolver = "2"
```

```toml
# agent-workspace/rust-toolchain.toml
[toolchain]
channel = "stable"
components = ["clippy", "rustfmt"]
```

```gitignore
# agent-workspace/.gitignore
/target
/frontend/node_modules
/frontend/dist
/daemon-data
```

```markdown
# agent-workspace/README.md
# Agent Workspace

Single-user, browser-first coding workspace backed by a local Rust daemon.

## Foundation Scope

- fixed PIN login
- workspace browsing
- SQLite-backed session persistence
- browser shell for login and session listing
```

```toml
# agent-workspace/daemon/Cargo.toml
[package]
name = "agent-workspace-daemon"
version = "0.1.0"
edition = "2024"

[lib]
name = "agent_workspace_daemon"
path = "src/lib.rs"

[[bin]]
name = "agent-workspace-daemon"
path = "src/main.rs"

[dependencies]
anyhow = "1.0"
axum = { version = "0.8", features = ["macros"] }
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
tokio = { version = "1.47", features = ["macros", "rt-multi-thread", "net"] }
tower = "0.5"

[dev-dependencies]
tower = { version = "0.5", features = ["util"] }
```

```rust
// agent-workspace/daemon/src/lib.rs
pub mod app;
```

```rust
// agent-workspace/daemon/src/app.rs
use axum::{routing::get, Json, Router};
use serde_json::json;

async fn health() -> Json<serde_json::Value> {
    Json(json!({ "ok": true }))
}

pub fn build_router() -> Router {
    Router::new().route("/api/health", get(health))
}

pub async fn build_test_router() -> Router {
    build_router()
}
```

```rust
// agent-workspace/daemon/src/main.rs
use std::net::SocketAddr;

use agent_workspace_daemon::app::build_router;

#[tokio::main]
async fn main() {
    let address: SocketAddr = "127.0.0.1:4123".parse().unwrap();
    let listener = tokio::net::TcpListener::bind(address).await.unwrap();
    axum::serve(listener, build_router()).await.unwrap();
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run:

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
cargo test -p agent-workspace-daemon health_endpoint_returns_ok_and_body
```

Expected:

```text
test health_endpoint_returns_ok_and_body ... ok
```

- [ ] **Step 5: Initialize git and commit the bootstrap**

Run:

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
git init
git add .gitignore Cargo.toml rust-toolchain.toml README.md daemon/Cargo.toml daemon/src/lib.rs daemon/src/app.rs daemon/src/main.rs daemon/tests/health_test.rs
git commit -m "chore: bootstrap agent workspace foundation"
```

## Task 2: Add Config, Fixed-PIN Auth, And Workspace Browsing APIs

**Files:**
- Create: `agent-workspace/daemon.example.toml`
- Create: `agent-workspace/daemon/src/config.rs`
- Create: `agent-workspace/daemon/src/auth.rs`
- Create: `agent-workspace/daemon/src/workspace.rs`
- Create: `agent-workspace/daemon/src/http/mod.rs`
- Create: `agent-workspace/daemon/src/http/dto.rs`
- Create: `agent-workspace/daemon/src/http/routes.rs`
- Modify: `agent-workspace/daemon/src/lib.rs`
- Modify: `agent-workspace/daemon/src/app.rs`
- Modify: `agent-workspace/daemon/src/main.rs`
- Modify: `agent-workspace/daemon/Cargo.toml`
- Test: `agent-workspace/daemon/tests/auth_api_test.rs`

- [ ] **Step 1: Write the failing auth and workspace API test**

```rust
// agent-workspace/daemon/tests/auth_api_test.rs
use axum::body::{to_bytes, Body};
use axum::http::{Request, StatusCode};
use tower::ServiceExt;

use agent_workspace_daemon::app::build_test_router;

#[tokio::test]
async fn login_unlocks_workspace_root_listing() {
    let app = build_test_router().await;

    let unauthenticated = app
        .clone()
        .oneshot(Request::builder().uri("/api/workspaces/roots").body(Body::empty()).unwrap())
        .await
        .unwrap();

    assert_eq!(unauthenticated.status(), StatusCode::UNAUTHORIZED);

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

    assert_eq!(login.status(), StatusCode::OK);

    let cookie = login.headers().get("set-cookie").unwrap().to_str().unwrap().to_string();

    let roots = app
        .oneshot(
            Request::builder()
                .uri("/api/workspaces/roots")
                .header("cookie", cookie)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(roots.status(), StatusCode::OK);

    let body = to_bytes(roots.into_body(), usize::MAX).await.unwrap();
    assert_eq!(
        &body[..],
        br#"{"roots":[{"id":"workspace","label":"Workspace","path":"/tmp/workspace"}]}"#
    );
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
cargo test -p agent-workspace-daemon login_unlocks_workspace_root_listing
```

Expected:

```text
assertion `left == right` failed
```

- [ ] **Step 3: Implement config, auth, and workspace routes**

```toml
# agent-workspace/daemon.example.toml
listen = "127.0.0.1:4123"
pin = "1234"

[[roots]]
id = "workspace"
label = "Workspace"
path = "/tmp/workspace"
```

```toml
# agent-workspace/daemon/Cargo.toml
[dependencies]
anyhow = "1.0"
axum = { version = "0.8", features = ["macros"] }
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
tokio = { version = "1.47", features = ["macros", "rt-multi-thread", "net"] }
tower = "0.5"
uuid = { version = "1.18", features = ["v4"] }
```

```rust
// agent-workspace/daemon/src/config.rs
#[derive(Clone)]
pub struct WorkspaceRoot {
    pub id: String,
    pub label: String,
    pub path: String,
}

#[derive(Clone)]
pub struct AppConfig {
    pub listen: String,
    pub pin: String,
    pub roots: Vec<WorkspaceRoot>,
}

impl AppConfig {
    pub fn for_tests() -> Self {
        Self {
            listen: "127.0.0.1:4123".into(),
            pin: "1234".into(),
            roots: vec![WorkspaceRoot {
                id: "workspace".into(),
                label: "Workspace".into(),
                path: "/tmp/workspace".into(),
            }],
        }
    }
}
```

```rust
// agent-workspace/daemon/src/auth.rs
use std::{collections::HashSet, sync::{Arc, Mutex}};

#[derive(Clone)]
pub struct AuthState {
    pin: Arc<String>,
    sessions: Arc<Mutex<HashSet<String>>>,
}

impl AuthState {
    pub fn new(pin: String) -> Self {
        Self {
            pin: Arc::new(pin),
            sessions: Arc::new(Mutex::new(HashSet::new())),
        }
    }

    pub fn login(&self, candidate: &str) -> Option<String> {
        if candidate != self.pin.as_str() {
            return None;
        }

        let token = uuid::Uuid::new_v4().to_string();
        self.sessions.lock().unwrap().insert(token.clone());
        Some(token)
    }

    pub fn is_authenticated(&self, token: &str) -> bool {
        self.sessions.lock().unwrap().contains(token)
    }
}
```

```rust
// agent-workspace/daemon/src/workspace.rs
use crate::config::WorkspaceRoot;

pub fn list_roots(roots: &[WorkspaceRoot]) -> Vec<WorkspaceRoot> {
    roots.to_vec()
}
```

```rust
// agent-workspace/daemon/src/http/dto.rs
use serde::{Deserialize, Serialize};

#[derive(Deserialize)]
pub struct LoginRequest {
    pub pin: String,
}

#[derive(Serialize)]
pub struct WorkspaceRootDto {
    pub id: String,
    pub label: String,
    pub path: String,
}
```

```rust
// agent-workspace/daemon/src/http/routes.rs
use axum::{
    extract::State,
    http::{header, HeaderMap, StatusCode},
    response::IntoResponse,
    routing::{get, post},
    Json, Router,
};
use serde_json::json;

use crate::{
    app::AppState,
    http::dto::{LoginRequest, WorkspaceRootDto},
    workspace,
};

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/api/health", get(health))
        .route("/api/auth/login", post(login))
        .route("/api/workspaces/roots", get(workspace_roots))
}

fn session_token_from_headers(headers: &HeaderMap) -> Option<&str> {
    headers
        .get(header::COOKIE)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.split("agent_workspace_session=").nth(1))
        .and_then(|value| value.split(';').next())
}

fn is_authenticated(state: &AppState, headers: &HeaderMap) -> bool {
    session_token_from_headers(headers)
        .is_some_and(|value| state.auth.is_authenticated(value))
}

async fn health() -> Json<serde_json::Value> {
    Json(json!({ "ok": true }))
}

async fn login(State(state): State<AppState>, Json(request): Json<LoginRequest>) -> impl IntoResponse {
    match state.auth.login(&request.pin) {
        Some(token) => {
            let headers = [(header::SET_COOKIE, format!("agent_workspace_session={token}; Path=/; HttpOnly"))];
            (StatusCode::OK, headers, Json(json!({ "ok": true }))).into_response()
        }
        None => (StatusCode::UNAUTHORIZED, Json(json!({ "error": "INVALID_PIN" }))).into_response(),
    }
}

async fn workspace_roots(State(state): State<AppState>, headers: HeaderMap) -> impl IntoResponse {
    if !is_authenticated(&state, &headers) {
        return (StatusCode::UNAUTHORIZED, Json(json!({ "error": "UNAUTHORIZED" }))).into_response();
    }

    let roots = workspace::list_roots(&state.config.roots)
        .into_iter()
        .map(|root| WorkspaceRootDto {
            id: root.id,
            label: root.label,
            path: root.path,
        })
        .collect::<Vec<_>>();

    (StatusCode::OK, Json(json!({ "roots": roots }))).into_response()
}
```

```rust
// agent-workspace/daemon/src/http/mod.rs
pub mod dto;
pub mod routes;
```

```rust
// agent-workspace/daemon/src/lib.rs
pub mod app;
pub mod auth;
pub mod config;
pub mod http;
pub mod workspace;
```

```rust
// agent-workspace/daemon/src/app.rs
use axum::Router;

use crate::{auth::AuthState, config::AppConfig, http::routes::routes};

#[derive(Clone)]
pub struct AppState {
    pub config: AppConfig,
    pub auth: AuthState,
}

pub fn build_router(config: AppConfig) -> Router {
    let state = AppState {
        auth: AuthState::new(config.pin.clone()),
        config,
    };

    routes().with_state(state)
}

pub async fn build_test_router() -> Router {
    build_router(AppConfig::for_tests())
}
```

```rust
// agent-workspace/daemon/src/main.rs
use std::net::SocketAddr;

use agent_workspace_daemon::{app::build_router, config::AppConfig};

#[tokio::main]
async fn main() {
    let config = AppConfig::for_tests();
    let address: SocketAddr = config.listen.parse().unwrap();
    let listener = tokio::net::TcpListener::bind(address).await.unwrap();
    axum::serve(listener, build_router(config)).await.unwrap();
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
cargo test -p agent-workspace-daemon auth_api_test
```

Expected:

```text
test login_unlocks_workspace_root_listing ... ok
```

- [ ] **Step 5: Commit the auth and workspace layer**

Run:

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
git add daemon.example.toml daemon/Cargo.toml daemon/src/lib.rs daemon/src/app.rs daemon/src/main.rs daemon/src/config.rs daemon/src/auth.rs daemon/src/workspace.rs daemon/src/http/mod.rs daemon/src/http/dto.rs daemon/src/http/routes.rs daemon/tests/auth_api_test.rs
git commit -m "feat: add daemon auth and workspace browsing"
```

## Task 3: Add SQLite Session Store And Snapshot Queries

**Files:**
- Create: `agent-workspace/daemon/src/session/mod.rs`
- Create: `agent-workspace/daemon/src/session/model.rs`
- Create: `agent-workspace/daemon/src/session/store.rs`
- Create: `agent-workspace/daemon/migrations/0001_init.sql`
- Modify: `agent-workspace/daemon/src/lib.rs`
- Modify: `agent-workspace/daemon/Cargo.toml`
- Test: `agent-workspace/daemon/tests/store_test.rs`

- [ ] **Step 1: Write the failing store test**

```rust
// agent-workspace/daemon/tests/store_test.rs
use agent_workspace_daemon::session::store::SqliteSessionStore;

#[tokio::test]
async fn store_builds_session_snapshot_in_event_order() {
    let store = SqliteSessionStore::in_memory().await.unwrap();
    let session_id = store
        .create_session("workspace".into(), "repo".into(), "managed".into(), "placeholder".into())
        .await
        .unwrap();

    store.append_event(&session_id, "session.created", r#"{"status":"created"}"#).await.unwrap();
    store.append_event(&session_id, "user.message", r#"{"text":"hello"}"#).await.unwrap();

    let snapshot = store.load_snapshot(&session_id).await.unwrap();

    assert_eq!(snapshot.session.id, session_id);
    assert_eq!(snapshot.events.len(), 2);
    assert_eq!(snapshot.events[0].event_type, "session.created");
    assert_eq!(snapshot.events[1].event_type, "user.message");
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
cargo test -p agent-workspace-daemon store_builds_session_snapshot_in_event_order
```

Expected:

```text
error[E0433]: failed to resolve: could not find `session`
```

- [ ] **Step 3: Implement the schema, models, and store**

```toml
# agent-workspace/daemon/Cargo.toml
[dependencies]
anyhow = "1.0"
axum = { version = "0.8", features = ["macros"] }
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
sqlx = { version = "0.8", features = ["runtime-tokio-rustls", "sqlite", "macros"] }
tokio = { version = "1.47", features = ["macros", "rt-multi-thread", "net"] }
tower = "0.5"
uuid = { version = "1.18", features = ["v4"] }

[dev-dependencies]
tempfile = "3.20"
tower = { version = "0.5", features = ["util"] }
```

```sql
-- agent-workspace/daemon/migrations/0001_init.sql
create table sessions (
  id text primary key,
  root_id text not null,
  workspace_path text not null,
  source_kind text not null,
  agent_kind text not null,
  status text not null,
  created_at text not null,
  updated_at text not null
);

create table session_events (
  id integer primary key autoincrement,
  session_id text not null,
  event_type text not null,
  payload_json text not null,
  created_at text not null
);
```

```rust
// agent-workspace/daemon/src/session/model.rs
#[derive(Clone, Debug, PartialEq)]
pub struct SessionRecord {
    pub id: String,
    pub root_id: String,
    pub workspace_path: String,
    pub source_kind: String,
    pub agent_kind: String,
    pub status: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct StoredEvent {
    pub id: i64,
    pub event_type: String,
    pub payload_json: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct SessionSnapshot {
    pub session: SessionRecord,
    pub events: Vec<StoredEvent>,
}
```

```rust
// agent-workspace/daemon/src/session/store.rs
use sqlx::{Row, SqlitePool};
use uuid::Uuid;

use crate::session::model::{SessionRecord, SessionSnapshot, StoredEvent};

pub struct SqliteSessionStore {
    pool: SqlitePool,
}

impl SqliteSessionStore {
    pub async fn in_memory() -> anyhow::Result<Self> {
        let pool = SqlitePool::connect("sqlite::memory:").await?;
        sqlx::migrate!("./migrations").run(&pool).await?;
        Ok(Self { pool })
    }

    pub async fn create_session(
        &self,
        root_id: String,
        workspace_path: String,
        source_kind: String,
        agent_kind: String,
    ) -> anyhow::Result<String> {
        let id = format!("sess_{}", Uuid::new_v4());
        sqlx::query(
            "insert into sessions (id, root_id, workspace_path, source_kind, agent_kind, status, created_at, updated_at)
             values (?1, ?2, ?3, ?4, ?5, 'created', datetime('now'), datetime('now'))",
        )
        .bind(&id)
        .bind(root_id)
        .bind(workspace_path)
        .bind(source_kind)
        .bind(agent_kind)
        .execute(&self.pool)
        .await?;
        Ok(id)
    }

    pub async fn append_event(&self, session_id: &str, event_type: &str, payload_json: &str) -> anyhow::Result<()> {
        sqlx::query(
            "insert into session_events (session_id, event_type, payload_json, created_at)
             values (?1, ?2, ?3, datetime('now'))",
        )
        .bind(session_id)
        .bind(event_type)
        .bind(payload_json)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn load_snapshot(&self, session_id: &str) -> anyhow::Result<SessionSnapshot> {
        let session_row = sqlx::query(
            "select id, root_id, workspace_path, source_kind, agent_kind, status from sessions where id = ?1",
        )
        .bind(session_id)
        .fetch_one(&self.pool)
        .await?;

        let session = SessionRecord {
            id: session_row.get("id"),
            root_id: session_row.get("root_id"),
            workspace_path: session_row.get("workspace_path"),
            source_kind: session_row.get("source_kind"),
            agent_kind: session_row.get("agent_kind"),
            status: session_row.get("status"),
        };

        let event_rows = sqlx::query(
            "select id, event_type, payload_json from session_events where session_id = ?1 order by id asc",
        )
        .bind(session_id)
        .fetch_all(&self.pool)
        .await?;

        let events = event_rows
            .into_iter()
            .map(|row| StoredEvent {
                id: row.get("id"),
                event_type: row.get("event_type"),
                payload_json: row.get("payload_json"),
            })
            .collect();

        Ok(SessionSnapshot { session, events })
    }
}
```

```rust
// agent-workspace/daemon/src/session/mod.rs
pub mod model;
pub mod store;
```

```rust
// agent-workspace/daemon/src/lib.rs
pub mod app;
pub mod auth;
pub mod config;
pub mod http;
pub mod session;
pub mod workspace;
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
cargo test -p agent-workspace-daemon store_builds_session_snapshot_in_event_order
```

Expected:

```text
test store_builds_session_snapshot_in_event_order ... ok
```

- [ ] **Step 5: Commit the session store**

Run:

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
git add daemon/Cargo.toml daemon/src/lib.rs daemon/src/session/mod.rs daemon/src/session/model.rs daemon/src/session/store.rs daemon/migrations/0001_init.sql daemon/tests/store_test.rs
git commit -m "feat: add sqlite session store"
```

## Task 4: Add Session Service And Placeholder Session APIs

**Files:**
- Create: `agent-workspace/daemon/src/session/service.rs`
- Modify: `agent-workspace/daemon/src/http/dto.rs`
- Modify: `agent-workspace/daemon/src/http/routes.rs`
- Modify: `agent-workspace/daemon/src/app.rs`
- Modify: `agent-workspace/daemon/src/lib.rs`
- Test: `agent-workspace/daemon/tests/session_api_test.rs`

- [ ] **Step 1: Write the failing session API test**

```rust
// agent-workspace/daemon/tests/session_api_test.rs
use axum::body::{to_bytes, Body};
use axum::http::{Request, StatusCode};
use tower::ServiceExt;

use agent_workspace_daemon::app::build_test_router;

#[tokio::test]
async fn create_session_returns_persisted_placeholder_snapshot() {
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

    let create = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/sessions")
                .header("content-type", "application/json")
                .header("cookie", cookie.clone())
                .body(Body::from(r#"{"rootId":"workspace","path":"repo","agentKind":"placeholder"}"#))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(create.status(), StatusCode::OK);

    let body = to_bytes(create.into_body(), usize::MAX).await.unwrap();
    let text = String::from_utf8(body.to_vec()).unwrap();

    assert!(text.contains("\"agentKind\":\"placeholder\""));
    assert!(text.contains("\"eventType\":\"session.created\""));
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
cargo test -p agent-workspace-daemon create_session_returns_persisted_placeholder_snapshot
```

Expected:

```text
assertion `left == right` failed
```

- [ ] **Step 3: Implement session service and HTTP DTOs**

```rust
// agent-workspace/daemon/src/session/service.rs
use std::sync::Arc;

use crate::session::store::SqliteSessionStore;

#[derive(Clone)]
pub struct SessionService {
    store: Arc<SqliteSessionStore>,
}

impl SessionService {
    pub fn new(store: SqliteSessionStore) -> Self {
        Self {
            store: Arc::new(store),
        }
    }

    pub async fn create_placeholder_session(
        &self,
        root_id: String,
        workspace_path: String,
        agent_kind: String,
    ) -> anyhow::Result<String> {
        let session_id = self
            .store
            .create_session(root_id, workspace_path, "managed".into(), agent_kind)
            .await?;
        self.store
            .append_event(&session_id, "session.created", r#"{"status":"created"}"#)
            .await?;
        Ok(session_id)
    }

    pub async fn load_snapshot(&self, session_id: &str) -> anyhow::Result<crate::session::model::SessionSnapshot> {
        self.store.load_snapshot(session_id).await
    }
}
```

```rust
// agent-workspace/daemon/src/http/dto.rs
use serde::{Deserialize, Serialize};

#[derive(Deserialize)]
pub struct CreateSessionRequest {
    #[serde(rename = "rootId")]
    pub root_id: String,
    pub path: String,
    #[serde(rename = "agentKind")]
    pub agent_kind: String,
}

#[derive(Serialize)]
pub struct SessionEventDto {
    pub id: i64,
    #[serde(rename = "eventType")]
    pub event_type: String,
    pub payload: serde_json::Value,
}

#[derive(Serialize)]
pub struct SessionSnapshotDto {
    pub id: String,
    #[serde(rename = "agentKind")]
    pub agent_kind: String,
    pub events: Vec<SessionEventDto>,
}
```

```rust
// agent-workspace/daemon/src/http/routes.rs
use crate::http::dto::{CreateSessionRequest, SessionEventDto, SessionSnapshotDto};

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/api/health", get(health))
        .route("/api/auth/login", post(login))
        .route("/api/workspaces/roots", get(workspace_roots))
        .route("/api/sessions", post(create_session))
}

async fn create_session(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<CreateSessionRequest>,
) -> impl IntoResponse {
    if !is_authenticated(&state, &headers) {
        return (StatusCode::UNAUTHORIZED, Json(json!({ "error": "UNAUTHORIZED" }))).into_response();
    }

    let session_id = state
        .sessions
        .create_placeholder_session(request.root_id, request.path, request.agent_kind)
        .await
        .unwrap();

    let snapshot = state.sessions.load_snapshot(&session_id).await.unwrap();
    let response = SessionSnapshotDto {
        id: snapshot.session.id,
        agent_kind: snapshot.session.agent_kind,
        events: snapshot
            .events
            .into_iter()
            .map(|event| SessionEventDto {
                id: event.id,
                event_type: event.event_type,
                payload: serde_json::from_str(&event.payload_json).unwrap(),
            })
            .collect(),
    };

    (StatusCode::OK, Json(response)).into_response()
}
```

```rust
// agent-workspace/daemon/src/app.rs
use crate::{auth::AuthState, config::AppConfig, http::routes::routes, session::{service::SessionService, store::SqliteSessionStore}};

#[derive(Clone)]
pub struct AppState {
    pub config: AppConfig,
    pub auth: AuthState,
    pub sessions: SessionService,
}

pub async fn build_test_router() -> Router {
    let config = AppConfig::for_tests();
    let store = SqliteSessionStore::in_memory().await.unwrap();
    let state = AppState {
        auth: AuthState::new(config.pin.clone()),
        config,
        sessions: SessionService::new(store),
    };
    routes().with_state(state)
}
```

```rust
// agent-workspace/daemon/src/lib.rs
pub mod app;
pub mod auth;
pub mod config;
pub mod http;
pub mod session;
pub mod workspace;
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
cargo test -p agent-workspace-daemon session_api_test
```

Expected:

```text
test create_session_returns_persisted_placeholder_snapshot ... ok
```

- [ ] **Step 5: Commit the placeholder session flow**

Run:

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
git add daemon/src/lib.rs daemon/src/app.rs daemon/src/http/dto.rs daemon/src/http/routes.rs daemon/src/session/service.rs daemon/tests/session_api_test.rs
git commit -m "feat: add placeholder session api"
```

## Task 5: Bootstrap The Browser Shell

**Files:**
- Create: `agent-workspace/frontend/package.json`
- Create: `agent-workspace/frontend/tsconfig.json`
- Create: `agent-workspace/frontend/vite.config.ts`
- Create: `agent-workspace/frontend/index.html`
- Create: `agent-workspace/frontend/src/main.tsx`
- Create: `agent-workspace/frontend/src/App.tsx`
- Create: `agent-workspace/frontend/src/api.ts`
- Create: `agent-workspace/frontend/src/types.ts`
- Create: `agent-workspace/frontend/src/styles.css`
- Create: `agent-workspace/frontend/src/test-setup.ts`
- Create: `agent-workspace/frontend/src/components/LoginView.tsx`
- Create: `agent-workspace/frontend/src/components/SessionListView.tsx`
- Create: `agent-workspace/frontend/src/components/CreateSessionView.tsx`
- Create: `agent-workspace/frontend/src/components/__tests__/LoginView.test.tsx`
- Create: `agent-workspace/frontend/src/components/__tests__/SessionListView.test.tsx`

- [ ] **Step 1: Write the failing login view test**

```tsx
// agent-workspace/frontend/src/components/__tests__/LoginView.test.tsx
import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

import { LoginView } from "../LoginView";

describe("LoginView", () => {
  it("submits the pin value", () => {
    const onSubmit = vi.fn();

    render(<LoginView loading={false} error={null} onSubmit={onSubmit} />);

    fireEvent.change(screen.getByLabelText("PIN"), { target: { value: "1234" } });
    fireEvent.click(screen.getByRole("button", { name: "Unlock" }));

    expect(onSubmit).toHaveBeenCalledWith("1234");
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace/frontend
npm test -- --run LoginView
```

Expected:

```text
npm ERR! Missing script: "test"
```

- [ ] **Step 3: Implement the browser shell**

```json
// agent-workspace/frontend/package.json
{
  "name": "@agent-workspace/frontend",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "tsc -p tsconfig.json && vite build",
    "test": "vitest run"
  },
  "dependencies": {
    "react": "^19.1.0",
    "react-dom": "^19.1.0"
  },
  "devDependencies": {
    "@testing-library/jest-dom": "^6.9.1",
    "@testing-library/react": "^16.3.0",
    "@testing-library/user-event": "^14.6.1",
    "@types/react": "^19.1.6",
    "@types/react-dom": "^19.1.5",
    "@vitejs/plugin-react": "^4.5.2",
    "jsdom": "^26.1.0",
    "typescript": "^5.8.3",
    "vite": "^6.3.5",
    "vitest": "^3.2.4"
  }
}
```

```tsx
// agent-workspace/frontend/src/components/LoginView.tsx
import { useState } from "react";

export function LoginView(props: {
  loading: boolean;
  error: string | null;
  onSubmit: (pin: string) => void;
}) {
  const [pin, setPin] = useState("");

  return (
    <form
      onSubmit={(event) => {
        event.preventDefault();
        props.onSubmit(pin);
      }}
    >
      <label>
        PIN
        <input aria-label="PIN" value={pin} onChange={(event) => setPin(event.target.value)} />
      </label>
      <button type="submit" disabled={props.loading}>Unlock</button>
      {props.error ? <p>{props.error}</p> : null}
    </form>
  );
}
```

```tsx
// agent-workspace/frontend/src/components/SessionListView.tsx
export interface SessionSummary {
  id: string;
  agentKind: string;
}

export function SessionListView(props: {
  sessions: SessionSummary[];
  onCreate: () => void;
}) {
  return (
    <section>
      <button onClick={props.onCreate}>New session</button>
      <ul>
        {props.sessions.map((session) => (
          <li key={session.id}>{session.agentKind}</li>
        ))}
      </ul>
    </section>
  );
}
```

```tsx
// agent-workspace/frontend/src/components/CreateSessionView.tsx
export function CreateSessionView(props: {
  onSubmit: (input: { rootId: string; path: string; agentKind: string }) => void;
}) {
  return (
    <button onClick={() => props.onSubmit({ rootId: "workspace", path: "repo", agentKind: "placeholder" })}>
      Create placeholder session
    </button>
  );
}
```

```tsx
// agent-workspace/frontend/src/App.tsx
import { useState } from "react";

import { LoginView } from "./components/LoginView";
import { SessionListView, type SessionSummary } from "./components/SessionListView";

export default function App() {
  const [authenticated, setAuthenticated] = useState(false);
  const [sessions] = useState<SessionSummary[]>([]);

  if (!authenticated) {
    return (
      <LoginView
        loading={false}
        error={null}
        onSubmit={() => {
          setAuthenticated(true);
        }}
      />
    );
  }

  return <SessionListView sessions={sessions} onCreate={() => {}} />;
}
```

- [ ] **Step 4: Run the UI tests to verify they pass**

Run:

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace/frontend
npm install
npm test -- --run LoginView
```

Expected:

```text
✓ LoginView.test.tsx
```

- [ ] **Step 5: Commit the browser shell**

Run:

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
git add frontend/package.json frontend/tsconfig.json frontend/vite.config.ts frontend/index.html frontend/src/main.tsx frontend/src/App.tsx frontend/src/api.ts frontend/src/types.ts frontend/src/styles.css frontend/src/test-setup.ts frontend/src/components/LoginView.tsx frontend/src/components/SessionListView.tsx frontend/src/components/CreateSessionView.tsx frontend/src/components/__tests__/LoginView.test.tsx frontend/src/components/__tests__/SessionListView.test.tsx
git commit -m "feat: add browser shell foundation"
```

## Task 6: Verify Foundation End To End

**Files:**
- Modify: `agent-workspace/README.md`
- Test: `agent-workspace/daemon/tests/health_test.rs`
- Test: `agent-workspace/daemon/tests/auth_api_test.rs`
- Test: `agent-workspace/daemon/tests/store_test.rs`
- Test: `agent-workspace/daemon/tests/session_api_test.rs`
- Test: `agent-workspace/frontend/src/components/__tests__/LoginView.test.tsx`
- Test: `agent-workspace/frontend/src/components/__tests__/SessionListView.test.tsx`

- [ ] **Step 1: Add a short setup section to the README**

```markdown
## Run The Foundation

### Daemon

```bash
cargo run -p agent-workspace-daemon
```

### Frontend

```bash
cd frontend
npm install
npm run dev
```
```

- [ ] **Step 2: Run the daemon tests**

Run:

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
cargo test -p agent-workspace-daemon
```

Expected:

```text
test result: ok
```

- [ ] **Step 3: Run the frontend tests**

Run:

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace/frontend
npm test
```

Expected:

```text
Test Files  ... passed
```

- [ ] **Step 4: Run both builds**

Run:

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
cargo build -p agent-workspace-daemon
cd /home/jhz/tools/agent-terminal-platform/agent-workspace/frontend
npm run build
```

Expected:

```text
Finished `dev` profile ...
vite v... building for production...
```

- [ ] **Step 5: Commit the verified foundation**

Run:

```bash
cd /home/jhz/tools/agent-terminal-platform/agent-workspace
git add README.md
git commit -m "docs: document verified foundation setup"
```

## Self-Review Notes

- Spec coverage for this slice:
  - daemon shell: covered by Tasks 1-2
  - local persistence foundation: covered by Tasks 3-4
  - browser shell: covered by Task 5
  - verified baseline: covered by Task 6
- Intentional omissions:
  - managed `Claude` and `Codex` execution are deferred to the next executable plan
  - attach, replay, and mobile polish are deferred to later plans
- Type consistency:
  - Rust uses `event_type`
  - browser DTOs use `eventType`
  - placeholder sessions are consistently called `placeholder`

## Execution Handoff

Plan complete and saved to `agent-workspace/docs/plans/2026-06-10-agent-workspace-foundation-implementation-plan.md`.

Two execution options:

1. **Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration
2. **Inline Execution** - Execute tasks in this session using `executing-plans`, batch execution with checkpoints

Which approach?
