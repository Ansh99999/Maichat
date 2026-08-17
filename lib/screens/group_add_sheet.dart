import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../models/character.dart';
import '../state/app_state.dart';
import '../widgets/character_avatar.dart';
import 'character_edit_screen.dart';

/// Opens the "add characters to this group" sheet: a bottom sheet that rises to
/// three-quarters of the screen, with a search field, a tag filter, and a `+`
/// in the top-right for spinning up a fresh character on the spot. Tapping a
/// row toggles that character's membership of [conversationId], so the same
/// sheet both adds and removes.
Future<void> showGroupAddSheet(
  BuildContext context, {
  required String conversationId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => FractionallySizedBox(
      heightFactor: 0.75,
      child: _GroupAddSheet(conversationId: conversationId),
    ),
  );
}

class _GroupAddSheet extends StatefulWidget {
  const _GroupAddSheet({required this.conversationId});

  final String conversationId;

  @override
  State<_GroupAddSheet> createState() => _GroupAddSheetState();
}

class _GroupAddSheetState extends State<_GroupAddSheet> {
  String _query = '';
  final Set<String> _tagFilter = <String>{};

  List<String> _allTags(List<Character> characters) {
    final tags = <String>{};
    for (final c in characters) {
      tags.addAll(c.tags);
    }
    final sorted = tags.toList()..sort();
    return sorted;
  }

  List<Character> _filtered(List<Character> characters) {
    final q = _query.trim().toLowerCase();
    return characters.where((c) {
      if (_tagFilter.isNotEmpty && !_tagFilter.every((t) => c.tags.contains(t))) {
        return false;
      }
      if (q.isEmpty) return true;
      return c.displayName.toLowerCase().contains(q) ||
          c.blurb.toLowerCase().contains(q) ||
          c.tags.any((t) => t.toLowerCase().contains(q));
    }).toList();
  }

  /// Routes to the character creator; a saved character is added to the group
  /// straight away, so "create a temporary character" lands them in the chat.
  Future<void> _createCharacter() async {
    final state = context.read<AppState>();
    final created = await Navigator.of(context).push<Character>(
      MaterialPageRoute<Character>(
        builder: (_) => const CharacterEditScreen(),
      ),
    );
    if (created != null) {
      await state.addParticipant(widget.conversationId, created);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final conversation = state.conversationById(widget.conversationId);
    final members = conversation?.memberIds.toSet() ?? <String>{};
    final all = state.characters;
    final tags = _allTags(all);
    final list = _filtered(all);
    final scheme = Theme.of(context).colorScheme;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Text('Add characters',
                    style: Theme.of(context).textTheme.titleLarge),
              ),
              IconButton(
                tooltip: 'Create a temporary character',
                onPressed: _createCharacter,
                icon: const Icon(Icons.add),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: SearchBar(
            hintText: 'Search characters',
            leading: const Icon(Icons.search),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        if (tags.isNotEmpty)
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                for (final tag in tags)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text(tag),
                      selected: _tagFilter.contains(tag),
                      onSelected: (on) => setState(() {
                        if (on) {
                          _tagFilter.add(tag);
                        } else {
                          _tagFilter.remove(tag);
                        }
                      }),
                    ),
                  ),
              ],
            ),
          ),
        const Divider(height: 1),
        Expanded(
          child: list.isEmpty
              ? Center(
                  child: Text('No characters found',
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: list.length,
                  itemBuilder: (context, i) {
                    final c = list[i];
                    final inGroup = members.contains(c.id);
                    return ListTile(
                      leading: CharacterAvatar(character: c, radius: 20),
                      title: Text(c.displayName, maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      subtitle: c.blurb.isEmpty
                          ? null
                          : Text(c.blurb,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: Icon(
                        inGroup
                            ? Icons.check_circle
                            : Icons.add_circle_outline,
                        color: inGroup ? scheme.primary : scheme.onSurfaceVariant,
                      ),
                      onTap: () {
                        if (inGroup) {
                          state.removeParticipant(widget.conversationId, c.id);
                        } else {
                          state.addParticipant(widget.conversationId, c);
                        }
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }
}
