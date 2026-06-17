# Session Communication Reliability Design

## Goal

Bring Agent Dock mobile session communication up to the reliability level of a typical IM product.

The target is not best-in-class realtime infrastructure. The target is a practical baseline where:

- opening a session feels immediate
- recent messages appear quickly, even before the latest sync finishes
- weak-network interruptions recover automatically
- sending a message does not depend on the current realtime connection health
- users can understand whether the system is sending, reconnecting, or waiting to retry

## Scope

This design covers the mobile client and daemon communication model for session detail and session open flows.

It includes:

- session open behavior
- session snapshot loading
- live event stream behavior
- weak-network reconnect and recovery
- outgoing message delivery semantics
- daemon event-stream and message-ack protocol changes
- phased rollout and verification

It does not include:

- end-to-end encryption
- multi-device unread state
- push notifications
- desktop/browser parity work beyond shared daemon protocol changes
- replacing HTTP and WebSocket with QUIC or WebTransport in this phase

## Product Standard

The baseline to match is a normal IM product, not a best-in-class one.

### User Expectations

- Tapping a session opens the detail screen immediately.
- The detail screen shows cached or recent content before full sync completes.
- Incoming updates resume automatically after short disconnects.
- Sending a message creates a visible local pending item instead of failing invisibly.
- Temporary network loss causes delayed delivery, not data loss.
- The UI clearly distinguishes `sending`, `sent`, `retrying`, `offline`, and `reconnecting`.

### Explicit Non-Requirements

- Millisecond-level multi-device consistency
- Zero duplicate edge cases across all failure modes
- Perfect background delivery while the app is suspended
- Transport protocol migration in the first stabilization phase

## Current Problems

The current implementation misses ordinary IM reliability in several places.

### Session Open Is Serial and Blocking

For suspended sessions, the list page waits for `resumeSession()` before navigating into the detail page.

- [mobile/lib/src/features/sessions/sessions_page.dart](/home/jhz/tools/agent-workspace/mobile/lib/src/features/sessions/sessions_page.dart:42)
- [mobile/lib/src/features/sessions/sessions_page.dart](/home/jhz/tools/agent-workspace/mobile/lib/src/features/sessions/sessions_page.dart:1337)

That means the user waits on runtime recovery before even seeing the conversation UI.

### Detail Sync Is Also Serial

When the detail page has no `initialSnapshot` or cached session, it waits for `sessionSnapshot()` before showing live content and only starts the event stream after the snapshot future resolves.

- [mobile/lib/src/features/session_detail/session_detail_page.dart](/home/jhz/tools/agent-workspace/mobile/lib/src/features/session_detail/session_detail_page.dart:360)
- [mobile/lib/src/features/session_detail/session_detail_page.dart](/home/jhz/tools/agent-workspace/mobile/lib/src/features/session_detail/session_detail_page.dart:1556)

This delays the latest visible information, especially under weak networks.

### Live Stream Has No Ordinary IM Reliability Layer

The mobile client opens a raw WebSocket and reads text frames.

- [mobile/lib/src/shared/api/daemon_client.dart](/home/jhz/tools/agent-workspace/mobile/lib/src/shared/api/daemon_client.dart:486)

The current design lacks:

- heartbeat or idle probes
- server-driven keepalive events
- automatic reconnect for all network failure classes
- explicit stream epoch or resume token semantics
- transport-independent connection state transitions

### Weak-Network Handling Is Incomplete

`SocketException` is mapped to offline text, but the reconnect path is not applied uniformly to that state.

- [mobile/lib/src/features/session_detail/session_detail_page.dart](/home/jhz/tools/agent-workspace/mobile/lib/src/features/session_detail/session_detail_page.dart:1411)

This produces a common weak-network failure mode where the app shows offline state but stops making useful progress.

### Sending Messages Is Not Delivery-Oriented

Sending a message is a single HTTP call from the detail screen.

- [mobile/lib/src/features/session_detail/session_detail_page.dart](/home/jhz/tools/agent-workspace/mobile/lib/src/features/session_detail/session_detail_page.dart:917)
- [mobile/lib/src/shared/api/daemon_client.dart](/home/jhz/tools/agent-workspace/mobile/lib/src/shared/api/daemon_client.dart:250)

There is no persisted outbox, no client message ID, and no explicit ack model. Under weak networks, the user sees a failure instead of a normal pending-and-retry workflow.

### Daemon Event Streaming Is Minimal

The daemon streams events by repeatedly querying for events after a cursor and sleeping for 25 ms.

- [daemon/src/http/ws.rs](/home/jhz/tools/agent-workspace/daemon/src/http/ws.rs:80)

This is enough for a basic stream, but not enough for ordinary IM reliability because it lacks:

- heartbeat events
- server-directed reconnect semantics
- stream invalidation semantics
- distinction between idle connection and broken connection

## Approved Direction

Keep `HTTP + WebSocket` for the first reliability phase.

Do not migrate to QUIC, HTTP/3, or WebTransport yet.

The main reliability gap is not the choice of transport protocol. The main gap is missing session-open concurrency, outbox semantics, heartbeat, reconnect state management, and cursor-based recovery behavior.

## Architecture

Use a split control-plane and data-plane model.

### Control Plane

Use HTTP for:

- bootstrap and session list
- session snapshot and reverse pagination
- message submission
- attachment upload
- runtime resume requests
- stream recovery fallback when cursor continuity is lost

### Data Plane

Use WebSocket for:

- live session events
- status changes
- assistant streaming deltas
- progress/tool events
- heartbeat

### Local Persistence

Persist, per `daemonUrl + userId + sessionId`:

- cached message timeline window
- expanded UI state already supported today
- last confirmed event ID
- local outbox entries
- local message delivery state

## Session Open Design

Session open must become immediate and non-blocking.

### New Open Flow

1. User taps a session row.
2. The app navigates to `SessionDetailPage` immediately.
3. The page renders, in order of preference:
   - cached timeline state
   - passed `initialSnapshot`
   - skeleton only if neither exists
4. The page then starts three asynchronous tasks in parallel:
   - connect the event stream using the last known event ID
   - request the latest snapshot
   - request runtime resume only if the session is suspended
5. The first successful source to return fresher data updates the page.
6. Snapshot results are merged with stream-driven events instead of replacing newer data.

### Why This Matches IM Expectations

Ordinary IM products do not block entry on full server reconciliation. They open the conversation quickly, show what they know, then converge to the latest state.

### Resulting UX

- session detail becomes visible immediately
- users can scroll recent history before live sync finishes
- runtime recovery no longer blocks navigation
- weak-network delays affect freshness, not entry

## Connection State Machine

The detail page must use a single explicit connection state machine.

### States

- `idle`
- `opening`
- `syncingSnapshot`
- `connectingStream`
- `connected`
- `degraded`
- `reconnecting`
- `offline`
- `closed`

### Triggers

- page open
- app foreground/background transition
- network loss
- heartbeat timeout
- socket close
- unauthorized token
- runtime resumed
- snapshot refresh success or failure

### Behavioral Rules

- `SocketException` does not terminate recovery; it moves the page into `reconnecting` or `offline` with scheduled retries.
- Backgrounding may suspend active transport work, but foregrounding always restarts recovery from the last known cursor.
- `resume runtime` success changes session status but does not control whether the page is visible.
- Unauthorized state immediately exits the normal state machine and routes to auth recovery.

## Event Stream Design

The event stream remains cursor-based, but the protocol becomes explicit.

### Required Semantics

- every event has a monotonically increasing `eventId`
- the client always stores the latest fully applied `eventId`
- websocket connect takes `afterEventId`
- the daemon guarantees only events with `eventId > afterEventId`

### Heartbeat

Add a daemon-generated heartbeat event at a fixed interval, for example every 20 to 30 seconds.

Suggested shape:

```json
{
  "id": 1042,
  "eventType": "session.heartbeat",
  "payload": {
    "serverTime": "2026-06-17T14:23:10Z"
  }
}
```

### Client Dead-Connection Detection

The client tracks `lastReceivedEventAt`.

If no event arrives within a timeout window, for example 45 to 60 seconds:

- mark the stream `degraded`
- close the socket proactively
- enter `reconnecting`
- reconnect using the last confirmed `eventId`

This avoids waiting indefinitely on half-dead sockets.

### Recovery Path

On reconnect:

1. connect websocket with `afterEventId`
2. if accepted, continue normal streaming
3. if the daemon rejects the cursor or indicates continuity loss, perform an HTTP snapshot refresh
4. rebuild local state from snapshot
5. reconnect websocket again from the snapshot's latest `eventId`

## Outgoing Message Delivery Design

Outgoing messages must behave like IM sends, not like a fragile form post.

### Local Outbox Model

Each outgoing message gets:

- `clientMessageId`
- `sessionId`
- `createdAt`
- `text`
- `imagePaths`
- `status`

Statuses:

- `sending`
- `sent`
- `retrying`
- `failedRetryable`
- `failedFinal`

### Send Flow

1. User taps send.
2. The app creates a local outbox record immediately.
3. The message appears in the UI immediately as pending.
4. A send worker submits the message over HTTP.
5. The daemon returns an ack containing `clientMessageId` and the accepted server event ID.
6. The local message transitions to `sent`.
7. If send fails transiently, the message remains visible and transitions to `failedRetryable`.
8. The app retries automatically when possible and exposes manual retry when needed.

### Why HTTP Stays Appropriate

Ordinary IM systems commonly separate outbound message submission from inbound realtime delivery. A healthy WebSocket is not a prerequisite for safely accepting an outbound message.

That matches the current project shape and minimizes migration cost.

## Daemon API Changes

### Message Submission Ack

Change `POST /api/sessions/{id}/messages` from a generic `{ "ok": true }` response to an explicit acceptance response.

Suggested response:

```json
{
  "accepted": true,
  "clientMessageId": "cli_msg_123",
  "eventId": 1043,
  "sessionStatus": "running"
}
```

### Request Payload

Extend the request to include `clientMessageId`.

Suggested request:

```json
{
  "clientMessageId": "cli_msg_123",
  "message": "Ship it",
  "imagePaths": []
}
```

### Runtime Resume

`POST /api/sessions/{id}/resume` remains available, but it is no longer a navigation precondition.

The daemon should treat resume as:

- a background attempt to reactivate runtime state
- something that updates session status and emits events
- not something the UI must await before rendering the conversation

### Snapshot Endpoint

`GET /api/sessions/{id}` remains the source of truth for repair and reconciliation.

This endpoint becomes the fallback recovery source when cursor continuity is lost.

## Daemon Runtime Delivery Semantics

The daemon currently appends a `user.message` event before runtime delivery is fully confirmed.

- [daemon/src/session/service.rs](/home/jhz/tools/agent-workspace/daemon/src/session/service.rs:334)

That behavior should be refined so the protocol distinguishes:

- accepted by daemon
- delivered to runtime input
- reflected back into the timeline

The first rollout does not need a fully separate event taxonomy, but it does need a clear acceptance ack so the mobile client can model user-facing send state correctly.

## Merge Rules Between Snapshot and Stream

Because session open becomes parallel, snapshot and stream updates can race.

The merge rules must be explicit:

- never remove an event with `eventId` greater than the latest snapshot event
- treat snapshot as authoritative for missing older events and canonical session metadata
- treat stream as authoritative for fresher events that arrived after the snapshot request started
- deduplicate strictly by `eventId`

This prevents old snapshots from replacing newer streamed events.

## User-Facing Status Model

The UI should surface a small, stable set of statuses.

### Session Detail Header / Banner

- `Connected`
- `Reconnecting…`
- `Offline. Waiting for network…`
- `Syncing latest activity…`
- `Retrying send…`

### Message-Level Send State

- no badge once sent
- subtle pending indicator while sending
- retry affordance on retryable failure
- explicit failure only for final, non-retryable errors

The purpose is clarity, not verbosity.

## Observability

Add structured logging and counters for:

- session open latency
- time to first visible timeline
- time to latest-event convergence
- websocket connect success/failure counts
- reconnect attempt counts
- heartbeat timeout counts
- outbox queue depth
- send success/failure/retry counts
- resume latency

Without these metrics, it will be difficult to tell whether transport work or open-flow work improved reliability.

## Verification

### Automated Tests

Add coverage for:

- opening a suspended session does not block initial navigation
- cached timeline is shown before snapshot completes
- stream starts before or independently of resume completion
- `SocketException` enters retry flow instead of terminal offline state
- heartbeat timeout forces reconnect
- reconnect from last known `eventId` replays only missing events
- lost cursor continuity triggers snapshot repair
- local pending messages remain visible across temporary send failure
- send retry succeeds after transient failure
- foreground recovery reconnects stream and drains pending outbox entries

### Manual Test Matrix

Validate:

- healthy Wi-Fi
- weak Wi-Fi with packet loss
- Wi-Fi to cellular switch
- cellular to Wi-Fi switch
- app background and foreground
- daemon restart while a session detail page is open
- suspended session open with slow runtime recovery
- send while stream is disconnected

## Rollout Plan

### Phase 1: Open Flow and Reconnect Baseline

- navigate into session detail immediately
- start snapshot, stream, and resume in parallel
- unify connection state machine
- make all transient socket failures auto-reconnect
- add heartbeat event and client idle timeout handling

### Phase 2: Outbox and Ack

- add `clientMessageId`
- add local outbox persistence
- add message submission ack response
- add retryable send state and resend flow

### Phase 3: Recovery Hardening

- add snapshot repair after cursor continuity loss
- improve daemon stream semantics
- add metrics and logs for open latency and reconnect behavior

### Phase 4: Server Push Optimization

- reduce or replace polling-based stream delivery
- evaluate broader protocol upgrades only after the above is stable

## Alternatives Considered

### Immediate Migration to QUIC / WebTransport

Rejected for this phase.

Reason:

- it does not solve the current blocking open flow
- it does not add outbox semantics
- it does not add heartbeat or recovery behavior by itself
- it increases complexity before the application protocol is mature

### Polling-Only Model

Rejected as the primary design.

Reason:

- it simplifies transport, but weakens perceived responsiveness
- it does not match ordinary chat expectations for typing and progress updates
- it remains useful only as a fallback path if websocket establishment fails repeatedly

## Decision

Adopt a normal IM-style communication model on top of the existing `HTTP + WebSocket` stack.

Do the reliability work in this order:

1. immediate session open with parallel recovery
2. proper stream state machine with heartbeat and reconnect
3. local outbox plus daemon ack semantics
4. cursor repair and stronger server-side streaming semantics

This gives the project a realistic path to ordinary IM reliability without a transport migration gamble.
