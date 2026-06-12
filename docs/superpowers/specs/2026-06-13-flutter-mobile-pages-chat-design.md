# Flutter Mobile Pages And Chat Display Design

## Purpose

Define the Flutter mobile app pages and the detailed Chat page display behavior for Agent Workspace. This document expands the existing Flutter mobile client design with screen-level UI requirements, event rendering rules, state transitions, and timing rules for live session updates.

The goal is to make the mobile app feel like a purpose-built native workbench rather than a compact version of the Web UI.

## Source Data

The Flutter app consumes the existing daemon DTOs:

- `WorkspaceRoot`
- `WorkspaceDirectoryListing`
- `SessionSummary`
- `SessionDetail`
- `SessionEvent`

`SessionEvent` is the raw wire event:

```json
{
  "id": 123,
  "eventType": "assistant.message",
  "payload": { "text": "Done" }
}
```

Flutter must keep raw events in session state and project them into mobile-specific timeline items. Projection is a UI concern; the daemon remains the source of truth.

## Global Presentation Model

### Visual Direction

- Use an OLED-friendly dark theme.
- Use near-black page background with slate cards.
- Use restrained green for active, running, and connected states.
- Use amber for reconnecting and warning states.
- Use red for failed, unauthorized, and destructive states.
- Use monospaced text only for paths, commands, IDs, diffs, and terminal output.
- Avoid emoji icons; use simple line icons or Flutter vector icons.

### Navigation Model

- Use stack navigation for phone screens.
- Primary entry after login is `Sessions`.
- Session detail is full screen and owns the bottom composer.
- Create, attach, server settings, session actions, image source, and destructive confirmations use bottom sheets or dialogs depending on severity.
- Back gesture must return from Chat to Sessions without losing the current session state.
- Avoid horizontal swipe gestures inside the Chat timeline because they conflict with iOS back gestures.

### Loading And Empty States

- No page may show a blank body while loading.
- Use skeleton rows for lists.
- Use compact inline spinners for buttons.
- Empty states must explain what to do next and expose the primary action.

### Motion And Feedback Principles

- Motion must explain state changes, not decorate the interface.
- Continuous animations are allowed only for active work: loading, sending, uploading, reconnecting, recording, streaming, or running tools.
- Prefer short transitions between 120 ms and 220 ms for page elements, button states, chips, and card expansion.
- Prefer longer but subtle transitions between 240 ms and 360 ms for bottom sheets, keyboard-adjacent composer movement, and new timeline item insertion.
- Respect reduced-motion settings by replacing shimmer, pulse, and slide transitions with opacity changes or static indicators.
- Use haptic feedback sparingly:
  - Light impact when send starts.
  - Success feedback when a message is accepted or image upload completes.
  - Warning feedback when send/upload fails.
  - No haptics for every incoming event.
- Never animate layout so aggressively that the user's reading position changes unexpectedly.
- Loading indicators should appear for operations expected to take longer than 300 ms; faster operations can complete without spinner to avoid flicker.
- State text must accompany long-running animations so the user understands what is happening.

### Standard Feedback Patterns

- `Skeleton`: used for first page load and first Chat snapshot load.
- `Inline spinner`: used inside buttons and compact rows for short operations.
- `Progress ring`: used for image upload when progress is known or approximated.
- `Pulse dot`: used for live/running/reconnecting status.
- `Typing cursor`: used for active assistant text streaming.
- `Recording pulse`: used for voice input while microphone capture is active.
- `Banner`: used for offline, reconnecting, and server-level errors.
- `Toast`: used only for non-blocking confirmations such as copied text.

### Error State Rules

- Connection errors stay visible as banners, not blocking dialogs, unless the app cannot authenticate or cannot verify the daemon.
- Unauthorized errors route to login and keep the saved daemon URL.
- Destructive errors are shown near the action that failed.
- App-wide offline state is shown as a slim banner at the top of the current screen.

## Page Inventory

### 1. Launch And Restore Page

This is a transient page shown only during startup.

Display:

- Centered app mark or text logo.
- Small status text below: `Checking daemon...`, `Restoring session...`, or `Preparing workspace...`.
- If restoration takes longer than two seconds, show the saved daemon host.
- Use a subtle breathing pulse on the app mark while work is active.
- Replace the pulse with a static mark when reduced motion is enabled.

Behavior:

- Load saved daemon URL and token from secure storage.
- If no daemon URL exists, route to Server Setup.
- If daemon health check fails, route to Server Setup with the last URL prefilled and an inline error.
- If token restore fails with unauthorized, route to Login.
- If token restore succeeds, route to Sessions.

### 2. Server Setup Page

Purpose: connect the mobile app to a remote daemon.

Display:

- Title: `Connect daemon`.
- Description: `Enter the HTTPS address of your remote Agent Workspace daemon.`
- Single URL field.
- `Test connection` primary button.
- Secondary text button: `Use local development address`, available only in debug builds.
- Inline help text showing examples: `https://agent.example.com`.
- Last error panel when connection fails.

Field behavior:

- Trim whitespace.
- Require `https://` in release builds.
- Allow `http://` only in debug builds.
- Normalize by removing a trailing slash.
- Validate before network request.

Success behavior:

- Call `/api/health`.
- Store the daemon URL only after health succeeds.
- Route to Login.

Failure behavior:

- Keep the entered URL.
- Show specific error:
  - Invalid URL.
  - HTTPS required.
  - Cannot reach daemon.
  - Daemon responded but does not look like Agent Workspace.

### 3. Login Page

Purpose: authenticate against the selected daemon.

Display:

- Title: `Unlock workspace`.
- Host pill showing the daemon host.
- PIN field using numeric keyboard.
- Primary button: `Sign in`.
- Secondary action: `Change daemon`.
- Error text below the PIN field.

Behavior:

- Submit calls `POST /api/auth/login`.
- On success, store token in secure storage and route to Sessions.
- On invalid PIN, clear the PIN field and keep focus.
- On network failure, keep PIN and show retryable error.
- On `Change daemon`, clear token but keep the previous URL in the Server Setup field.

### 4. Sessions Page

Purpose: mobile home for current and historical sessions.

Display hierarchy:

- Top app bar:
  - Title: `Sessions`.
  - Connection status dot and daemon host.
  - Settings icon.
- Primary action row:
  - `New session` button.
  - `Attach` secondary button.
- Running session strip when any sessions are active.
- Session list grouped by status priority.
- Empty state when there are no sessions.

Page animation:

- On first load, show three skeleton session rows with muted shimmer.
- When real sessions arrive, crossfade skeleton rows into session rows over about 160 ms.
- Insert newly created sessions with a short slide-up and fade-in from the top of the list section.
- Updating a session status changes only the status pill; do not reanimate the whole row.

Session row display:

- Title from `title`, falling back to workspace basename or agent kind.
- Status pill: `running`, `active`, `idle`, `completed`, or raw status if unknown.
- Agent chip: `codex` or `claude`.
- Source chip: `managed` or `attached`.
- Workspace path in one or two lines with middle truncation.
- Last known runtime ID hidden by default; visible in details sheet.

Sorting:

1. Running or active sessions.
2. Idle sessions.
3. Completed sessions.
4. Unknown or empty status.

Interactions:

- Tap row opens Chat.
- Long press row opens actions sheet.
- Pull to refresh reloads roots and sessions.
- Settings opens daemon/account sheet.

Actions sheet:

- Open.
- Copy runtime session ID when available.
- Copy workspace path.
- Delete session.

Delete flow:

- Show confirmation dialog with session title.
- Confirm button is destructive.
- While deleting, disable the row and show inline progress.
- On failure, keep the row and show a toast/banner.
- During delete, row opacity drops slightly and the menu action label changes to `Deleting...`.
- On successful delete, row collapses vertically and fades out.

Empty state:

- Title: `No sessions yet`.
- Body: `Start a managed session or attach an existing runtime.`
- Primary action: `New session`.
- Secondary action: `Attach runtime`.

### 5. New Session Sheet

Purpose: create a managed daemon session.

Display:

- Bottom sheet with drag handle.
- Title: `New session`.
- Session name field.
- Agent segmented control: `codex`, `claude`.
- Workspace selector.
- Path selector.
- Primary button: `Create`.

Field rules:

- Session name is required.
- Root is required.
- Path is required.
- If only one root exists, show it as readonly context instead of a dropdown.
- Path selector should start at the root path and support drilling into directories.
- Manual path edit is available behind an `Edit path` affordance.

Success:

- Close sheet.
- Insert or refresh the created session.
- Navigate directly to Chat.

Failure:

- Keep sheet open.
- Show error above the primary button.
- Preserve all entered fields.

### 6. Attach Session Sheet

Purpose: attach an existing runtime session to a workspace path.

Display:

- Bottom sheet with title `Attach runtime`.
- Agent segmented control.
- Recent attachable sessions list when known.
- Runtime session ID field.
- Workspace selector.
- Path selector.
- Primary button: `Attach`.

Behavior:

- Tapping a recent session fills runtime ID, agent kind, and path.
- Runtime session ID is required.
- Path is required.
- On success, navigate to Chat.
- On failure, preserve values and show inline error.

### 7. Settings Sheet

Purpose: manage daemon connection and app metadata.

Display:

- Current daemon URL.
- Connection status.
- App version.
- Daemon version when known.
- Actions:
  - Test connection.
  - Change daemon.
  - Logout.

Behavior:

- Logout clears token and in-memory drafts.
- Change daemon clears token and routes to Server Setup.
- If a session is streaming, show a confirmation before changing daemon.

### 8. Chat Page

Purpose: primary mobile workbench for an active or historical session.

This page requires the most detailed behavior because it combines reverse pagination, live WebSocket events, streaming assistant text, tool lifecycle updates, image attachments, voice input, and keyboard management.

## Chat Page Layout

### Top Bar

Display:

- Back button.
- Session title in one line.
- Status pill.
- Overflow menu.

Status pill:

- Shows latest non-empty `session.status.changed` status.
- Falls back to `SessionDetail.status`.
- If WebSocket is reconnecting, show `reconnecting` with amber styling.
- If offline, show `offline` with amber styling.
- If unauthorized, route away to Login instead of showing a pill.

Overflow menu:

- Session details.
- Copy session ID.
- Copy runtime session ID when available.
- Copy workspace path.
- Delete session.

Session details sheet:

- Title.
- Agent kind.
- Source kind.
- Status.
- Workspace path.
- Runtime session ID.
- Daemon URL host.

### Timeline Area

Use a virtualized vertical list. The newest messages appear at the bottom.

Initial state:

- Show skeleton cards while `GET /api/sessions/{id}?limit=50` loads.
- On success, render projected timeline items.
- Scroll to bottom after the first snapshot layout completes.
- Then connect to `/ws/sessions/{id}/events?after=<lastEventId>`.

Initial animation:

- Skeleton timeline should mimic the final layout: right-aligned user bubble, left assistant block, compact activity card.
- Use shimmer only while snapshot is loading.
- After snapshot loads, fade in the timeline over about 160 ms without staggering every historical item.
- The first automatic scroll to bottom must happen before the fade completes so the user does not see a jump.

Older history:

- When the user scrolls near the top and `hasMoreHistory` is true, request older events with `before=<oldestEventId>`.
- Show a top inline loader: `Loading earlier events...`.
- Prepend older events.
- Preserve visual scroll anchor so content does not jump.
- If no more history remains, show a subtle `Beginning of session` marker.
- The top loader uses a small spinner and fixed height so prepending does not resize unpredictably.
- Older cards fade in only if they were not previously in memory; do not animate every prepended historical card.

New event behavior:

- Deduplicate events by numeric `id`.
- Append raw events in id order.
- Re-project timeline after merging events.
- If the user is within 80 px of the bottom before the update, auto-follow to bottom.
- If the user is not near the bottom, do not move the viewport.
- When not auto-following, show a floating chip above the composer: `N new updates`.
- Tapping the chip scrolls to bottom and clears the count.
- New timeline items inserted at the bottom fade and slide upward by a few pixels over about 180 ms.
- Lifecycle updates to an existing card animate only the changed sub-elements, such as status pill, spinner, output preview, or progress text.
- Do not animate text reflow for every streaming token; assistant text should append smoothly without per-token bounce or flashing.
- When the `N new updates` chip appears, it scales from 96 percent to 100 percent once, then remains static.

### Composer Area

Display:

- Attachment button.
- Text field.
- Voice button.
- Send button.
- Optional upload/voice/status row above the input.

Keyboard behavior:

- Composer sits above the safe area and keyboard.
- Timeline bottom padding equals composer height plus safe area.
- Text field grows up to about five lines, then scrolls internally.
- Slash-command suggestions appear above the composer and never cover the send button.

Send button states:

- Disabled when there is no text and no uploaded attachment.
- Disabled while image upload is in progress.
- Disabled while voice state is connecting, listening, or stopping.
- Shows progress when `sendSessionMessage` is in flight.
- On send failure, restores draft and attachments and shows retry text.

Send animation:

- On tap, the send icon morphs or swaps to a compact spinner inside the same circular button.
- Composer input stays visible and readable while the request is in flight.
- Draft text remains in place until the HTTP request succeeds.
- On success, clear the text with a quick fade rather than an abrupt jump.
- On failure, shake the composer status row once and show `Send failed. Retry`.
- The failed send row exposes `Retry` and `Keep editing`.

Attachment states:

- Selected local image shows a thumbnail chip immediately.
- Uploading chip shows progress.
- Uploaded chip uses daemon attachment path.
- Failed chip shows retry and remove controls.
- Removing a chip removes it from the pending send payload.

Attachment animation:

- Newly selected image chips fade in with a small scale-up.
- Upload progress appears as a circular ring over the thumbnail.
- If byte progress is unavailable, use an indeterminate ring and text `Uploading...`.
- On upload success, the progress ring completes to 100 percent, then fades into a check mark for about 600 ms.
- On upload failure, the chip border turns red and the overlay changes to `Retry`.
- Removing a chip fades and shrinks the chip while neighboring chips reposition.

Voice states:

- Idle: microphone icon.
- Connecting: disabled controls and `Connecting microphone...`.
- Listening: active pulse ring and `Listening...`.
- Stopping: `Finishing transcript...`.
- Error: inline error with retry when useful.
- Stopped: transcript stays in composer for review before send.

Voice animation:

- Connecting uses a small spinner on the microphone button.
- Listening uses a breathing ring around the microphone button and a subtle waveform in the status row.
- Transcript changes should update the text field in place; do not animate each word.
- Stopping freezes the waveform and shows an inline spinner until the final transcript arrives.
- Permission denied shows a static warning icon, not an infinite animation.
- Canceling voice input fades out the status row and leaves any previously committed transcript text intact.

## Chat Timeline Projection

Flutter should project raw `SessionEvent[]` into `TimelineItem[]`. Projection must match current Web behavior unless this document specifies a mobile-specific presentation.

### Projection Order

Process events in ascending `id` order.

Before rendering a new explicit item type, flush pending status or activity summaries.

Adjacent assistant deltas and adjacent thinking deltas are coalesced into one item to reduce visual noise.

Lifecycle tool items with the same item id replace/update the earlier card rather than creating separate started and completed cards.

### Timeline Item Types

Flutter UI item union:

- `UserMessageItem`
- `AssistantMessageItem`
- `ThinkingItem`
- `ToolCallItem`
- `FileChangeItem`
- `ActivitySummaryItem`
- `StatusSummaryItem`
- `AttachedSessionItem`
- `UnknownEventItem`

Unknown events should not crash rendering. In debug builds, show an `Unknown event` collapsed card. In release builds, hide unknown empty events and show unknown non-empty payloads as collapsed diagnostics only if they are useful to the user.

## Event Display Rules

### `user.message`

Payload:

```json
{
  "text": "look at this",
  "imagePaths": ["/tmp/attachments/sess-1/screenshot.png"]
}
```

Projection:

- Create one `UserMessageItem`.
- `text` is `payload.text` string or empty string.
- `imagePaths` is an array of strings or empty array.

Display:

- Right-aligned message bubble.
- Bubble width maxes at about 82 percent of screen width.
- User text uses normal UI font.
- Images display above text in a rounded grid.
- One image: full bubble width thumbnail.
- Two or more images: two-column grid.
- Tapping an image opens full-screen preview.
- Long press message opens copy/share actions.

Timing:

- User message appears after daemon confirms the send because current daemon records the user event server-side.
- If optimistic UI is added later, pending user messages must be visually distinct and reconciled by event id or client request id.

Empty text:

- If text is empty but images exist, render image-only bubble.
- If text is empty and images are empty, do not render the item.

### `assistant.message`

Payload:

```json
{ "text": "## Done\n\n- Render markdown" }
```

Projection:

- Coalesce adjacent `assistant.message` events into the previous `AssistantMessageItem`.
- Filter internal system/context messages that begin with known system prompt or environment prefixes.
- Preserve markdown text.

Display:

- Left-aligned assistant content, not a heavy chat bubble.
- Render markdown with mobile spacing.
- Headings are compact.
- Inline code uses monospaced pill styling.
- Code blocks are horizontally scrollable and collapsed when long.
- Lists use readable indentation.
- Links are tappable and show external-link affordance.

Streaming behavior:

- During adjacent assistant deltas, update the existing assistant card in place.
- If the user is near the bottom, keep auto-following as text grows.
- If the user is reading older content, update in place without moving the viewport and increment the `new updates` chip only once for the assistant stream segment.
- Show a subtle typing cursor or shimmer at the end only while session status is active/running and the latest visible item is assistant text.
- Remove typing indicator when a non-assistant event arrives or session becomes completed/idle.

Assistant animation:

- The assistant card appears once when the first visible assistant delta arrives.
- New text appends without animating previous text.
- The typing cursor blinks at a calm pace and pauses when the app is backgrounded.
- Markdown block upgrades, such as a paragraph becoming a heading, should crossfade the affected block instead of flashing the whole card.
- Long code blocks should not animate height repeatedly while streaming; reserve a stable block area once code formatting is detected.

Internal message filtering:

- Hide assistant messages starting with:
  - `You are Codex, a coding agent`
  - `You are Claude Code`
  - `<environment_context>`
  - `<system-reminder>`
  - `# AGENTS.md`
  - `<INSTRUCTIONS>`
  - `<claude-mem-context>`

### `assistant.thinking.delta`

Payload:

```json
{ "text": "plan first" }
```

Projection:

- Coalesce adjacent thinking deltas into one `ThinkingItem`.
- Thinking items default collapsed.

Display:

- Collapsed card labeled `Reasoning`.
- Subtitle shows a short preview, for example first 80 characters, when available.
- Expanded state shows monospaced or muted body text.
- Use subdued styling so it does not compete with final assistant output.
- If empty after trimming, hide the item.

Timing:

- While reasoning text streams, update the same collapsed card.
- If the user expands it during streaming, keep it expanded.
- Do not auto-expand new reasoning cards.
- If reasoning is the latest item and no assistant answer has arrived yet, show a small active indicator in the card header.

Reasoning animation:

- Collapsed reasoning cards use a tiny pulse dot only while new reasoning text is arriving.
- The preview line crossfades when it changes substantially.
- Expanding reasoning uses a height animation capped at about 220 ms.
- If the reasoning body is very long, expansion opens to a constrained height with internal scrolling instead of pushing the whole timeline far away.

### `tool.call.started`

Payload shape:

```json
{
  "item": {
    "id": "cmd-1",
    "type": "commandExecution",
    "command": "/bin/zsh -lc npm test",
    "cwd": "/tmp/workspace",
    "status": "inProgress"
  }
}
```

Projection:

- If `item.type` is `commandExecution` and has command details, create or update `ToolCallItem` keyed by `commandExecution:<item.id>`.
- If `item.type` is `fileChange` and has changes, create or update `FileChangeItem` keyed by `fileChange:<item.id>`.
- If the item has no detailed fields, accumulate it into an `ActivitySummaryItem`.

Command display:

- Collapsed card labeled `shell`.
- Primary line is friendly command label:
  - Prefer `commandActions[].command` joined by ` && `.
  - Fall back to `item.command`.
  - Fall back to `shell`.
- Status pill shows `inProgress`, `started`, or raw status.
- Header shows spinner while in progress.
- `cwd` appears in expanded body.
- No output yet state: `Waiting for output...`.

Command running animation:

- In-progress shell cards show a small spinner or animated terminal cursor in the header.
- Status pill gently pulses while running.
- The card should not expand automatically on start.
- In the first release, command output appears when the completed event arrives; before completion, keep the expanded output area at `Waiting for output...`.

File change display:

- Collapsed card labeled `Files changed`.
- Status pill shows `inProgress`.
- File list shows paths when available.
- No diff yet state: `Preparing changes...`.

File change running animation:

- In-progress file cards show a small scanning-line accent on the left edge.
- When completed, the accent becomes a static success or failure color.
- Diff blocks fade in after completion; do not animate individual diff lines by default.

Timing:

- Started cards appear immediately when detailed enough.
- They update in place when completed event arrives with the same item id.
- If a started event is followed by assistant text, keep the card in chronological position and update it in place later.

### `tool.call.completed`

Command payload shape:

```json
{
  "item": {
    "id": "cmd-1",
    "type": "commandExecution",
    "command": "/bin/zsh -lc npm test",
    "cwd": "/tmp/workspace",
    "status": "completed",
    "commandActions": [
      { "type": "runCommand", "command": "npm test", "path": null }
    ],
    "aggregatedOutput": "PASS src/app.test.ts\n",
    "exitCode": 0,
    "durationMs": 42
  }
}
```

Projection:

- If matching lifecycle card exists, merge completed fields into it.
- If no matching card exists, create the final `ToolCallItem`.
- For `commandExecution`, extract and trim `aggregatedOutput`.
- If output contains a unified diff, show only the diff portion to avoid verbose surrounding text.

Command card display:

- Collapsed by default.
- Header:
  - Tool label: `shell`.
  - Command label.
  - Status pill.
  - Success or failure icon derived from `exitCode` when present.
- Expanded body:
  - `cwd` in compact monospaced text.
  - Output block.
  - Footer metadata: `exit 0`, `42ms`.

Completion animation:

- When a matching started card completes, spinner crossfades into success or failure icon.
- Status pill updates with a short color transition.
- If output appears for the first time, show the output preview with a fade-in.
- Preserve card expansion state during the transition.

Output presentation:

- Empty output: show `No output`.
- Short output under about 12 lines: show all when expanded.
- Long output: show first visible block with `Show full output`.
- Diffs use colored additions/deletions.
- On small screens, long lines scroll horizontally inside the code block instead of wrapping command output.

Failure presentation:

- If `exitCode` is non-zero, status color is red.
- Keep card collapsed by default.
- Automatically expand a failed command only when it is the latest timeline item and no assistant explanation has arrived after it.
- On automatic expansion for failure, use one short height animation and then stop; do not pulse the failed card continuously.

### `tool.call.completed` with `fileChange`

Payload shape:

```json
{
  "item": {
    "id": "patch-1",
    "type": "fileChange",
    "status": "completed",
    "changes": [
      {
        "path": "src/app.ts",
        "kind": { "type": "update", "move_path": null },
        "diff": "@@\n-old\n+new\n"
      }
    ]
  }
}
```

Projection:

- Create or update `FileChangeItem`.
- `files` are `changes[].path` values.
- `diffs` are non-empty trimmed `changes[].diff` values.
- Preserve previous file list if completed event omits paths but started event had them.

Display:

- Collapsed card labeled `Files changed`.
- Header shows count: `1 file` or `N files`.
- Status pill shows raw status.
- Expanded body:
  - File list with path and change kind when available.
  - Diff blocks grouped by file.
  - Additions green, deletions red, context muted.

Completion animation:

- When file changes complete, file count and status update in place.
- New diff blocks fade in as grouped blocks.
- A completed success state may show a check mark for about 600 ms, then leave a static status pill.

Timing:

- Started file change card appears as soon as path or diff is known.
- Completed event updates the same card.
- Do not render both started and completed cards for the same item id.

### Undetailed tool calls

Payload shape:

```json
{
  "item": { "id": "tool-1", "type": "commandExecution" }
}
```

Projection:

- Accumulate adjacent undetailed tool started/completed events into an `ActivitySummaryItem`.
- Group by `item.type` and status `started` or `completed`.
- Count repeated groups.

Display:

- Compact collapsed row labeled `Activity`.
- Summary examples:
  - `commandExecution completed x2`
  - `reasoning completed x1`
- Expanded body lists grouped rows.

Animation:

- Count changes animate with a small number crossfade.
- The Activity row should not pulse unless at least one grouped item is currently `started`.
- When a grouped segment completes, stop any spinner immediately.

Timing:

- Activity segment is flushed before user, assistant, thinking, file, detailed tool, attached, or non-adjacent status items.
- Adjacent activity groups should remain one card to reduce timeline noise.

### `file.change.reported`

Payload:

```json
{ "files": ["src/app.ts", "src/lib.rs"] }
```

Projection:

- Create `FileChangeItem` with files.
- No diffs unless payload later includes them through another event type.

Display:

- Collapsed card labeled `Files changed`.
- Show file count in header.
- Expanded body lists file paths.
- If there are no files, hide the item.

Timing:

- Render when the event arrives.
- Do not merge with unrelated `tool.call.completed` fileChange items unless they share lifecycle item id, which this event type does not provide.

### `session.attached`

Payload:

```json
{ "runtimeSessionId": "thread-abc" }
```

Projection:

- Create `AttachedSessionItem`.

Display:

- Compact system card.
- Header: `Attached runtime`.
- Body: `Connected to an existing runtime session.`
- Runtime session ID is not shown inline by default to reduce noise.
- Runtime ID is available in session details menu.

Timing:

- Render at the chronological event position.
- Does not affect status pill unless a status event follows.

### `session.status.changed`

Payload:

```json
{ "status": "running" }
```

Projection:

- Adjacent status events become one `StatusSummaryItem`.
- Empty status payloads produce empty status strings and should not render visible cards.
- Status can be string or object with `type`; read object `type` when present.

Display in timeline:

- Status cards are hidden by default in release UI unless they communicate a useful transition.
- Useful transitions:
  - `running`
  - `completed`
  - `failed`
  - `cancelled`
- Churn such as `running -> active -> idle` should be summarized only when diagnostics are enabled.

Display in top bar:

- Top status pill shows latest non-empty status from projected items.
- If there is no non-empty timeline status, use `SessionDetail.status`.
- Blank status events must not clear a meaningful existing status.

Timing:

- Top bar updates immediately when a non-empty status event arrives.
- If status changes to `completed`, remove active typing indicators.
- If status changes to `running` or `active`, allow active indicators for reasoning, assistant, and tools.

### Unknown events

Projection:

- Preserve raw event in debug state.
- Create `UnknownEventItem` only when payload is non-empty and useful for diagnostics.

Display:

- Debug builds: collapsed card with event type and formatted JSON.
- Release builds: hide by default.

Timing:

- Unknown events should not break adjacent assistant or tool lifecycle state.
- Flush pending status/activity before a visible unknown diagnostic card.

## Chat State Transitions

### Entering Chat

1. User taps session row.
2. App navigates immediately with session summary data.
3. Top bar renders title/status from summary.
4. Timeline skeleton appears.
5. Snapshot loads.
6. Timeline renders last 50 events.
7. App scrolls to bottom.
8. WebSocket connects after snapshot so `after` uses the latest known event id.

### WebSocket Connected

- Show connected state only subtly, for example green status dot.
- Do not show a persistent banner for normal connected state.
- Incoming event ids less than or equal to latest known id are ignored.

### WebSocket Reconnecting

- Show top slim banner: `Reconnecting...`.
- Status pill changes to amber `reconnecting`.
- Composer remains editable.
- Send is allowed only if HTTP is reachable; if send fails, keep draft.
- Retry with exponential backoff.
- The reconnecting banner uses a slow left-to-right progress sweep.
- The status dot pulses amber while reconnecting.
- After three failed reconnect attempts, banner text changes to `Still reconnecting...`.
- After repeated failures, expose a `Retry now` action.

### Reconnected

1. Compute latest local event id.
2. Reopen WebSocket with `after=<latestLocalEventId>`.
3. Merge replayed events.
4. Remove reconnecting banner.
5. If events arrived while user was away from bottom, show `N new updates`.

Reconnected animation:

- Banner collapses upward over about 160 ms.
- Status dot transitions back to green without pulsing.
- If replayed events arrive, use normal new-event rules; do not show a separate success toast.

### Unauthorized During Chat

1. Stop WebSocket.
2. Clear token.
3. Keep daemon URL.
4. Route to Login.
5. After login, return to Sessions, not automatically back into Chat unless session restore is explicitly implemented later.

### Leaving Chat

- Close WebSocket.
- Keep raw events in memory while app remains alive.
- Preserve unsent composer draft for the active app process.
- Do not persist draft to disk in the first release.

## Chat Interaction Details

### Scrolling

- First load scrolls to bottom.
- New events auto-follow only when near bottom.
- Loading older events preserves anchor.
- Manual scroll up disables auto-follow.
- Tapping the `N new updates` chip re-enables auto-follow and scrolls to bottom.
- The top bar remains fixed.
- The composer remains fixed above keyboard and safe area.

### Collapsible Cards

Default collapsed:

- Reasoning.
- Tool calls.
- File changes.
- Activity.
- Attached runtime details.
- Unknown diagnostics.

Default expanded:

- User messages.
- Assistant messages.

Persist expanded state:

- Expansion state should be keyed by timeline item id.
- If a lifecycle item updates from started to completed, preserve expansion state.
- If a new snapshot reprojects the same item id, preserve expansion state.

### Copy And Share

Long press behavior:

- User message: copy text, share image when image exists.
- Assistant message: copy markdown text.
- Tool card: copy command, copy output.
- File change: copy path, copy diff.
- Runtime attached card: copy runtime ID from details sheet.

### Accessibility

- Every card has a concise semantic label.
- Status updates should not spam screen readers during high-frequency streams.
- Send, attach, voice, back, and menu buttons have explicit labels.
- Code blocks and diffs are readable with dynamic text size, but may cap at a practical maximum to preserve layout.

## Page-Specific Data Refresh Rules

### Sessions Page Refresh

- On app foreground, refresh session list.
- On pull-to-refresh, refresh roots and sessions.
- If returning from Chat, keep the last list visible and refresh in background.
- If delete succeeds from Chat, remove session from list after returning.

### Chat Refresh

- Snapshot is loaded on first open.
- WebSocket handles live updates.
- Pull-to-refresh is not used for Chat because it conflicts with reverse pagination.
- A manual `Reconnect` action appears only when reconnect attempts fail repeatedly.

### Create And Attach Refresh

- Roots are loaded before sheets open.
- Directory listings are loaded on demand when browsing paths.
- After create or attach succeeds, session list cache is updated or invalidated.

## Visual Examples In Words

### Running Session Row

`Launch Pad` appears as the primary row title. A green `running` pill sits on the right. Below it, `/home/jhz/project` is shown in muted monospaced text with middle truncation. A chip row shows `codex` and `managed`.

### Assistant Markdown

Assistant output is rendered as a document block on the left edge of the timeline, not inside a saturated bubble. Headings use strong white text. Body text is comfortable and readable. Code is visually separated but compact.

### Shell Tool Card

Collapsed header:

```text
shell        npm test                 completed
```

Expanded body:

```text
cwd: /tmp/workspace

PASS src/app.test.ts

exit 0 - 42ms
```

### File Change Card

Collapsed header:

```text
Files changed        1 file        completed
```

Expanded body:

```text
src/app.ts

@@
-old
+new
```

### Reconnecting Chat

Top banner:

```text
Reconnecting to daemon...
```

The timeline remains readable. Composer remains enabled, but failed sends preserve drafts.

## Testing Expectations

### Projection Tests

- Adjacent assistant messages merge.
- Adjacent thinking deltas merge.
- Internal system prompt assistant messages are hidden.
- Command started and completed with same item id render one card.
- File change started and completed with same item id render one card.
- Undetailed tool events group into activity summary.
- Adjacent status events group.
- Blank status does not clear latest meaningful status.
- User image paths are preserved.
- Unknown events do not crash projection.

### Widget Tests

- Sessions page shows empty state and primary action.
- Running sessions appear before completed sessions.
- New Session sheet validates title and path.
- Attach sheet fills values from recent session.
- Chat first load scrolls to bottom.
- Older history prepends without visual jump.
- New event chip appears when user is scrolled away from bottom.
- Tool card expansion persists after lifecycle update.
- Composer keeps draft after send failure.
- Voice state changes update the composer status row.

### Motion And Feedback Tests

- Send button swaps to progress state while send request is in flight.
- Composer text clears only after send succeeds.
- Failed send keeps draft visible and shows retry state.
- Upload chip shows uploading, success, failed, retry, and removed states.
- Assistant streaming updates the existing card rather than inserting repeated cards.
- Tool started/completed transition preserves expansion state and updates status in place.
- Reconnecting banner appears during socket retry and disappears after reconnect.
- Reduced-motion mode disables shimmer, pulse, slide, and shake animations.

### Manual Device Checks

- iPhone small screen with keyboard open.
- iPhone large screen with dynamic text enabled.
- Android device with back button.
- Slow network during live stream.
- Airplane mode while a command is running.
- Long assistant answer.
- Long terminal output.
- Multiple image attachments.
- Failed image upload.
- Microphone permission denied.
- Reduced-motion accessibility setting enabled.

## Implementation Boundaries

- Do not implement WebView screens.
- Do not force pixel parity with the Web client.
- Do not show every raw daemon event by default.
- Do not add persistent drafts in the first release.
- Do not add push notifications in the first release.
- Do not add multi-daemon profiles in the first release.

## Success Criteria

- Each mobile page has a clear primary task and no desktop-style dense layout.
- Chat renders all current event types without losing important information.
- Live streaming updates existing cards instead of creating noisy duplicates.
- Users can read older history while new events arrive without losing scroll position.
- Composer remains usable through keyboard, upload, voice, send, and reconnect states.
- The app communicates daemon connection state clearly without blocking normal reading.
