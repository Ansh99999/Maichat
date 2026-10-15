import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../../models/character.dart';
import '../../../models/home_layout.dart';
import '../../../services/chat_graph.dart';
import '../../../state/app_state.dart';
import '../../../widgets/character_avatar.dart';
import '../../character_actions.dart';
import '../../chat_screen.dart';
import '../../chats_screen.dart' show relativeTime;
import '../home_spec.dart';

/// A pill search bar over chats and characters, like a phone's home search.
class SearchSpec extends HomeWidgetSpec {
  const SearchSpec();

  @override
  HomeWidgetKind get kind => HomeWidgetKind.search;

  @override
  String get title => 'Search';

  @override
  String get description => 'A search bar over chats and characters';

  @override
  IconData get icon => Icons.search;

  @override
  ({int w, int h}) get minSpan => (w: 2, h: 1);

  @override
  String describe(BuildContext context, HomeTile tile) => 'Search';

  @override
  Widget build(BuildContext context, HomeTileContext tile) {
    final state = context.watch<AppState>();
    final persona = state.defaultPersona;
    final theme = Theme.of(context);

    // A search bar is 56 dp tall whatever cell it sits in (Material 3), centred
    // in the rest; only a cell shorter than that squeezes it.
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 56),
        child: _bar(context, tile, persona, theme),
      ),
    );
  }

  Widget _bar(
    BuildContext context,
    HomeTileContext tile,
    Character? persona,
    ThemeData theme,
  ) {
    return Semantics(
      button: true,
      label: 'Search chats and characters',
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest,
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: tile.editing
              ? null
              : () => Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => const HomeSearchScreen()),
                  ),
          child: LayoutBuilder(
            builder: (context, c) {
              final h = c.maxHeight.isFinite ? c.maxHeight : 56.0;
              final pad = c.maxWidth < 96 ? 4.0 : (h >= 48 ? 16.0 : 10.0);
              final icon = (h - 8).clamp(14.0, 24.0);
              // Squeezed below its minimum span: just the glass, centred.
              if (c.maxWidth < icon + 12 + pad * 2 + 40) {
                return Center(
                  child: Icon(Icons.search_rounded,
                      size: icon, color: theme.colorScheme.onSurfaceVariant),
                );
              }
              final avatar = (h - 12).clamp(14.0, 32.0);
              final room = c.maxWidth - pad * 2 - icon - 12;
              final showAvatar = persona != null && room - avatar - 8 > 48;
              final showHint = room > 40;
              return Padding(
                padding: EdgeInsets.symmetric(horizontal: pad),
                child: HomeShrink(
                  size: Size(c.maxWidth - pad * 2, h),
                  alignment: AlignmentDirectional.centerStart,
                  child: Row(
                    children: [
                      Icon(Icons.search_rounded,
                          size: icon, color: theme.colorScheme.onSurfaceVariant),
                      const SizedBox(width: 12),
                      Expanded(
                        child: showHint
                            ? Text(
                                'Search chats and characters',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyLarge?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant),
                              )
                            : const SizedBox.shrink(),
                      ),
                      if (showAvatar) ...[
                        const SizedBox(width: 8),
                        CharacterAvatar(character: persona, size: avatar),
                      ],
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// A full-screen filter over characters (by name) and chats (title + last
/// message), live as the user types.
class HomeSearchScreen extends StatefulWidget {
  const HomeSearchScreen({super.key});

  @override
  State<HomeSearchScreen> createState() => _HomeSearchScreenState();
}

class _HomeSearchScreenState extends State<HomeSearchScreen> {
  final TextEditingController _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _openChat(AppState state, String id) {
    state.selectConversation(id);
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ChatScreen()),
    );
  }

  void _startChat(AppState state, Character character) {
    state.startChatWithCharacter(character);
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ChatScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final query = _query.trim().toLowerCase();

    final characters = query.isEmpty
        ? const <Character>[]
        : state.characters
            .where((c) => c.displayName.toLowerCase().contains(query))
            .toList();

    final chats = query.isEmpty
        ? const <ChatTreeEntry>[]
        : collapseForks(state.conversations.where((c) => !c.isEmpty)).where((t) {
            final title = t.root.title.toLowerCase();
            final last = t.latest.messages.isEmpty
                ? ''
                : t.latest.messages.last.content.toLowerCase();
            return title.contains(query) || last.contains(query);
          }).toList();

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Search chats and characters',
            border: InputBorder.none,
          ),
          onChanged: (v) => setState(() => _query = v),
        ),
      ),
      body: query.isEmpty
          ? const Center(child: Text('Type to search'))
          : ListView(
              children: [
                if (characters.isNotEmpty) ...[
                  const _ResultHeader('Characters'),
                  for (final c in characters)
                    ListTile(
                      leading: CharacterAvatar(character: c, radius: 20),
                      title: Text(c.displayName),
                      onTap: () => _startChat(state, c),
                      onLongPress: () => openCharacterDetail(context, c.id),
                    ),
                ],
                if (chats.isNotEmpty) ...[
                  const _ResultHeader('Chats'),
                  for (final t in chats)
                    ListTile(
                      leading: const Icon(Icons.chat_bubble_outline),
                      title: Text(
                        t.root.title.trim().isEmpty ? 'New chat' : t.root.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        relativeTime(t.latest.updatedAt),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => _openChat(state, t.latest.id),
                    ),
                ],
                if (characters.isEmpty && chats.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: Text('No results')),
                  ),
              ],
            ),
    );
  }
}

class _ResultHeader extends StatelessWidget {
  const _ResultHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(
          label,
          style: Theme.of(context)
              .textTheme
              .titleSmall
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
      );
}
