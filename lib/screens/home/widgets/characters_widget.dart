import 'package:flutter/material.dart';

import '../../../models/character.dart';
import '../../../models/home_layout.dart';
import '../../../state/app_state.dart';
import '../../character_actions.dart';
import '../../characters_screen.dart';
import '../../chat_screen.dart';
import '../../../widgets/character_avatar.dart';
import '../home_spec.dart';
import 'chat_card_tile.dart' show HomeEmptyCard;

/// A row (or grid, taller spans) of character faces.
class CharactersSpec extends HomeWidgetSpec {
  const CharactersSpec();

  @override
  HomeWidgetKind get kind => HomeWidgetKind.characters;

  @override
  String get title => 'Characters';

  @override
  String get description => 'Recent, starred, or every character you have';

  @override
  IconData get icon => Icons.groups_outlined;

  @override
  List<HomeOption> options(HomeTile tile) => const [
        HomeChoiceOption(
          key: 'source',
          label: 'Show',
          choices: {
            'recent': 'Recently chatted',
            'starred': 'Starred',
            'all': 'All characters',
          },
        ),
        HomeChoiceOption(
          key: 'tapAction',
          label: 'Tapping a face',
          choices: {'chat': 'Starts a chat', 'sheet': 'Opens their sheet'},
        ),
        HomeToggleOption(key: 'names', label: 'Show names', fallback: false),
      ];

  @override
  String describe(BuildContext context, HomeTile tile) {
    final source = tile.str('source') ?? 'recent';
    return 'Characters · ${_sourceLabel(source)}';
  }

  static String _sourceLabel(String source) => switch (source) {
        'starred' => 'Starred',
        'all' => 'All',
        _ => 'Recent',
      };

  @override
  Widget build(BuildContext context, HomeTileContext tile) {
    final state = homeWatch(context, (s) {
      final b = StringBuffer();
      for (final c in s.characters) {
        b.write('${c.id}:${c.avatar}:${c.starred}:${c.name}|');
      }
      for (final c in s.conversations) {
        b.write(c.memberIds.join(','));
        b.write(';');
      }
      return b.toString();
    });
    final source = tile.tile.str('source') ?? 'recent';
    final tapAction = tile.tile.str('tapAction') ?? 'chat';
    final showNames = tile.tile.flag('names', false);

    List<Character> list;
    if (source == 'starred') {
      list = state.characters.where((c) => c.starred).toList();
    } else if (source == 'all') {
      list = state.characters.toList();
    } else {
      final seen = <String>{};
      list = [];
      for (final c in state.conversations) {
        for (final id in c.memberIds) {
          if (seen.add(id)) {
            final ch = state.characterById(id);
            if (ch != null) list.add(ch);
          }
        }
      }
      // Then everyone else, starred first, so a short history still fills
      // the row.
      final rest = state.characters.where((c) => !seen.contains(c.id)).toList()
        ..sort((a, b) => (b.starred ? 1 : 0) - (a.starred ? 1 : 0));
      list.addAll(rest);
    }

    if (list.isEmpty) {
      return const HomeEmptyCard(
        icon: Icons.groups_outlined,
        message: 'Your characters will gather here',
      );
    }

    return HomeCard(
      semanticLabel: 'Characters',
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      alignment: AlignmentDirectional.centerStart,
      builder: (context, inner) => _FacesRow(
        characters: list,
        showNames: showNames,
        editing: tile.editing,
        size: inner,
        onTapFace: (c) => _onTap(context, state, c, tapAction),
        onMore: () => _openAll(context),
      ),
    );
  }

  void _onTap(
    BuildContext context,
    AppState state,
    Character character,
    String tapAction,
  ) {
    if (tapAction == 'sheet') {
      openCharacterDetail(context, character.id);
      return;
    }
    state.startChatWithCharacter(character);
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ChatScreen()),
    );
  }

  void _openAll(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const CharactersScreen()),
    );
  }
}

class _FacesRow extends StatelessWidget {
  const _FacesRow({
    required this.characters,
    required this.showNames,
    required this.editing,
    required this.size,
    required this.onTapFace,
    required this.onMore,
  });

  final List<Character> characters;
  final bool showNames;
  final bool editing;

  /// The room inside the card.
  final Size size;
  final void Function(Character) onTapFace;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final nameH = showNames
        ? homeLineHeight(context, Theme.of(context).textTheme.labelSmall) + 4
        : 0.0;
    // The faces take the height there is (between 28 and 56 px), then as
    // many rows of them as fit.
    const gap = 10.0;
    // As tall as the row allows (28–48 px), but small enough that a narrow
    // card still shows three faces rather than one and a "+6".
    final byWidth = (size.width - gap * 2) / 3;
    final face = [size.height - nameH, 48.0, byWidth < 36 ? 36.0 : byWidth]
        .reduce((a, b) => a < b ? a : b)
        .clamp(28.0, 48.0);
    final rowH = face + nameH;
    final rows = ((size.height + 8) / (rowH + 8)).floor().clamp(1, 6);
    final slotW = (showNames ? (face > 56 ? face : 56.0) : face) + gap;
    final perRow = ((size.width + gap) / slotW).floor().clamp(1, 999);
    final fit = perRow * rows;
    final hasMore = characters.length > fit;
    final shown = (hasMore ? fit - 1 : fit).clamp(0, characters.length);
    final visible = characters.take(shown).toList();
    return Wrap(
      spacing: gap,
      runSpacing: 8,
      children: [
        for (final c in visible)
          _Face(
            character: c,
            size: face,
            showName: showNames,
            onTap: editing ? null : () => onTapFace(c),
          ),
        if (hasMore)
          _MoreFace(
            size: face,
            count: characters.length - visible.length,
            onTap: editing ? null : onMore,
          ),
      ],
    );
  }
}

class _Face extends StatelessWidget {
  const _Face({
    required this.character,
    required this.size,
    required this.showName,
    this.onTap,
  });

  final Character character;
  final double size;
  final bool showName;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: character.displayName,
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CharacterAvatar(character: character, size: size),
            if (showName) ...[
              const SizedBox(height: 4),
              SizedBox(
                width: size > 56 ? size : 56,
                child: Text(
                  character.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MoreFace extends StatelessWidget {
  const _MoreFace({required this.size, required this.count, this.onTap});

  final double size;
  final int count;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: '$count more characters',
      child: GestureDetector(
        onTap: onTap,
        child: CircleAvatar(
          radius: size / 2,
          backgroundColor: scheme.surfaceContainerHighest,
          child: Text('+$count', style: Theme.of(context).textTheme.labelMedium),
        ),
      ),
    );
  }
}
