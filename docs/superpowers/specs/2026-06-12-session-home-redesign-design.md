# Session Home Redesign Design

## Goal

Rework the authenticated sessions home so it feels like a deliberate control surface instead of a stack of raw forms. The sessions list should read like a recent-project launcher, the primary actions should be obvious, and creating a session should happen in a modal with a user-provided title.

## Approved Direction

The approved direction is a mobile-first dark control surface inspired by the reference screenshot's rhythm, not its exact visuals:

- the authenticated home becomes a compact launcher-style page with a title block, a two-action control row, and a large-card session list
- each session is represented by one full-width clickable card instead of a text dump plus a separate open button
- `New session` and `Attach session` move into matching modal dialogs instead of rendering inline below the list
- managed sessions gain a create-time `title` field; the list page and detail header show that title first
- the create modal hides `Workspace` when only one root exists and still submits that root automatically

## Scope

This slice changes only the sessions home and the minimum supporting data model:

- `frontend/src/App.tsx`
- `frontend/src/components/SessionListView.tsx`
- `frontend/src/components/CreateSessionView.tsx`
- `frontend/src/components/AttachSessionView.tsx`
- shared frontend styles used by the authenticated home and dialogs
- frontend tests covering the new list and modal behavior
- daemon request/response DTOs, session store, and migration support required to persist a managed-session title

This slice does not include:

- renaming a session after creation
- new filtering, sorting, search, or pinning features
- changes to message sending, timeline projection, or session-detail transcript behavior
- making `Attach session` require a title

## Information Architecture

The authenticated home becomes a single-purpose sessions launcher.

### Top block

The top block contains:

- page title such as `Sessions`
- one short supporting line explaining that these are local Agent Dock sessions

This block should feel compact and confident, not like dashboard copy.

### Primary actions

Below the title sits a two-column action row:

- primary card button: `New session`
- secondary card button: `Attach session`

Both actions should look like tappable surfaces, not small gradient pills. The primary action may carry a brighter accent fill; the secondary action should stay darker with a strong border and icon treatment.

### Session cards

The session list becomes a vertical stack of large cards. Each card is a single clickable surface that opens the session.

Card content hierarchy:

1. session title
2. workspace path
3. compact metadata chips for agent, source kind, and status
4. attached-session runtime id as low-priority supporting text only when present

The title is the only large text on the card. Supporting metadata should never visually compete with it.

### Empty state

If there are no sessions, the page should still show the action row and a compact empty-state card inviting the user to create or attach a session. This avoids the current feeling of an unfinished screen.

## Visual Direction

The home should feel closer to a polished launcher than an admin form:

- dark graphite and blue-black shell
- large rounded cards with restrained borders and layered shadows
- stronger separation between page background, action cards, and session cards
- minimal accent color usage reserved for the primary action and active-status chips
- typography with one clear display weight for titles and a quieter UI face for metadata

Avoid generic dashboard treatment, bright gradients on every element, or over-decorated sci-fi effects. The memorable part should be the clean hierarchy and tactile card surfaces.

## Create Modal

`New session` opens a centered modal on desktop and a bottom-sheet style surface on small screens. The modal contains only the fields needed to create a managed session:

- `Session name`
- `Agent`
- `Path`
- `Workspace` only when more than one root exists

Behavior:

- `Session name` is required and trimmed before submit
- `Path` remains required and trimmed before submit
- when there is exactly one root, the UI hides `Workspace` and silently submits that root's id
- the modal shows a short derived hint such as `Creates in /root/path` so the path field has visible context
- submit stays disabled only for obviously invalid empty required fields; server failures remain inline in the modal

The modal footer should present a clear primary submit button and a quiet cancel action. Closing the modal should not mutate the current list selection.

## Attach Modal

`Attach session` uses the same modal shell so both entry points feel like one system. Its fields remain:

- `Agent`
- `Runtime session ID`
- `Path`
- `Workspace` only when more than one root exists

This modal does not add a title field in this slice. Attached sessions continue to rely on fallback display naming unless a future rename feature is added.

## Session Naming And Fallback Rules

Managed sessions need a persisted `title`.

Data model changes:

- add nullable `title` to stored session records
- include `title` in session summary and session detail responses
- accept `title` in managed-session creation requests

Fallback rules:

- list cards display `title` when present
- if `title` is missing, display the last path segment from `workspacePath` when possible
- if no useful path segment exists, fall back to `agentKind`
- session detail header follows the same rule so old sessions remain readable without migration backfill

This keeps backward compatibility with existing rows and attached sessions while making new managed sessions feel intentional.

## Backend And Persistence Notes

The backend change should stay minimal:

- add a migration that introduces nullable `title` on `sessions`
- thread `title` through create-session request DTOs, store insertions, summaries, and snapshots
- keep attach-session storage unchanged except for returning the nullable `title` field

There is no need for a rename endpoint, title history, or title validation beyond basic non-empty trimmed input in this slice.

## Error Handling

The new UI should handle the common failure cases without adding speculative behavior:

- empty required fields show inline validation before submit
- create or attach API failures surface a short inline error message in the open modal
- if root loading fails or returns zero roots, the page should not pretend creation is available; the create modal submit must stay blocked until a root exists
- very long titles and runtime ids must wrap or truncate without widening the viewport

## Testing

Automated tests should cover:

- session list renders title-first cards and uses a single clickable card surface to open a session
- create modal submits `title`, `agentKind`, `path`, and the default single root id
- create modal hides the `Workspace` field when only one root exists and shows it when multiple roots exist
- attach modal uses the same conditional workspace behavior
- existing sessions without `title` still render a fallback title
- backend create-session persistence returns the stored title in both list and detail payloads

Manual verification should include:

- phone width around 375px: action cards and session cards read clearly with no horizontal scroll
- desktop width: cards remain centered and do not become a stretched form slab
- modal open/close transitions do not feel jarring and keep focus behavior usable
- creating a managed session with a custom title shows that title immediately in the list and the detail header
