# Agent Workspace Design

## Product Identity

`Agent Workspace` is a single-user, browser-first coding product backed by a local Rust daemon.

It is not a terminal platform, not a remote shell, and not a generic multi-agent control plane.
Its primary experience is a structured coding session timeline for `Codex` and `Claude`, accessible from desktop and mobile browsers on the same local network.

## Goal

Build a new product around structured agent sessions:

- browser UI first, with mobile usable from day one
- local Rust daemon as the product core
- structured timeline cards for message, thinking, tool activity, file-change summary, and status
- persistent local sessions that survive browser disconnects
- managed sessions started by the product, plus limited support for attaching to existing sessions

## Non-Goals

Phase 1 does not include:

- terminal-first interaction
- any real terminal surface
- PTY transcript rendering
- built-in code editor
- built-in file tree or code viewer
- diff viewer
- external editor deep linking
- daemon-controlled patch application
- product-managed change sets
- product-level rollback
- product-level conflict detection
- optimistic locking across concurrent sessions
- generic custom-agent support
- multi-user permissions or account system

## Product Shape

### Primary form

- Local Rust daemon runs on the user's machine
- Browser UI connects to the daemon over local HTTP and WebSocket
- Access is allowed from the same machine and other devices on the local network
- Authentication uses a single fixed PIN/password

### Session model

- Single user only
- Each session binds to one workspace directory or one repository
- Multiple sessions may run concurrently against the same directory
- Sessions keep running in the daemon when browsers disconnect
- Session history is locally persisted and restored after daemon restart

### Supported agents

Phase 1 supports two first-class structured adapters:

- `Codex`
- `Claude`

Managed sessions created by the product are the primary path.
Attached sessions are a compatibility path and may expose reduced capability depending on what the source CLI exposes.

## Core UX

### Main UI

The UI is a structured timeline, not a terminal.

Desktop and mobile share the same semantic model:

- session list
- session detail page
- composer
- timeline cards
- session status

Mobile is prioritized through layout and composer behavior, not by introducing a separate terminal mode.

### Composer

The composer is a first-class input surface:

- stable multiline input
- explicit send action
- attachment entry point
- predictable behavior on mobile keyboards

The composer submits a structured user message into the active session turn.

### Timeline cards

The timeline is rendered from structured session events.

Phase 1 cards:

- `UserCard`
- `ThinkingCard`
- `ToolCard`
- `FileChangeCard`
- `MessageCard`
- `StatusCard`

`FileChangeCard` is intentionally weak in phase 1:

- it only shows file modifications that the agent itself declares
- the daemon does not verify, diff, or reverse those edits

## Architecture

### 1. Web UI

Responsibilities:

- render session list and session detail
- render structured timeline cards
- handle login and session selection
- send user input and attachments
- reconnect and resume from persisted history

The UI does not parse PTY output and does not attempt to infer thinking from plain text.

### 2. Control/API Layer

The Rust daemon exposes:

- HTTP APIs for login, session creation, session listing, history fetch, and settings
- WebSocket streams for live session events and status updates

The transport is structured from the start. There is no primary PTY channel in the product contract.

### 3. Session Orchestrator

Responsibilities:

- create managed sessions
- attach to supported existing sessions
- supervise agent lifecycle
- keep sessions alive in the background
- restore session state after restart

Session lifecycle states should include:

- `created`
- `starting`
- `running`
- `waiting_input`
- `completed`
- `failed`
- `stopped`

### 4. Agent Adapters

Each supported agent has a dedicated adapter:

- `CodexAdapter`
- `ClaudeAdapter`

Responsibilities:

- launch or attach to the underlying agent runtime
- consume the agent's machine-readable output
- map native events into the product's unified event model
- surface declared file modifications as structured `file-change` events

Phase 1 design requirement:

- `thinking` is only emitted when the adapter receives a genuine structured thinking signal
- no heuristics based on stdout

### 5. Persistence Layer

The daemon stores local persistent session state.

Recommended storage split:

- `SQLite` for sessions, turns, events, auth state, and snapshots
- file-backed blobs for larger raw payloads when necessary

Source of truth:

- append-only structured event log

Derived state:

- session snapshot
- current turn summary
- timeline card projection

## Event Model

The product is built around a structured event log, not around chat bubbles and not around scrollback.

Recommended phase 1 event types:

- `session.created`
- `session.attached`
- `session.resumed`
- `session.status.changed`
- `user.message`
- `assistant.message`
- `assistant.thinking.started`
- `assistant.thinking.delta`
- `assistant.thinking.completed`
- `tool.call.started`
- `tool.call.output`
- `tool.call.completed`
- `file.change.reported`
- `session.failed`

### Event constraints

1. Every event must be persistable.
2. Every event must be replayable.
3. Timeline cards are derived from events, not stored as the only truth.
4. `thinking` must come from real structured adapter signals.
5. `file.change.reported` is declarative metadata from the agent, not filesystem truth.

## Timeline Projection

Each user message starts a logical turn.

The common turn flow is:

- `user.message`
- optional `assistant.thinking.*`
- optional `tool.call.*`
- optional `file.change.reported`
- `assistant.message`

Projection rules:

- a single thinking sequence becomes one collapsible `ThinkingCard`
- a single tool invocation becomes one `ToolCard` that updates in place while streaming
- one or more file-change reports inside a turn become one `FileChangeCard`
- terminal-style output blocks are never the primary UI unit

## Managed vs Attached Sessions

### Managed sessions

Managed sessions are created by the product and launched by the daemon.

These are the phase 1 reference path and receive the highest quality support for:

- structure
- persistence
- recovery
- status fidelity

### Attached sessions

The product may attach to existing Codex or Claude sessions if the adapter can establish a structured control path.

Important limitation:

- attached sessions are best-effort
- if the source runtime does not expose enough structure, the product may show reduced capability or reject the attach request

Phase 1 should explicitly document that attached sessions are not guaranteed to match managed sessions feature-for-feature.

## File Modification Semantics

The product does not own filesystem mutation in phase 1.

Instead:

- the agent directly edits files using its own native capabilities
- the daemon records structured file-change reports when the adapter receives them
- the product displays those reports as timeline metadata

The product does not:

- apply patches itself
- compute reversible change sets
- guarantee file-level truth
- resolve concurrent write conflicts

This is an intentional scope cut to keep phase 1 focused on structured session UX rather than on becoming a code-change engine.

## Concurrency

Phase 1 allows multiple sessions against the same workspace directory.

Because the daemon is not the file-write authority:

- there is no optimistic locking
- there is no product-level merge or conflict engine
- there is no rollback layer

User-facing implication:

- the product may show concurrent structured timelines for multiple sessions
- actual file mutation conflicts remain the responsibility of the underlying agents and the user's repository workflow

## Authentication and Local Network Access

Phase 1 is single-user and local-network friendly.

Authentication model:

- daemon can listen on localhost and optionally on a LAN address
- browser clients authenticate with one fixed PIN/password
- authenticated clients receive a local session token

This is sufficient for a personal tool used across laptop, phone, and tablet on the same network.
It is not intended to be a production multi-user auth model.

## Why Rust

Rust is a better fit for the daemon because the product core is a local long-lived runtime, not a conventional web backend.

The daemon must reliably handle:

- external process supervision
- background sessions
- structured event streams
- durable local persistence
- reconnect and replay
- LAN-facing API service

The value of Rust here is mainly:

- strong state-machine implementation
- safer concurrency in a long-lived daemon
- predictable resource behavior
- easier growth into a durable local product core

WebAssembly is not required for the product architecture.
It may be useful later for focused frontend performance work, but it is not a prerequisite for phase 1.

## Phase 1 Deliverable

Phase 1 is successful if all of the following are true:

1. A local Rust daemon can run managed `Codex` and `Claude` sessions.
2. Desktop and mobile browsers can log in and view the same session timeline.
3. Sessions continue running when browsers disconnect.
4. Reconnect restores structured history without transcript duplication.
5. The timeline renders real structured cards for user messages, thinking, tools, file-change reports, and status.
6. Thinking cards are backed by genuine structured signals only.
7. Attached sessions are supported when the adapter can establish a structured control path.
8. No terminal UI is required for primary product use.

## Risks

### Risk 1: Existing-session attach is weaker than managed-session launch

This is acceptable in phase 1.
Managed sessions define the reference experience.

### Risk 2: File-change reporting is incomplete or misleading

This is acceptable if the UI clearly presents file changes as agent-reported metadata, not as authoritative diff truth.

### Risk 3: Product scope drifts back toward terminal or patch-engine behavior

This must be resisted in phase 1.
The product is a structured agent workspace, not a terminal shell and not a repository mutation engine.

## Final Recommendation

Proceed with a clean-slate product under `agent-workspace/` using:

- Rust daemon
- browser-first UI
- local structured event protocol
- Codex and Claude native adapters
- persistent local sessions
- no terminal
- no built-in editor
- no product-managed patch engine in phase 1

This creates a focused foundation for a new agent-first coding product instead of extending the existing PTY-first platform in the wrong direction.
