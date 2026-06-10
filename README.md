# Agent Workspace

Single-user, browser-first coding workspace backed by a local Rust daemon.

## Foundation Scope

- fixed PIN login
- workspace browsing
- SQLite-backed session persistence
- browser shell for login and session listing

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
