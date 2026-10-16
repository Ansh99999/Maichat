# Home v2 — plan (hand-off document)

Written so another model or harness can pick this up mid-way. Branch: `beta`.
Base commit: `6cef2d4` ("Home becomes a launcher of widgets…"). Read
`CLAUDE.md` (sections "Home screen (launcher)", "Nothing heavy runs before
Home's first frame") first — the architecture below extends it, it does not
replace it.

Status markers: `[ ]` todo · `[~]` in progress · `[x]` done (update as you go).

## Ground rules (from the user)

- Android design philosophy; **Material 3 Expressive is a must**.
- Smooth on a Snapdragon 695 (low-end): every animation must hold 60 fps there.
- Push to `origin beta` when done. Commit trailer `Co-Authored-By: Claude Code
  <noreply@anthropic.com>`. This host has no git identity: commit with
  `git -c user.name=Ansh99999 -c user.email=Ansh99999@users.noreply.github.com`.
- `export TMPDIR=$HOME/tmp` before every flutter command (/tmp is a tiny tmpfs).
- Done = `flutter analyze` clean + `flutter test` fully green (~2900 tests,
  ~10 min with `-j 2`). Gestures can't be verified here — say so.

## 1. Page swipe stutter  `[x]`

Causes (in `lib/screens/home_screen.dart`, `home/home_grid.dart`):
- Every page's tiles rebuild + relayout each frame of the swipe: tiles are built
  through `HomeCard`'s `LayoutBuilder` (+ `FittedBox`) every frame because the
  `PageView.builder` item subtree is not isolated.
- `context.watch<AppState>()` at the top of `HomeScreen.build` — any notify
  (a streamed reply, usage ledger) rebuilds the whole page mid-swipe.
- Images (gallery, avatars) decode on first sight of a page.
Fixes:
- Wrap each page in `RepaintBoundary`; each tile in `RepaintBoundary` too
  (a tile repainting must not repaint its neighbours).
- `PageView(allowImplicitScrolling: true)` so the neighbouring page is built
  and laid out *before* the swipe (no first-frame build hitch), and
  `KeepAlive` pages (`AutomaticKeepAliveClientMixin`) so returning never
  rebuilds.
- HomeScreen watches only what it needs: `context.select` for `ready`,
  `loadError`, `isConfigured`, `homeLayout`. Widgets watch their own slices
  (`context.select`) instead of the whole `AppState`.
- Page physics: `PageScrollPhysics` parent `BouncingScrollPhysics`-free, with a
  custom spring (`SpringDescription.withDampingRatio(ratio: 1.0, stiffness:
  ~500)`) — Expressive "spatial" spring, critically damped (no overshoot jitter).
- Pre-cache the next page's images (`precacheImage`) after first frame.

## 2. Edit mode redesign  `[x]`

Approved by the user, replacing the bottom toolbar (which shrank the screen
and showed tiles at 0.96 scale — "not approved"):
- **No global shrink.** Tiles are drawn exactly as live (scale 1.0).
- **Long-press a tile → a small context menu anchored at the tile's top-left
  edge** (floating, M3 Expressive "toolbar/menu": rounded 16 superellipse,
  `surfaceContainerHigh`, elevation 3): Edit (settings), Replace, Resize
  (shows handles), Duplicate, Move to page…, Remove. Positioned in an
  `Overlay`/`CompositedTransformFollower` so it never moves the grid; flips to
  below/right when there is no room above/left.
- **Keep holding and move → the menu closes and the tile lifts and follows the
  finger** (launcher behaviour). Drop snaps with a spring to the landing cell.
- Edit mode itself (entered by long-press on empty space or ⋮ → Edit) shows:
  the top bar (Done · Add · Grid · Look · ⋮), faint cell dots, and a gentle
  "jiggle-free" outline on every tile. Tapping a tile in edit mode = select →
  shows the same anchored menu + resize handles.
- **Selection border edge-to-edge** (user: "border comes a little off at the
  breadth"): the outline must be drawn *exactly* on the tile's shape — same
  rect (the gutter-deflated rect), same `RoundedSuperellipseBorder`, painted as
  a foreground on the tile's own clip — not on a separately padded/scaled box.
  The resize dots sit centred on the outline.

## 3. Multi-finger cross-page move  `[x]`

"Holding down on an app or widget, then swiping with a different finger should
move it across pages." Implementation:
- While a tile is lifted (pointer A down), a second pointer B doing a
  horizontal drag anywhere pages the `PageView` (`animateToPage` on fling /
  drag distance > 1/4 width), carrying the lifted tile along (the lifted tile
  is drawn in an overlay layer above the PageView, not inside a page).
- Also the classic launcher edge-hover: holding a lifted tile within 24 dp of
  the left/right edge for 450 ms flips the page.
- Drop resolves against the page now showing (`HomeLayout.moveTo(id, page, x,
  y)`, falls back to nearest free / spring back).
- Implemented with a `Listener` (raw pointers) over the whole grid area so it
  does not fight the gesture arena; the lifted tile's position = pointer A.

## 4. Fluid animation on low-end  `[x]`

- Only transform/opacity animations (no layout per frame): lift = `Transform`
  scale + elevation via a pre-rendered shadow; drag = `Transform.translate` in
  an overlay; ghost = `CustomPaint` of a rect.
- Springs (`SpringSimulation`) for drop/snap/menu, M3 Expressive motion
  tokens: spatial fast (stiffness 1400, damping 0.9), spatial default (700,
  0.9), effects (opacity) 1600/1.0.
- `RepaintBoundary` everywhere a thing moves independently.
- Avoid `AnimatedScale` per tile per state change during drags.

## 5. Chat widgets — denser + customisable  `[x]`

Problem: "majority of it just grey space". New `ChatPreviewCard`:
- Content fills the card: preview lines computed from the real height (already
  measured), larger body text at large sizes (bodyLarge ≥ 3 rows), name in
  titleMedium, avatar scales with card height (32 → 64 dp), message shown as a
  speech-bubble-like block when roomy, and the **last two turns** (user +
  character) at h ≥ 3.
- New options (both recent + pinned chat, written to `tile.config`):
  - `avatar`: `none` | `left` | `topLeft` | `topRight` | `right` |
    `background`. Background modes: `bgStyle` = `opaque` | `blur` | `fade`;
    `fadeFrom` = `left` | `right` | `top` | `bottom` (gradient scrim from that
    side); `bgDim` 0–90 %.
  - `showName` (toggle), `nameFont` (Google Fonts family picker — new
    `HomeFontOption` → `showSearchPicker`, like `FontPickerRow`).
  - `showTime` (toggle).
  - `lines`: `lastLine` (last line of the last message) | `firstLine` (first
    line of the last message) | `lastMessage` (whole last message, as many
    lines as fit) | `lastTwo` (last user + character turns).
- Blur background: `ImageFiltered` is expensive — pre-blur once with
  `ImageFilter.blur` inside a `RepaintBoundary` (cached raster), sigma ≤ 12,
  decode at small bucket (avatars cache by size). Fade = `ShaderMask`/gradient
  `DecoratedBox`, cheap.

## 6. Folders  `[x]`

a) **Character folder widget** (`HomeWidgetKind.characterFolder`): the
   existing `Folder` model (characters + lorebooks, scenarios, presets,
   providers, documents, pictures). Option `folderId` (new
   `HomePickKind.folder`). Look: the folder's colour + avatar; at 1×1 a folder
   icon tile (2×2 mini-grid of member faces, like an Android folder); larger:
   name, member faces, counts ("4 characters · 2 lorebooks"). Tap →
   `showFolderWindow(context, folderId:)` (existing).
b) **App folders** (`HomeWidgetKind.appFolder`): a launcher folder of
   quick-open shortcuts. Config: `name`, `targets` (comma-joined QuickTarget
   names — config values are scalars only), optional `color`. 1×1: the M3
   folder look (tonal container with a 2×2 preview of member icons); tap opens
   an M3 Expressive folder popup (scale-from-tile spring, rounded 28, title
   editable inline, grid of icons, "+" to add). Larger spans show the icons
   inline (up to what fits) plus a "more" cell.
   Creating one: in edit mode, **drag a quick-open icon onto another quick-open
   icon → they merge into an app folder** (Android behaviour; the target tile
   becomes the folder, the dragged tile is removed). Also "Add widget → App
   folder" and the folder popup's "+". Dragging an icon out of the popup puts
   it back on the grid.

## 7. New widgets  `[x]`

- **Clock** (`clock`): local time (+ date), and optional extra time zones.
  Options: `zones` (comma list of IANA names, picker over a bundled list),
  `style` (`digital` | `analog` | `expressive` — big bold numerals, M3
  Expressive), `seconds` toggle, `24h` toggle (default: follow
  `MediaQuery.alwaysUse24HourFormat`). Ticking: one shared `ClockTicker`
  (a single `Timer` aligned to the minute — or second when shown — feeding a
  `ValueNotifier<DateTime>`); paused when `TickerMode` is off (other page not
  visible, app backgrounded). Time zones: add `timezone: 0.11.2` (pure Dart,
  pinned, no native code → no AGP hook), load `latest_10y.tzf` bundled asset
  lazily (off the first frame, in an isolate if > 5 ms). If the asset is too
  big, fall back to a hand-written fixed-offset table — check APK size impact
  first and note it.
- **Notes** (`note`): a sticky note. Options: `noteId`; colour (`tone`: a few
  tonal containers), `font` size. Note text lives in its own store entry
  `homeNotes` (map id → {title, body, updatedAt}) — **never** in the layout
  blob (the layout is rewritten on every edit-mode Done). Tap → a full-screen
  M3 editor (`NoteEditorScreen`): large title field, body field filling the
  screen (`expands: true`, no fixed height jumps — see CLAUDE.md creator-field
  rule), markdown-ish preview off by default, autosave on pause/back
  (debounced 600 ms, never per keystroke), word count, "last edited". The
  widget shows title + as many body lines as fit.
- **Studio v2** (rework `studio_widget.dart`): visual progress. Per session:
  avatar + name, a status chip (Working / Waiting / Not applied / Applied),
  a todo progress bar (completed / total of `session.todos`), the current
  in-progress todo text, sub-agent dots (one per sub-agent, coloured by
  status), the last op summary ("edited Personality · 2 min ago"), tokens
  and cost. More information as size grows: 1×1 icon + live dot; 2×1 the
  latest session one line; 2×2 latest session in detail; 4×2+ a list of
  sessions with progress bars; 4×4 adds the last few ops as a timeline.
  Live: listen to `StudioHub` controllers (ChangeNotifier) of running
  sessions; rebuild only that row (`ListenableBuilder`).

## 8. Files touched (expected)

- `lib/models/home_layout.dart` — new kinds (`clock`, `note`,
  `characterFolder`, `appFolder`), `moveTo`, merge helpers.
- `lib/screens/home_screen.dart` — edit mode, menu overlay, cross-page drag,
  select instead of watch.
- `lib/screens/home/home_grid.dart` — rewrite of gestures (raw `Listener`),
  lift overlay, edge-exact outline, springs.
- `lib/screens/home/home_menu.dart` (new) — the anchored tile menu.
- `lib/screens/home/home_spec.dart` — `HomeFontOption`, `HomePickKind.folder`,
  `HomePickKind.timezone`.
- `lib/screens/home/home_sheets.dart` — render the new option types; add
  widget sheet lists new kinds.
- `lib/screens/home/widgets/chat_card_tile.dart` — the new chat card.
- `lib/screens/home/widgets/{clock,note,character_folder,app_folder}_widget.dart`
  (new), `studio_widget.dart` (rework).
- `lib/screens/home/note_editor_screen.dart` (new), `lib/models/home_note.dart`
  (new), `Storage.load/saveHomeNotes`, `AppState.homeNotes` API.
- `lib/screens/home/clock_ticker.dart` (new); `pubspec.yaml` (+timezone).
- Tests: extend `test/home_layout_test.dart`, `home_widgets_test.dart`,
  `home_widget_sizes_test.dart` (matrix includes new kinds), `home_screen_test`
  (menu, drag-to-merge, cross-page move with two pointers), new
  `home_notes_test.dart`, `clock_widget_test.dart`.
- `CLAUDE.md` Home section updated.

## 9. Order of work

1. Plan file (this) → commit.
2. Perf: selects, RepaintBoundaries, implicit scrolling, keep-alive, spring.
3. Grid gesture rewrite + anchored menu + edge-exact outline + springs.
4. Cross-page move (second finger + edge hover).
5. Chat card redesign + options (+ HomeFontOption).
6. Notes (model, store, editor, widget).
7. Clock (+ timezone).
8. Studio v2.
9. Folders (character folder widget, app folders + merge).
10. Size matrix + tests for everything; screenshots for a visual check
    (throwaway script under test/screenshots/, not committed).
11. Full suite, CLAUDE.md, commit, push `beta`.

## Progress log

- Shared pieces landed: `HomeTileStatus` / `HomeOutlined` / `homeOutlineSide`
  (the selection ring drawn by each widget's own surface, edge to edge),
  `homeWatch` (value-signature selects instead of watching all of AppState),
  `HomeFontOption`, `HomeDependentOption`, `HomePickOption(multiple:)`,
  `HomePickKind.folder|note|timezone`, `HomeNote` + `homeNotes` store,
  `ClockTicker`/`ClockListener`/`HomeTimeZones` (timezone 0.11.2, 10-year db,
  ~35 ms on first use), `HomeLayout.moveTo` / `mergeIntoFolder` /
  `folderTargets`.
- Grid rewrite: `home_grid.dart` (`HomeTileFrame` with a 380 ms lift
  recognizer that survives the switch into edit mode, keep-alive pages,
  RepaintBoundary per page and per tile, `HomePagePhysics` critically damped
  spring), `home_menu.dart` (anchored tile menu), `home_screen.dart` (carry
  overlay above the PageView, second-finger page swipe via raw `Listener`,
  edge hover, merge into folder on drop, `TickerMode` per page, Back closes the
  menu first).
- Widgets landed: chat card (`chat_card_tile.dart`), clock, note + editor,
  character folder, app folder, Studio v2. Menu is a 3-column icon grid;
  a 4x1 clock with zones shows them as chips beside the local time.
- Not verifiable here: gesture feel and frame times on a Snapdragon 695.
