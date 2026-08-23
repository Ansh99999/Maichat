import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../models/character.dart';
import '../models/conversation.dart';
import '../services/jank_logger.dart';
import '../state/app_state.dart';
import 'avatar_image.dart';
import 'photo_surface.dart';

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
  return Navigator.of(context).push(
    // The same see-through route the gallery viewer uses, so a picture flicked
    // away here leaves the chat visible behind it as it goes.
    photoRoute<void>(
      (_) => AvatarSwipeScreen(
        characterId: character.id,
        conversationId: conversationId,
      ),
    ),
  );
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

  /// The pictures to swipe, captured once. Frozen on purpose: [avatarPoolIn]
  /// lists the thread's *current* pick first, so tapping Set reorders it — the
  /// live pool would slide a different picture under the page you're on the
  /// instant you choose one, which is the "original avatar flashes back" on Set.
  List<String>? _pool;

  /// Whether the picture on screen is zoomed in, so paging can get out of the way
  /// of a one-finger pan.
  bool _zoomed = false;

  /// How near the picture is to being flicked away, 0 → 1.
  final ValueNotifier<double> _leaving = ValueNotifier<double>(0);

  @override
  void dispose() {
    _pages?.dispose();
    _leaving.dispose();
    super.dispose();
  }

  Future<void> _set(AppState state, String ref) async {
    // The "old avatar flashes back on Set" has two parts, and both have to be
    // closed or the flash survives.
    //
    // 1. Decode the chosen picture first, at the exact sizes the chat draws its
    //    avatars, so the thread has the bitmap ready and does not repaint a
    //    blank/old frame while it decodes. Both role sizes are warmed because the
    //    sheet doesn't know whether it was opened on the bot or the persona.
    final conversation = state.conversationById(widget.conversationId);
    if (conversation != null && mounted) {
      final ui = state.interfaceFor(conversation);
      final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
      final sizes = {ui.avatarFor(false).size, ui.avatarFor(true).size};
      for (final size in sizes) {
        final provider = avatarImage(ref, displaySize: size, devicePixelRatio: dpr);
        if (provider != null && mounted) {
          await precacheImage(provider, context);
        }
      }
    }
    await state.setChatAvatar(widget.conversationId, widget.characterId, ref);
    if (!mounted) return;
    // 2. `setChatAvatar` only *marks* the covered chat dirty; it still holds the
    //    old avatar until its next build runs. Popping in the same microtask
    //    reveals that stale frame for an instant. Wait for the frame that
    //    rebuilds it (and paints the now-decoded new picture) before leaving, so
    //    the chat is already showing the new avatar when it is uncovered.
    await WidgetsBinding.instance.endOfFrame;
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
    // Any picture the app can draw can float — a gallery entry is not a
    // prerequisite, so an avatar that arrived on an imported card works too.
    // `floatPictureRef` ties it to the gallery record when there is one.
    JankLogger.instance.breadcrumb('float added from avatar sheet');
    await state.floatPictureRef(widget.conversationId, ref);
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
    // Captured once and reused: the pool must not reshuffle under the PageView
    // when Set changes the override (see [_pool]).
    final pool = _pool ??= state.avatarPoolIn(conversation, widget.characterId);
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
      // Painted by [PhotoBackdrop] instead, so it thins out as a picture is
      // flicked away and the chat shows through behind it.
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight),
        child: PhotoFade(
          leaving: _leaving,
          child: AppBar(
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
        ),
      ),
      body: Stack(
        children: [
          Positioned.fill(child: PhotoBackdrop(leaving: _leaving)),
          if (pool.isEmpty)
            _NoPictures(character: character)
          else ...[
            PageView.builder(
              controller: _pages,
              physics: _zoomed
                  ? const NeverScrollableScrollPhysics()
                  : const PageScrollPhysics(),
              itemCount: pool.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (context, i) => _AvatarPage(
                key: ValueKey('avatar-page-${pool[i]}'),
                ref: pool[i],
                leaving: _leaving,
                onDismiss: () => Navigator.of(context).maybePop(),
                onZoomChanged: (zoomed) {
                  if (_zoomed != zoomed) setState(() => _zoomed = zoomed);
                },
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: PhotoFade(
                leaving: _leaving,
                child: _AvatarActions(
                  isCurrent: pool[_index] == current,
                  canReset: overridden,
                  onSet: () => _set(state, pool[_index]),
                  onDefault: () => _setDefault(state, pool[_index]),
                  onReset: () => _reset(state),
                  onFloat: () => _float(state, pool[_index]),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One picture in the swipe run: pinchable so a detail can be checked before
/// choosing it, and flickable so it can be put away without reaching for Back.
class _AvatarPage extends StatelessWidget {
  const _AvatarPage({
    super.key,
    required this.ref,
    required this.leaving,
    required this.onDismiss,
    required this.onZoomChanged,
  });

  final String ref;
  final ValueNotifier<double> leaving;
  final VoidCallback onDismiss;
  final ValueChanged<bool> onZoomChanged;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final provider = avatarImage(
      ref,
      displaySize: media.size.longestSide,
      devicePixelRatio: media.devicePixelRatio,
    );
    return PhotoSurface(
      dismissProgress: leaving,
      onDismiss: onDismiss,
      onZoomChanged: onZoomChanged,
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
    state.avatarPoolIn(conversation, character.id).isNotEmpty;
