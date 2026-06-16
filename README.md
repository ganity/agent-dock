# Agent Dock

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

## Recovery And Attach

The current branch also adds:

- file-backed SQLite persistence for daemon state
- durable restart recovery for stored sessions and events
- best-effort attach records for existing `codex` / `claude` runtime session ids
- attach-session UI flow in the browser shell
- mobile-oriented spacing and panel sizing polish

## Run The Foundation

### Daemon

The daemon loads config from these paths, in order:

1. `AGENT_DOCK_CONFIG`
2. `./daemon.local.toml`
3. `./daemon.toml`
4. `./daemon.example.toml`

Use `daemon.local.toml` for machine-local secrets such as voice-input credentials.

```bash
cargo run -p agent-dock-daemon
```

### Frontend

```bash
cd frontend
npm install
npm run dev
```

### Flutter Mobile Environment

Flutter is installed outside the repository at `/home/jhz/development/flutter`.
Android SDK is installed outside the repository at `/home/jhz/Android/Sdk`.

Use this shell setup before running mobile commands in non-login shells:

```bash
export PATH="$HOME/development/flutter/bin:$HOME/Android/Sdk/cmdline-tools/latest/bin:$HOME/Android/Sdk/platform-tools:$PATH"
export ANDROID_HOME="$HOME/Android/Sdk"
export ANDROID_SDK_ROOT="$HOME/Android/Sdk"
```

See `docs/superpowers/specs/2026-06-13-flutter-mobile-implementation-prerequisites.md`
for the verified environment state and remaining desktop/web-only gaps.

### Mobile

```bash
cd mobile
flutter test
dart analyze .
flutter run
```

The current mobile app is a verified Flutter shell. It intentionally does not
connect to daemon APIs until the daemon multi-user contract is implemented.
