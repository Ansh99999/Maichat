# Floating-image lag — diagnosis & fix (SOLVED)

The floating-picture manipulation lag (drag / pinch / resize / rotate / place)
**and** the chat scroll stutter were fixed and **confirmed smooth on a real
device** (iQOO/vivo PD2251KF, ~90–120Hz, Impeller engine) on 2026-08-21.

**Known-smooth baseline: commit `4543a31`.** If lag ever returns, `git log` the
files below and compare against that commit.

## The insight that mattered

The lag was **not** the picture, and **not** the rendering technology. A native
Android overlay was tried in an earlier attempt and *also* stuttered. The real
cost was **redrawing the whole chat every frame** — which is why:

- scrolling the chat lagged the same as pinching a picture over it, and
- it lagged *at any picture size* (a small picture is nearly free to transform).

So the fix was to make the **chat cheap to redraw per frame**. Do that and
pinch, rotate, resize, and scroll all improve together. Chasing the float
renderer (game engine, WebView, native overlay) is a dead end — all were tried
or rejected for cost.

## What actually fixed it (all on `main`)

1. **`4543a31` — chat background fades via `Image(opacity:)`, not an `Opacity`
   widget.** `_ChatBackground` in `lib/screens/chat_screen.dart`. The `Opacity`
   widget forces a full-screen offscreen save-layer; `Image.opacity` is a
   paint-level alpha with no save-layer. This is the build the user installed and
   confirmed smooth.
2. **`0f92124` — floating pictures are in-memory only, never written to disk.**
   `floatingImages` is removed from `Conversation.toJson`; `settleFloatingImage`
   only mutates in-memory geometry (no save, no debounce timer); add/remove go
   through `_mutateFloats` (notify, no save). This removed the whole-store JSON
   re-save that fired on every "place" and scaled with history size. Floats
   vanish only on full app close; they still survive navigation and are copied on
   a fork.
3. **`63d1fa3` — HTML message rendering is spread across frames.** `MessageHtml`
   in `lib/widgets/message_html.dart` caps expensive `flutter_html` builds per
   frame (`_HtmlFrameBudget`, reset on a persistent frame callback → no idle
   cost) and defers the rest to later frames. A single streaming message never
   hits the cap, so replies don't flash. This fixed the ~600ms chat-open freeze.
4. **`ca8bf13` — jank logger threshold calibrated to the real refresh rate.**
   It was a fixed 16ms (60Hz) budget, which hid every 11–16ms dropped frame on
   this 90Hz+ phone — the reason a laggy drag looked "clean" in early logs.
5. **`89b676e` — rounded corners kept during manipulation.** The bare
   (manipulation) picture wraps its image in a `ClipRRect` (clip only, no shadow,
   no ✕). On Impeller a rounded clip is a stencil op, not a save-layer, so it
   does not restore the per-frame cost the bare path exists to avoid.

## Diagnosis tooling (temporary — delete when done)

`lib/services/jank_logger.dart` + Settings → Appearance → "Record jank logs":
records over-budget frames + a breadcrumb trail (streaming / float drag / chat
open) to a downloadable log. On-device logs pinned the cost to the UI-thread
Build phase and the chat — not the GPU or the float. `MessageBubble` and
`MessageHtml` carry small build/parse counters that feed it. Remove all of this
once the perf work is truly finished.

## Do NOT regress

- Do not re-add float **disk persistence** (`floatingImages` in
  `Conversation.toJson`, or a save in `settleFloatingImage`).
- Do not put an **`Opacity` widget** back on the chat background — use
  `Image.opacity`.
- Do not remove the **per-frame HTML budget** in `MessageHtml`.
- Do not "fix" this by switching the float layer to a **game engine, WebView, or
  native overlay** — all rejected (continuous resource cost, or already stuttered
  in a past attempt).
