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

## The chat turn: sideways swipe, and editing in place

- **A swipe over a message has to be won from the text.** On Android a
  `SelectableText` (and a `SelectionArea`) installs a
  `TapAndHorizontalDragGestureRecognizer` with `eagerVictoryOnDrag`, so it claims
  every horizontal drag as soon as the touch slop is cleared — and being the
  deeper widget it is offered the pointer first, so a detector *wrapped around*
  the turn can never win. `_SwipeGestureArea` (in `message_bubble.dart`) instead
  puts the gesture in a **translucent `Positioned.fill` sheet as the last child of
  a `Stack` over the turn**: the last child is hit first, so its recognizer is
  offered the pointer first and wins the tie at the ordinary threshold. Do not
  "fix" this by lowering the recognizer's slop — the per-axis race with the
  thread's vertical scroll is what keeps scrolling reliable, and a lowered slop
  starts stealing scrolls. The cost of the sheet: dragging across a message no
  longer *selects* text (long-press still does).
- The turn follows the finger through a `ValueNotifier` + a permanently-present
  `Transform.translate`. Both halves matter: a `setState` per drag frame would
  rebuild the bubble (markdown/HTML/avatar) 90 times a second, and inserting or
  removing the `Transform` would re-parent — and so rebuild — the whole subtree.
- **Editing is the same bubble, not a replacement.** `MessageBubble(editing: ...)`
  swaps the words for an undecorated `TextField` and the action bar for ✕/✓;
  everything else (avatar, name, pictures, layout, swipe control) is untouched.
  Two things keep it from jumping: `decoration: null` (a *decorated* field is 44 px
  tall whatever its padding says) and the real action bar kept behind the ✕/✓,
  invisible but still measured (an overflow menu makes it 48 px, a plain row 40).
  `IntrinsicWidth` is what stops a short turn's bubble from ballooning to the full
  thread width. One caveat that cannot be fixed: a line ending within ~3 px of the
  thread's maximum width rewraps, because a caret needs those pixels.
- **A view preference is not the only thing that must stay off the hot path:**
  `setSwipe` saves through `_saveConversationsSoon()`. Re-encoding the whole
  `conversations` blob on the frame that swapped the text is what made stepping
  through alternatives feel choppy. In a `testWidgets` body, pump past the 400 ms
  timer or the test fails with a pending timer.
- **Never read `MediaQuery.padding` in `ChatScreen.build`.** `padding` is
  `viewPadding` minus `viewInsets`, so it *changes on every frame of the keyboard's
  animation* — which rebuilt the whole chat (thread, composer, drawer) when the
  keyboard only ever needed to relayout it. `viewPaddingOf` is the same number and
  does not move. `test/chat_keyboard_test.dart` pins this by comparing widget
  identity across a keyboard frame.

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
- **A drag in a test is not a drag on a phone.** `tester.drag` sends the touch slop
  as one jump, so two recognizers with thresholds a couple of pixels apart both
  trip in the same event and the deeper one wins; a real finger arrives in small
  moves. Drag on the *words* (`find.text`), not the bubble's centre — the centre
  can land on the ‹ 1/2 › arrows, where a short drag is simply a tap on one.
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
