# Flutter Mobile Client Design

## Purpose

Build a high-quality iOS and Android client for Agent Workspace using Flutter. The mobile app connects to a remote Rust daemon and must feel like a native mobile workspace, not a browser wrapped in an app shell.

The existing browser client remains available for desktop use. The mobile client is a separate product surface with mobile-first navigation, input, streaming, media, and recovery behavior.

## Assumptions

- The daemon runs remotely over HTTPS/WSS.
- The mobile app does not run the Rust daemon, Codex, Claude, SQLite, or workspace file access locally.
- The daemon remains the source of truth for sessions, events, attachments, workspace roots, and runtime state.
- The first version targets one authenticated user per remote daemon.
- Flutter is selected over React Native and Capacitor to maximize cross-platform visual consistency and avoid browser-shell behavior.

## Goals

- Provide a native-feeling mobile experience for active coding sessions.
- Support the core session loop: authenticate, list sessions, create or attach sessions, stream events, send messages, upload images, and use voice input.
- Preserve reliability under mobile network changes with reconnect, event replay, and visible connection status.
- Keep the backend protocol small and explicit so the Web client and Flutter client can evolve independently.
- Avoid speculative features that do not improve the first mobile workflow.

## Non-Goals

- Replacing the existing Web frontend.
- Running agent runtimes directly on the phone.
- Building a full mobile file manager.
- Adding multi-tenant account management.
- Implementing App Store billing, organization management, or collaboration features.
- Reusing the current Web UI inside a WebView.

## Product Scope

### First Release

- Server setup screen with daemon URL entry and health check.
- PIN login against the selected daemon.
- Secure local storage for daemon URL and auth token.
- Session list with running sessions emphasized.
- Session creation with workspace root, path, agent kind, and optional title.
- Session detail timeline with mobile-native event cards.
- WebSocket live event streaming with reconnect and event replay.
- Reverse pagination for older events.
- Message composer with text, image attachments, slash-command hints, and send state.
- Image selection from gallery or camera and upload to the daemon.
- Voice input using the daemon voice WebSocket.
- Delete session flow with confirmation.
- Clear offline, reconnecting, unauthorized, and server-version messages.

### Later Releases

- Push notifications for session completion or input-needed states.
- Share-sheet integration for sending text or images into a session.
- Local draft persistence per session.
- Tablet layout.
- App lock using biometrics.
- Multiple daemon profiles.

## Architecture

### Repository Layout

Create a new Flutter app next to the existing projects:

```text
agent-workspace/
  daemon/
  frontend/
  mobile/
```

The mobile app owns its UI, routing, state, and local storage. It consumes daemon HTTP and WebSocket APIs. Shared code between Web and Flutter is limited to documented JSON contracts, not UI components.

### Flutter Layers

```text
mobile/lib/
  main.dart
  app/
    app.dart
    router.dart
    theme.dart
  features/
    connection/
    auth/
    sessions/
    session_detail/
    composer/
    voice/
  shared/
    api/
    models/
    storage/
    widgets/
```

- `app` defines app bootstrap, routing, theme, and global providers.
- `features/connection` handles daemon URL setup, health check, and saved daemon state for the first single-profile release.
- `features/auth` handles PIN login, token storage, token restoration, and logout.
- `features/sessions` handles roots, session list, create session, attach session, and delete session.
- `features/session_detail` handles snapshot loading, live event stream, pagination, timeline projection, and event cards.
- `features/composer` handles text entry, slash-command hints, image attachment selection, uploads, and send state.
- `features/voice` handles microphone permission, audio capture, voice WebSocket lifecycle, transcript updates, stop, and cancellation.
- `shared/api` contains daemon clients and transport primitives.
- `shared/models` contains JSON DTOs generated with immutable model tooling.
- `shared/storage` wraps secure storage and lightweight local preferences.
- `shared/widgets` contains reusable loading, empty, error, status, and confirmation widgets.

## Recommended Flutter Stack

- `go_router` for declarative navigation.
- `flutter_riverpod` for state management.
- `dio` for HTTP requests and interceptors.
- `web_socket_channel` for WebSocket streams.
- `flutter_secure_storage` for auth token and daemon URL.
- `freezed` and `json_serializable` for immutable DTOs.
- `image_picker` for gallery and camera selection.
- `record` or an equivalent audio-stream package for microphone capture.
- `permission_handler` for microphone and camera permissions.
- `cached_network_image` for attachment display.
- `connectivity_plus` for connection-state hints.
- `package_info_plus` for app version metadata.

## Daemon Protocol Changes

The current daemon is browser-cookie oriented. Flutter should not rely on browser cookie behavior. Add explicit token support while preserving Web compatibility.

### Authentication

`POST /api/auth/login`

Request:

```json
{ "pin": "1234" }
```

Response:

```json
{ "ok": true, "token": "session-token" }
```

The daemon may continue setting `agent_workspace_session` for the Web client. The Flutter client stores `token` in secure storage and sends:

```text
Authorization: Bearer session-token
```

### Session Restore

`GET /api/auth/session`

Accepts either `Authorization: Bearer <token>` or the existing cookie. Returns:

```json
{ "ok": true }
```

### WebSocket Authentication

Session event and voice WebSockets must accept token authentication. Preferred behavior:

- Flutter sends the token using the `Sec-WebSocket-Protocol` header if supported by the client stack.
- Fallback supports `?token=<token>` for mobile clients that cannot reliably set custom headers.
- The daemon validates the token before upgrading the socket.

### Mobile Bootstrap

Add `GET /api/mobile/bootstrap` to reduce startup round trips.

Response:

```json
{
  "daemonVersion": "0.1.0",
  "roots": [],
  "sessions": []
}
```

This endpoint is not required for correctness, but it improves launch performance and gives the app a place for compatibility checks.

### Error Format

Standardize API errors:

```json
{
  "error": "UNAUTHORIZED",
  "message": "Session expired"
}
```

The Flutter app should branch on `error` and show `message` when present.

## Core User Flows

### First Launch

1. User opens the app.
2. App checks secure storage for a daemon URL and token.
3. If no daemon URL exists, app shows the server setup screen.
4. User enters `https://daemon.example.com`.
5. App calls `/api/health`.
6. If healthy, app asks for PIN.
7. App calls `/api/auth/login`.
8. App stores token and daemon URL securely.
9. App loads `/api/mobile/bootstrap` or falls back to roots and sessions requests.
10. App routes to the session list.

### Session List

1. App loads sessions from the daemon.
2. Running sessions appear first.
3. Each row shows title, agent kind, workspace path, source kind, and status.
4. Pull-to-refresh reloads the list.
5. Tapping a session opens session detail.
6. Creating a session opens a bottom sheet optimized for short mobile input.

### Session Detail

1. App loads `GET /api/sessions/{id}?limit=50`.
2. App renders timeline cards using a virtualized list.
3. App connects to `/ws/sessions/{id}/events?after=<lastEventId>`.
4. Incoming events are deduplicated by event id.
5. If the user is near the bottom, new events auto-scroll into view.
6. If the user is reading older history, new event count appears above the composer.
7. On WebSocket disconnect, app shows reconnecting state and retries with backoff.
8. After reconnect, app resumes from the latest local event id.

### Composer

1. User types text in a bottom composer that avoids the keyboard.
2. Slash-command suggestions appear above the keyboard and never cover the send button.
3. User can attach images from gallery or camera.
4. Images upload before send and appear as removable chips.
5. User taps send.
6. App disables send while the request is in flight.
7. On success, composer clears.
8. On failure, draft and attachments remain visible with retry affordance.

### Voice Input

1. User taps microphone.
2. App requests microphone permission when needed.
3. App opens `/ws/voice-input`.
4. App streams audio frames to the daemon.
5. Transcript updates the composer text.
6. User can stop, cancel, or edit before sending.
7. If voice is unavailable on the daemon, app shows a clear disabled state.

## UX Direction

Use an OLED-friendly dark workspace with high contrast and restrained green accents for active/runtime states:

- Background: near-black.
- Primary surfaces: slate and blue-black panels.
- Action color: terminal green for live/running/ready.
- Error color: warm red with plain-language copy.
- Typography: clean sans for UI, monospaced only for paths, commands, and technical output.

The app should feel closer to a focused chat/workbench than a dashboard. Prioritize:

- Full-screen session detail.
- One-handed bottom controls.
- Large tap targets.
- Predictable back gestures.
- Smooth list performance.
- Minimal modal depth.
- Explicit reconnect and send states.

Avoid:

- Desktop-style dense forms.
- Sticky Web layout assumptions.
- Horizontal swipe gestures on the main timeline.
- Tiny status chips that are hard to tap.
- Long uncollapsed technical output that overwhelms the screen.

## State Management

Use Riverpod providers grouped by feature:

- `connectionProvider`: daemon URL, health status, and saved profile state.
- `authProvider`: token restoration, login, logout, and unauthorized handling.
- `sessionListProvider`: roots, sessions, refresh, create, attach, delete.
- `sessionDetailProvider(sessionId)`: snapshot, event stream, pagination, reconnect, and send state.
- `composerProvider(sessionId)`: draft text, attachments, upload state, voice transcript state.

State that must survive app restart:

- daemon URL
- auth token
- last selected session id

State that should remain in memory only:

- open WebSocket objects
- microphone stream
- transient upload progress
- current scroll position
- unsent composer drafts for the active app process

## Data Mapping

Flutter models should mirror daemon DTOs:

- `WorkspaceRoot`
- `WorkspaceDirectoryListing`
- `SessionSummary`
- `SessionDetail`
- `SessionEvent`
- `TimelineItem`
- `CreateSessionInput`
- `AttachSessionInput`

`SessionEvent` remains the wire representation. `TimelineItem` is the UI projection used by session detail cards. This keeps rendering decisions out of API models and allows mobile-specific grouping without changing the daemon protocol.

## Error Handling

### Unauthorized

If any HTTP or WebSocket request returns unauthorized:

- Clear the stored token.
- Keep the daemon URL.
- Route to PIN login.
- Show "Session expired. Sign in again."

### Network Unavailable

If the app cannot reach the daemon:

- Keep existing screen content visible when possible.
- Show a compact offline or reconnecting banner.
- Retry WebSocket connections with exponential backoff.
- Let the user manually retry HTTP requests.

### Version Incompatibility

If `/api/mobile/bootstrap` reports an unsupported daemon version:

- Block mutating actions.
- Show the daemon version and required version.
- Let the user return to server setup.

### Upload Failure

If image upload fails:

- Keep the selected image in the composer.
- Mark it failed.
- Provide retry and remove actions.

### Voice Failure

If microphone permission is denied:

- Keep text composer usable.
- Show a permission-specific message.

If daemon voice input is unavailable:

- Disable microphone affordance for the session.
- Explain that voice input is not configured on the daemon.

## Security

- Require HTTPS/WSS for saved remote daemon URLs, except local development builds.
- Store tokens only in secure storage.
- Do not log tokens, PINs, or full attachment URLs containing credentials.
- Do not persist audio frames.
- Treat uploaded images as daemon-owned attachments after upload.
- Add explicit logout that clears token and in-memory draft state.
- Keep Web cookie support for desktop, but use Bearer token for mobile.

## Testing Strategy

### Daemon Tests

- Login returns token while preserving existing cookie behavior.
- `Authorization: Bearer` authenticates HTTP routes.
- WebSocket event stream accepts valid token and rejects invalid token.
- Voice WebSocket accepts valid token and rejects invalid token.
- `/api/mobile/bootstrap` returns version, roots, and sessions.
- Existing Web auth tests continue passing.

### Flutter Unit Tests

- API client sends bearer token.
- DTO decoding handles all current session event kinds.
- Auth state restores saved token and daemon URL.
- Unauthorized responses clear token and trigger login state.
- Session event deduplication uses event id.
- Reconnect resumes from latest local event id.

### Flutter Widget Tests

- Server setup validates URL and shows health errors.
- Login screen preserves daemon URL after failed PIN.
- Session list sorts running sessions first.
- Session detail shows reconnecting banner.
- Composer keeps draft after send failure.
- Upload failure shows retry and remove actions.

### Manual Verification

- Android physical device.
- iPhone physical device.
- Poor network or airplane-mode toggle while a session streams.
- Keyboard open on small screens.
- Long assistant output.
- Large event history.
- Gallery upload.
- Camera upload.
- Microphone permission denied and granted.

## Rollout Plan

### Phase 1: Mobile Protocol Foundation

- Add Bearer token auth to daemon.
- Add token to login response.
- Add token support to WebSocket authentication.
- Add `/api/mobile/bootstrap`.
- Keep Web client behavior unchanged.

### Phase 2: Flutter App Skeleton

- Create `mobile/` Flutter project.
- Add routing, theme, secure storage, API client, and environment handling.
- Implement server setup and login.

### Phase 3: Read-Only Sessions

- Implement session list.
- Implement session detail snapshot.
- Implement live event WebSocket with reconnect and replay.
- Implement older-history pagination.

### Phase 4: Mutating Session Actions

- Implement create session.
- Implement send message.
- Implement image upload.
- Implement delete session.

### Phase 5: Mobile-First Enhancements

- Implement voice input.
- Add offline/reconnect polish.
- Add app icons, splash screen, permissions, and build profiles.

### Phase 6: Internal Release

- Build Android APK for internal testing.
- Build iOS TestFlight package.
- Test against a remote HTTPS daemon.
- Fix device-specific keyboard, permission, and network issues.

## Open Decisions

- Push notification provider is deferred until after the first release.
- Multi-daemon profile support is deferred until after the first release.
- Tablet layout is deferred until phone flows are stable.
- The exact minimum supported daemon version will be set when mobile protocol changes are implemented.

## Success Criteria

- A user can connect to a remote daemon, log in, open an active session, watch events stream live, and send a message from iOS and Android.
- The app continues gracefully through network interruption and resumes without duplicate events.
- The composer remains usable with the keyboard open on small screens.
- Image upload and voice input use native mobile affordances.
- Existing Web client behavior remains intact.
