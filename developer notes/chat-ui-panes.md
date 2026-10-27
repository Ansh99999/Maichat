# Chat panes and Tools

The chat and Studio Playground share a three-pane layout. Below 720 logical
pixels, the menu takes 78% of the width and pushes a full-width, inactive chat
to the right. On larger screens it takes 25% (180–360 pixels), and both the
chat and menu remain usable. The menu has edge-swipe, close, scrim and Back
paths; closing it does not restore keyboard focus.

Typing `/`, `/b` or `/btw` uses the Studio slash-command list. Sending the side
question opens a Document-style thread from the right. On phones it covers
the main chat; on larger screens its divider resizes it alongside the chat
and menu. Each side thread supports follow-ups, streamed answers, Stop,
copy, Back and starting a fresh thread. Completed exchanges stay in memory
while the chat screen is open, including after closing the pane. Switching
chats clears them. They never become roleplay messages or saved chat history.
Both tool-enabled and ordinary requests receive prior side exchanges and
budget them along with the current question.

Settings → Tools contains search, category filters, sorting and the tool list.
Each row has a toggle and a horizontal action strip. Inspect, opening a tool
and creating one use full screens. Built-in definitions remain read-only;
their Follow up setting is a separate per-scope override. The settings screen
contains enable/disable, call limits, tracker placement, hiding call details,
and import/export. Global defaults and per-chat overrides use the same state
resolution as execution.

Tracker chips read `Excitement: 50%`. With message placement they follow the
message text and precede the swipe selector. Hiding tool-call details preserves
tracker chips; pinned and hidden tracker placements remain independent.

## Verification

The default suite includes phone/tablet/desktop × composer tests, narrow
message-action layouts, tracker placement × hidden-call tests, Tools settings
and persistence tests, and actual wire tests for side follow-ups and built-in
follow-up controls. Run the full suite and analyzer before pushing.

Generate previews explicitly:

```sh
flutter test test/screenshots/chat_tools_preview.dart test/screenshots/chat_panes_preview.dart --update-goldens
```

Previews are in `docs/previews/`: `chat-tool-calls.png`,
`chat-tool-results.png`, `btw-thread.png`, `chat-menu-pane.png` and
`chat-panes-wide.png`. A Linux release under Xvfb checks startup; touch feel,
the Android keyboard and real provider endpoints still need device testing.
