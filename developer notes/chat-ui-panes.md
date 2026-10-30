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
the main chat and pushes that full-width surface left; on larger screens its
divider resizes it alongside the chat and menu. Each side thread supports
follow-ups, streamed answers, Stop, copy and Back. The top-left rectangular
cutout returns to chat; the matching top-right `<` cutout reopens the existing
thread. Both support horizontal dragging at the same height. Dragging assigns
progress directly, pauses/reversals hold exactly, and releases use a spring.
Touching a closing cutout catches its current position. Covered/closing panes
exclude focus, semantics and chat taps; the outer pointer listener stays opaque
so moving controls remain catchable. Reduced-motion settings skip the settle.

Every `/btw` command or New side thread action creates a saved thread, including
a blank command. Threads are stored separately in `btwThreads`; switching main
chats loads only that chat's threads. They never enter roleplay messages,
summaries or future story context. Saved partial replies load as stopped.
Deleting a thread/chat cancels its side request and title request; delayed
callbacks cannot resurrect it. Snapshot backups restore side preferences and
threads; merge imports side threads while retaining current title preferences.
Restore fences and cancels side jobs, then drains serialized thread, preference
and side-usage writes before loading the archive. Old callbacks cannot overwrite
the restored store, including when a chat controller is disposed during restore.

The settings cutout below Back pours out the existing Material liquid panel.
Search and the saved-thread list are above the prompt/provider/tools symbols;
selecting a symbol expands its name and editor. Long press or the accessible
row action opens anchored Delete/Export controls. Export saves only that thread
as native JSON or text. Android Back closes actions, then settings, then the
thread. Short keyboard layouts retain 48 dp controls and scroll their content.
The side settings window and Settings → Side conversations both offer
Main-chat arrow opacity, from 10–100%, defaulting to fully visible for older
settings. The global preference persists on slider release. Fill, icon and
shadow alpha are painted directly; the 48 dp tap/drag target stays usable.

Settings → Side conversations chooses first-line or AI-generated titles. AI
titles use one separately metered, tool-free request after the first answer;
failure retains the first line. Thread settings resolve provider/model,
system prompt and tools separately from the main chat. A custom system prompt
replaces the leading system block before history budgeting; protected in-chat
instructions remain. Both tool and ordinary requests include prior completed
successful side exchanges and budget the final request. Large discarded main
prompts must not prune history that fits under the shorter side prompt.

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

The default suite includes phone/tablet/desktop × composer tests, intermediate
pane motion, interrupted/held/cancelled gestures, saved-thread persistence,
keyboard × large-text layouts and actual side-override wire requests, plus narrow
message-action layouts, tracker placement × hidden-call tests, Tools settings
and persistence tests, and actual wire tests for side follow-ups and built-in
follow-up controls. Run the full suite and analyzer before pushing.

Generate previews explicitly:

```sh
flutter test test/screenshots/chat_tools_preview.dart test/screenshots/chat_panes_preview.dart --update-goldens
flutter test test/screenshots/chat_tool_editor_preview.dart --update-goldens
flutter test test/screenshots/btw_settings_preview.dart --update-goldens
```

Previews are in `docs/previews/`: `chat-tool-calls.png`,
`chat-tool-results.png`, `chat-tool-tags.png`, `chat-tool-test.png`,
`btw-thread.png`, `btw-reopen.png`, `btw-settings.png`, `btw-settings-tools.png`,
`btw-thread-actions.png`, `btw-settings-large-text.png`,
`btw-settings-landscape.png`, `chat-menu-pane.png` and `chat-panes-wide.png`.
A Linux release under Xvfb checks startup; touch feel,
the Android keyboard and real provider endpoints still need device testing.

The saved-thread update was verified on 2026-10-29 with a clean analyzer,
3,878 passing tests, generated previews and a Linux release startup under Xvfb.
The original phone motion and custom-prompt budgeting regressions failed before
their fixes. The final suite includes queued-write/restore races and idle-flush
teardown coverage; an idle side queue must not suspend `flushPendingSaves`.
These host checks do not establish Android GPU frame pacing or live-provider
compatibility. APK production and rolling beta publication run in GitHub Actions.
