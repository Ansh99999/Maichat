import 'studio/studio_commands.dart';

/// `/btw` — a quick side question, Claude Code's `/btw`: asked with the whole
/// conversation as context, answered in a sheet, and then gone. The question
/// and its answer never enter the transcript, the swipes, the summaries, the
/// store, or any later request.
///
/// Both composers understand it: the roleplay chat's (where it is the only
/// slash command, see [btwQuestion]) and the Studio's (one of its built-ins,
/// read by the same [parseSlash]). The requests are made by
/// `AppState.askAside` and `StudioController.askAside`, each through the
/// single assembly path its own sends use.

/// The question in [text] when it is a `/btw` line ('' for a bare `/btw`),
/// or null when it is not one.
String? btwQuestion(String text) {
  final line = parseSlash(text.trimLeft());
  if (line == null || line.name != 'btw') return null;
  return line.args;
}

/// What the roleplay model is told, as the last `user` turn of the chat's own
/// assembled prompt.
String chatBtwInstruction(String question) =>
    '[A side question from the user, outside the story. Answer it directly '
    'and briefly, out of character, using the conversation above. This '
    'exchange is not part of the chat — do not continue the roleplay.]\n\n'
    '${question.trim()}';

/// What the Studio's agent is told, as the last `user` turn of its own next
/// request.
String studioBtwInstruction(String question) =>
    '[Studio note] A quick side question from the user (/btw). Answer it '
    'briefly, in words only, from what is already in this conversation — '
    'tools are off for this answer, and neither the question nor the answer '
    'is kept in the session.\n\n${question.trim()}';

/// What a tool call still running reads in a side question's copy of the
/// conversation, so the copy is one every host accepts.
const String kBtwOpenCallResult =
    'Still running — no result yet (this is a side question; the real result '
    'arrives in the main conversation).';

/// One side question being answered. The sheet holds it and cancels it when
/// it is put away; whoever makes the request registers how to stop it.
class BtwRun {
  bool _cancelled = false;
  final List<void Function()> _hooks = <void Function()>[];

  bool get cancelled => _cancelled;

  /// [hook] runs on [cancel] (at once, if that has happened already).
  void onCancel(void Function() hook) {
    if (_cancelled) {
      hook();
      return;
    }
    _hooks.add(hook);
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final hook in _hooks) {
      hook();
    }
    _hooks.clear();
  }
}
