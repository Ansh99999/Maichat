import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../../models/character.dart';
import '../../../models/folder.dart';
import '../../../models/home_layout.dart';
import '../../../state/app_state.dart';
import '../../../widgets/avatar_image.dart';
import '../../../widgets/character_avatar.dart';
import '../../folders/folder_window.dart';
import '../home_icon_shape.dart';
import '../home_spec.dart';
import 'chat_card_tile.dart';

/// A folder of characters, shown as an Android-style folder icon (a cluster of
/// member avatars) at 1x1, growing into a fuller card with its name and
/// essentials counts as it is given more room. Tapping opens the folder
/// window.
class CharacterFolderSpec extends HomeWidgetSpec {
  const CharacterFolderSpec();

  @override
  HomeWidgetKind get kind => HomeWidgetKind.characterFolder;

  @override
  String get title => 'Character folder';

  @override
  String get description => 'A folder of characters and what they share';

  @override
  IconData get icon => Icons.folder_outlined;

  @override
  List<HomeOption> options(HomeTile tile) => const [
        HomePickOption(
          key: 'folderId',
          label: 'Folder',
          pick: HomePickKind.folder,
          allowNone: true,
          noneLabel: 'Choose a folder',
        ),
      ];

  @override
  String describe(BuildContext context, HomeTile tile) {
    final state = context.read<AppState>();
    final folder = state.folderById(tile.str('folderId'));
    if (folder == null) return 'Character folder';
    return 'Character folder · ${folder.displayName}';
  }

  @override
  Widget build(BuildContext context, HomeTileContext tile) =>
      _FolderCard(key: ValueKey(tile.tile.id), tile: tile);
}

class _FolderCard extends StatelessWidget {
  const _FolderCard({super.key, required this.tile});

  final HomeTileContext tile;

  void _open(BuildContext context, Folder folder) {
    if (tile.editing) return;
    showFolderWindow(context, folderId: folder.id);
  }

  @override
  Widget build(BuildContext context) {
    final folderId = tile.tile.str('folderId');
    final state = homeWatch(context, (s) {
      final f = s.folderById(folderId);
      if (f == null) return (false, s.folders.isEmpty);
      final members = [
        for (final id in f.characterIds) s.characterById(id),
      ].whereType<Character>().take(5);
      final memberSig = members.map((m) => '${m.id}:${m.name}:${m.avatar}').join(',');
      return (
        f.name,
        f.color,
        f.avatar,
        f.characterIds.length,
        f.lorebookIds.length,
        f.scenarioIds.length,
        memberSig,
      );
    });
    final folder = state.folderById(folderId);

    if (folder == null) {
      final noFolders = state.folders.isEmpty;
      return HomeEmptyCard(
        icon: Icons.folder_outlined,
        message: noFolders ? 'No folders yet' : 'Choose a folder',
        compact: tile.compact,
      );
    }

    final members = <Character>[
      for (final id in folder.characterIds)
        if (state.characterById(id) != null) state.characterById(id)!,
    ];

    if (tile.w == 1 && tile.h == 1) {
      return _FolderIcon(
        folder: folder,
        members: members,
        shape: tile.layout.iconShape,
        onTap: () => _open(context, folder),
      );
    }

    return HomeCard(
      semanticLabel: '${folder.displayName} folder',
      onTap: () => _open(context, folder),
      builder: (context, inner) => _FolderBody(
        folder: folder,
        members: members,
        inner: inner,
      ),
    );
  }
}

/// The 1x1 Android-folder look: a tonal blob holding up to 4 member avatars
/// in a 2x2 cluster (or a plain folder glyph with none).
class _FolderIcon extends StatelessWidget {
  const _FolderIcon({
    required this.folder,
    required this.members,
    required this.shape,
    required this.onTap,
  });

  final Folder folder;
  final List<Character> members;
  final HomeIconShape shape;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint = folder.color != 0 ? Color(folder.color) : null;
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = constraints.biggest.shortestSide.isFinite
            ? constraints.biggest.shortestSide
            : 72.0;
        final border = homeIconBorder(shape, side);
        return HomeOutlined(
          shape: border,
          child: Material(
            color: tint?.withValues(alpha: 0.25) ?? scheme.secondaryContainer,
            shape: border,
            child: InkWell(
              onTap: onTap,
              customBorder: border,
              child: Padding(
                padding: EdgeInsets.all(side * 0.12),
                child: members.isEmpty
                    ? Icon(
                        Icons.folder_rounded,
                        color: tint ?? scheme.onSecondaryContainer,
                      )
                    : _MemberGrid(members: members, side: side * 0.76),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _MemberGrid extends StatelessWidget {
  const _MemberGrid({required this.members, required this.side});

  final List<Character> members;
  final double side;

  @override
  Widget build(BuildContext context) {
    final shown = members.take(4).toList();
    final cell = side / 2 - 2;
    return SizedBox(
      width: side,
      height: side,
      child: GridView.count(
        crossAxisCount: 2,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
        children: [
          for (final m in shown)
            CharacterAvatar(character: m, radius: cell / 2),
        ],
      ),
    );
  }
}

class _FolderBody extends StatelessWidget {
  const _FolderBody({
    required this.folder,
    required this.members,
    required this.inner,
  });

  final Folder folder;
  final List<Character> members;
  final Size inner;

  String get _counts {
    final parts = <String>[];
    void add(int n, String one, String many) {
      if (n > 0) parts.add('$n ${n == 1 ? one : many}');
    }

    add(folder.characterIds.length, 'character', 'characters');
    add(folder.lorebookIds.length, 'lorebook', 'lorebooks');
    add(folder.scenarioIds.length, 'scenario', 'scenarios');
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tint = folder.color != 0 ? Color(folder.color) : null;
    final nameStyle =
        theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600);
    final countsStyle = theme.textTheme.bodySmall
        ?.copyWith(color: scheme.onSurfaceVariant);
    final nameH = homeLineHeight(context, nameStyle);
    final countsH = homeLineHeight(context, countsStyle);
    final avatarRow = inner.height >= 56;
    final showCounts = _counts.isNotEmpty &&
        inner.height >= nameH + (avatarRow ? 40 : 0) + countsH + 8;

    final avatar = avatarImage(folder.avatar, displaySize: 40);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: tint?.withValues(alpha: 0.3) ??
                  scheme.secondaryContainer,
              backgroundImage: avatar,
              child: avatar == null
                  ? Icon(
                      Icons.folder_rounded,
                      size: 18,
                      color: tint ?? scheme.onSecondaryContainer,
                    )
                  : null,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                folder.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: nameStyle,
              ),
            ),
          ],
        ),
        if (avatarRow && members.isNotEmpty) ...[
          const SizedBox(height: 8),
          SizedBox(
            height: 28,
            child: Stack(
              children: [
                for (var i = 0; i < members.length.clamp(0, 5); i++)
                  Positioned(
                    left: i * 20.0,
                    child: CharacterAvatar(character: members[i], radius: 14),
                  ),
              ],
            ),
          ),
        ],
        if (showCounts) ...[
          const SizedBox(height: 6),
          Text(
            _counts,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: countsStyle,
          ),
        ],
      ],
    );
  }
}
