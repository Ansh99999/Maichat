# Feature notes & recurring test traps

Distilled non-obvious knowledge per feature, plus Flutter/test traps that keep
recurring. Architecture itself is in `CLAUDE.md`; this is the "watch out" layer.

## Per-chat overrides — resolve in exactly one place each
`AppState.interfaceFor(conversation)` (style) and `AppState.characterFor(
conversation, id)` (a character *inside a thread*) are the **only** ways to read
them — `_assemble`, `restartConversation`, `impersonationFor`, the message list
and the exporter all go through them, so an override can't be honoured in one
place and forgotten in another. A per-chat `ChatInterface` is a full frozen copy
(offers Reset, says app-wide changes won't reach it). Editing a character "for
this chat" goes through `Character.clone()` + `CharacterEditScreen(persist:false)`
— `Character` is mutable, so without the clone, editing mutated the shared card
as you typed. Saving asks per character (this chat / globally) and refuses to
finish while any row is unanswered.

**`Conversation.copyAs` is field-blind on purpose** — fork/renumber used to
enumerate fields by hand, which silently dropped each new per-chat field. Every
new per-chat field must survive `copyAs` (there are tests; a dropped field here
has shipped more than once).

**The endless "update available" prompt was version drift, not the updater:**
`kAppVersion` (`lib/app_info.dart`) drifted from `pubspec.yaml`, and
`UpdateService` compares the latest tag to `kAppVersion`. `test/
app_version_test.dart` fails on drift — that guard is the real fix; keep it.

## Lorebooks (world info / memory books)
- `priority` and `weight` are **deliberately separate** (Agnai's split): priority
  survives the token budget, weight orders (heaviest nearest the reply). An ST
  book has only `order`, so it fills both.
- Codec sniffs 4 shapes (world-info object-keyed-by-uid, card `character_book`
  array, Agnai `kind:'memory'`, our superset). ST export writes **exactly one
  top-level `entries` key** (the only shape Agnai's importer accepts).
- Activation (`world_info.dart`): literal keys with `*`→`\w*`/`?`→`\w`, or a regex
  when written `/pattern/flags`; case-insensitive whole-word; speaker names are in
  the searched text. Then constant entries → selective logic → recursion (cap 3) →
  inclusion groups → budget (default 500 tok, stop at first that doesn't fit) →
  placement. **Deliberately inert (need per-chat bookkeeping that doesn't exist):
  sticky/cooldown/delay, min activations, vectorised activation.**
- **Never independently reviewed** — reviewer subagents died on proxy quota; only
  the risky bits were self-read. Character import can read a card's
  `character_book` but the Discover download path is what actually files it (a
  plain character import may still drop it).

## Group chats
- **Whose card is sent (default SWAP, matches ST/Agnai):** the invoked member's
  **full card** is `{{char}}`; others are one compact "Other characters present"
  system block; every turn is labelled `Name:` on the wire. So all are involved,
  only the speaker's card is paid for. Lives in `_assemble(responder:)` +
  `_groupBriefing` + `_groupTurnLabel`.
- **Turn model (v1.13.7):** a plain `send` adds only the user's turn — **nobody
  auto-replies**. Tap a chip (`speakAs`) or set a per-chat auto-responder
  (`Conversation.groupResponder`: null=manual, `kGroupResponderRandom`, or a member
  id). `nextSpeaker` (round-robin) survives only as the regenerate fallback.
- `participantIds` (≥2 ⇒ `isGroup`); bound `characterId` stays the primary so 1:1
  paths are untouched. `ChatMessage.speakerId/Name` are null in 1:1 (pre-group
  JSON byte-identical).

## Gallery (non-float parts — floats are in `floating-image-lag-fix.md`)
- Floating a picture puts **nothing** in the transcript or on the wire. A
  picture's owner is optional. `FloatingImage` names its picture by `imageId`
  (gallery record) **or** `imageRef` (a picture never in the gallery — e.g. an
  avatar off an imported card must be floatable).
- **`avatarPoolIn(conversation, characterId)` unions** the chat's own choice, the
  override's pool and the roster's — an override is about a character's *text*,
  never which pictures exist (reading the pool off the frozen override made
  multi-avatars invisible in chats with per-chat definitions).
- "Send to chat" is gated on `conversationId != null`, **not** on the gallery
  mode — "All pictures" reached from a chat must still send.
- **`_sweepAvatars`' keep-list must name**: gallery images, `Character.avatars`,
  per-chat `avatarOverrides`, override cards' pools, chat backgrounds, **and**
  `FloatingImage.imageRef`. A miss deletes a picture that's on screen. Deleting a
  *character* keeps their photos (unlike Agnai).

## Recurring Flutter / test traps
- **`Transform.translate` moves paint, not hit-testing** — a box is only hit
  inside its own layout bounds, so a translated control freezes after one use
  unless the gesture target is *inside* the transform (or laid out where drawn).
- **Never `ImmediateMultiDragGestureRecognizer`** — passes widget tests, dead on a
  real touchscreen. Kill gesture-arena competition at the source instead (e.g. a
  non-scrolling host), not with an exotic recognizer.
- **`GestureDetector.onPanUpdate` loses the arena** to an enclosing scrollable for
  a mostly-vertical drag. Preview/drag hosts must not be scrollable where a
  vertical drag matters.
- **`ChatInterface.hashCode` is at the `Object.hash` 20-arg limit** — new fields
  must fold into an existing slot, not add an arg.
- **Anything layout-conditional: write the full matrix** (TextPlacement ×
  NamePosition × avatar-shown × ActionBarPlacement) and confirm it fails before
  the fix. Silent fallbacks + testing one config shipped the same "fixed it"
  broken several times.
- **Verification honesty:** no device here; the Linux `xvfb` build + widget tests
  are the only checks, and they are **blind to gesture/GPU feel** — that has
  shipped wrong repeatedly. Say plainly what was verified vs what needs the phone.
- Test image work needs `tester.runAsync` (decode/`toImage` hang under the fake
  clock); PNG fixtures are hand-built. A measured widget (`_MeasureSize`/post-frame)
  needs **two** `pump()`s before its rect is right.
