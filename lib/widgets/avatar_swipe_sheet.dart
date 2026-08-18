import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../models/character.dart';
import '../models/conversation.dart';
import '../state/app_state.dart';
import 'avatar_image.dart';

/// Opens a character's pictures full screen, to look through and to choose from.
///
/// Reached by tapping an avatar in a chat — the user's own included, when they are
/// impersonating somebody. Swipe through what the character has, then:
///
/// * **Set** pins that picture for this thread only,
/// * **Default** makes it the character's picture everywhere,
/// * **Reset** drops the per-chat choice again,
/// * **Float** drops it onto the conversation as a movable window.
///
/// The counterpart of Agnai's `AvatarSwipeModal`, done as a full-screen route
/// because a phone has no room for a modal over a photo.
Future<void> showAvatarSwipeSheet(
  BuildContext context, {
  required Character character,
  required String conversationId,
}) {
  return Navigator.of(context).push(MaterialPageRoute<void>(
    fullscreenDialog: true,
    builder: (_) => AvatarSwipeScreen(
      characterId: character.id,
      conversationId: conversationId,
    ),
  ));
}

class AvatarSwipeScreen extends StatefulWidget {
  const AvatarSwipeScreen({
    super.key,
    required this.characterId,
    required this.conversationId,
  });

  final String characterId;
  final String conversationId;

  @override
  State<AvatarSwipeScreen> createState() => _AvatarSwipeScreenState();
}

class _AvatarSwipeScreenState extends State<AvatarSwipeScreen> {
  PageController? _pages;
  int _index = 0;

  /// Whether the page has been aimed at the picture the character is currently
  /// wearing. Done once, on the first build that has the pool: opening the viewer
  /// should show what you are looking at, not the start of the list.
  bool _aimed = false;

  @override
  void dispose() {
    _pages?.dispose();
    super.dispose();
  }

  Future<void> _set(AppState state, String ref) async {
    await state.setChatAvatar(widget.conversationId, widget.characterId, ref);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _setDefault(AppState state, String ref) async {
    await state.setDefaultAvatar(widget.characterId, ref);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _reset(AppState state) async {
    await state.setChatAvatar(widget.conversationId, widget.characterId, null);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _float(AppState state, String ref) async {
    // Floats are gallery pictures, so this only works for a picture the gallery
    // still knows about — an avatar that came in on a card was never in it.
    final image = state.gallery.where((i) => i.image == ref).firstOrNull;
    if (image == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Only pictures kept in the gallery can float.'),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }
    await state.floatImage(widget.conversationId, image.id);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final conversation = state.conversationById(widget.conversationId);
    final character = state.characterFor(conversation, widget.characterId);
    if (character == null) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Text('That character is gone.',
              style: TextStyle(color: Colors.white70)),
        ),
      );
    }

    final pool = state.avatarPoolFor(character);
    final current = state.avatarRefFor(conversation, character);
    if (!_aimed) {
      _aimed = true;
      final at = pool.indexOf(current);
      _index = at < 0 ? 0 : at;
      _pages = PageController(initialPage: _index);
    }
    final overridden = conversation?.avatarOverrides
            .containsKey(widget.characterId) ??
        false;

    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.black.withValues(alpha: 0.35),
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(character.displayName),
        actions: [
          if (pool.length > 1)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                child: Text(
                  '${_index + 1} / ${pool.length}',
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
            ),
        ],
      ),
      body: pool.isEmpty
          ? _NoPictures(character: character)
          : Stack(
              children: [
                PageView.builder(
                  controller: _pages,
                  itemCount: pool.length,
                  onPageChanged: (i) => setState(() => _index = i),
                  itemBuilder: (context, i) => _AvatarPage(ref: pool[i]),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _AvatarActions(
                    isCurrent: pool[_index] == current,
                    canReset: overridden,
                    onSet: () => _set(state, pool[_index]),
                    onDefault: () => _setDefault(state, pool[_index]),
                    onReset: () => _reset(state),
                    onFloat: () => _float(state, pool[_index]),
                  ),
                ),
              ],
            ),
    );
  }
}

/// One picture in the swipe run, zoomable so a detail can be checked before
/// choosing it.
class _AvatarPage extends StatelessWidget {
  const _AvatarPage({required this.ref});

  final String ref;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final provider = avatarImage(
      ref,
      displaySize: media.size.longestSide,
      devicePixelRatio: media.devicePixelRatio,
    );
    return InteractiveViewer(
      minScale: 1,
      maxScale: 5,
      child: Center(
        child: provider == null
            ? const Icon(Icons.person_outline, color: Colors.white38, size: 64)
            : Image(
                image: provider,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => const Icon(Icons.person_outline,
                    color: Colors.white38, size: 64),
              ),
      ),
    );
  }
}

/// What can be done with the picture on screen.
class _AvatarActions extends StatelessWidget {
  const _AvatarActions({
    required this.isCurrent,
    required this.canReset,
    required this.onSet,
    required this.onDefault,
    required this.onReset,
    required this.onFloat,
  });

  /// Whether the picture shown is already the one being worn here.
  final bool isCurrent;

  /// Whether this thread has a choice of its own to drop.
  final bool canReset;

  final VoidCallback onSet;
  final VoidCallback onDefault;
  final VoidCallback onReset;
  final VoidCallback onFloat;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            Colors.black.withValues(alpha: 0.55),
            Colors.black.withValues(alpha: 0.85),
          ],
        ),
      ),
      padding: EdgeInsets.fromLTRB(16, 28, 16, 12 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Says which picture is in use rather than renaming the button that
          // applies it: an action whose label changes underneath you reads as two
          // different actions.
          if (isCurrent)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'In use in this chat',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.75),
                  fontSize: 12,
                ),
              ),
            ),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  // Stays enabled on the picture already in use: saying "this one,
                  // here" when it is already pinned is harmless, and a dead
                  // primary action reads as broken.
                  onPressed: onSet,
                  icon: const Icon(Icons.check, size: 18),
                  label: const Text('Set'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white38),
                  ),
                  onPressed: onDefault,
                  icon: const Icon(Icons.push_pin_outlined, size: 18),
                  label: const Text('Default'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: Colors.white70),
                  onPressed: onFloat,
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: const Text('Float'),
                ),
              ),
              Expanded(
                child: TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: Colors.white70),
                  // Nothing to reset to when the thread has no choice of its own.
                  onPressed: canReset ? onReset : null,
                  icon: const Icon(Icons.restart_alt, size: 18),
                  label: const Text('Reset'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A character with no picture at all. Says where pictures come from rather than
/// showing an empty black screen.
class _NoPictures extends StatelessWidget {
  const _NoPictures({required this.character});

  final Character character;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(32, 0, 32, 48),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.person_outline,
                  color: Colors.white38, size: 56),
              const SizedBox(height: 16),
              Text(
                '${character.displayName} has no pictures yet',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
              const SizedBox(height: 8),
              const Text(
                'Add some to their gallery, then set one as an avatar to swipe '
                'between them here.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54, fontSize: 13),
              ),
            ],
          ),
        ),
      );
}

/// Whether tapping [character]'s avatar in [conversation] would show anything
/// worth opening: a picture to look at, or a pool to swipe.
bool hasAvatarToShow(
  AppState state,
  Conversation? conversation,
  Character character,
) =>
    state.avatarPoolFor(character).isNotEmpty ||
    state.avatarRefFor(conversation, character).trim().isNotEmpty;
