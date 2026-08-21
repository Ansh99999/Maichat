# Chat import/export — cross-app format facts

`lib/services/chat_codec.dart` reads/writes chats across SillyTavern/TavernAI
`.jsonl`, Agnai export JSON, our native JSON, ooba `data_visible`, CAI Tools
`histories`, RisuAI `risuChat`, KoboldAI Lite `savedsettings`, and a plain
`[{role,content}]` log. All verified against the real code in
`/home/ubuntu/SillyTavern` and `/home/ubuntu/agnai`, not from memory.

**Parse order:** whole-document `jsonDecode` is tried **first**, the line
(JSONL) format second — a JSONL file's first line parses alone but the file does
not.

## The facts that were easy to get wrong
- **ST `is_system` lines are interface notices, not transcript** — ST's own
  `.txt` export skips them, so importing them invents turns.
- **Agnai keeps the greeting on the chat, not in the log** — it must be put back
  as the opening turn or the character loses it.
- **Agnai `retries` are newest-first and exclude the live text** (which stays in
  `msg`). Ours are oldest-first with an index, so the mapping reverses.
- **Agnai's client validator requires `name`/`greeting`/`scenario`/`sampleChat`
  as present strings** plus `messages[].msg`; extra keys are ignored.
  `characterId:'imported'` is the marker it swaps for the real character.
- **ST recognises any JSON object with a `messages` array as an Agnai export** and
  reads the speaker from `!!message.userId`.
- **ST jsonl** only demands the header define one of `user_name`/`name`/
  `chat_metadata`; per-swipe extras live in `swipe_info[i].extra`; reasoning is
  `extra.reasoning` + `reasoning_duration` + `reasoning_type:'model'`. Chub's
  variant nests text as `{message:…}` in both `mes` and each swipe.
- **Timestamps are derived, not recorded** — a thread here has one `updatedAt`;
  both ecosystems order by per-message stamps, so exports spread them one second
  apart, ending at the thread's.

## The one-file-three-apps trick
The native export is **one file all three apps read**: the whole thread plus
those four Agnai strings, every turn carrying `msg` + `userId`/`characterId`
beside `role`/`content`. (Same trick as the lorebook export: an ST world-info
export writes exactly one top-level `entries` key, which is the only shape Agnai's
importer recognises; our extras ride in `extensions.maichat`.)

## The contract test that guards it
`test/chat_codec_test.dart` has a **"what the other apps will accept"** group that
mirrors each app's real validation — so a change fails *here* rather than
producing a file another app silently refuses. Keep it green when touching export.

## Groups round-trip too
Exports attribute each turn to its speaker (`_turnSpeaker`; non-primary members
get a stable `char-<slug>` id, the primary keeps `imported`). A multi-speaker
`.jsonl`/Agnai import is reconstructed into a group: ≥2 distinct AI speaker names
become per-chat name-only members (`characterOverrides` + `overrideDefinitions`),
since such logs carry names but not cards. `_reseat` uses `Conversation.copyAs`
(hand-enumerating fields dropped `participantIds` on native re-import).

## UI traps here (see also feature-notes-and-test-traps.md)
- A large app bar renders its title **twice** (headline + collapsed toolbar) — a
  trailing button in the title also sits top-right, tappable while invisible.
  `_HeadlineAction` tells the copies apart via
  `findAncestorWidgetOfExactType<NavigationToolbar>()`.
- `Clipboard.getData` **never completes under `flutter_test`** (hangs → timeout),
  and disposing a `TextEditingController` right after `showDialog` returns throws
  mid-fade. The paste box is its own `StatefulWidget` with an un-awaited prefill.
