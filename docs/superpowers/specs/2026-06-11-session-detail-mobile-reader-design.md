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

## Visual Direction

The page should feel like an industrial reader for agent work, not a terminal log. Use a dark OLED-style shell with restrained depth, green running-state accents, and a warm assistant reading surface. The contrast between the dark operational shell and the warm answer card makes the user's default path obvious: read the prompt, read the answer, inspect activity only when needed.

Recommended visual tokens:

- Background: deep black / blue-black shell such as `#05080d`, `#08111d`, and `#0b1422`.
- Panel surface: navy slate cards such as `#0b1625`, `#0d1b31`, and `#101c2d`.
- Running accent: green such as `#22c55e` with darker green badge backgrounds.
- Assistant card: warm paper such as `#f1eadc` with dark ink text such as `#141a22`.
- Muted text: blue-grey such as `#8fa1bd` / `#9fb0ca`.
- Borders: low-opacity slate borders; avoid bright neon outlines.
- Depth: use a few soft shadows on major cards only; do not shadow every event equally.

Typography should prioritize readability. Use a highly legible sans for UI and prose, with a monospace only for runtime ids, labels, and command-like text. The preferred pairing is Atkinson Hyperlegible for UI/prose and JetBrains Mono for technical metadata. If external font loading is avoided, choose the closest local fallback while preserving the same role split.

Avoid cyberpunk treatment, scanlines, glitch effects, excessive neon, or fully monospace body text. The product is a serious developer workspace, not a sci-fi terminal skin.

## Component Treatment

The detail page should have distinct visual roles:

- Top bar: sticky or near-sticky compact navigation with Back, agent kind, and concise status/source text.
- Session summary: compact context card with workspace path, source kind, runtime id, and a live/running badge when applicable.
- User card: dark blue prompt card, compact but readable.
- Assistant card: larger warm reading card with comfortable line height and clear label.
- Activity summary: collapsed by default, showing grouped counts like `commandExecution completed × 12`.
- Reasoning card: collapsed by default, lower visual priority than assistant output.
- Composer: touch-sized message field and send button, visually attached to the bottom of the mobile flow without hiding content.

Touch targets for primary controls should be at least 44px high. Interactive elements need visible hover and focus states; do not remove focus outlines without an obvious replacement.

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

At desktop width, the reader can widen and optionally place metadata/activity in side rails. The transcript remains the center of gravity. Do not reintroduce a narrow timeline column on desktop.

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

Manual verification should include:

- 375px width: no horizontal scroll, answer card readable, controls touch-sized.
- 768px width: single-column or transitional layout remains readable.
- 1024px+ width: transcript gets more space without becoming a narrow log column.
- Keyboard navigation: Back, collapsible sections, textarea, and Send have visible focus.
- Reduced-motion preference: no required motion for comprehension.
