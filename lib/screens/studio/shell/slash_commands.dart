import '../../../models/message_image.dart';
import '../../../services/studio/studio_commands.dart';
import '../../../services/studio/studio_controller.dart';
import '../../../services/studio/studio_memory.dart';
import '../../../services/studio/studio_skills.dart';

/// Acts on a `/command` the composer sent — the screen hands it every such
/// line through [StudioController.onSlashCommand]. What reaches the model does
/// so through [StudioController.send] with `asText`; what is only the app's
/// (help, the context, stopping) never does.
///
/// The screen supplies what only it can do — sheets, the sub-agent panel, a
/// new session, a toast — as callbacks, so the reading of commands stays here
/// and testable.
class StudioSlashCommands {
  StudioSlashCommands({
    required this.controller,
    required this.onHelp,
    required this.onSkills,
    required this.onContext,
    required this.onAgents,
    required this.onNewSession,
    required this.onToast,
    required this.onUnknown,
    this.onBtw,
    this.memory,
  });

  final StudioController controller;
  final void Function() onHelp;
  final void Function() onSkills;

  /// `/btw <question>`: the screen opens the side-question sheet, which asks
  /// through [StudioController.askAside]. Nothing reaches the session.
  final void Function(String question, List<MessageImage> images)? onBtw;

  /// `/context`: the context inspector for the agent on screen.
  final void Function() onContext;
  final void Function() onAgents;
  final Future<void> Function() onNewSession;
  final void Function(String message) onToast;

  /// A line naming no command: the screen puts it back in the composer and
  /// offers to send it as text.
  final void Function(String text, List<MessageImage> images, String name)
      onUnknown;

  /// Where `/remember` writes; opened lazily from the Studio's folder when
  /// not given.
  final Future<StudioMemory> Function()? memory;

  /// Every command there is right now.
  List<StudioCommand> get commands => studioCommands(
        skills: StudioSkillLibrary.active?.enabled ?? const [],
        custom: StudioCommandStore.active?.commands ?? const [],
      );

  /// Acts on [text]; returns true when it was a command (handled here, or
  /// sent on in its expanded form), false to send it as it is.
  Future<bool> handle(String text, List<MessageImage> images) async {
    final line = parseSlash(text);
    if (line == null) return false;
    final command =
        commands.where((c) => c.name == line.name).firstOrNull;
    if (command == null) {
      onUnknown(text, images, line.name);
      return true;
    }
    switch (command.kind) {
      case StudioCommandKind.skill:
        final skill = StudioSkillLibrary.active?.skill(command.name);
        if (skill == null) {
          onUnknown(text, images, line.name);
          return true;
        }
        await controller.send(
          skillInvocation(skill, line.args),
          images: images,
          asText: true,
        );
        return true;
      case StudioCommandKind.custom:
        await controller.send(
          expandTemplate(command.template, line.args),
          images: images,
          asText: true,
        );
        return true;
      case StudioCommandKind.builtIn:
        await _builtIn(command.name, line.args, images);
        return true;
    }
  }

  Future<void> _builtIn(
    String name,
    String args,
    List<MessageImage> images,
  ) async {
    switch (name) {
      case 'help':
        onHelp();
      case 'btw':
        if (args.isEmpty) {
          onToast('Say what to ask: /btw <question>.');
          return;
        }
        final ask = onBtw;
        if (ask == null) {
          onToast('Side questions are not available here.');
          return;
        }
        ask(args, images);
      case 'skills':
        onSkills();
      case 'context':
        onContext();
      case 'agents':
        if (controller.hasSubagents) {
          onAgents();
        } else {
          onToast('No sub-agents in this session yet.');
        }
      case 'new':
        await onNewSession();
      case 'stop':
        if (controller.busy) {
          controller.stop();
          onToast('Stopped.');
        } else {
          onToast('Nothing is running.');
        }
      case 'compact':
        if (controller.running) {
          onToast('The Studio summarises on its own while it works — try '
              'again once it has finished.');
          return;
        }
        onToast('Summarising the older conversation…');
        final done = await controller.compactNow();
        onToast(done
            ? 'Summarised the older conversation.'
            : 'Nothing to summarise yet.');
      case 'remember':
        if (args.isEmpty) {
          onToast('Say what to remember: /remember <preference>.');
          return;
        }
        if (!controller.state.studioConfig.memoryEnabled) {
          onToast('Memory is off in Studio settings.');
          return;
        }
        final store = await (memory?.call() ??
            StudioMemory.forDirectory(controller.store.directory));
        final refused = store.add(args);
        onToast(refused ?? 'Remembered.');
      case 'playtest':
        await controller.send(
          args.isEmpty
              ? 'Playtest the draft now with two or three realistic user '
                  'messages of your choosing, then tell me briefly what '
                  'works and what to fix.'
              : 'Playtest the draft now: send it this as the user — '
                  '"$args" — then tell me briefly how it went and what to '
                  'fix.',
          images: images,
          asText: true,
        );
    }
  }
}
