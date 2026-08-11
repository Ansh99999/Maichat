import '../models/character.dart';
import '../models/message.dart';

/// The two SillyTavern variable scopes used by {{setvar}}/{{getvar}} and the
/// `.name`/`$name` DSL: [local] is per-chat, [global] is app-wide.
class MacroVariables {
  MacroVariables({Map<String, String>? local, Map<String, String>? global})
      : local = local ?? <String, String>{},
        global = global ?? <String, String>{};

  final Map<String, String> local;
  final Map<String, String> global;
}

/// Everything a macro might resolve against. Assembled by the prompt builder for
/// each generation and passed to [MacroEngine.evaluate]. Optional fields default
/// sensibly so callers can populate only what they have.
class MacroContext {
  MacroContext({
    this.userName = 'User',
    this.charName = '',
    this.character,
    List<ChatMessage>? messages,
    this.model = '',
    this.maxContext = 0,
    this.maxResponse = 0,
    this.maxPrompt = 0,
    this.input = '',
    this.generationType = 'normal',
    this.isMobile = true,
    this.lastUserActivity,
    MacroVariables? variables,
    Map<String, String Function()>? dynamicMacros,
  })  : messages = messages ?? const <ChatMessage>[],
        variables = variables ?? MacroVariables(),
        dynamicMacros = dynamicMacros ?? const <String, String Function()>{};

  String userName;
  String charName;

  /// Source of card-field macros ({{description}}, {{personality}}, …).
  Character? character;

  /// Chat history (excludes the in-flight assistant turn), oldest first.
  List<ChatMessage> messages;

  String model;
  int maxContext;
  int maxResponse;
  int maxPrompt;

  /// The current send-box text, for {{input}}.
  String input;

  /// normal | swipe | continue | impersonate | quiet — for {{lastGenerationType}}.
  String generationType;
  bool isMobile;

  /// When the user last sent, for {{idle_duration}}.
  DateTime? lastUserActivity;

  MacroVariables variables;

  /// Per-call macro overrides ({{name}} -> value), highest precedence.
  Map<String, String Function()> dynamicMacros;
}

/// Resolves SillyTavern macros in a string against a [MacroContext].
/// See `macro_engine.dart` for the concrete implementation.
abstract interface class MacroEngine {
  String evaluate(String text, MacroContext ctx);
}
