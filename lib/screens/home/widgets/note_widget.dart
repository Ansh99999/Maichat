import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../../models/home_layout.dart';
import '../../../state/app_state.dart';
import '../../chats_screen.dart' show relativeTime;
import '../home_spec.dart';
import '../note_editor_screen.dart';
import 'chat_card_tile.dart';

/// A quick note kept right on Home. Tapping opens the full editor; with no
/// note chosen yet, tapping mints a fresh one (keyed to this tile) and opens
/// straight into it.
class NoteSpec extends HomeWidgetSpec {
  const NoteSpec();

  @override
  HomeWidgetKind get kind => HomeWidgetKind.note;

  @override
  String get title => 'Note';

  @override
  String get description => 'A quick note kept on Home';

  @override
  IconData get icon => Icons.note_outlined;

  @override
  List<HomeOption> options(HomeTile tile) => const [
        HomePickOption(
          key: 'noteId',
          label: 'Note',
          pick: HomePickKind.note,
          allowNone: true,
          noneLabel: 'A new note',
        ),
        HomeChoiceOption(
          key: 'tone',
          label: 'Colour',
          choices: {
            'default': 'Default',
            'primary': 'Tinted',
            'tertiary': 'Tinted (alt)',
          },
        ),
        HomeChoiceOption(
          key: 'fontSize',
          label: 'Text size',
          choices: {
            'medium': 'Medium',
            'small': 'Small',
            'large': 'Large',
          },
        ),
      ];

  @override
  String describe(BuildContext context, HomeTile tile) {
    final state = context.read<AppState>();
    final note = state.homeNoteById(tile.str('noteId'));
    if (note == null || note.heading.isEmpty) return 'Note';
    return 'Note · ${note.heading}';
  }

  @override
  Widget build(BuildContext context, HomeTileContext tile) =>
      _NoteCard(key: ValueKey(tile.tile.id), tile: tile);
}

double _fontScaleOf(String size) => switch (size) {
      'small' => 0.85,
      'large' => 1.2,
      _ => 1.0,
    };

Color? _toneOf(ColorScheme scheme, String tone) => switch (tone) {
      'primary' => scheme.primaryContainer,
      'tertiary' => scheme.tertiaryContainer,
      _ => null,
    };

class _NoteCard extends StatelessWidget {
  const _NoteCard({super.key, required this.tile});

  final HomeTileContext tile;

  /// The id a fresh note gets when this tile has none chosen yet — stable
  /// per tile, so re-opening the same empty tile reopens the same note
  /// rather than minting a new one each time.
  String get _impliedNoteId => 'tile-${tile.tile.id}';

  Future<void> _open(BuildContext context, String noteId) async {
    if (tile.editing) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => NoteEditorScreen(noteId: noteId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = tile.tile;
    final chosenId = t.str('noteId');
    final noteId = chosenId ?? _impliedNoteId;
    final tone = t.str('tone') ?? 'default';
    final fontScale = _fontScaleOf(t.str('fontSize') ?? 'medium');
    final state = homeWatch(
      context,
      (s) {
        final n = s.homeNoteById(noteId);
        return (n?.title, n?.body, n?.updatedAt);
      },
    );
    final note = state.homeNoteById(noteId);
    final scheme = Theme.of(context).colorScheme;

    return HomeCard(
      semanticLabel: note == null || note.isEmpty
          ? 'Note, empty'
          : 'Note, ${note.heading}',
      color: _toneOf(scheme, tone),
      onTap: () => _open(context, noteId),
      builder: (context, inner) {
        final theme = Theme.of(context);
        final bodyStyle = theme.textTheme.bodyMedium?.apply(
          fontSizeFactor: fontScale,
        );
        final titleStyle = theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w600,
        ).apply(fontSizeFactor: fontScale);

        if (note == null || note.isEmpty) {
          return const HomeEmptyCard(
            icon: Icons.note_add_outlined,
            message: 'Tap to write a note',
          );
        }

        final titleH = homeLineHeight(context, titleStyle);
        final bodyH = homeLineHeight(context, bodyStyle);
        final agoStyle = theme.textTheme.labelSmall
            ?.copyWith(color: scheme.onSurfaceVariant);
        final agoH = homeLineHeight(context, agoStyle);
        final hasTitle = note.title.trim().isNotEmpty;
        final headerH = hasTitle ? titleH + 4 : 0.0;
        final showAgo = inner.height >= headerH + bodyH + agoH + 6;
        final bodyRoom =
            inner.height - headerH - (showAgo ? agoH + 4 : 0) - 4;
        final bodyLines = (bodyRoom / bodyH).floor().clamp(1, 10);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (hasTitle)
              Text(
                note.title.trim(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: titleStyle,
              ),
            if (hasTitle) const SizedBox(height: 4),
            if (note.body.trim().isNotEmpty)
              Text(
                note.body.trim(),
                maxLines: bodyLines,
                overflow: TextOverflow.ellipsis,
                style: bodyStyle,
              ),
            if (showAgo) ...[
              const SizedBox(height: 4),
              Text(
                'Edited ${relativeTime(note.updatedAt)}',
                maxLines: 1,
                style: agoStyle,
              ),
            ],
          ],
        );
      },
    );
  }
}
