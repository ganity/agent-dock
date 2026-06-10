# Agent Workspace

Single-user, browser-first coding workspace backed by a local Rust daemon.

## Foundation Scope

- fixed PIN login
- workspace browsing
- SQLite-backed session persistence
- browser shell for login and session listing

## Managed Sessions

The current branch now supports managed structured sessions for:

- `codex`
- `claude`

Implemented so far:

- create/list/detail session APIs
- live event replay/follow over WebSocket
- message send API for active sessions
- structured timeline cards for user, thinking, assistant, tool, file-change, and status events
- real `codex` app-server bootstrap using `initialize`, `thread/start`, and `turn/start`
- multi-turn `claude` sessions using `--resume <session_id>` across per-turn subprocesses

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
