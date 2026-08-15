# MaiChat

**A mobile-first, UI-driven AI frontend — inspired by SillyTavern, Agnaistic, RisuAI and the
rest of the family, rebuilt for a phone.**

MaiChat is a Flutter app. Android is the primary target, and it also builds and runs on
Linux desktop. It follows Android's Material You design (wallpaper-derived colours, light /
dark / AMOLED, your own accent), is provider-agnostic, and is built to be driven from the
UI rather than from config files.

If you're on mobile, there is no server to run. MaiChat is **single-user focused**: grab an
APK from [Releases](https://github.com/Ansh99999/Maichat/releases), enter an API key, and
chat. Open an [issue](https://github.com/Ansh99999/Maichat/issues) if you want a feature
added.

This project is partly vibe-coded — but it is actively maintained, and each change is kept
under test (550+ unit and widget tests, `flutter analyze` clean, enforced in CI on every
push).

---

## Install

1. Download the latest `MaiChat-<version>.apk` from
   [Releases](https://github.com/Ansh99999/Maichat/releases). It's a single universal APK —
   no ABI to pick.
2. Allow install from unknown sources and open it.
3. Open **Settings → Providers**, add a provider, paste your API key, pick a model.

Notes:

- Releases from **v1.2.0** onward are signed with the project's real key. If you installed
  a v1.0.x/v1.1.x build (debug-signed), **uninstall it first** — Android will refuse the
  upgrade otherwise.
- No account, no telemetry, no backend. Your keys and chats live in the app's own storage
  on your device, and requests go straight to whichever provider you configured.

## Updating

Updates are **sporadic and frequent** — sometimes 2–3 in a day. Each one adds a feature or
fixes a bug, and each one carries some chance of introducing a new minor bug. MaiChat checks
the GitHub Releases API and shows an update icon in the navigation drawer when a newer
version exists.

**Recommendation: update when the app tells you to**, not by watching the tag list.

---

## Features

**Providers** — bring your own key, any of three wire formats:

| Format | Speaks to | Notes |
| --- | --- | --- |
| OpenAI-compatible | OpenAI, OpenRouter, DeepSeek, Groq, local llama.cpp / Ollama / LM Studio, most proxies | Just change the base URL |
| Anthropic | Claude | Native `/messages`, extended thinking, exact token counting |
| Google Gemini | Gemini | Native `streamGenerateContent`, thinking budgets |

- Multiple named providers side by side; switch the active one from the chat itself.
- **Multiple API keys per provider** with round-robin, random or error-based rotation.
- Model list fetched from the provider and searchable (cached, refresh on demand).
- Streaming with a stop button — and a real non-streaming mode when you turn streaming off.

**Characters**

- Import from **file, pasted JSON, a direct URL, or a JannyAI/JanitorAI link**.
- Reads SillyTavern **v1 / v2 / v3** cards, **Agnai** characters, character JSON **embedded
  in a PNG** (`chara` / `ccv3` chunks), and RisuAI **CharX** (`.charx`, including cards
  appended after a JPEG) — with the card's own art kept as the avatar.
- Full card editor: description, personality, scenario, first message, alternate greetings,
  example dialogue, system prompt, post-history instructions, creator notes, tags.
- Library with search, tag filter, sort, starred shelf, grid/list toggle, multi-select,
  duplicate, and bulk export as SillyTavern v2 cards.
- **Impersonation**: pick any character as *you*, per chat — their name, avatar and persona
  are used for your turns and injected into the prompt.

**Prompts, presets and macros** — the SillyTavern generation model, presented Agnai-style:

- Reorderable **prompt blocks** with enable/disable, roles, and absolute-depth injection.
- Samplers and budget: temperature, top-p/top-k, penalties, seed, stop sequences, max
  response tokens, max context.
- **Macros**: a full `{{...}}` engine — nesting, `{{if}}/{{else}}`, scoped blocks,
  `{{setvar}}`/`{{getvar}}` with per-chat and global variables, `{{char}}`/`{{user}}`
  identity, escaping.
- Import/export presets as **SillyTavern**, **Agnai**, or MaiChat's own format; unknown
  fields are preserved on round-trip.
- Per-chat preset override, or a library default.
- **Real token counting** (tiktoken `cl100k`/`o200k`, offline) — plus exact counts from
  Anthropic's `count_tokens` when a Claude key is set.
- **Prompt inspector**: see exactly what will be sent, section by section, with token
  totals, per-message info, and "copy raw request".

**Chat**

- **Message swipes** — alternate greetings from the card, and regenerations kept as
  variants you can swipe back to instead of losing.
- Per-message actions (regenerate, edit in place, delete, copy, fork, view prompt, info),
  each placeable inline or in an overflow menu, with a choice of where the bar sits.
- **Thinking / reasoning** support: Anthropic extended thinking, Gemini thinking budgets,
  OpenAI-style `reasoning_effort`, and `<think>`-tag splitting for models that inline it —
  shown in a collapsible block with elapsed time.
- Markdown and inline HTML in messages, including code blocks.
- Fork, restart, rename, delete a chat; export the transcript to the clipboard.

**Looks** — the part that gets the most attention:

- Material You: wallpaper colours on Android 12+, or your own seed colour with a built-in
  HSV picker; System / Light / Dark / **AMOLED** (true black).
- Any Google Font, app-wide or per name label.
- Chat style: bubbles or document mode, content width, font size, message spacing, bubble
  opacity, and explicit colours for user/bot text, bubbles and background.
- Avatars: per-role size (up to very large), shape, corner roundness, fit, side, and
  drag-to-nudge position.
- Name labels: per-role size, colour, font, alignment, above/below, drag-to-nudge.
- **Text wrapping rules**: give any symbol pair a colour, and choose whether the markers
  stay visible — the general form of what `*italics*` and `"quotes"` already do.
- A live preview of all of it while you tune.

---

## Coming from SillyTavern, Agnai, RisuAI or JanitorAI

MaiChat aims to read what those ecosystems produce. Concretely:

**Comes in cleanly**

- Character cards — SillyTavern v1/v2/v3 JSON, character PNGs, Agnai characters, RisuAI
  CharX.
- Chat-completion presets — SillyTavern and Agnai preset files, including their prompt
  order, samplers and reasoning settings.
- Character links — RisuAI realm and JannyAI/JanitorAI URLs (JanitorAI sits behind a bot
  wall that sometimes blocks a direct download; when it does, MaiChat tells you to download
  the file and import it from disk).

**Does not come in (yet)**

- **Chat histories.** There is no `.jsonl` chat-log import, so past conversations do not
  travel. Characters and presets do.
- **Lorebooks / world info.** The prompt blocks exist and are ordered correctly, but there
  is no lorebook system behind them yet, so those blocks render empty.
- Group chats, extensions, image generation, TTS.

**Going the other way**

- Characters export as SillyTavern v2 cards (single or bulk), presets export as SillyTavern
  or Agnai, chats export as a plain-text transcript. So cards and presets travel back out;
  chats do not, in a form another app will read.

MaiChat and SillyTavern are **inherently different things**. MaiChat is a Flutter/Dart app
built for one person on one device; SillyTavern is a Node.js server with scale and an
extension ecosystem built in. Expect differences in functionality, not a drop-in
replacement.

If a platform you use is open source and you want compatibility with it, open an issue.

## Platform support

| Platform | State |
| --- | --- |
| **Android** | Primary target. Signed universal APK on every release. |
| **Linux** | Builds and runs (`flutter run -d linux`); used for development and UI checks. |
| **Windows / macOS** | Nothing in the app is Android-only, but the desktop scaffolding isn't in the repo yet — run `flutter create --platforms=windows,macos .` first. Untested; reports welcome. |
| **iOS** | Not scaffolded. No signing story. |

---

## For developers

**Prerequisites**

- Flutter **3.44.9** (the version CI pins) with Dart SDK `^3.12.2`
- JDK **17** and the Android SDK, for Android builds
- Nothing else — no server, no database, no codegen step

**Build and run**

```bash
flutter pub get
flutter analyze          # must be clean
flutter test             # 550+ tests, all must pass
flutter run -d linux     # fastest loop for UI work
flutter build apk --release
```

**Recommended: let GitHub Actions build the APK.** `.github/workflows/build-apk.yml` runs
`analyze` + `test` and builds a universal release APK on every push and PR to `main`, on
manual dispatch, and on `v*` tags — a tag also attaches the APK to a GitHub Release. Fork
the repo and the workflow works as-is; without the signing secrets
(`KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`, `KEY_PASSWORD`, `KEY_ALIAS`) it falls back to
debug signing. This is easier than keeping a local Android toolchain healthy, especially on
a small machine.

**Layout**

```
lib/
  models/     Character, Preset, PromptBlock, Provider, Conversation, ChatInterface, …
  services/   chat_client (the wire), prompt_builder, macro_engine, tokenizer,
              character_codec (card formats), preset_io, storage, update_service
  screens/    home, chats, chat, characters, presets/, settings/
  widgets/    message_bubble, thinking_block, avatars, pickers
  state/      app_state.dart — the single ChangeNotifier everything reads
test/         one file per concern; ~half are widget tests driving real screens
```

**Gotchas worth knowing before you build**

- Some plugins don't compile under AGP 9 unless the Kotlin plugin is applied to them by
  hand; `android/build.gradle.kts` has a `subprojects` hook naming the affected ones. Add
  to it if you add a native plugin and hit "cannot find symbol …Plugin".
- `android/gradle.properties` lowers `org.gradle.jvmargs` on purpose — the Flutter
  template's `-Xmx8G` gets OOM-killed on small hosts.
- Release builds need `android.permission.INTERNET` declared explicitly in
  `android/app/src/main/AndroidManifest.xml`; Flutter only injects it for debug.
- `version:` in `pubspec.yaml` and `kAppVersion` in `lib/app_info.dart` must stay in step —
  the in-app update check compares the latter against the latest release tag.
- The app's own `Provider` model collides with the `provider` package, so UI files import it
  as `import 'package:provider/provider.dart' hide Provider;`.

## Contributing

Pull requests are welcome, with a few asks:

- **Don't change core features.** Rework of the send pipeline, storage shape or provider
  wire needs discussion in an issue first.
- Priority goes to **cosmetic changes, customisability, and logic features** — in that
  spirit.
- Keep `flutter analyze` clean and the test suite green, and add tests for what you change.
- For anything layout-conditional, test the **matrix**, not the one configuration you were
  looking at. Several bugs here shipped because a fix was verified in the default layout
  only.

Feature requests and bug reports both belong in
[Issues](https://github.com/Ansh99999/Maichat/issues). Please say which provider and model
you were using for anything generation-related.

## Credits

Standing on the shoulders of [SillyTavern](https://github.com/SillyTavern/SillyTavern),
[Agnaistic](https://github.com/agnaistic/agnai) and [RisuAI](https://github.com/kwaroran/RisuAI)
— their card, preset and prompt formats are the reason MaiChat can read your existing
library at all.
