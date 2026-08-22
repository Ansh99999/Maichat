import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../models/character.dart';
import '../state/app_state.dart';
import '../widgets/character_avatar.dart';
import 'character_edit_screen.dart';

/// Opens the "default persona" picker: a bottom sheet that rises to
/// three-quarters of the screen, with a search field, a tag filter, and a `+`
/// in the top-right for creating a fresh persona on the spot. Picking a row
/// makes that character the persona new chats adopt as the user's identity; the
/// "Just me" row at the top clears it. Acts on [AppState] directly and pops.
Future<void> showPersonaPickerSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const FractionallySizedBox(
      heightFactor: 0.75,
      child: _PersonaPickerSheet(),
    ),
  );
}

class _PersonaPickerSheet extends StatefulWidget {
  const _PersonaPickerSheet();

  @override
  State<_PersonaPickerSheet> createState() => _PersonaPickerSheetState();
}

class _PersonaPickerSheetState extends State<_PersonaPickerSheet> {
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

  Future<void> _choose(String? id) async {
    await context.read<AppState>().setDefaultPersona(id);
    if (mounted) Navigator.of(context).pop();
  }

  /// Routes to the character creator (which saves to the roster), then makes the
  /// new card the default persona — "create a persona" lands you as it.
  Future<void> _createPersona() async {
    final navigator = Navigator.of(context);
    final state = context.read<AppState>();
    final created = await navigator.push<Character>(
      MaterialPageRoute<Character>(
        builder: (_) => const CharacterEditScreen(),
      ),
    );
    if (created == null) return;
    await state.setDefaultPersona(created.id);
    if (mounted) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final selectedId = state.defaultPersonaId;
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
                child: Text('Default persona',
                    style: Theme.of(context).textTheme.titleLarge),
              ),
              IconButton(
                tooltip: 'Create a persona',
                onPressed: _createPersona,
                icon: const Icon(Icons.add),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: SearchBar(
            hintText: 'Search personas',
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
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              // Speaking as yourself — the reset that clears any default persona.
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: scheme.secondaryContainer,
                  child: Icon(Icons.person_outline,
                      color: scheme.onSecondaryContainer),
                ),
                title: const Text('Just me'),
                subtitle: const Text('New chats start with no persona'),
                trailing: selectedId == null
                    ? Icon(Icons.check_circle, color: scheme.primary)
                    : null,
                onTap: () => _choose(null),
              ),
              if (list.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 32),
                  child: Center(
                    child: Text('No personas found',
                        style: TextStyle(color: scheme.onSurfaceVariant)),
                  ),
                )
              else
                for (final c in list)
                  ListTile(
                    leading: CharacterAvatar(character: c, radius: 20),
                    title: Text(c.displayName,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: c.blurb.isEmpty
                        ? null
                        : Text(c.blurb,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: c.id == selectedId
                        ? Icon(Icons.check_circle, color: scheme.primary)
                        : null,
                    onTap: () => _choose(c.id),
                  ),
            ],
          ),
        ),
      ],
    );
  }
}
