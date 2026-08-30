# MaiChat — project guide for Claude Code

MaiChat is a from-scratch Flutter mobile AI chat client (package
`me.maitavern.maichat`). Scope grew from one chat screen into a full
SillyTavern/Agnai-class frontend: multi-provider chat, characters, presets with
a macro engine, lorebooks, an in-app catalogue browser ("Discover"), chat
import/export, and deep per-chat customisation. Primary target is **Android**
(sideloaded APK). There is **no iOS build** and the Linux desktop build exists
only for headless smoke-testing.

This file is the durable context; it is not a changelog. The commit history and
the code are the source of truth — verify file:line claims before relying on them.

## Build & verify (works in a fresh container/Codespace)

- `flutter pub get`, then `flutter analyze` must be **clean** and `flutter test`
  must be **fully green** before anything is considered done. The suite is large
  (800+ tests) and is the real safety net — there is usually **no physical device
  or emulator available**, so tests + a Linux build are the only end-to-end check.
- Linux smoke test runs headless under `xvfb-run` (e.g. build `--release` for
  linux and launch briefly). Use it to eyeball UI changes.
- Android release APK: `flutter build apk --release` (or
  `--split-per-abi` + a universal build, as CI does).

### Build gotchas that have each cost a failed build

- **Gradle heap:** the low-RAM dev host needed `android/gradle.properties`
  `org.gradle.jvmargs=-Xmx1536m` + `org.gradle.daemon=false` (the template's
  `-Xmx8G` got OOM-killed → exit 144, empty log). A Codespace has more RAM, so
  this is less likely to bite, but that's why the value looks small.
- **INTERNET permission:** Flutter only injects it into the *debug* manifest.
  It is added explicitly in `android/app/src/main/AndroidManifest.xml` for
  release, or every network request fails on device. Leave it in.
- **AGP-9 Kotlin-plugin workaround:** under this project's AGP, several native
  plugins don't get the Kotlin plugin applied and fail with "cannot find symbol
  <Plugin>". `android/build.gradle.kts` has a `subprojects { ... }` hook that
  applies `org.jetbrains.kotlin.android` to the affected modules. When you add a
  plugin that ships native Android code (file_picker, url_launcher_android,
  path_provider_android, webview_flutter_android are already listed), **add it to
  that hook** or the release APK won't build. Prefer pure-Dart deps to avoid this.
- Dependencies are **pinned exactly (no `^`)** on purpose.

## Release & version discipline

- CI (`.github/workflows/build-apk.yml`): on push/PR to `main`, on `v*` tags, and
  on manual dispatch — runs analyze + test, then builds APKs. On a `v*` tag it
  cuts a GitHub Release with **keystore-signed** APKs (signing decodes
  `KEYSTORE_BASE64` etc. from repo secrets into `android/key.properties`; the
  build falls back to debug-signing when absent).
- `kAppVersion` in `lib/app_info.dart` **must track `pubspec.yaml`**. Drift here
  caused an "update available" prompt that never went away (the updater compares
  the latest GitHub tag to `kAppVersion`). `test/app_version_test.dart` fails on
  drift — keep it that way.
- Debug-signed installs (early versions) must be uninstalled before installing a
  real-key release; the signatures don't match for in-place upgrade.

## How the user wants me to work

- **Small, self-contained UI fixes:** commit (with the standard Co-Authored-By
  trailer) and `git push origin main` **without asking**. Still confirm before
  larger/riskier changes, version bumps, release tags, or anything destructive.
- **Layout-conditional code:** write the full **matrix** of tests (e.g.
  TextPlacement × NamePosition × avatar-shown × ActionBarPlacement) and confirm
  it *fails before* the fix. Silent fallbacks and testing one configuration have
  caused the same "fixed it" to ship broken several times.
- **Prompt/wire behaviour:** never reason about assembly alone — assert against
  the **actual outgoing request**. `test/wire_payload_test.dart` boots the real
  `AppState` + `ChatClient` against a loopback `HttpServer`; the app also has a
  "copy raw request" button in View prompt.
- **Verification honesty:** with no device here, gesture/hardware behaviour has
  shipped wrong twice despite green widget tests. Say plainly what was verified
  (analyze, tests, Linux/xvfb) and what needs the user's phone.

### Widget tests and real file I/O

A `testWidgets` body runs inside a fake-async zone that **never pumps real
`dart:io` futures**, so anything that writes a picture (`storePicture`,
`storeAttachment`, `addGalleryImages`, `AvatarStore.write`) hangs forever if it is
plainly awaited — the symptom is a test that sits there until `pumpAndSettle`
times out ten minutes later, with no assertion failure. Wrap those calls in
`tester.runAsync(...)`, or wait for a chain of them with a loop of
`runAsync(Future.delayed(...))` + `pump()` (see
`test/image_gen_ui_test.dart`'s `settleRealWork`). Plain `test()` bodies are
unaffected. Two related traps in the same tests: a progress spinner means
`pumpAndSettle` never settles, and a drag started at the left edge of the chat is
eaten by the drawer's edge-swipe region.

## Critical invariants — do not regress these

- **Exactly one leading `system` message on the wire.** The request must contain
  a single `system` message at position 0; any preset block that lands after the
  conversation starts (depth/absolute injections, trailing `<task>`/`<output_format>`)
  goes out as a `user` turn. Enforced in `PromptBuilder._oneSystemBlock` +
  `mergeSameRole`. Reason: some OpenAI→other gateways map `role:system` into a
  single `system_instruction` and the **last** system message overwrites earlier
  ones — multiple system messages silently drop the character sheet, and the model
  then claims it has no character definition.
- **Pictures are files, never base64 in SharedPreferences.** Avatars/backgrounds
  live in the `AvatarStore` directory; `Character.avatar` holds an `http(s)` URL,
  a `local:<file>` ref, or legacy base64 only until the startup migration moves
  it. Base64 blobs inside prefs previously grew the store until Android's native
  prefs parser OOM'd *before Dart ran* — an unopenable app. `lib/services/prefs_repair.dart`
  is the escape hatch. There is **no avatar size cap** by design. This holds for
  message attachments too (`MessageImage.ref`): base64 only ever exists on the
  copy handed to the wire, and `_sweepAvatars`' keep-list must name every message
  attachment or the sweep deletes a picture that is in the transcript.
- **Per-chat overrides resolve in exactly one place each.** Read a thread's style
  via `AppState.interfaceFor(conversation)`, a character *inside a thread* via
  `AppState.characterFor(conversation, id)` and its scenario via
  `AppState.scenarioFor(conversation, character)` — assembly, restart,
  impersonation, the message list and the exporter all go through them.
  `Conversation.copyAs` keeps fork/renumber from dropping a new per-chat field.
- **`AppState.init()` must always finish** (timeout + catch, surfaces `loadError`,
  goes read-only on failure). A throw here = permanent startup spinner.
- **The thread is a `reverse: true` list, and that has consequences.** Its newest
  turn is anchored to the bottom and every older message is positioned relative to
  it, so a turn that grows moves the whole conversation above it. Two rules follow:
  a streaming reply repaints on a cadence (`AppState._streamPaintMs`) rather than
  per delta, and while the reader is scrolled away mid-stream the newest turn is
  drawn frozen at the text it had (`_ChatScreenState._frozenTail`). Never `jumpTo`
  the thread while a gesture is live — `jumpTo` goes through `goIdle`, which
  cancels the drag or fling outright (`_scrollToEnd` guards on
  `userScrollDirection`). At offset 0 nothing needs scrolling at all: the bottom
  anchor already follows a growing reply.
- **A view preference never rides in the `conversations` blob.** That entry holds
  every message of every chat, so re-encoding it to record one boolean is tens of
  milliseconds of JSON on the UI thread. Memory-block folds live in their own
  `summaryFolds` entry and are laid back over the summaries on load
  (`AppState._applySummaryFolds`); `browseLayout` does the same via `viewPrefs`.

## Architecture map (where things live)

- **State/persistence:** `AppState` (provider `ChangeNotifier`) + `Storage`
  (`shared_preferences`, keyed blobs: `providers`, `presets`, `characters`,
  `discover`, `macroGlobals`, `tokenizer`, …). Note the app's own `Provider`
  model clashes with the `provider` package — UI files do
  `import 'package:provider/provider.dart' hide Provider;`.
- **Providers & networking:** `models/provider.dart` (`ProviderKind`
  openai/anthropic/gemini; multi-key with `keyStrategy` rotation), `ChatClient`
  (`streamChat` yields `ChatDelta{text,reasoning}`; branches per kind for SSE,
  headers, thinking/reasoning wire, non-streaming).
- **Generation pipeline:** `models/preset.dart` + `models/prompt_block.dart`
  (SillyTavern-style blocks/order), `services/macro_engine.dart` (full ST macro
  superset), `services/prompt_builder.dart` (assembles blocks→messages, budgeting,
  absolute-depth injection), `services/tokenizer.dart` (real BPE via
  `tiktoken_tokenizer_gpt4o_o1`), `services/model_context.dart`. `AppState._assemble`
  is the single path real sends and the prompt inspectors share.
- **Characters:** `models/character.dart` (ST v1/v2/v3 + Agnai superset, macro
  resolution), `services/character_codec.dart` (parses flat/spec cards, PNG
  `chara`/`ccv3` chunks, `.charx` ZIP carving), `services/character_sources.dart`
  (import plugins), screens under `lib/screens/` + `widgets/character_avatar.dart`.
- **Lorebooks:** `models/lorebook.dart`, `services/lorebook_codec.dart` (ST world
  info / card `character_book` / Agnai memory books — one export file all read),
  `services/world_info.dart` (activation scan). `lib/screens/library/`.
- **Scenarios:** `models/scenario.dart` (Agnai's shape: text plus
  `overwriteCharacterScenario`; Agnai's triggered `entries`/`states` ride in
  `extensions` and deliberately do not fire), `services/scenario_codec.dart`
  (Agnai / character card / MaiChat / plain prose in, MaiChat + Agnai out),
  `screens/library/scenarios_screen.dart` + `scenario_edit_screen.dart`,
  `widgets/scenario_picker_sheet.dart` (the browse → preview → edit-in-place →
  "library or here only?" → Proceed sheet, used by the character sheet's scenario
  fold and by chat settings). A scenario arrives by one of three routes and they
  are ranked in `AppState.scenarioFor` alone: the chat's own text, the library
  scenario `Conversation.scenarioId` names, then `Character.activeScenario`.
- **Browse layout:** cards-vs-rows for Characters / Lorebooks / Scenarios is a
  *persisted* preference (`models/view_prefs.dart`, the `viewPrefs` store entry,
  `AppState.browseLayout`/`setBrowseLayout`) — no screen holds it in a field.
- **Discover (in-app catalogue browser):** `models/discover.dart`,
  `services/discover/*` (per-site sources: Chub, JannyAI, CharacterTavern, Risu
  realm, Botbooru, Pygmalion, Wyvern, DataCat — each with its own API quirks),
  `screens/discover/*`. A feed is a live remote view held by
  `discover_controller.dart`, deliberately *not* in `AppState`.
  `discover_item_screen.dart` is the **character sheet drawn from a listing**: it
  builds the same slivers out of `screens/character_sheet_parts.dart`
  (`TagBand`, `SheetDivider`, `NotesBlock`, `DefinitionFolds`) plus its own
  natural-ratio portrait, so a catalogue entry gets the card's images, HTML and
  CSS exactly as a local character does. Its two differences: a flat "From the
  catalogue" block between the tags and the notes, and `DefinitionFolds(
  interactive: false)` — the scenario picker writes onto a *stored* character and
  this one is not saved yet.
- **Chat portability:** `services/chat_codec.dart` (imports ST `.jsonl`, Agnai,
  ooba, CAI, Risu, Kobold, plain logs; native export is one file ST+Agnai+MaiChat
  all read). `test/chat_codec_test.dart` has a "what the other apps accept" group.
- **Backups (Settings ▸ Backups):** `models/backup.dart` (schedule, destination,
  `BackupPrefs`, `BackupRecord`, counts, stats), `services/backup_codec.dart`,
  `services/backup_store.dart` (the app's own `backups/` folder),
  `services/drive_client.dart`, `services/foreign_backup.dart`,
  `screens/backups/*`. A backup is a zip of `maichat-backup.json` +
  `pictures/` + `vectors/`, and the manifest holds **the store itself**, entry by
  entry, decoded — copied verbatim rather than rebuilt from the models, which is
  why a restore lands per-chat overrides and any field added later without this
  code knowing about them. `kBackupExcludedKeys` keeps `backupPrefs`/`backups`
  out of a backup, so restoring an old snapshot cannot disconnect Drive or erase
  the history that is being read from. A restore writes files first, then the
  store (`replace` removes anything the archive does not mention; merge
  reconciles lists by id and leaves settings alone), then `reloadFromStore()`;
  keys blanked out of a keyless backup fall back to the live ones
  (`preserveSecrets`). Every export goes through `AppState.exportBackup`, which
  is also what the schedule calls — there is no background worker, so
  `runDueBackup()` runs from `init()` when one is owed, and only the in-app and
  Drive destinations can run without a save dialog.
- **A backup is never held in memory whole**, and that is the invariant the whole
  feature is built around: the first version read the picked file with
  `withData: true` and inflated every picture into a map, which on a real gallery
  is hundreds of megabytes and killed the process — a crash with no Dart error to
  show for it. So: the picker is called **without `withData`** and everything
  works from the path it returns; an export is written to a temp file with
  `writeBackupFile` (pictures *stored*, not deflated — they are already
  compressed) and then moved into place or streamed to Drive
  (`DriveClient.uploadFile` builds the multipart body from a file stream, and
  `downloadToFile` streams the other way); a restore opens `BackupArchive` from
  the path, which inflates only the manifest, and `extractFiles` writes one entry
  at a time. `looksLikeOurBackupFile` is how the import screen tells one of ours
  from somebody else's without reading it twice.
- **Foreign imports** are a different mechanism (`services/foreign_backup.dart`):
  the archive is opened from disk, every entry is routed through the codec that
  already reads it, and pictures go straight into the pictures directory through
  an injected `PictureStore` sink as they are read (so nothing accumulates, and a
  picture used in a message *and* in the gallery is one file). The SillyTavern
  layout is taken from its own repo, not guessed: `USER_DIRECTORY_TEMPLATE` in
  `src/constants.js` for the folders, and `chats.js` for the fact that a chat
  lives in `chats/<card file name>/` (from `avatar_url` minus `.png`) — which is
  the *only* record of whose chat it is, so the cards are read first and indexed
  by file name. `settings.json` carries the personas (`power_user.personas`, keyed
  by avatar file, with `persona_descriptions` and `default_persona`) and the tag
  names (`tags` + `tag_map`); `groups/*.json` + `group chats/*.jsonl` are the two
  halves of a group chat; a turn's pictures are `extra.media[].url` (plus legacy
  `extra.image`/`image_swipes`) pointing into `user/images`, and those paths are
  rewritten to `local:` refs *before* `ChatCodec` parses the transcript, which is
  what puts a generated picture back on the turn that made it. Everything with no
  home here (themes, quick replies, extensions, wallpapers, `secrets.json`) is
  counted in `ForeignBackup.skipped` and reported — including `instruct/` and
  `context/`, which frame a *text*-completion prompt (literal sequences and a
  Handlebars story string) and would import as markup; `sysprompt/` does come
  across, as a preset whose Main Prompt and Post-History blocks are its
  `content`/`post_history`. Both readers report through `BackupProgress`, which
  is what the import screen's bar and the restore dialog's bar draw. `test/backup_sillytavern_test.dart`
  builds that layout file by file, with a real world-info fixture and a real
  chat-completion preset out of SillyTavern's own `default/content`.
  Drive is OAuth with a "Desktop app" client, PKCE, and a loopback listener —
  deliberately no custom scheme, so no native plugin and no AGP-9 hook. The
  client the app ships with lives in `kBundledDriveClientId`/`Secret`, injected
  by CI from the `DRIVE_CLIENT_ID`/`DRIVE_CLIENT_SECRET` repo secrets and empty
  in a fork (or a local build), which is what makes connecting one tap; an installed app's client secret is not a confidential credential and the
  only scope asked for is `drive.file`, so the pair grants nothing on its own.
  `DriveClient.clientIdFor` prefers a client the user pasted under Advanced, and
  the grant never records which client made it.
- **Gallery:** `models/gallery_image.dart` (a record + the sort/zoom enums),
  `models/floating_image.dart`, `services/gallery_group.dart` (the pure
  date-bucketing and sorting the screens draw), `screens/gallery/*` (one
  `GalleryScreen` in three modes, the viewer, the upload/edit/picker sheets, the
  pinch ladder), `widgets/avatar_swipe_sheet.dart`,
  `widgets/floating_images_layer.dart`. Pictures are files like every other
  image; a character's extra avatars live in `Character.avatars` and are resolved
  only through `AppState.avatarPoolFor`/`avatarRefFor`.
- **Chat UI:** `screens/chat_screen.dart`, `widgets/message_bubble.dart`
  (swipes/variants, per-message action bar, name placement, attachments),
  `widgets/thinking_block.dart`, per-chat settings screen,
  `screens/prompt_view_screen.dart` (View prompt inspector).
- **Pictures in a chat (sending):** `models/message_image.dart` — a turn's
  `ChatMessage.images` hold a `local:`/URL ref plus a mime; the base64 only exists
  on the copy `AppState._wireImages` builds, capped at `kMaxWireImages` newest.
  Each dialect carries an attachment differently and the four shapes live together
  in `ChatClient`'s "attachments" block (`anthropicTurn`, `geminiParts`,
  `_responsesImage`, `ChatMessage.openAiContent`); `requestPreview` elides the
  payload. The composer's tray (`_AttachBar` in `chat_screen.dart`) opens off the
  operations strip and offers gallery-or-device, then previews what will be sent.
  `test/image_wire_test.dart` asserts the outgoing bytes per dialect.
- **Image studio (generation):** `models/image_gen.dart` (`ImageGenConfig` — its
  own endpoint and key, deliberately *not* the chat provider, which is what makes
  "every chat can generate a picture" true), `services/image_client.dart` (OpenAI
  `/images/generations`, multipart `/images/edits` when there are reference
  pictures, and Gemini `:generateContent` asking for an image modality; failures
  are `ChatApiException` with the chat client's own wording),
  `screens/image_gen/image_gen_sheet.dart` (a 75%-height sheet with its settings
  page swapped in *inside* the sheet) + `image_gen_settings.dart`. Everything it
  makes is filed in the gallery under the chat's character by
  `AppState.generateImages`; "Send to chat" goes through `postImageToChat`. Reached
  from the drawer footer, the composer's operations strip, and
  `MessageAction.imagine`.
- **Branches / Chat Graph:** a branch is a whole `Conversation` linked to its
  source by `Conversation.parentId` + `forkIndex` (set only by
  `AppState.forkConversation`). `services/chat_graph.dart` is the pure view over
  that: `buildFamilyTree`/`flattenGraph` for `screens/chat_graph_screen.dart`,
  and `collapseForks` → `ChatTreeEntry`, which is why a tree is **one row** in
  the Chats/Home lists (named after its root, previewing its freshest branch).
  A missing parent degrades to a root — no cascade delete, no dangling tree.

## Can't be verified from a headless host

- **On-device gestures/touch** — verify drag/nudge on the user's phone. This now
  includes the gallery's pinch-to-zoom ladder and the drag/resize/rotate of
  pictures floating over a chat, and how smooth scrolling back through a chat
  *feels* while a reply streams (the widget tests pin down offsets and extents,
  not perceived smoothness).
- **A real image endpoint.** The studio is written against agreeing sources and
  loopback tests; whether a given host wants `quality`, rejects a `size`, or hands
  back a link instead of base64 is only settled by pointing it at one. Nothing
  here has a key.
- **Saving a picture to the device gallery.** "Save to this device" uses the
  system save dialog (`FilePicker.saveFile`), the same permission-free path every
  other export takes — it writes wherever the user points it, not into MediaStore,
  which would need a native plugin (and the AGP-9 Kotlin hook).
- **Google Drive backups.** The whole flow (consent, PKCE, token exchange,
  multipart upload, listing, download, delete) is exercised against a loopback
  stand-in for Google in `test/drive_client_test.dart`, and nothing here has a
  Google client. What only a real account settles: whether the browser on the
  user's phone follows the `http://127.0.0.1:<port>` redirect back into the app,
  and whether their own Cloud project has the Drive API enabled.
- **Chub** (`api.chub.ai` etc.) geo-blocks datacentre IPs; **JannyAI** is
  Cloudflare-challenged from a datacentre. Those Discover paths are written from
  agreeing sources + loopback tests and confirmed on the user's phone, not here.
  If Chub 403s on device it's geo-blocking, not a client bug.

## Note for a cloud environment

The host-specific verification aids from the original dev machine (a local
AIClient2API proxy, an APK-staging file server, seeded prefs stores) are **not**
present in a Codespace. The portable equivalents — loopback-server wire tests,
`flutter analyze`/`flutter test`, and the `xvfb` Linux smoke build — are what to
lean on here.
