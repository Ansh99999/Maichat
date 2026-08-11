import '../models/character.dart';
import '../models/message.dart';
import '../models/preset.dart';
import '../models/prompt_block.dart';
import 'macro_context.dart';
import 'token_estimator.dart';

/// The result of assembling a preset into a request: the role-tagged messages
/// ready for [ChatClient] (which splits out `system` for Anthropic itself), and
/// a rough token estimate for diagnostics.
class BuiltPrompt {
  BuiltPrompt(this.messages, this.estimatedTokens);
  final List<ChatMessage> messages;
  final int estimatedTokens;
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

  BuiltPrompt build({
    required Preset preset,
    Character? character,
    required List<ChatMessage> history,
    String userName = 'User',
    String model = '',
    MacroVariables? variables,
    String input = '',
  }) {
    final charName = character?.displayName ?? '';
    final budget = (preset.maxContext - preset.maxResponseTokens)
        .clamp(0, 1 << 30)
        .toInt();

    final ctx = MacroContext(
      userName: userName,
      charName: charName,
      character: character,
      messages: history,
      model: model.isEmpty ? preset.model : model,
      maxContext: preset.maxContext,
      maxResponse: preset.maxResponseTokens,
      maxPrompt: budget,
      input: input,
      variables: variables ?? MacroVariables(),
    );

    // Resolve the content each marker stands in for (macros applied later).
    String markerSource(String id) {
      switch (id) {
        case PromptId.charDescription:
          return character?.description ?? '';
        case PromptId.charPersonality:
          return character?.personality ?? '';
        case PromptId.scenario:
          return character?.scenario ?? '';
        case PromptId.dialogueExamples:
          return character?.mesExample ?? '';
        case PromptId.personaDescription:
        case PromptId.worldInfoBefore:
        case PromptId.worldInfoAfter:
          return ''; // no persona/lorebook system yet
        default:
          return '';
      }
    }

    // Blocks that inject into the history at a depth rather than inline.
    final absolute = <PromptBlock>[];
    // Fixed (non-history) messages, in order; chatHistory marks where history goes.
    final leading = <ChatMessage>[];
    final trailing = <ChatMessage>[];
    var sawHistory = false;

    void emit(String role, String content) {
      final text = macros.evaluate(content, ctx).trim();
      if (text.isEmpty) return;
      final msg = ChatMessage(role: role, content: text);
      (sawHistory ? trailing : leading).add(msg);
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
        emit('system', markerSource(block.identifier));
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
      emit(block.role, content);
    }

    // PLACEHOLDER_HISTORY
    int cost(ChatMessage m) => tokens.estimate(m.content) + _perMessageOverhead;

    final fixed = [...leading, ...trailing];
    var fixedTokens = fixed.fold<int>(0, (sum, m) => sum + cost(m));

    // Absolute-injection blocks are reserved before history fills the rest.
    final injections = <ChatMessage>[];
    for (final block in absolute
      ..sort((a, b) => b.injectionOrder.compareTo(a.injectionOrder))) {
      final text = macros.evaluate(block.content, ctx).trim();
      if (text.isEmpty) continue;
      final msg = ChatMessage(role: block.role, content: text);
      injections.add(msg);
      fixedTokens += cost(msg);
    }

    // Chat history greedily fills the remaining budget, newest first.
    var remaining = (budget - fixedTokens).clamp(0, 1 << 30).toInt();
    final chosen = <ChatMessage>[];
    for (final msg in history.reversed) {
      final c = cost(msg);
      if (c > remaining) break;
      remaining -= c;
      chosen.add(msg);
    }
    final chatHistory = chosen.reversed.toList();

    // Merge absolute injections in at their depth-from-end (highest order first).
    if (injections.isNotEmpty) {
      final byDepth = <int, List<ChatMessage>>{};
      for (var i = 0; i < absolute.length; i++) {
        if (i < injections.length) {
          byDepth.putIfAbsent(absolute[i].injectionDepth, () => []).add(injections[i]);
        }
      }
      final depths = byDepth.keys.toList()..sort();
      for (final depth in depths) {
        final at = (chatHistory.length - depth).clamp(0, chatHistory.length);
        chatHistory.insertAll(at, byDepth[depth]!);
      }
    }

    var messages = <ChatMessage>[...leading, ...chatHistory, ...trailing];
    if (preset.squashSystemMessages) messages = _squashSystem(messages);

    final total = messages.fold<int>(0, (sum, m) => sum + cost(m));
    return BuiltPrompt(messages, total);
  }

  /// Collapses runs of consecutive `system` messages into one, joined by blank
  /// lines — SillyTavern's `squash_system_messages`.
  static List<ChatMessage> _squashSystem(List<ChatMessage> input) {
    final out = <ChatMessage>[];
    for (final m in input) {
      if (m.role == 'system' && out.isNotEmpty && out.last.role == 'system') {
        out[out.length - 1] = ChatMessage(
          role: 'system',
          content: '${out.last.content}\n\n${m.content}',
        );
      } else {
        out.add(m);
      }
    }
    return out;
  }
}
