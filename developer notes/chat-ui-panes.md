# Chat panes and Tools

The chat and Studio Playground share a three-pane layout. Below 720 logical
pixels, the menu takes 78% of the width and pushes a full-width, inactive chat
to the right. Phone users can choose Slide chat or Overlay chat under Settings →
Appearance; Overlay leaves the chat in place beneath the menu. The choice survives
restarts. At 720 logical pixels and above the menu is always 25% of the width,
and both the chat and menu remain usable.

The menu follows a held finger directly, including pauses and reversals. Release
settles it by position and velocity, and touching a moving menu stops its animation
so the same finger can take over. The hamburger toggles the menu; edge dragging,
the phone scrim and Back also work. There is no separate close chip. Closing it
does not restore keyboard focus. Phone movement uses retained transform layers,
and streamed text does not rebuild menu content whose displayed data is unchanged.

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
and creating one use full screens. Test is also a full-screen route with its
arguments JSON, Run button and result. Built-in definitions remain read-only;
their Follow up setting is a separate per-scope override. User tags can be
added, renamed and removed in both built-in and custom editors, and persist
per scope (global or that chat). The settings screen
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
flutter test test/screenshots/chat_tool_editor_preview.dart --update-goldens
```

Previews are in `docs/previews/`: `chat-tool-calls.png`,
`chat-tool-results.png`, `chat-tool-tags.png`, `chat-tool-test.png`,
`btw-thread.png`, `chat-menu-pane.png` and `chat-panes-wide.png`. A Linux release under Xvfb checks startup; touch feel,
the Android keyboard and real provider endpoints still need device testing.
