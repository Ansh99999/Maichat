import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/character.dart';
import '../state/app_state.dart';
import '../widgets/character_avatar.dart';
import '../widgets/fab_menu.dart';
import '../widgets/natural_image.dart';
import 'character_actions.dart';
import 'character_edit_screen.dart';
import 'chat_screen.dart';
import 'character_sheet_parts.dart';

/// A character's sheet: the card's picture at its own proportions with the name
/// burned into its lower corner, a scrolling band of tags, the creator's notes
/// rendered as they wrote them (HTML and CSS included), then the definition —
/// scenario, description, greetings and the rest — behind folds.
///
/// The whole page is one [CustomScrollView] of slivers, and every fold builds its
/// body only while open, so opening the sheet costs the header, the tags and the
/// notes and nothing else. Reads live from [AppState] by id, so an edit made from
/// the menu shows up without a reload.
class CharacterSheetScreen extends StatelessWidget {
  const CharacterSheetScreen({super.key, required this.characterId});

  final String characterId;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final character = state.characterById(characterId);
    // Deleted out from under us (e.g. via the menu's delete): leave gracefully.
    if (character == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('This character is no longer here.')),
      );
    }

    final recent = state.mostRecentChatWith(character.id);
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      body: Stack(
        children: [
          CustomScrollView(
            slivers: [
              _SheetAppBar(character: character, state: state),
              SliverToBoxAdapter(child: _Portrait(character: character)),
              SliverToBoxAdapter(child: TagBand(tags: character.tags)),
              SliverToBoxAdapter(child: NotesBlock(character: character)),
              const SliverToBoxAdapter(child: SheetDivider()),
              SliverToBoxAdapter(
                child: DefinitionFolds(character: character),
              ),
              // Room for the action bubbles to sit over nothing important.
              SliverToBoxAdapter(child: SizedBox(height: 120 + bottomInset)),
            ],
          ),
          Positioned.fill(
            child: FabMenu(
              tooltip: 'Chat',
              padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottomInset),
              actions: [
                if (recent != null)
                  FabMenuAction(
                    icon: Icons.forum_outlined,
                    label: 'Most recent chat',
                    onPressed: () {
                      state.selectConversation(recent.id);
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const ChatScreen(),
                        ),
                      );
                    },
                  ),
                FabMenuAction(
                  icon: Icons.chat_bubble_outline,
                  label: 'New chat',
                  onPressed: () =>
                      startCharacterChat(context, state, character),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The bar over the picture: back, star, edit and the existing character menu.
/// Floating and transparent, so the portrait reads as the top of the page.
class _SheetAppBar extends StatelessWidget {
  const _SheetAppBar({required this.character, required this.state});

  final Character character;
  final AppState state;

  @override
  Widget build(BuildContext context) => SliverAppBar(
        floating: true,
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            tooltip: character.starred ? 'Unstar' : 'Star',
            icon: Icon(character.starred ? Icons.star : Icons.star_border),
            onPressed: () => state.toggleCharacterStar(character.id),
          ),
          IconButton(
            tooltip: 'Edit',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => CharacterEditScreen(character: character),
              ),
            ),
          ),
          PopupMenuButton<CharacterAction>(
            onSelected: (action) =>
                runCharacterAction(context, state, character, action),
            itemBuilder: (context) => characterMenuItems(),
          ),
        ],
      );
}

/// The picture at its own aspect ratio across the full width, with the name in
/// the lower-right over a fade so it stays readable whatever the art is doing.
class _Portrait extends StatelessWidget {
  const _Portrait({required this.character});

  final Character character;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final meta = <String>[
      character.format.label,
      if (character.creator.trim().isNotEmpty) 'by ${character.creator.trim()}',
    ].join(' · ');

    return NaturalImage(
      imageRef: character.avatar,
      fallback: ColoredBox(
        color: scheme.secondaryContainer,
        child: Center(
          child: CharacterAvatar(character: character, size: 120),
        ),
      ),
      // Passed as the picture's own overlay rather than stacked around it, so a
      // capped (very tall) picture keeps its caption on the artwork instead of
      // in the empty margin beside it.
      overlay: IgnorePointer(
        // The fade and the name are decoration; they must never eat a gesture
        // meant for the page.
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          // The fade is a full-width band across the foot of the picture, so the
          // name reads against a gradient rather than against a patch of it.
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(20, 40, 20, 14),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0),
                    Colors.black.withValues(alpha: 0.62),
                  ],
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    character.displayName,
                    textAlign: TextAlign.right,
                    style:
                        Theme.of(context).textTheme.headlineMedium?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                  ),
                  if (meta.isNotEmpty)
                    Text(
                      meta,
                      textAlign: TextAlign.right,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Colors.white.withValues(alpha: 0.82),
                          ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
