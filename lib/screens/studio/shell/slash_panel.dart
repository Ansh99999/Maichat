import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../models/message_image.dart';
import '../../../services/studio/studio_commands.dart';

/// The list that floats above the composer while a `/command` is being typed:
/// one roomy row per match — `/name`, what it takes, a line on what it does,
/// and what kind of command it is. The highlighted row is what Enter or Tab
/// completes.
///
/// When a line that was sent names no command, the panel says so instead and
/// offers to send it as ordinary text.
class StudioSlashPanel extends StatelessWidget {
  const StudioSlashPanel({
    super.key,
    required this.matches,
    required this.highlighted,
    required this.onPick,
    this.unknown,
    this.onSendAsText,
    this.onDismiss,
  });

  final List<StudioCommand> matches;
  final int highlighted;
  final ValueChanged<StudioCommand> onPick;

  /// A command name that was sent and exists nowhere.
  final String? unknown;
  final VoidCallback? onSendAsText;
  final VoidCallback? onDismiss;

  /// How tall one row is; the panel shows four and a half before it scrolls,
  /// so the half row says there is more.
  static const double rowHeight = 64;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final Widget body;
    if (unknown != null) {
      body = Padding(
        key: const Key('studio-slash-unknown'),
        padding: const EdgeInsets.fromLTRB(20, 14, 8, 14),
        child: Row(
          children: [
            Icon(Icons.help_outline, color: scheme.onSurfaceVariant),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                'No command /$unknown',
                style: theme.textTheme.bodyLarge,
              ),
            ),
            TextButton(
              key: const Key('studio-slash-send-as-text'),
              onPressed: onSendAsText,
              child: const Text('Send as text'),
            ),
            IconButton(
              tooltip: 'Dismiss',
              onPressed: onDismiss,
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      );
    } else if (matches.isEmpty) {
      body = Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
        child: Text(
          'No command matches. Keep typing to send it as text.',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
      );
    } else {
      final rows = matches.length > 4 ? 4.5 : matches.length.toDouble();
      body = SizedBox(
        height: rows * rowHeight,
        child: ListView.builder(
          key: const Key('studio-slash-list'),
          padding: EdgeInsets.zero,
          itemCount: matches.length,
          itemExtent: rowHeight,
          itemBuilder: (context, i) => _Row(
            command: matches[i],
            highlighted: i == highlighted,
            onTap: () => onPick(matches[i]),
          ),
        ),
      );
    }
    return Material(
      key: const Key('studio-slash-panel'),
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(28),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: body,
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.command,
    required this.highlighted,
    required this.onTap,
  });

  final StudioCommand command;
  final bool highlighted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fg = highlighted ? scheme.onSecondaryContainer : scheme.onSurface;
    final muted = highlighted
        ? scheme.onSecondaryContainer.withValues(alpha: 0.75)
        : scheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Material(
        color: highlighted ? scheme.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(22),
        child: InkWell(
          key: Key('studio-slash-${command.name}'),
          borderRadius: BorderRadius.circular(22),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text.rich(
                        TextSpan(children: [
                          TextSpan(
                            text: '/${command.name}',
                            style: theme.textTheme.titleSmall?.copyWith(color: fg),
                          ),
                          if (command.argumentHint.isNotEmpty)
                            TextSpan(
                              text: '  ${command.argumentHint}',
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: muted),
                            ),
                        ]),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        command.description,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: muted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                _Badge(kind: command.kind),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.kind});

  final StudioCommandKind kind;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (bg, fg) = switch (kind) {
      StudioCommandKind.builtIn => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
      StudioCommandKind.skill => (scheme.tertiaryContainer, scheme.onTertiaryContainer),
      StudioCommandKind.custom => (scheme.primaryContainer, scheme.onPrimaryContainer),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        kind.label,
        style: theme.textTheme.labelSmall?.copyWith(color: fg),
      ),
    );
  }
}

/// What the slash panel shows, kept beside the composer's text: the command
/// being typed, which match is highlighted, and — after a line naming no
/// command was sent — the offer to send it as text.
///
/// It watches the composer's controller rather than living in the composer,
/// so the composer knows nothing of commands; Enter from a soft keyboard
/// arrives as a newline typed after the name, and completes the highlighted
/// match like Tab or a hardware Enter.
class StudioSlashState extends ChangeNotifier {
  StudioSlashState({required this.input, required this.commands}) {
    input.addListener(_onInput);
  }

  final TextEditingController input;

  /// The commands there are right now (skills and the user's own change).
  final List<StudioCommand> Function() commands;

  int _highlighted = 0;
  String? _query;
  bool _dismissed = false;

  String? unknownName;
  String? _unknownText;
  List<MessageImage> unknownImages = const <MessageImage>[];

  int get highlighted => _highlighted;

  /// The name being typed, or null when no panel should show.
  String? get query => _dismissed ? null : slashQuery(input.text);

  List<StudioCommand> get matches {
    final q = query;
    return q == null ? const <StudioCommand>[] : matchCommands(commands(), q);
  }

  bool get visible => unknownName != null || query != null;

  /// The line that named no command, while its offer shows.
  String? get unknownText => _unknownText;

  void _onInput() {
    final text = input.text;
    if (_unknownText != null && text != _unknownText) {
      unknownName = null;
      _unknownText = null;
      unknownImages = const <MessageImage>[];
    }
    // Enter on a soft keyboard types a newline; after a name being typed it
    // means "complete this".
    final entered = RegExp(r'^/([A-Za-z0-9_:\-]*)\n$').firstMatch(text);
    if (entered != null && !_dismissed) {
      final found = matchCommands(commands(), entered.group(1)!);
      if (found.isNotEmpty) {
        complete(found[_highlighted.clamp(0, found.length - 1)]);
        return;
      }
    }
    final q = slashQuery(text);
    if (q != _query) {
      _query = q;
      _highlighted = 0;
      if (q == null) _dismissed = false;
    }
    notifyListeners();
  }

  void move(int delta) {
    final n = matches.length;
    if (n == 0) return;
    _highlighted = (_highlighted + delta) % n;
    if (_highlighted < 0) _highlighted += n;
    notifyListeners();
  }

  /// Fills in `/name ` for [command] (or the highlighted match) and leaves
  /// the caret after it, for the arguments.
  bool complete([StudioCommand? command]) {
    final found = matches;
    final pick = command ??
        (found.isEmpty ? null : found[_highlighted.clamp(0, found.length - 1)]);
    if (pick == null) return false;
    final text = '/${pick.name} ';
    input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    return true;
  }

  /// Closes the panel until the text starts over.
  void dismiss() {
    if (unknownName != null) {
      unknownName = null;
      _unknownText = null;
      unknownImages = const <MessageImage>[];
    } else {
      _dismissed = true;
    }
    notifyListeners();
  }

  /// A line that was sent and named no command: it goes back in the
  /// composer, and the panel offers to send it as it is.
  void showUnknown(String text, List<MessageImage> images, String name) {
    _unknownText = text;
    unknownName = name;
    unknownImages = images;
    // Set first, so the listener sees the text it is being given as the
    // offer's own and keeps the offer.
    input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    notifyListeners();
  }

  /// The keys that work while the panel shows: arrows to move, Tab or Enter
  /// to complete, Escape to close.
  Map<ShortcutActivator, VoidCallback> get shortcuts => visible && unknownName == null
      ? {
          const SingleActivator(LogicalKeyboardKey.arrowDown): () => move(1),
          const SingleActivator(LogicalKeyboardKey.arrowUp): () => move(-1),
          const SingleActivator(LogicalKeyboardKey.tab): complete,
          const SingleActivator(LogicalKeyboardKey.enter): complete,
          const SingleActivator(LogicalKeyboardKey.escape): dismiss,
        }
      : visible
          ? {const SingleActivator(LogicalKeyboardKey.escape): dismiss}
          : const <ShortcutActivator, VoidCallback>{};

  @override
  void dispose() {
    input.removeListener(_onInput);
    super.dispose();
  }
}
