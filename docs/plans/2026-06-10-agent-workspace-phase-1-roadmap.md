# Agent Workspace Phase 1 Roadmap

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement the executable plans linked below. Do not execute this roadmap file directly.

**Goal:** Decompose the approved `agent-workspace` spec into executable implementation slices that can be built and verified without guessing.

**Architecture:** Phase 1 is intentionally split into three sequential plans. The first plan establishes the repository, daemon shell, auth, workspace browsing, local persistence, and browser shell. The second adds managed structured sessions for `Claude` and `Codex`. The third adds recovery, best-effort attach, and mobile/session polish.

**Tech Stack:** Rust, Tokio, Axum, Serde, SQLx with SQLite, React, TypeScript, Vite, Vitest, Testing Library

---

## Why The Original Monolith Was Rejected

The original single-file implementation plan was not executable enough because:

- it spanned multiple independent subsystems in one sequence
- several tasks depended on types or helpers that were only vaguely defined later
- many code steps were skeletons rather than complete implementation guidance
- the review loop would have had to redesign the plan while coding

Per the planning rules, this is a sign the work should be decomposed into separate executable plans.

## Execution Order

Implement these plans in order:

1. [Agent Workspace Foundation Plan](/home/jhz/tools/agent-terminal-platform/agent-workspace/docs/plans/2026-06-10-agent-workspace-foundation-implementation-plan.md)
2. [Managed Sessions Plan](/home/jhz/tools/agent-terminal-platform/agent-workspace/docs/plans/2026-06-10-agent-workspace-managed-sessions-implementation-plan.md)
3. Recovery And Attach Plan

Plans 1 and 2 are executable now. Plan 3 should be written immediately after Plan 2 is implemented and verified, using the same planning discipline.

## Scope Mapping

### Plan 1: Foundation

Covers:

- fresh repository bootstrap under `agent-workspace/`
- Rust daemon shell
- fixed PIN auth
- workspace root and directory browsing
- SQLite event store and session snapshot model
- browser shell with login, session list, and create-session flow

Does not cover:

- real managed `Codex` / `Claude` execution
- event streaming UI
- attach support
- recovery after daemon restart

### Plan 2: Managed Sessions

Covers:

- managed `Claude` adapter
- managed `Codex` adapter
- unified event mapping
- session orchestration
- WebSocket event streaming
- structured timeline UI and composer

### Plan 3: Recovery And Attach

Covers:

- local durable recovery after daemon restart
- event replay
- best-effort attach support
- mobile-specific UI polish
- full-stack verification pass

## Rule For Execution

- Do not start Plan 2 until Plan 1 tests are green.
- Do not start Plan 3 until Plan 2 tests are green.
- If the implementation drifts enough to invalidate a later plan, rewrite that later plan before coding it.

## Current Recommended Next Step

Execute Plan 2:

- [Managed Sessions Plan](/home/jhz/tools/agent-terminal-platform/agent-workspace/docs/plans/2026-06-10-agent-workspace-managed-sessions-implementation-plan.md)
