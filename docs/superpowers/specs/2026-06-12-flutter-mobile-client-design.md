# Flutter Mobile Client Design

## Purpose

Build a high-quality iOS and Android client for Agent Dock using Flutter. The mobile app connects to a remote Rust daemon and must feel like a native mobile workspace, not a browser wrapped in an app shell.

The existing browser client remains available for desktop use. The mobile client is a separate product surface with mobile-first navigation, input, streaming, media, and recovery behavior.

## Assumptions

- The daemon runs remotely over HTTPS/WSS.
- The mobile app does not run the Rust daemon, Codex, Claude, SQLite, or workspace file access locally.
- The daemon remains the source of truth for sessions, events, attachments, workspace roots, and runtime state.
- The first version targets a multi-user remote daemon. Every workspace root, session, event stream, attachment, and mutation is scoped to the authenticated user.
- Flutter is selected over React Native and Capacitor to maximize cross-platform visual consistency and avoid browser-shell behavior.

## Current Implementation Update

This section supersedes older single-user and daemon-forwarded voice assumptions in this document.

- Authentication is multi-user, not fixed-PIN single-user auth.
- Flutter stores daemon URL, auth token, and last selected session per `daemonUrl + userId`.
- `GET /api/auth/session` returns the current user identity as well as auth validity.
- Session, workspace, attachment, message, delete, and WebSocket routes must enforce user-scoped authorization. Unauthorized tokens return `401`; valid users without access to a resource return `403`.
- Voice input is direct from Flutter to Doubao ASR. The daemon must not proxy microphone audio.
- Doubao long-lived credentials must not be embedded in the app package. The mobile app may use user-provided credentials stored in secure storage, or a daemon-issued short-lived ASR session config if the provider credential model supports it.
- If no safe Doubao credential source is configured, the microphone affordance is disabled with an explanation instead of falling back to daemon audio forwarding.

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
- Adding organization administration, billing, or cross-user collaboration management.
- Implementing App Store billing, organization management, or collaboration features.
- Reusing the current Web UI inside a WebView.

## Product Scope

### First Release

- Server setup screen with daemon URL entry and health check.
- Multi-user login against the selected daemon.
- Secure local storage for daemon URL and auth token.
- Session list with running sessions emphasized.
- Session creation with workspace root, path, agent kind, and optional title.
- Session detail timeline with mobile-native event cards.
- WebSocket live event streaming with reconnect and event replay.
- Reverse pagination for older events.
- Message composer with text, image attachments, slash-command hints, and send state.
- Image selection from gallery or camera and upload to the daemon.
- Voice input using Flutter microphone capture and direct Doubao ASR WebSocket transport.
- Delete session flow with confirmation.
- Clear offline, reconnecting, unauthorized, and server-version messages.

### Later Releases

- Push notifications for session completion or input-needed states.
- Share-sheet integration for sending text or images into a session.
- Local draft persistence per session.
- Tablet layout.
- App lock using biometrics.
- Multiple daemon profiles.
- Organization administration, billing, and collaborative sharing.

## Architecture

### Repository Layout

Create a new Flutter app next to the existing projects:

```text
agent-dock/
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
- `features/auth` handles multi-user login, current-user restore, token storage, user-scoped local state, and logout.
- `features/sessions` handles roots, session list, create session, attach session, and delete session.
- `features/session_detail` handles snapshot loading, live event stream, pagination, timeline projection, and event cards.
- `features/composer` handles text entry, slash-command hints, image attachment selection, uploads, and send state.
- `features/voice` handles microphone permission, audio capture, Doubao ASR WebSocket lifecycle, transcript updates, stop, and cancellation.
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

The current daemon is browser-cookie oriented. Flutter should not rely on browser cookie behavior. Add explicit multi-user bearer-token support while preserving Web compatibility.

### Authentication

`POST /api/auth/login`

Request:

```json
{
  "username": "alice",
  "password": "correct horse battery staple"
}
```

Response:

```json
{
  "ok": true,
  "token": "session-token",
  "user": {
    "id": "usr_123",
    "displayName": "Alice"
  }
}
```

The daemon sets `agent_dock_session` for the Web client, while still accepting the legacy `agent_workspace_session` cookie during migration. The Flutter client stores `token` in secure storage and sends:

```text
Authorization: Bearer session-token
```

### Session Restore

`GET /api/auth/session`

Accepts either `Authorization: Bearer <token>` or the existing cookie. Returns:

```json
{
  "ok": true,
  "user": {
    "id": "usr_123",
    "displayName": "Alice"
  }
}
```

The app uses `user.id` to partition local secure-storage keys and in-memory caches.

### Session WebSocket Authentication

Session event WebSockets must accept token authentication. Preferred behavior:

- Flutter sends the token using the `Sec-WebSocket-Protocol` header if supported by the client stack.
- Fallback supports `?token=<token>` for mobile clients that cannot reliably set custom headers.
- The daemon validates the token before upgrading the socket.
- The daemon validates that the authenticated user can access the requested session before streaming events.

### Mobile Bootstrap

Add `GET /api/mobile/bootstrap` to reduce startup round trips.

Response:

```json
{
  "daemonVersion": "0.1.0",
  "user": {
    "id": "usr_123",
    "displayName": "Alice"
  },
  "roots": [],
  "sessions": [],
  "voice": {
    "doubaoDirectAvailable": true
  }
}
```

This endpoint is not required for correctness, but it improves launch performance and gives the app a place for compatibility checks.

### Direct Doubao Voice

Flutter connects directly to Doubao ASR for microphone transcription.

The daemon does not receive, relay, or persist microphone audio frames.

Credential source rules:

- Preferred production mode: the daemon returns a short-lived ASR session config for the authenticated user if the Doubao credential model supports temporary credentials.
- User-owned mode: the user enters Doubao credentials in mobile settings and the app stores them in secure storage under `daemonUrl + userId`.
- Development mode: local credentials may be injected through build-time or debug-only configuration, but release builds must not ship hard-coded Doubao credentials.

If direct credentials are unavailable, the voice button is disabled and shows `Voice input is not configured`.

The mobile voice implementation owns:

- Doubao WebSocket connection setup.
- Required Doubao request headers.
- PCM 16 kHz mono audio chunking.
- Doubao binary frame encoding and decoding.
- Gzip compression and decompression.
- Transcript merge into the composer draft.
- Stop, cancel, permission-denied, provider-error, and reconnect states.

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
6. If healthy, app asks for user credentials.
7. App calls `/api/auth/login`.
8. App stores token, daemon URL, and current user id securely.
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
3. App obtains a safe Doubao credential source from secure storage or a daemon-issued short-lived ASR session config.
4. App opens the Doubao ASR WebSocket directly.
5. App streams microphone audio frames directly to Doubao.
6. Transcript updates the composer text.
7. User can stop, cancel, or edit before sending.
8. If direct voice credentials are unavailable, app shows a clear disabled state.

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
- current user id
- last selected session id per `daemonUrl + userId`

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
- Route to login.
- Show "Session expired. Sign in again."

### Forbidden

If a request returns forbidden:

- Keep the stored token and current user.
- Keep existing screen content visible where possible.
- Show "You do not have access to this resource."
- For Chat, stop the session stream and disable composer actions for that session.

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

If direct Doubao voice credentials are unavailable:

- Disable microphone affordance for the session.
- Explain that voice input is not configured.

## Security

- Require HTTPS/WSS for saved remote daemon URLs, except local development builds.
- Store tokens only in secure storage.
- Do not log tokens, passwords, Doubao credentials, or full attachment URLs containing credentials.
- Do not embed long-lived Doubao credentials in release app binaries.
- Do not persist audio frames.
- Treat uploaded images as daemon-owned attachments after upload.
- Add explicit logout that clears token and in-memory draft state.
- Keep Web cookie support for desktop, but use Bearer token for mobile.

## Testing Strategy

### Daemon Tests

- Login returns token while preserving existing cookie behavior.
- Login returns current user identity.
- Session, root, attachment, message, delete, and event-stream routes enforce user-scoped authorization.
- `Authorization: Bearer` authenticates HTTP routes.
- WebSocket event stream accepts valid token and rejects invalid token.
- WebSocket event stream returns or closes as forbidden when a valid user cannot access a session.
- `/api/mobile/bootstrap` returns version, current user, user-visible roots, user-visible sessions, and voice configuration status.
- Optional short-lived Doubao ASR config is issued only for the authenticated user when configured.
- Existing Web auth tests continue passing.

### Flutter Unit Tests

- API client sends bearer token.
- DTO decoding handles all current session event kinds.
- Auth state restores saved token and daemon URL.
- Unauthorized responses clear token and trigger login state.
- Forbidden responses preserve token and show access-denied state.
- Local storage keys include `daemonUrl + userId`.
- Session event deduplication uses event id.
- Reconnect resumes from latest local event id.
- Doubao voice frame codec encodes request frames and decodes transcript/error frames.

### Flutter Widget Tests

- Server setup validates URL and shows health errors.
- Login screen preserves daemon URL and username after invalid credentials.
- Session list sorts running sessions first.
- Session detail shows reconnecting banner.
- Composer keeps draft after send failure.
- Upload failure shows retry and remove actions.
- Missing Doubao voice configuration disables microphone affordance.

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
- Doubao provider connection failure.

## Rollout Plan

### Phase 1: Mobile Protocol Foundation

- Add Bearer token auth to daemon.
- Add token to login response.
- Add token support to WebSocket authentication.
- Add current-user identity and user-scoped authorization to daemon APIs.
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
- Implement direct Doubao ASR transport in Flutter.
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
