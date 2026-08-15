import '../models/character.dart';
import '../models/message.dart';
import '../models/preset.dart';
import '../models/prompt_block.dart';
import 'macro_context.dart';
import 'token_estimator.dart';
import 'world_info.dart';

/// The result of assembling a preset into a request: the role-tagged messages
/// ready for [ChatClient] (which splits out `system` for Anthropic itself), a
/// rough token estimate, and a per-section breakdown (Main / Description /
/// History / …) for the message "Info" view.
class BuiltPrompt {
  BuiltPrompt(this.messages, this.estimatedTokens, this.sections);
  final List<ChatMessage> messages;
  final int estimatedTokens;
  final List<PromptSection> sections;
}

/// One labeled slice of the assembled prompt, for the context-window breakdown.
class PromptSection {
  const PromptSection({
    required this.label,
    required this.role,
    required this.tokens,
    required this.messageCount,
  });

  final String label;
  final String role;
  final int tokens;
  final int messageCount;
}

/// Turns a [Preset] (prompt blocks + order) plus a character and chat history
/// into the final message list, following SillyTavern's assembly model:
/// ordered blocks with markers filled from live data, macros resolved, and chat
/// history greedily fitted into the remaining context budget (newest-first).
class PromptBuilder {
  PromptBuilder({required this.macros, TokenEstimator? tokens})
      : tokens = tokens ?? const HeuristicTokenEstimator();

  final MacroEngine macros;
  final TokenEstimator tokens;

  /// Per-message framing overhead (role tags etc.), matching the small constant
  /// SillyTavern reserves per message.
  static const int _perMessageOverhead = 4;

  /// The share of the prompt budget chat history is guaranteed, however large
  /// the fixed blocks are. Without a floor, a heavy preset frame plus a big
  /// character sheet silently reduces the conversation to nothing.
  static const double _historyFloorFraction = 0.25;

  BuiltPrompt build({
    required Preset preset,
    Character? character,
    required List<ChatMessage> history,
    String userName = 'User',
    String persona = '',
    String model = '',
    MacroVariables? variables,
    String input = '',
    int? maxContext,
    WorldInfo? lore,
  }) {
    final charName = character?.displayName ?? '';
    // The caller may resolve a different window than the preset carries (the
    // "use the model's own limit" case); the preset's value is the fallback.
    final contextWindow = maxContext ?? preset.maxContext;
    final budget = (contextWindow - preset.maxResponseTokens)
        .clamp(0, 1 << 30)
        .toInt();

    // Chat history carries {{char}}/{{user}} (a greeting, a pasted line, …) that
    // must reflect the *current* identity — the impersonated name when the user
    // is speaking as a character. SillyTavern (substituteParams per message) and
    // Agnai (prompt.ts placeholderReplace) both resolve these on every message at
    // build time. We resolve only the identity macros here — never the full,
    // stateful engine — so {{setvar}}/{{roll}} in old turns are not re-run each
    // generation. Marker/block content still goes through the full engine below.
    final resolvedHistory = [
      for (final m in history)
        m.content.contains('{') || m.content.contains('<')
            ? m.copyWith(
                content: Character.resolveMacros(
                  m.content,
                  charName: charName,
                  userName: userName,
                ),
              )
            : m,
    ];

    final ctx = MacroContext(
      userName: userName,
      charName: charName,
      character: character,
      messages: resolvedHistory,
      model: model.isEmpty ? preset.model : model,
      maxContext: contextWindow,
      maxResponse: preset.maxResponseTokens,
      maxPrompt: budget,
      input: input,
      variables: variables ?? MacroVariables(),
    );

    // Resolve the content each marker stands in for (macros applied later).
    final world = lore ?? WorldInfo.none;
    String markerSource(String id) {
      switch (id) {
        case PromptId.charDescription:
          return character?.description ?? '';
        case PromptId.charPersonality:
          return character?.personality ?? '';
        case PromptId.scenario:
          return character?.scenario ?? '';
        case PromptId.dialogueExamples:
          // Lore can ask to sit around the examples rather than around the
          // definitions, so it rides along with this marker.
          return [
            world.exampleTop,
            character?.mesExample ?? '',
            world.exampleBottom,
          ].where((s) => s.trim().isNotEmpty).join('\n');
        case PromptId.personaDescription:
          return persona; // the impersonated user persona, when set
        case PromptId.worldInfoBefore:
          return world.before;
        case PromptId.worldInfoAfter:
          return world.after;
        default:
          return '';
      }
    }

    // Blocks that inject into the history at a depth rather than inline.
    final absolute = <PromptBlock>[];
    // Fixed (non-history) messages, in order, each tagged with the section it
    // belongs to for the breakdown; chatHistory marks where history goes.
    final leading = <_Part>[];
    final trailing = <_Part>[];
    var sawHistory = false;

    void emit(String label, String role, String content) {
      final text = macros.evaluate(content, ctx).trim();
      if (text.isEmpty) return;
      final msg = ChatMessage(role: role, content: text);
      (sawHistory ? trailing : leading).add(_Part(label, msg));
    }

    for (final entry in preset.promptOrder) {
      final block = preset.blockById(entry.identifier);
      if (block == null) continue;
      // Enabled state lives on the order; `main` is never skipped (ST parity).
      if (!entry.enabled && block.identifier != PromptId.main) continue;

      if (block.injectionPosition == InjectionPosition.absolute && !block.marker) {
        absolute.add(block);
        continue;
      }

      if (block.identifier == PromptId.chatHistory) {
        sawHistory = true;
        continue;
      }

      if (block.marker) {
        emit(_labelFor(block), 'system', markerSource(block.identifier));
        continue;
      }

      // A normal block. main/jailbreak accept a character-card override.
      var content = block.content;
      if (!block.forbidOverrides) {
        if (block.identifier == PromptId.main &&
            (character?.systemPrompt.trim().isNotEmpty ?? false)) {
          content = character!.systemPrompt;
        } else if (block.identifier == PromptId.jailbreak &&
            (character?.postHistoryInstructions.trim().isNotEmpty ?? false)) {
          content = character!.postHistoryInstructions;
        }
      }
      emit(_labelFor(block), block.role, content);
    }

    // PLACEHOLDER_HISTORY
    int cost(ChatMessage m) => tokens.estimate(m.content) + _perMessageOverhead;

    var fixedTokens =
        [...leading, ...trailing].fold<int>(0, (sum, p) => sum + cost(p.msg));

    // Absolute-injection blocks are placed into the chat history at a depth
    // from the end rather than inline. Resolve them now (so their tokens are
    // reserved before history greedily fills the remaining budget), keeping
    // each block's depth and order attached to its message. Crucially we do NOT
    // map injections back to `absolute` by list index later: the instant one
    // block resolves to empty and is skipped, an index map desynchronizes and
    // silently drops or mis-depths the rest (real presets inject empty comment
    // blocks, so this happened constantly).
    final injections = <_Injection>[];
    for (final block in absolute) {
      final text = macros.evaluate(block.content, ctx).trim();
      if (text.isEmpty) continue;
      final msg = ChatMessage(role: block.role, content: text);
      injections.add(_Injection(
        depth: block.injectionDepth,
        order: block.injectionOrder,
        seq: injections.length,
        part: _Part('Injected (depth ${block.injectionDepth})', msg),
      ));
      fixedTokens += cost(msg);
    }

    // Lore that asked to sit inside the conversation rather than in front of it.
    // Reserved here for the same reason as the blocks above: the history budget
    // is what is left over, so anything fixed has to be counted first. A lower
    // injection order than a preset block's default puts lore after the frame at
    // the same depth, which is the order SillyTavern ends up with too.
    for (final inj in world.injections) {
      final text = macros.evaluate(inj.text, ctx).trim();
      if (text.isEmpty) continue;
      final msg = ChatMessage(role: inj.role.wireName, content: text);
      injections.add(_Injection(
        depth: inj.depth,
        order: 0,
        seq: injections.length,
        part: _Part('World info (depth ${inj.depth})', msg),
      ));
      fixedTokens += cost(msg);
    }

    // Chat history greedily fills the remaining budget, newest first.
    //
    // A heavy preset frame plus a large character sheet can consume the entire
    // budget on its own — a real, common case: a 4095-token preset (SillyTavern's
    // default, and what a partial preset export imports as) with an 8 KB
    // character sheet leaves ~0 tokens, so every prior turn was silently dropped
    // and the model saw the instructions and the newest message only. A chat app
    // sending no conversation is never the useful answer, so guarantee history a
    // floor of the budget even when that means overshooting `maxContext` — which
    // is a preset field, not a hard limit the host enforces.
    final floor = (budget * _historyFloorFraction).round();
    var remaining = (budget - fixedTokens).clamp(0, 1 << 30).toInt();
    if (remaining < floor) remaining = floor;
    final chosen = <ChatMessage>[];
    for (final msg in resolvedHistory.reversed) {
      final c = cost(msg);
      if (c > remaining) break;
      remaining -= c;
      chosen.add(msg);
    }
    final history0 =
        chosen.reversed.map((m) => _Part('Chat history', m)).toList();

    // Merge absolute injections in at their depth-from-end. Depth d means "d
    // messages follow this block", so it lands at index (len - d). Within a
    // depth, a higher injection order sits earlier; equal orders keep prompt
    // order (stable). Depths are applied shallowest-last (ascending) so a
    // deeper insert at a lower index does not shift an already-placed shallower
    // group.
    if (injections.isNotEmpty) {
      final byDepth = <int, List<_Injection>>{};
      for (final inj in injections) {
        byDepth.putIfAbsent(inj.depth, () => []).add(inj);
      }
      // Positions are measured against the history length *before* any injection
      // — inserting a group must not shift the target index of the next one.
      // Processing depths ascending inserts at strictly decreasing indices, so
      // each insert leaves every not-yet-used (lower) target index untouched.
      final baseLen = history0.length;
      final depths = byDepth.keys.toList()..sort();
      for (final depth in depths) {
        final bucket = byDepth[depth]!
          ..sort((a, b) {
            final byOrder = b.order.compareTo(a.order);
            return byOrder != 0 ? byOrder : a.seq.compareTo(b.seq);
          });
        final at = (baseLen - depth).clamp(0, history0.length);
        history0.insertAll(at, bucket.map((i) => i.part));
      }
    }

    final parts = _oneSystemBlock(<_Part>[...leading, ...history0, ...trailing]);
    // Collapse consecutive same-role turns into one. This is not cosmetic:
    //
    //  * Presets that frame the prompt with many small blocks (tags, headings,
    //    one block per rule) otherwise emit dozens of tiny `system` messages.
    //    Plenty of OpenAI-compatible hosts and proxies honour only the *first*
    //    system message and discard the rest — which silently reduced the whole
    //    character definition and instruction frame to whatever the first
    //    fragment happened to be (often a bare `<role>` tag).
    //  * Anthropic rejects consecutive same-role turns outright.
    //
    // Adjacent blocks of the same role are contiguous document text by design,
    // so joining them with a blank line is what the preset author intended. The
    // preset's own `squashSystemMessages` flag is a strict subset of this and is
    // kept only for lossless preset import/export.
    final messages = mergeSameRole(parts.map((p) => p.msg).toList());

    // The breakdown stays per-block (unmerged) so the Info view can still name
    // each section; its total is measured on the same unmerged parts so the two
    // agree with each other.
    final sections = _sectionsFrom(parts, cost);
    final total = parts.fold<int>(0, (sum, p) => sum + cost(p.msg));
    return BuiltPrompt(messages, total, sections);
  }

  /// Keeps `system` for the leading run only; any system block that would land
  /// *after* the conversation has started is re-tagged `user`.
  ///
  /// Presets that wrap the chat in tags (`</chat_history>`, `<last_message>`,
  /// a trailing `<task>` / `<output_format>`) place those blocks at a chat depth,
  /// so they naturally fall between and after the turns. Sending them as `system`
  /// leaves several system messages scattered through the request, and hosts
  /// disagree badly about what that means: a gateway that folds them into one
  /// system field can end up keeping only the *last* one, which is the trailing
  /// task block — instructions to roleplay, with the character sheet nowhere in
  /// sight. The model then reads the conversation, guesses from context, and says
  /// it was never given a definition.
  ///
  /// One leading system block plus in-chat framing as `user` turns is what
  /// SillyTavern sends, is unambiguous everywhere, and preserves both the content
  /// and its position — only the role label of the in-chat framing changes.
  static List<_Part> _oneSystemBlock(List<_Part> parts) {
    final out = <_Part>[];
    var conversationStarted = false;
    for (final part in parts) {
      final isSystem = part.msg.role == 'system';
      if (!isSystem) conversationStarted = true;
      if (isSystem && conversationStarted) {
        out.add(_Part(
          part.label,
          ChatMessage(role: 'user', content: part.msg.content),
        ));
      } else {
        out.add(part);
      }
    }
    return out;
  }

  /// A human-readable section label for a prompt [block].
  static String _labelFor(PromptBlock block) {
    switch (block.identifier) {
      case PromptId.main:
        return 'Main prompt';
      case PromptId.nsfw:
        return 'Auxiliary prompt';
      case PromptId.charDescription:
        return 'Character description';
      case PromptId.charPersonality:
        return 'Personality';
      case PromptId.scenario:
        return 'Scenario';
      case PromptId.dialogueExamples:
        return 'Example dialogue';
      case PromptId.personaDescription:
        return 'User persona';
      case PromptId.worldInfoBefore:
      case PromptId.worldInfoAfter:
        return 'World info';
      case PromptId.jailbreak:
        return 'Post-history instructions';
      case PromptId.enhanceDefinitions:
        return 'Enhance definitions';
      default:
        return block.name.trim().isEmpty ? 'Custom' : block.name.trim();
    }
  }

  /// Groups consecutive same-label parts into sections, summing token cost, so
  /// the breakdown reads in prompt order and its totals match the real budget.
  static List<PromptSection> _sectionsFrom(
      List<_Part> parts, int Function(ChatMessage) cost) {
    final out = <PromptSection>[];
    for (final part in parts) {
      final t = cost(part.msg);
      if (out.isNotEmpty && out.last.label == part.label) {
        final prev = out.last;
        out[out.length - 1] = PromptSection(
          label: prev.label,
          role: prev.role,
          tokens: prev.tokens + t,
          messageCount: prev.messageCount + 1,
        );
      } else {
        out.add(PromptSection(
          label: part.label,
          role: part.msg.role,
          tokens: t,
          messageCount: 1,
        ));
      }
    }
    return out;
  }
}

/// A prompt message tagged with the breakdown section it belongs to, tracked
/// through assembly so the "Info" view can report per-section token cost.
class _Part {
  const _Part(this.label, this.msg);
  final String label;
  final ChatMessage msg;
}

/// An absolute (depth) injection awaiting placement in the chat history: its
/// target [depth] from the end, its [order] tiebreaker within that depth, a
/// stable [seq] (prompt-order index) for equal orders, and the [part] to place.
class _Injection {
  const _Injection({
    required this.depth,
    required this.order,
    required this.seq,
    required this.part,
  });
  final int depth;
  final int order;
  final int seq;
  final _Part part;
}
