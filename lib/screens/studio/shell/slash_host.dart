import 'dart:async';

import 'package:flutter/material.dart';

import '../../../models/message_image.dart';
import '../../../services/studio/studio_commands.dart';
import '../../../services/studio/studio_controller.dart';
import '../../../services/studio/studio_skills.dart';
import '../settings/studio_skills_page.dart';
import 'slash_commands.dart';
import 'slash_panel.dart';

/// Everything `/` commands need from a Studio session's screen, gathered so
/// the screen only has to place two things: the panel (above the composer)
/// and the keys around the composer.
///
/// It reads the skills and the user's own commands from the Studio's folder,
/// hands the controller the line-reading hook
/// ([StudioController.onSlashCommand]), and owns the panel's state.
class StudioSlashHost {
  StudioSlashHost({
    required this.controller,
    required this.input,
    required this.attachments,
    required this.context,
    required this.onContext,
    required this.onAgents,
    required this.onNewSession,
    required this.toastInset,
  }) {
    state = StudioSlashState(input: input, commands: () => runner.commands);
    runner = StudioSlashCommands(
      controller: controller,
      onHelp: _showHelp,
      onSkills: () {
        final ctx = context();
        if (ctx.mounted) unawaited(openStudioSkills(ctx, store: controller.store));
      },
      onContext: onContext,
      onAgents: onAgents,
      onNewSession: onNewSession,
      onToast: _toast,
      onUnknown: state.showUnknown,
    );
    controller.onSlashCommand = runner.handle;
    unawaited(_load());
  }

  final StudioController controller;
  final TextEditingController input;
  final ValueNotifier<List<MessageImage>> attachments;

  /// The screen's context, read when it is needed (it outlives this call).
  final BuildContext Function() context;
  final VoidCallback onContext;
  final VoidCallback onAgents;
  final Future<void> Function() onNewSession;

  /// How far above the bottom a toast must float to clear the dock.
  final double Function() toastInset;

  late final StudioSlashState state;
  late final StudioSlashCommands runner;

  StudioSkillLibrary? _skills;
  StudioCommandStore? _commands;
  bool _disposed = false;

  Future<void> _load() async {
    final dir = controller.store.directory;
    StudioSkillLibrary skills;
    StudioCommandStore commands;
    try {
      skills = await StudioSkillLibrary.forDirectory(dir);
      commands = await StudioCommandStore.forDirectory(dir);
    } catch (e) {
      debugPrint('MaiChat: could not read the Studio skills ($e)');
      return;
    }
    // The screen may have closed while they were read.
    if (_disposed) return;
    _skills = skills;
    _commands = commands;
    _skills?.addListener(_changed);
    _commands?.addListener(_changed);
    _changed();
  }

  /// The skills or commands changed: the panel's matches with them.
  void _changed() => state.refresh();

  void dispose() {
    _disposed = true;
    _skills?.removeListener(_changed);
    _commands?.removeListener(_changed);
    if (controller.onSlashCommand == runner.handle) {
      controller.onSlashCommand = null;
    }
    state.dispose();
  }

  /// The panel, for the screen's dock to reveal while [StudioSlashState.visible].
  Widget panel() => Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
        child: StudioSlashPanel(
          matches: state.matches,
          highlighted: state.highlighted,
          onPick: state.complete,
          unknown: state.unknownName,
          onSendAsText: _sendAsText,
          onDismiss: state.dismiss,
        ),
      );

  /// [composer] with the panel's keys — only while the panel shows, so the
  /// arrows and Enter are the text field's the rest of the time.
  Widget keys(Widget composer) => ListenableBuilder(
        listenable: state,
        builder: (context, child) =>
            CallbackShortcuts(bindings: state.shortcuts, child: child!),
        child: composer,
      );

  void _sendAsText() {
    final text = input.text;
    final images = state.unknownImages;
    state.dismiss();
    input.clear();
    attachments.value = const <MessageImage>[];
    unawaited(controller.send(text, images: images, asText: true));
  }

  void _toast(String message) {
    final ctx = context();
    if (!ctx.mounted) return;
    final messenger = ScaffoldMessenger.of(ctx);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        margin: EdgeInsets.fromLTRB(16, 0, 16, toastInset() + 12),
      ));
  }

  void _showHelp() {
    final ctx = context();
    if (!ctx.mounted) return;
    unawaited(showStudioCommandsSheet(ctx, runner.commands));
  }
}

/// Every command, grouped by kind, in a sheet — `/help`.
Future<void> showStudioCommandsSheet(
  BuildContext context,
  List<StudioCommand> commands,
) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheet) {
        final theme = Theme.of(sheet);
        final scheme = theme.colorScheme;
        final muted =
            theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.6,
          maxChildSize: 0.92,
          builder: (context, scroll) => ListView(
            key: const Key('studio-commands-sheet'),
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
            children: [
              Text('Commands', style: theme.textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text('Type / at the start of a message.', style: muted),
              for (final kind in StudioCommandKind.values)
                if (commands.any((c) => c.kind == kind)) ...[
                  const SizedBox(height: 28),
                  Text(
                    switch (kind) {
                      StudioCommandKind.builtIn => 'Built in',
                      StudioCommandKind.skill => 'Skills',
                      StudioCommandKind.custom => 'Your commands',
                    },
                    style: theme.textTheme.titleMedium
                        ?.copyWith(color: scheme.primary),
                  ),
                  const SizedBox(height: 8),
                  for (final c in commands.where((c) => c.kind == kind))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text.rich(TextSpan(children: [
                            TextSpan(
                              text: '/${c.name}',
                              style: theme.textTheme.titleSmall,
                            ),
                            if (c.argumentHint.isNotEmpty)
                              TextSpan(text: '  ${c.argumentHint}', style: muted),
                          ])),
                          const SizedBox(height: 2),
                          Text(
                            c.description,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: muted,
                          ),
                        ],
                      ),
                    ),
                ],
            ],
          ),
        );
      },
    );
