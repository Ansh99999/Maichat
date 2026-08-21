# Prompt wire shape & storage — hard-won invariants

## Exactly one leading `system` message (verify at the wire, not the assembly)
The outgoing request must contain **one** `system` message, at position 0.
Any preset block that lands after the conversation starts (depth/absolute
injections like `</chat_history>`, `<last_message>`, a trailing `<task>`/
`<output_format>`) must go out as a **`user`** turn. Enforced in
`PromptBuilder._oneSystemBlock` + `mergeSameRole`.

**Why (verified at a proxy, not inferred):** some OpenAI→other gateways (e.g.
AIClient2API's openai→gemini converter) map `role:system` into a single
`system_instruction`, and the **last** system message overwrites the earlier
ones. With a preset that emitted system at positions 0/2/4, `system_instruction`
arrived upstream as the trailing 2265-char `<task>` block **with the character
sheet gone entirely** — the model then claimed it had no character definition.
Confirmed by diffing the proxy's `[Req Processed]` log lines (broken:
system=2265 chars no sheet; fixed: 12258 chars sheet present).

**Method:** never reason about assembly alone — assert the actual outgoing
request. `test/wire_payload_test.dart` boots real `AppState` + `ChatClient`
against a loopback `HttpServer`; the app also has a "copy raw request" button in
View prompt. Real preset fixture: `test/fixtures/marinara_spaghetti.json`.
`test/lorebook_wire_test.dart` asserts depth-injected lore lands as a `user`
turn, i.e. the one-system rule still holds.

## Pictures are files, never base64 in SharedPreferences
`Character.avatar` (and chat backgrounds, extra avatars) hold an `http(s)` URL, a
`local:<file>` ref into the `AvatarStore` directory, or legacy base64 **only
until the startup migration moves it**. There is **no size cap anywhere** by
design (the old 768px re-encode and 4MB embed ceiling were deleted).

**Why this is a hard invariant:** base64 avatars used to live *inside*
SharedPreferences. Android reads the whole prefs file at launch and builds each
value in a `StringBuilder` — a single ~47M-char value (`characters`, full of
base64) hits `OutOfMemoryError` in `KXmlParser.readValue` **before any Dart
runs**. The app becomes unopenable, and the read that would let you fix it is the
read that dies. `lib/services/prefs_repair.dart` is the escape hatch: it streams
the prefs *file*, treats any run of base64 >1MB as an embedded picture, writes
each to its own file leaving a `local:` ref in place, and renames the old store
aside (reached from the load-error card, which asks to restart — the platform
caches the unreadable store for the process life).

## `AppState.init()` must always finish
Timeout + catch; on failure it surfaces `loadError` and goes read-only
(`_writable=false`) so a half-loaded session can't overwrite the store. A throw
here = permanent startup spinner. Also: resolve the pictures directory
(`getApplicationSupportDirectory`) in `main()` **before** `runApp`, never inside
`init()` — it never completes under a widget test's fake clock.

## Render-cost facts worth keeping
- `ChatScreen` does `context.watch<AppState>()`, so **any** `notifyListeners()`
  rebuilds every visible `MessageBubble`. Scope notifications; don't fire them for
  cheap/local state. (This is the exact cause behind the float-settle freeze —
  see `floating-image-lag-fix.md`.)
- `flutter_html`'s `expressionToFontFamily` keeps only the first family of a CSS
  stack and never sets `fontFamilyFallback` → resolve stacks to a platform-real
  family (`serif`/`sans-serif`/`monospace`/`cursive`) before parsing
  (`message_html.dart`).
- Avatar images: `avatarImage()` returns the identical `ResizeImage`-capped
  provider per (content signature, pixel bucket), because `MemoryImage` keys the
  cache by byte-list *identity* — one avatar on N turns was N decodes + N full
  bitmaps otherwise.
- Settings ▸ About ▸ Storage lists the biggest prefs entries.
