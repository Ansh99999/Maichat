# Chat tool calling — SillyTavern research and MaiChat integration

Research date: 2026-10-26. This is source research and a proposed sequence,
not a feature implementation.

## Baseline and provenance

The user's latest instruction is to use the latest MaiChat code, superseding
the earlier beta/studio-preset branch preference.

- Official origin configured here: `https://github.com/Ansh99999/Maichat.git`.
- Newest locally available branch-tip commit:
  `1f46ea9cea38f6c0d6eb1ae53280ff99a61639fc`, dated 2026-10-21,
  `Add generation presets to Character Studio`.
- Local `studio-presets`, `chat-tools-beta`, and cached `origin/beta` all point
  to that commit. `main`/`origin/main` point to older `e98185e`.
- Research destination: `/home/ubuntu/Maichat-studio-presets`, local branch
  `studio-presets`. Its application/test/dependency source matches the cached
  `origin/beta`. Existing edits in the other two worktrees were preserved.
- **Live GitHub freshness is unverified.** `git ls-remote` failed to resolve
  `github.com`; the GitHub connector also failed its transport request. Cached
  `origin/beta` was last fetched on 2026-10-25. This report does not establish
  that `studio-presets` is an official remote branch or that no newer upstream
  commit exists. Fetch and compare official branch tips before implementation.
- SillyTavern source, abbreviated `ST/` below:
  `/home/ubuntu/.npm/_npx/7eac5c8c7035008a/node_modules/sillytavern/`.
  Its installed `package.json` reports **1.19.0**; this is an installed package,
  not an independently verified upstream Git revision. Runtime user data and
  credentials were not needed.
- Two fresh **DeepSeek v4.1 Flash / high** agents completed read-only
  scouting: core protocol/lifecycle (`01a17669-9a6c-72f1-a2ca-d1ae4d5eabfb`)
  and bundled capabilities/custom tools (`01a17669-9a8e-7dc1-821e-5ed1bd47fb94`).
  The owner reviewed important claims directly and owns the design. Optional
  GLM was omitted because the available route did not establish the required
  Logfare provenance.

Installed-source SHA-256 fingerprints:

| ST file | SHA-256 |
| --- | --- |
| `public/scripts/tool-calling.js` | `934be74f6bd672a821e5f3e5dc34ad4548c1cac60ee41c48feaa630e6e2f7712` |
| `public/script.js` | `955c603d0bad84bac5a716f0818d85c2543e44d4c43878e0d63ef1e55ca91855` |
| `public/scripts/openai.js` | `0b77c30282825540265d5a09e681e5ccacf6760b05111ec880ffe237a9250604` |
| `src/prompt-converters.js` | `eadc6ccd7961273c887c0986c2ed1ffe61e2e7da03f83afeb8ba4dc5a5041a13` |

## How SillyTavern integrates tools into a chat

The model requests an operation; the application executes it. For example, a
model requests a dice roll, receives the application's recorded result, then
writes the character's reaction in a subsequent request.

```text
chat prompt + eligible tool schemas
  -> assistant text and/or complete function calls
  -> application handlers
  -> saved call/result records
  -> next model request containing those records
  -> final reply or another bounded tool round
```

| Stage | Observed implementation | ST source |
| --- | --- | --- |
| Definition | Name, display name, description, JSON parameter schema, action, formatter, eligibility callback, and stealth flag. A shared in-memory registry replaces same-name definitions. | `public/scripts/tool-calling.js:150`, `:247`, `:269` |
| Advertisement | Evaluate `shouldRegister()` for each request; advertise eligible definitions as OpenAI-shaped `tools` with `tool_choice: auto`. Tool schemas consume reserved prompt budget. | `public/scripts/tool-calling.js:400`; `public/scripts/openai.js:1309` |
| Gating | Function-calling switch, provider/model support and compatible post-processing are required. `openai` here names the chat-completions frontend, which also routes Claude/Gemini. Quiet, continue and impersonate modes exclude calls; multi-swipe generation skips registration. | `public/scripts/tool-calling.js:614`, `:694`; `public/scripts/openai.js:2840` |
| Collection | Separate text and structured calls; accumulate streamed fragments, including Anthropic partial JSON and Gemini signatures. Whole responses have a corresponding extraction path. | `public/scripts/tool-calling.js:427`, `:707`; `public/scripts/openai.js:3164` |
| Execution | Sequential calls; parse arguments, look up handler, execute, encode the result. Unknown names, invalid JSON and handler failures become error results for ordinary tools. | `public/scripts/tool-calling.js:325`, `:786` |
| Persistence/UI | Save a small expandable display message with `extra.tool_invocations`, call IDs, arguments, results, errors and provider/model metadata. Its display-system status is not a protocol system instruction. | `public/scripts/tool-calling.js:899` |
| History | Rebuild assistant calls plus matching tool results. Keep a complete call/result group together when budgeting history. Filter model-specific signatures/reasoning by provenance. | `public/scripts/openai.js:621`, `:996`, `:3575` |
| Follow-up | Save invocations, then recursively call generation with incremented depth. Default recursion limit is five. Both streaming and whole-response paths support this loop. | `public/scripts/tool-calling.js:255`; `public/script.js:5408`, `:5541` |

ST translates its common frontend shape on the server. Claude gets
`input_schema`, `tool_use` and `tool_result`; Gemini gets function declarations,
`functionCall` and `functionResponse`. See
`src/endpoints/backends/chat-completions.js:289`, `:571` and
`src/prompt-converters.js:235`, `:541`. MaiChat calls hosts directly and must
retain its own dialect adapters.

Three policies should be improved when adapting this pattern:

1. Parsing JSON does not validate arguments against the advertised schema.
   Validate definitions and arguments before invoking application operations.
2. Stream EOF is not sufficient evidence of successful model completion.
   ST's stream ends on EOF or `[DONE]` (`public/scripts/openai.js:3169`), and
   invocation uses `isFinished`/`isStopped` (`public/script.js:5408`). Require
   appropriate provider completion status and reject interrupted/truncated calls.
3. Visibility and continuation need separate settings. ST stealth calls are
   unsaved and stop the follow-up; a mixed stealth/ordinary batch can return
   before saving ordinary results (`public/scripts/tool-calling.js:836`,
   `public/script.js:5421`). A hidden stat update may still need a follow-up.
   Keep a durable execution record regardless of how prominently it is shown.

ST's central handler API has no cancellation context/deadline. Stop aborts model
requests, but does not inherently interrupt an already running action
(`public/scripts/tool-calling.js:325`, `public/script.js:5607`). A MaiChat run
needs cancellation across model requests, actions and pending follow-ups.

## Actual tools versus macros, commands and extension hooks

The native registry is a general mechanism. Most requested RP features are
separate command/macro APIs in the bundled ST source, rather than preinstalled
model-callable tools. They can be composed into tools.

A search of bundled `registerFunctionTool` uses found **one concrete
app-executed function definition: `GenerateImage`**, alongside the general
script-registration API. This is the ToolManager inventory, not an assertion
that ST lacks provider-managed tools.

| Requested feature | What the installed source supplies | Application to MaiChat |
| --- | --- | --- |
| Automatic images | Bundled Stable Diffusion extension registers `GenerateImage`, requiring a prompt and calling image generation; gated by its function-tool setting. This registration is not stealth. | Reuse MaiChat Image Studio generation/storage and attach results to the producing assistant variant. |
| Health, energy, arousal %, custom trackers | Chat/global variables, arithmetic commands and macros; no bundled typed RPG-stat suite was identified. | Typed tracker definitions and update operations, plus user-chosen presentation below replies or in a pinned panel. |
| Dice/random values | `roll`, `random` and stable `pick` macros. These are not native function-tool registrations. | A shared RNG service used by macros, manual commands and model tools; persist the actual draw once. |
| `/btw` analysis | No bundled `/btw` command identified. Quiet generation and `/gen` are useful primitives. `/ask` is a visible character interaction. | Extend MaiChat's existing aside path with an independent tool-capable side conversation. |
| OOC at depth N | `/inject` stores a prompt injection with position, depth, role, filter and ephemeral options. | A tool accepting correction text, depth and lifetime; preserve MaiChat's single-leading-system rule. |
| Lorebook changes | Entry search/read/create/update commands and world-info activation machinery. | Wrap MaiChat's scoped lorebook services in narrow revision-checked operations. |
| Summary changes | Memory extension, `/summarize`, summary macro, automatic hooks and prompt injection. | Read/update MaiChat memory through shared services; coordinate with automatic summarization. |
| Dynamic lore agent | Editing/activation primitives, not a complete implementation of the requested future policy. | Design around existing world-info activation; settle autonomous update triggers/canon rules later. |
| Delayed additional replies | `/delay` waits in a script; group auto mode periodically generates replies. | A separate per-chat response scheduler with speaker, count, delay and cancellation; tool recursion alone does not implement this. |

Feature source anchors in ST:

- Images: `public/scripts/extensions/stable-diffusion/index.js:5452`, `:5493`.
- Variables: `public/scripts/variables.js:48`, `:105`, `:934`;
  `public/scripts/macros/definitions/variable-macros.js:11`.
- RNG: `public/scripts/macros/definitions/core-macros.js:303`, `:340`, `:363`.
  The legacy equivalents also exist in `public/scripts/macros.js`; this audit
  does not establish which macro-engine setting a running ST user selected.
- Quiet/OOC: `public/scripts/slash-commands.js:2211`, `:2893`, `:3780`, `:4688`.
- Lore: `public/scripts/world-info.js:1741`, `:1781`, `:1824`, `:1860`.
- Memory: `public/scripts/extensions/memory/index.js:953`, `:1079`, `:1085`.
- Timing: `public/scripts/slash-commands.js:2478`, `:4279`;
  `public/scripts/group-chats.js:144`, `:1398`.

This inventory covers the inspected bundled package, not third-party tools
installed into an ST runtime or every possible user script.

Provider-managed search is a separate path: ST adds Anthropic `web_search`
(`src/endpoints/backends/chat-completions.js:323`), Gemini `google_search`
(`:596`), and the OpenRouter `web` plugin (`:198`) when enabled and eligible.
The inspected Gemini path suppresses search when function declarations are
present; capabilities cannot be assumed freely composable. Some structured-JSON
requests also use a forced schema tool in the Claude adapter (`:303`). These
are provider/formatting features, not local handlers to place in ToolManager.
If exposed in MaiChat later, keep their eligibility and wire handling distinct
from user-authored application operations.

## User-created tools and the settings experience

ST exposes `registerFunctionTool`/`unregisterFunctionTool` through its extension
context (`public/scripts/st-context.js:183`) and provides these commands in
`public/scripts/tool-calling.js`:

| Command | Source | Purpose |
| --- | --- | --- |
| `/tools-list` | `:942` | List registered function schemas. |
| `/tools-invoke` | `:966` | Manually invoke a named tool with JSON arguments. |
| `/tools-register` | `:1001` | Register schema, description and an executable ST slash-command closure. |
| `/tools-unregister` | `:1152` | Remove a definition from the active registry. |

The registry itself is in memory. Extensions register during initialization,
and users can rerun registration scripts saved through other ST facilities.
The inspected tool subsystem has no persistent custom-definition library or
complete tool import/export API. Its settings expose an enable switch and
recursion limit (`public/index.html:2004`, `:2017`), plus interleaved-thinking
options for selected sources; it does not provide the requested tool catalog
and editor. Recursion is enforced in `public/script.js:4495`.

The important distinction is **schema plus executable action**: a name and
parameter editor alone cannot implement a user-created tool. ST supplies its
slash-command runtime. That runtime and JavaScript extension functions cannot
be imported as executable Dart code.

MaiChat should provide Settings → Tool calls as the main library, listing
shipped tools by default, with create/edit/test/duplicate/enable/import/export
actions and explicit global versus this-chat scope. Use the existing Material 3
Expressive theme (`lib/main.dart:148`, `:220`) and the settings hub pattern
(`lib/screens/settings_screen.dart:31`). Keep schemas/action code in the tool
editor and inspector; show ordinary action names/results in the chat.

Provide one persisted tool-definition format and one registry shared by settings,
the composer and `/btw`. Include schema, executable action/recipe, version,
scope, availability condition, progress/result presentation and follow-up policy.
Import/export must preserve the executable definition and name conflicts must
be resolved explicitly. Do not claim lossless ST tool import: an exported
schema omits the closure/runtime it requires.

For `/btw` authoring, the assistant should draft/refine/test a tool through this
same service, then save it in the user-selected chat/global scope. The runtime
choice needs an Android feasibility spike: reusable native operations plus a
user-code/recipe layer with bounded execution and explicit operation access.
The inspected MaiChat code has built-in Dart handlers, not a saved user-action
interpreter. Runtime selection remains a design decision, not delivered code.

## What MaiChat already has at the named commit

Paths below refer to `/home/ubuntu/Maichat-studio-presets`.

| Existing code | Reusable part | Integration work |
| --- | --- | --- |
| `lib/models/agent_message.dart:22`, `:45`, `:128` | `ToolSpec`, `ToolCall`, agent call/results, JSON persistence, Gemini signatures. | Chat variants still need their own durable run/call/result records and stable identity. |
| `lib/services/agent_client.dart:137`, `:197` | Structured tools for Chat Completions, Responses, Anthropic and Gemini. | Extract/adapt shared transport while preserving chat model/preset settings and explicit completion state. |
| `lib/services/studio/agent_runner.dart:246` | Model/action loop, error results, cancellation and bounded steps. | Runner is Studio-context-specific and uses `Future.wait` at `:333`; define ordering for chat state writes. |
| `lib/services/studio/studio_tools.dart:204`, `:1530` | Native handlers, argument helpers and a registry; lore/image/workbench services. | Handlers mutate Studio drafts; reuse operations through chat-owned contexts rather than redirecting chat into Studio. |
| `lib/screens/chat_screen.dart:358`; `lib/state/app_state.dart:5373`; `lib/services/btw.dart` | `/btw` parsing, a separate aside request, cancellation and sheet UI. | Existing aside is temporary, text-only, and keeps no side transcript. Tool management/OOC changes need new behavior. Installed-device availability was not checked. |
| `lib/state/app_state.dart:5992`, `:6122` | Real roleplay assembly, selected provider/preset, stream painting and accounting. | Currently calls text-oriented `ChatClient`; empty text is an error even when a future tool-only turn could be legitimate. |
| `lib/services/macro_engine.dart:681`, `:746`, `:956` | Local/global variables, dice/random/pick. | Freeze intended macro resolution within a logical run; follow-ups/inspectors must not accidentally reroll or repeat variable writes. |
| `lib/state/app_state.dart:2662`, `:3932`, `:4231` | Resolved lorebook overrides, summaries and generated-image storage. | Scoped/revisioned writes, summary conflict handling and variant-associated image attachments. `postImageToChat` at `:7359` currently inserts a user turn. |

Two transport gaps are source findings rather than reproduced failures:
`AgentClient.stream` flushes pending calls at stream exit (`:181`), and its
Responses reader treats `response.incomplete` and `response.completed` alike
for stopping (`:900`). Test interruption/truncation before enabling state writes.
`AgentParams` (`:16`) also lacks many chat `GenParams` settings; simply routing
roleplay through Studio's request builder would change the selected chat's
generation behavior (`lib/state/app_state.dart:5698`).

## Proposed implementation sequence

1. **Shared protocol and chat integration.** Reuse/extract agent transport;
   keep ordinary chat's provider/preset/prompt assembly. Add a bounded logical
   run, per-round inspection/usage, complete-call validation, tool-result history
   and cancellation. Keep call/result exchanges intact under context budgeting,
   including schemas and results. Preserve required provider signatures and
   support a readable historical projection when provider changes prevent replay.
   Structured calls/results must bypass prose regex/macro transformations.
2. **Tool library and a complete first example.** Deliver the registry, Settings
   → Tool calls, global/chat resolution, execution/result UI and a working dice
   tool. Prove user-action runtime feasibility early so custom tools, import/export
   and `/btw` authoring are part of the architecture from the start.
3. **Trackers and history effects.** Add typed define/read/update operations and
   configurable stat bubbles/panel. Effects belong to the selected reply variant.
   Swipes/regeneration/forks/deletions must restore the correct state; loading
   history must never execute handlers or reroll. Record before/after values and
   revisions; flag downstream effects whose assumptions became stale.
4. **Tool-capable `/btw` and OOC.** Keep analysis separate from roleplay. Let tools
   create corrections with text, depth N and lifetime, modify trackers and author
   tool definitions. Count N in RP messages rather than tool/aside records. Apply
   the existing one-leading-system policy in preset and no-preset paths, and keep
   the user's response hint separate. Coordinate side/main state changes.
5. **Automatic images and memory editing.** Reuse Image Studio and file refs;
   associate generated pictures with the producing variant and retain them in
   sweeps/backups/export. Add scoped lore/summary read-and-patch tools with
   revisions and readable change history. Prevent stale background summaries
   from overwriting newer edits. Persist execution status and avoid automatic
   retries of remote operations whose outcome is unknown after interruption.
6. **Later behavior specifications.** Build dynamic lore policy and delayed N
   replies on those services. A scheduler owns delays, speaker and origin
   revision, revalidates on new input/edit/swipe/fork, and supports Stop. Start
   with explicit foreground semantics; Dart timers do not promise suspended-app
   delivery. Generate-now/show-later versus later fresh requests remains open.

A useful first demonstration is: the model requests a roll, MaiChat records the
draw, the model reacts, the user sees the result beneath the reply, and reopening
or changing a swipe does not run the operation again. This is a validation slice
of the general tool system, not the complete requested feature scope.

## Verification performed in this pass

Executed in the `studio-presets` worktree at the named commit:

```text
git diff --exit-code origin/beta -- lib test pubspec.yaml pubspec.lock
flutter test --no-pub --reporter expanded \
  test/agent_client_test.dart test/btw_test.dart
```

The source comparison succeeded and **43 tests passed**. These existing tests
exercise actual loopback tool-wire requests across four dialects and existing
aside request/state behavior, including cancellation and isolation while a main
reply streams. They establish a reusable baseline, not the proposed feature.
Test log: `/tmp/maichat-chat-tools-scout-2026-10-26-tests.log`.

No feature source was changed. The full suite, analyzer, app smoke run,
Android build/device interactions, and live model/image endpoints were not run;
no new UI was implemented. Live upstream verification was unavailable as
described above. Future implementation must
pass the project's analyzer/full-suite requirements and actual outgoing-request
checks, with device verification reported separately. No commit/push, release or
AI authorship/co-author attribution was added.
