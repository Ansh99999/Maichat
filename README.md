# MaiChat

**SillyTavern-class customisation and control, with the ease of a UI built for a thumb.**

[![Release](https://img.shields.io/github/v/release/Ansh99999/Maichat?label=release)](https://github.com/Ansh99999/Maichat/releases)
[![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)
[![Build](https://github.com/Ansh99999/Maichat/actions/workflows/build-apk.yml/badge.svg)](https://github.com/Ansh99999/Maichat/actions/workflows/build-apk.yml)

MaiChat is an Android app for talking to AI characters, written from scratch in Flutter. It
is built around one idea: the depth SillyTavern, Agnaistic and RisuAI give you shouldn't
cost you a server, a text editor, or a laptop. Nothing here is configured by editing a file
— every knob is a knob you reach with a thumb, and the app is designed for one person on
one device rather than scaled down from something multi-user.

---

## Install

1. Download the latest `MaiChat-<version>.apk` from
   [Releases](https://github.com/Ansh99999/Maichat/releases) — one universal APK, no ABI to
   pick.
2. Allow installs from unknown sources, open it.
3. Add a provider from the drawer, paste your key, pick a model. That's setup.

No account, no telemetry, no backend of any kind. Keys and chats live in the app's own
storage on your device, and requests go straight from your phone to whichever provider you
configured.

Two notes: releases from **v1.2.0** onward are signed with the project's real key, so if you
still have a v1.0.x/v1.1.x build you have to uninstall it first — Android refuses the
upgrade otherwise. And updates land **often**, sometimes two or three in a day; the app
checks GitHub itself and puts an icon in the drawer when there's a newer one, so update when
it says so rather than watching the tag list.

---

## What makes it MaiChat

### Discover — a character catalogue *inside* the app

Eight community sites browsable from the drawer — Chub, JanitorAI/JannyAI, Character Tavern,
RisuRealm, Botbooru, Pygmalion, Wyvern and DataCat — each with its own search, sort and tag
list. Tap a tag once to require it, twice to exclude it; adult content is a switch, not a
default. A listing then opens on **the same page a character in your own library gets**: art
at its natural ratio, tags, creator notes, and the card's own HTML and CSS rendered rather
than dumped as markup. You decide before importing, not after. The same shelf is wired for
lorebooks and presets wherever a site publishes them.

No browser tab, no download folder, no "copy JSON and paste it in".

### A chat interface you actually design

Most of the app's surface area is here, and none of it is a theme preset:

- **Turns**: bubbles or flat document mode, content width, font size, spacing between
  messages, bubble opacity, and explicit colours for user and bot text, bubbles and
  background.
- **Avatars**: per-role size (up to very large), shape, corner roundness, fit, which side
  they sit on — and **dragged into position** with a finger rather than nudged by a number.
- **Name labels**: their own font, size, colour and alignment per role, above or below the
  turn, positioned the same way.
- **Actions**: whether each per-message action is an inline icon or lives in the overflow
  menu, in your order, with the bar itself placed where you want it — or switched off so
  only the long-press sheet remains.
- **Text wrapping rules**: give *any* symbol pair a colour and decide whether the markers
  stay visible. `*italics*` and `"quotes"` are just the two rules that ship with it.
- **Floating buttons**: how visible the menu square and the jump-to-newest arrow are, per
  chat, because it depends on the picture behind the thread.

A live preview sits under your finger the whole time you tune it. Then any of it — plus the
preset, the persona, the scenario, the lorebooks, its own background image — can be
**overridden for a single chat** without disturbing the rest.

### The prompt is yours, and you can see it

The generation half is SillyTavern's model, presented the way a phone can handle it:
**reorderable prompt blocks** you can enable, disable, re-role or inject at an absolute
depth; samplers and budgets; and a **full `{{macro}}` engine** — the legacy built-ins plus
the recursive superset, so nesting, `{{if}}` blocks, per-chat and global variables and
escaping all behave as they do upstream.

Two things make that usable rather than merely present. Token counts are **real** — proper
BPE counting offline, and exact counts from Anthropic when a Claude key is set — so the
budget readout isn't a character-count guess. And the **prompt inspector** shows what will
actually be sent, block by block, with per-message totals and a copy-raw-request button, so
"why did it forget the character sheet" is a question you can answer by looking instead of
by theorising.

### Being someone

Pick any character as **you**, per chat: their name, avatar and persona label your turns and
go into the prompt. Your profile holds a default persona for new chats, so the common case is
already set, and the uncommon case is one tap away in the chat you want it in.

### Material You, taken seriously

The whole app follows Android's design language rather than approximating it: the palette is
derived from your wallpaper on Android 12+, or from your own seed colour with a built-in HSV
picker; System / Light / Dark / **AMOLED** true black; any Google Font, app-wide or just for
name labels. Material 3 components, sheets that drag, and motion that means something —
that's the point, not a skin over a cross-platform grey.

### Providers with a bill attached

A provider isn't just a base URL and a key here. It has **prices per model, a spend ledger
and budgets**: tokens and money in and out, a per-model breakdown, usage charted over time,
and ceilings — per provider or per model, per period — that either warn you or refuse the
send. Where the host reports real token counts they're used; where it doesn't, the app's own
tokenizer estimates them and **says that it estimated**, because a guess presented as a bill
is worse than no number. Alongside that: several keys per provider with round-robin, random
or error-based rotation, a fallback chain, and per-provider headers.

### Memory that isn't just a bigger context window

Four mechanisms, each optional, each switchable for one chat without touching the others:

- A **running summary** made on an interval — rolling (recondense everything) or incremental
  (append the newest window). Its blocks are yours: retitle, edit, fold, reorder, write one
  by hand, or regenerate from where the conversation actually is.
- **Semantic recall** — earlier turns come back because they *mean* something relevant, not
  because a keyword matched.
- A **Data Bank** — drop documents into the Library (PDFs included) and let a chat draw on
  them.
- **Lorebooks / world info** — keyword activation as the desktop apps do it, with optional
  vector activation on top.

### Pictures are part of the conversation

A gallery per character and per chat, with date grouping and a pinch ladder to zoom the grid
itself. An **image studio** reachable from any chat, drawer or turn — it carries its own
endpoint and key, deliberately separate from the chat provider, which is what makes "any
chat can make a picture" true even when you're talking to a model that can't draw. Anything
it makes is filed under that chat's character. You can send pictures *to* a model that
accepts them, and pull any picture out of the gallery to **float over the thread**, dragged,
resized and rotated with your fingers.

### Steering a reply without saying it

A **response hint** is a line you type beside the conversation — "she's lying", "keep it
short", "don't resolve this yet" — that is injected into every send until you erase it, at a
depth you choose. It never becomes a turn in the transcript, so the nudge doesn't end up in
the story the model is telling back to you.

### Branches drawn as a tree

Fork any turn and the branch is a real conversation of its own, but your chat list still
shows **one row per family** — named after its root, previewing whichever branch you touched
last, so twenty experiments don't bury the twenty other chats. The **Chat Graph** draws the
whole tree when you want to see where you are.

### Turn-level craft

Editing a message happens **in the turn itself** — the words become editable where they sit,
the avatar, name and pictures don't move, and the action bar turns into ✕ / ✓. A regenerated
reply is kept as an alternative rather than thrown away, and the alternatives are a **ring**:
the arrows wrap, and a sideways drag across the turn steps through them with your finger.
Deleting always asks first, and offers to take the replies after it too. Reasoning arrives in
a collapsible block with the time it took, whether the model reports it properly or inlines
it in `<think>` tags.

### Backups you own

A whole-app snapshot — every chat, character, preset, lorebook, picture and setting — written
to a file you choose, the app's own folder, or **Google Drive**, on a schedule if you want
one. Restores can replace or merge, and a keyless backup falls back to the keys already on
the device rather than blanking them.

It also reads **somebody else's** backup: point it at a SillyTavern user-data archive and it
places the cards, chats, personas, tags, world info, presets, group chats — and the pictures
a turn generated, back onto the turn that generated them — then tells you plainly what it
couldn't place.

Nothing is ever held in memory whole, which is why a gallery of hundreds of megabytes backs
up on a phone at all. And a storage screen says where the space actually went — category by
category, each one openable and clearable — instead of leaving you to guess at an app that
has quietly grown to a gigabyte.

---

## Coming from SillyTavern, Agnai, RisuAI or JanitorAI

Your library should not be a reason to stay. MaiChat reads what those ecosystems produce, and
writes files they can read back.

| | Comes in | Goes out |
| --- | --- | --- |
| **Characters** | SillyTavern v1 / v2 / v3, character PNGs (`chara` / `ccv3`), Agnai, RisuAI `.charx` | SillyTavern v2 cards, single or in bulk |
| **Presets** | SillyTavern and Agnai, prompt order and samplers included | SillyTavern or Agnai |
| **Lorebooks** | SillyTavern world info, a card's own book, Agnai memory books | one file all three read |
| **Scenarios** | Agnai scenarios, a card's scenario, or plain prose | MaiChat and Agnai |
| **Chats** | SillyTavern `.jsonl`, Agnai, oobabooga, Character.AI, RisuAI, Kobold, plain logs | one file SillyTavern, Agnai and MaiChat all read |
| **Everything at once** | a whole SillyTavern user-data archive | MaiChat's own backup |

Characters also import straight from a URL — RisuRealm and JanitorAI links included — and
unknown fields survive a round trip instead of being quietly dropped.

**What doesn't travel:** instruct and context templates, because they frame a *text*
completion prompt and MaiChat speaks chat completions only — importing them would paste
markup into your prompt. Nor do themes, quick replies, extensions, wallpapers or
`secrets.json`. The importer counts and reports every one of those rather than failing
silently.

MaiChat and SillyTavern are **different kinds of thing**, and this isn't a drop-in
replacement: one is a Flutter app for one person on one phone, the other is a Node server
with an extension ecosystem. Expect the shapes to differ. Also not here: TTS, an extension
API, and any form of account, sync service or telemetry.

If a platform you use is open source and you want its files to load, open an issue.

## Platform support

| Platform | State |
| --- | --- |
| **Android** | The target. Signed universal APK on every release. |
| **Linux** | Builds and runs; used for development and UI checks. |
| **Windows / macOS** | Nothing is Android-only, but the desktop scaffolding isn't committed — run `flutter create --platforms=windows,macos .` first. Untested; reports welcome. |
| **iOS** | Not scaffolded, no signing story, not planned. |

---

## Building it yourself

Flutter 3.44.9 (the version CI pins), JDK 17 and the Android SDK. No server, no database, no
codegen.

```bash
flutter pub get
flutter analyze        # must be clean
flutter test           # must be green
flutter build apk --release
```

Easier still: fork it and let GitHub Actions build the APK — the workflow runs analyze and
tests on every push and attaches signed APKs to a release on a `v*` tag (falling back to
debug signing when the signing secrets aren't set).

The parts of this codebase that will bite you — the prompt-assembly invariants, the
per-chat override rules, the reverse-list chat, the Android build workarounds, and the
widget-test traps that have each cost a day — are written down in
[`CLAUDE.md`](CLAUDE.md) and [`developer notes/`](developer%20notes/). Read those before a
non-trivial change; they exist because something shipped broken first.

This project is partly vibe-coded, and openly so. What keeps that honest is the test suite:
1,700+ unit and widget tests, `flutter analyze` clean, both enforced in CI on every push.

## Contributing

Pull requests are welcome, with a few asks:

- **Don't rework core features.** The send pipeline, the storage shape and the provider wire
  need an issue and a conversation first.
- Cosmetic work, customisability and self-contained logic features get priority — that's the
  spirit of the app.
- Keep `flutter analyze` clean and the suite green, and add tests for what you change.
- For anything layout-conditional, test the **matrix**, not the one configuration you were
  looking at. Several bugs here shipped because a fix was verified in the default layout only.

Bugs and feature requests both belong in
[Issues](https://github.com/Ansh99999/Maichat/issues). For anything generation-related, say
which provider and model you were using.

## License

MaiChat is free software under the **GNU General Public License, version 3** — see
[`LICENSE`](LICENSE) for the full text.

In short: use it, study it, change it, share it. If you distribute a modified build, its
source has to be available under the same terms, so a fork of MaiChat stays as open as
MaiChat is. There is no warranty.

Copyright (C) 2026 Ansh Raj.

One dependency has its own terms worth knowing about if you plan to sell a fork:
`syncfusion_flutter_pdf` (PDF text extraction for the Data Bank) is free under Syncfusion's
community licence for individuals and small organisations, but it is not open source. It
governs itself, not MaiChat's code.

## Credits

Standing on the shoulders of [SillyTavern](https://github.com/SillyTavern/SillyTavern),
[Agnaistic](https://github.com/agnaistic/agnai) and
[RisuAI](https://github.com/kwaroran/RisuAI). Their card, preset, lorebook and chat formats
are the reason MaiChat can read the library you already have — and the reason it made sense
to build this at all.

