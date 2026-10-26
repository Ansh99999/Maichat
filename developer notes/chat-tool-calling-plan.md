# Chat tool calling — implementation plan, points 1–5

Authorized 2026-10-26. Owner: design, difficult implementation, integration and
verification. Bounded coding work goes to GLM 5.3 with high reasoning through
the verified `log/glm-5.3` → `https://logfare.ai/v1` route. No AI authorship or
co-author attribution in commits. The initial implementation request did not
include publication; the follow-up request "push it for an apk" authorizes
committing and pushing to official `beta` and monitoring APK publication.

Official branch heads were fetched on 2026-10-26. Both `origin/beta` and
`origin/studio-presets` point to the newest official commit `1f46ea9`; the
other remote branches are older. Work in `/home/ubuntu/Maichat-studio-presets`.
Preserve existing research and edits in all worktrees.

## 1. Reuse harness transport without changing chat generation settings

- [x] Keep ordinary chat's selected provider, model, preset, character, prompt
  assembly, usage budgets and stream-paint cadence.
- [x] Reuse AgentClient's four dialect adapters; add an explicit successful
  completion contract so EOF, truncation and Stop cannot execute partial calls.
- [x] Carry normal generation parameters into tool requests, with dialect-aware
  filtering; preserve provider-required call metadata.
- [x] Verify actual loopback requests, streaming and whole responses.

## 2. Chat-owned execution and history

- [x] Add optional persisted run history to each message variant, retaining old
  records and selected-swipe behavior.
- [x] Run enabled tools sequentially inside one bounded/cancellable logical run;
  record errors as results and aggregate usage across requests.
- [x] Keep complete call/result exchanges together in history and context
  budgeting, and keep structured values out of prose regex/macro processing.
- [x] Record results before follow-ups; loading history never invokes a handler.
- [x] Show compact readable actions/results with inspectable details.

## 3. Tool library and Settings → Tool calls

- [x] Persist global defaults and per-chat overrides through one resolver.
- [x] Ship dice/random and tracker operations; gate image and management tools
  by actual configuration and calling context.
- [x] Provide create/edit/test/duplicate/delete, enablement and import/export.
- [x] Custom tools contain schema plus executable action source. Initial runtime:
  a portable JSON recipe language supporting references, operation calls,
  variables, arithmetic, conditions and returns with bounded execution. This
  avoids pretending a schema is an implementation; the editor labels the language.
- [x] Use the current Material 3 Expressive theme, accessible controls and
  explicit app-wide/this-chat scope. Test meaningful settings/editor flows.

## 4. Tracker and image ownership across history changes

- [x] Define typed tracker records with subject, label, unit, bounds and value;
  expose define/read/update, including set and numeric delta.
- [x] Journal before/after effects against reply variants; project selected
  history rather than rerunning actions on load/swipe/fork.
- [x] Detect stale dependent effects after an earlier alternative changes;
  keep transcript text and surface that regeneration is required.
- [x] Place stat results below replies or in a pinned chat panel, as configured.
- [x] Reuse Image Studio requests/gallery storage and attach generated file refs
  to the producing variant. Preserve files for inactive swipes, export and backup.
- [x] Stop covers pending actions; interrupted remote-image outcomes are not
  automatically retried.

## 5. Tool-capable `/btw`

- [x] Retain aside analysis outside the roleplay transcript with independent
  cancellation and the chat's own selected model/context.
- [x] Support tracker operations, tool-library inspection and tool authoring.
  A generated tool uses the same validated executable definition as settings;
  global/chat scope is explicit.
- [x] Add OOC correction operation with text, depth N and lifetime. N counts RP
  messages; expiry happens after a completed logical character reply, not a tool
  round. Preserve the existing response hint and one-leading-system wire rule.
- [x] Coordinate writes with an active main reply; preserve source context for
  forks and stale-effect detection.

Dynamic agentic lore policy, autonomous lore/summary editing, and delayed N
replies are later work. They are outside these five points.

## Acceptance and verification

Demonstrate tool-only and mixed responses, saved dice results, state after
swipe/regeneration/fork/delete/restart, custom recipe import/export and test,
scoped `/btw` authoring/OOC correction, and variant-owned generated images.
Cover malformed/disabled/unknown tools, incomplete responses, limits, Stop,
actual outgoing requests and persistence. Re-run Studio tests for shared-client
regressions. Finish with `flutter pub get`, clean `flutter analyze`, green full
`flutter test`, and a Linux/xvfb smoke check where supported. Report device and
live-endpoint limits explicitly. Monitor any started build to completion.


## Delivered implementation

The implementation was completed on `studio-presets`, based on the
verified official `1f46ea9` tip. The five points above are implemented. Final verification completed on
2026-10-26: clean analyzer, green full suite, generated UI previews and a
Linux release startup smoke check. The first full run passed the existing tests and exposed an
in-progress Stop-test/cleanup mismatch, subsequently corrected and checked in
focused tests. Do not cite that first run as a green full-suite result.

- `lib/models/chat_tool.dart`: portable definitions/configuration, per-variant
  run records, effects and pure state projection. `message.dart` and
  `conversation.dart` persist records, controls and per-chat overrides. A
  transient prompt-protection marker never enters saved chat data.
- `lib/services/chat_tools/`: shipped schemas, strict argument/schema and recipe
  validation, executable Recipe JSON, bounded arithmetic/control flow, and the
  dice service shared with existing roll macros.
- `lib/state/chat_tools_state.dart`: ordinary-chat orchestration, scoped tool
  operations, usage/budget/cancellation, complete-exchange context trimming,
  persisted results, tracker projection and `/btw` management. Runs carry a
  history anchor, endpoint/model provenance and local effect preconditions.
- `AgentClient` reuses normal chat sampling fields while retaining dialect
  call/result shapes and required opaque output blocks. Successful completion
  is required for tool-enabled chat; EOF/truncation do not execute actions or
  consume a next-reply correction. Tool-enabled rounds use one candidate.
- Settings → Tool calls is the global library; Chat settings → Tool calls is a
  full per-chat override with Follow app defaults. Built-ins can be inspected,
  tested and duplicated; custom recipes can be edited, deleted and exchanged as
  versioned MaiChat JSON files. Built-in implementation code is not exported as
  portable user code. ST slash-command closures are not imported as executable
  recipes.
- `/btw` analysis remains ephemeral and outside RP. Requested tracker/control
  changes and saved tool definitions persist. While a main reply is running,
  aside queries have read-only capabilities. Global/chat tool creation is
  explicit; the default requested authoring scope is this chat.
- Corrections have a depth and next-reply/persistent lifetime. Preset injections
  reserve context budget separately from the existing response hint. Timed-out
  or stopped work keeps a cancellation flag even after the run ends.
- Generated images use Image Studio configuration and gallery storage, with
  file refs on the producing variant. All alternatives are included in picture
  retention; image requests have separate transport ownership from Image Studio.
- Redacted actual request snapshots for the last eight runs are retained in
  memory for View prompt, including each round. After reopening, the inspector
  reconstructs requests from saved structured records; it does not recover old
  in-memory snapshots or invoke handlers.
- Tool calling starts disabled. The shipped catalog is visible before enabling;
  actual model/endpoint support is still required. Numeric tracker IDs are
  unique within a chat; subject/label/unit/bounds are configurable.

Generated previews use synthetic data and the actual screens/theme:
[settings](../docs/previews/chat-tool-calls.png) and
[chat results](../docs/previews/chat-tool-results.png).
Regenerate explicitly with:

```text
flutter test --no-pub test/screenshots/chat_tools_preview.dart --update-goldens
```
No screenshot generator runs in the default test suite.

Delegation: GLM 5.3/high through the verified Logfare route implemented the
portable models/runtime/definitions and the settings/results widgets in disjoint
write scopes. The owner integrated and revised them, implemented protocol/state
and generation behavior, added actual-wire/history/persistence checks, fixed
projection/cancellation/context issues and reviewed rendered previews. The UI
worker was stopped after implementation during redundant post-implementation
inspection; its files were reviewed and tested by the owner. Worker prompts,
JSONL execution logs and the runtime report are in
`/tmp/maichat-chat-tools-implementation/`. No alternate GLM provider was used.

Current completed checks: dependency resolution succeeded; analyzer clean;
103 focused tests passed; two generated screen previews passed and were viewed.
The final full suite and Linux smoke results are recorded below.
No Android/device or live chat/image provider verification is claimed.


Practical behavior notes: per-chat settings are full overrides, matching other
MaiChat settings. Recipes execute the enabled operations available in their
calling context; keep a recipe's dependencies enabled. The initial trackers are
numeric; separate subjects should have distinct IDs (for example `aria_health`
and `bandit_health`). These are implementation choices, not claims of a general
JavaScript runtime or a third-party extension API.


## Final verification — 2026-10-26

- `flutter pub get`: succeeded; no dependency declarations/lockfile changes.
- `flutter analyze --no-pub`: **No issues found**.
- Focused wire/runtime/settings checks: **103 passed**.
- `flutter test --no-pub -j 2 --reporter expanded`: **3,568 passed**, terminal
  exit 0; final run completed in 8 minutes 28 seconds. No application source
  changes were made during this final run.
- Explicit generated-preview run: **2 passed**; both previews were visually
  inspected. Narrow slider labels were corrected and checked at 320/600 logical
  pixels with text scales 1.0/1.5.
- `flutter build linux --release --no-pub`: succeeded, terminal exit 0. Binary:
  `build/linux/arm64/release/bundle/maichat`.
- Linux release launched under `xvfb-run` with software rendering and isolated
  XDG data/config/cache directories. It stayed alive for 12 seconds, then its
  process group was intentionally stopped. This is a startup smoke check;
  rendered feature screens were inspected through generated widget previews.
- `git diff --check`: clean. No version bump, dependency/native-platform change,
  commit, push, or release was part of this verification pass. No AI authorship
  attribution was added.

Verification logs are under `/tmp/maichat-chat-tools-implementation/`:
`pub-get.log`, `verified-analyze.log`, `verified-targeted.log`,
`full-tests-final.log`, `previews.log`, `linux-build.log`, and `linux-smoke.log`.
The smoke command's terminal report records the deliberate timed shutdown; the
release process itself emitted no startup errors.

Still unverified: Android/device touch and keyboard behavior, on-device
performance, and actual chat/image provider endpoints. The tested protocol
compatibility is loopback-fixture coverage across four dialects, not a claim
that every compatible host accepts every model/schema combination. APK building
and publication follow in the authorized official-beta GitHub Actions workflow.
