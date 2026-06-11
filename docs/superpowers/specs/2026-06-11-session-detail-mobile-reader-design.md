# Session Detail Mobile Reader Design

## Goal

Make the session detail page readable on mobile first. The current page renders the session as a narrow stream of equal-weight cards, so real assistant output is buried under repeated status and tool events. This design makes the transcript readable, keeps operational noise available, and avoids changing backend behavior.

## Scope

This slice only changes the session detail experience:

- `SessionDetailView`
- timeline projection for detail-page display
- timeline card presentation
- CSS used by the detail page

It does not change the daemon API, managed session protocol, create flow, attach flow, persistence, or agent adapters.

## Mobile Baseline

The mobile layout is the source of truth. At phone width the page is a single column:

1. Compact top bar with Back, agent kind, and current status.
2. Compact session summary card with workspace path, source kind, and runtime session id when present.
3. Transcript cards with user messages and assistant answers as the primary content.
4. Collapsed operational summaries for tool activity, reasoning, and status changes.
5. Composer near the bottom of the page, using the existing send behavior.

Assistant answers must use readable text sizing, line height, wrapping, and spacing. Long text should feel like a reading surface, not a log cell.

## Event Presentation

The detail page should stop rendering every low-level event as a peer card.

- Consecutive assistant deltas remain merged into one assistant card.
- Consecutive reasoning deltas remain merged, but reasoning is collapsed by default.
- Tool lifecycle events are grouped into compact activity summaries by label and status count.
- Repeated status changes are compressed so they do not dominate the transcript.
- User and assistant message cards stay visible in the main flow.
- File-change reports remain visible, but can be compact.

The UI may still expose raw-ish operational detail inside collapsible sections. The default reading path should be user prompt, assistant answer, relevant file/activity summary.

## Desktop Enhancement

Desktop layout is progressive enhancement only. Above tablet width, metadata and activity may move into side areas, but the mobile information model remains the same. The implementation should not depend on desktop-only sidebars to make the page usable.

## Error And Edge States

- Empty sessions show a compact empty transcript state above the composer.
- Very long runtime session ids wrap or truncate safely without widening the viewport.
- Long assistant output wraps naturally and remains selectable.
- Many tool events collapse into one or a few summaries instead of producing dozens of cards.

## Testing

Frontend tests should cover:

- Tool events are grouped into a compact activity item.
- Reasoning is collapsed by default.
- Session detail renders the compact mobile-first structure.
- Existing send behavior still calls the provided `onSend` callback.

Manual verification should include opening the app at a narrow viewport and confirming the transcript is readable before checking desktop width.
