import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/character.dart';
import '../../state/app_state.dart';
import '../../widgets/avatar_image.dart';
import 'gallery_screen.dart';

/// Whose gallery, when the chat sidebar's Gallery is opened in a group.
///
/// A one-to-one chat skips this and goes straight into the album — asking "whose
/// pictures?" when there is only one answer is a screen for nothing. Reached from
/// the chat, so a picture opened from here can be sent to the conversation.
class ChatGalleryScreen extends StatelessWidget {
  const ChatGalleryScreen({super.key, required this.conversationId});

  final String conversationId;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final conversation = state.conversationById(conversationId);
    final members = <Character>[
      for (final id in conversation?.memberIds ?? const <String>[])
        if (state.characterFor(conversation, id) != null)
          state.characterFor(conversation, id)!,
    ];

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          const SliverAppBar.large(title: Text('Gallery')),
          if (members.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: _NoCharacters(),
            )
          else ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  'Characters involved',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
            ),
            SliverList.builder(
              itemCount: members.length,
              itemBuilder: (context, i) => _MemberRow(
                character: members[i],
                count: state.galleryCountFor(members[i].id),
                onTap: () => _openAlbum(context, members[i].id),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
            // Everything, in case the picture wanted belongs to somebody who is
            // not in this conversation (or to nobody at all).
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                child: OutlinedButton.icon(
                  onPressed: () => _openAlbum(context, null, everything: true),
                  icon: const Icon(Icons.photo_library_outlined),
                  label: const Text('All pictures'),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _openAlbum(
    BuildContext context,
    String? characterId, {
    bool everything = false,
  }) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => GalleryScreen(
        mode: everything ? GalleryMode.everything : GalleryMode.chat,
        characterId: characterId,
        // Carried into "All pictures" too: the conversation is what makes "send
        // to chat" possible, and it is the reason this route exists.
        conversationId: conversationId,
      ),
    ));
  }
}

/// Opens the gallery for a chat: straight into the album in a one-to-one thread,
/// or the "whose gallery?" list when several characters are involved.
void openChatGallery(BuildContext context, String conversationId) {
  final state = context.read<AppState>();
  final conversation = state.conversationById(conversationId);
  final members = conversation?.memberIds ?? const <String>[];

  Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => members.length == 1
        ? GalleryScreen(
            mode: GalleryMode.chat,
            characterId: members.single,
            conversationId: conversationId,
          )
        : ChatGalleryScreen(conversationId: conversationId),
  ));
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({
    required this.character,
    required this.count,
    required this.onTap,
  });

  final Character character;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final provider = avatarImage(character.avatar, displaySize: 44);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      leading: CircleAvatar(
        radius: 22,
        backgroundColor: scheme.secondaryContainer,
        foregroundImage: provider,
        child: provider == null
            ? Text(
                character.displayName.characters.firstOrNull?.toUpperCase() ??
                    '?',
                style: TextStyle(color: scheme.onSecondaryContainer),
              )
            : null,
      ),
      title: Text(character.displayName,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(count == 0
          ? 'No pictures yet'
          : '$count picture${count == 1 ? '' : 's'}'),
      trailing: const Icon(Icons.photo_library_outlined),
      onTap: onTap,
    );
  }
}

class _NoCharacters extends StatelessWidget {
  const _NoCharacters();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 0, 32, 64),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.person_off_outlined, size: 48, color: scheme.outline),
            const SizedBox(height: 12),
            Text(
              'This chat has no character attached, so there is no album to '
              'open. Add one in Chat settings.',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
