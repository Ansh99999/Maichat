import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/character.dart';
import '../state/app_state.dart';
import '../widgets/avatar_dots.dart';
import '../widgets/avatar_image.dart';
import '../widgets/character_avatar.dart';
import '../widgets/character_theme_scope.dart';
import '../widgets/fab_menu.dart';
import '../widgets/natural_image.dart';
import 'character_actions.dart';
import 'character_editor.dart';
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

    // The sheet is where a character's own theme is most worth wearing: this is
    // their page. A card with no theme of its own gets the app's, untouched.
    return CharacterThemeScope(
      theme: character.theme,
      child: Scaffold(
        body: Stack(
          children: [
            CustomScrollView(
              slivers: [
                _SheetAppBar(character: character, state: state),
                SliverToBoxAdapter(
                  child: _Portrait(character: character, state: state),
                ),
                SliverToBoxAdapter(child: TagBand(tags: character.tags)),
                SliverToBoxAdapter(
                  child: NotesBlock(notes: character.creatorNotes),
                ),
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
            onPressed: () =>
                openCharacterEditor(context, character: character),
          ),
          PopupMenuButton<CharacterAction>(
            onSelected: (action) =>
                runCharacterAction(context, state, character, action),
            itemBuilder: (context) => characterMenuItems(),
          ),
        ],
      );
}

/// The pictures at their own aspect ratio across the full width, with the name in
/// the lower-right over a fade so it stays readable whatever the art is doing.
///
/// A card can wear several pictures, and this is where they are looked through:
/// swipe, and the one you stop on becomes the one the card wears everywhere. No
/// dialog and no snackbar — the dots said what happened, and it is one swipe back.
class _Portrait extends StatefulWidget {
  const _Portrait({required this.character, required this.state});

  final Character character;
  final AppState state;

  @override
  State<_Portrait> createState() => _PortraitState();
}

class _PortraitState extends State<_Portrait> {
  PageController? _pages;

  /// The run being swiped, captured rather than read live. [AppState.avatarPoolFor]
  /// lists the worn picture first, so committing a swipe reorders it — a live pool
  /// would slide a different picture under the page you are on the instant you
  /// stopped on it.
  List<String> _pool = const <String>[];

  /// Whose proportions the frame keeps: the picture worn when the sheet opened.
  /// Fixed on purpose — sizing the frame to the picture on show would resize the
  /// whole page mid-swipe, and a page that jumps is not a carousel.
  String _anchor = '';

  int _index = 0;

  /// Committing the default is held back until the swiping stops: it writes the
  /// roster, and a write per page crossed would be felt.
  Timer? _commit;

  @override
  void initState() {
    super.initState();
    _adopt();
  }

  @override
  void dispose() {
    _commit?.cancel();
    _pages?.dispose();
    super.dispose();
  }

  void _adopt() {
    _pool = widget.state.avatarPoolFor(widget.character);
    _anchor = _pool.isEmpty ? '' : _pool.first;
    _index = 0;
    _pages?.dispose();
    _pages = PageController();
  }

  void _onPage(int page) {
    setState(() => _index = page);
    _commit?.cancel();
    final ref = _pool[page];
    if (ref == widget.character.avatar) return;
    _commit = Timer(const Duration(milliseconds: 420), () {
      if (!mounted) return;
      widget.state.setDefaultAvatar(widget.character.id, ref);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final character = widget.character;
    // A picture added or deleted elsewhere is a different run; a *reordered* one
    // is the same run and must not disturb the pager.
    final live = widget.state.avatarPoolFor(character);
    if (!setEquals(live.toSet(), _pool.toSet())) _adopt();

    final fallback = ColoredBox(
      color: scheme.secondaryContainer,
      child: Center(child: CharacterAvatar(character: character, size: 120)),
    );

    return NaturalFrame(
      imageRef: _anchor,
      builder: (context, size, image) => Stack(
        fit: StackFit.expand,
        children: [
          if (_pool.length < 2)
            if (image == null)
              fallback
            else
              Image(
                image: image,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => fallback,
              )
          else
            PageView.builder(
              controller: _pages,
              itemCount: _pool.length,
              onPageChanged: _onPage,
              itemBuilder: (context, i) => _PortraitPage(
                ref: _pool[i],
                width: size.width,
                fallback: fallback,
              ),
            ),
          _Caption(character: character),
          if (_pool.length > 1)
            Positioned(
              left: 0,
              right: 0,
              // Clear of the caption's own band, which is the bottom of the fade.
              bottom: 10,
              child: IgnorePointer(
                child: Center(
                  child: AvatarDots(
                    count: _pool.length,
                    index: _index,
                    onArtwork: true,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One picture in the run, drawn the way the single portrait is.
class _PortraitPage extends StatelessWidget {
  const _PortraitPage({
    required this.ref,
    required this.width,
    required this.fallback,
  });

  final String ref;
  final double width;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    final provider = avatarImage(
      ref,
      displaySize: width,
      devicePixelRatio: MediaQuery.maybeDevicePixelRatioOf(context) ?? 1,
    );
    if (provider == null) return fallback;
    return Image(
      image: provider,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => fallback,
    );
  }
}

/// The name, the catcher and the provenance, over a fade at the foot of the
/// picture. Drawn inside the picture's own frame, so a capped (very tall) picture
/// keeps its caption on the artwork instead of in the empty margin beside it.
class _Caption extends StatelessWidget {
  const _Caption({required this.character});

  final Character character;

  @override
  Widget build(BuildContext context) {
    final meta = <String>[
      character.format.label,
      if (character.creator.trim().isNotEmpty) 'by ${character.creator.trim()}',
    ].join(' · ');

    return IgnorePointer(
      // The fade and the name are decoration; they must never eat a gesture
      // meant for the page — or for the run of pictures under them.
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
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                ),
                // The one-line catcher, under the name and above the
                // provenance — the order it reads in.
                if (character.hasTitle)
                  Text(
                    character.title.trim(),
                    textAlign: TextAlign.right,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: Colors.white.withValues(alpha: 0.92),
                          fontStyle: FontStyle.italic,
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
    );
  }
}
