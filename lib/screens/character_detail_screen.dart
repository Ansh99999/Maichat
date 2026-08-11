import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/character.dart';
import '../state/app_state.dart';
import '../widgets/character_avatar.dart';
import 'character_actions.dart';
import 'character_edit_screen.dart';

/// A character's page: a calm header (avatar, name, tags), the persona laid out
/// section by section, and the actions — start a chat, edit, export, duplicate,
/// delete. Reads live from [AppState] by id so edits reflect immediately.
class CharacterDetailScreen extends StatelessWidget {
  const CharacterDetailScreen({super.key, required this.characterId});

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

    return Scaffold(
      appBar: AppBar(
        title: Text(character.displayName, overflow: TextOverflow.ellipsis),
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
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => startCharacterChat(context, state, character),
        icon: const Icon(Icons.chat_bubble_outline),
        label: const Text('Start chat'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 96),
        children: [
          _Header(character: character),
          _Section('Description', character.description),
          _Section('Personality', character.personality),
          _Section('Scenario', character.scenario),
          _Section('Greeting', character.firstMes),
          if (character.alternateGreetings.isNotEmpty)
            _Section(
              'Alternate greetings',
              character.alternateGreetings
                  .asMap()
                  .entries
                  .map((e) => '${e.key + 1}. ${e.value}')
                  .join('\n\n'),
            ),
          _Section('Example dialogue', character.mesExample),
          _Section('System prompt', character.systemPrompt),
          _Section(
              'Post-history instructions', character.postHistoryInstructions),
          _Section('Creator notes', character.creatorNotes),
        ],
      ),
    );
  }
}

/// The header block: a large avatar, the name, provenance/creator line and the
/// tag chips.
class _Header extends StatelessWidget {
  const _Header({required this.character});

  final Character character;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final meta = <String>[
      character.format.label,
      if (character.creator.trim().isNotEmpty) 'by ${character.creator.trim()}',
    ].join(' · ');

    return Column(
      children: [
        const SizedBox(height: 8),
        CharacterAvatar(character: character, radius: 48),
        const SizedBox(height: 12),
        Text(
          character.displayName,
          textAlign: TextAlign.center,
          style: Theme.of(context)
              .textTheme
              .headlineSmall
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(
          meta,
          textAlign: TextAlign.center,
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
        if (character.tags.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final tag in character.tags)
                Chip(
                  label: Text(tag),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// A titled block of body text, hidden entirely when [body] is empty so the
/// page only shows what a card actually filled in.
class _Section extends StatelessWidget {
  const _Section(this.title, this.body);

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    if (body.trim().isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
          ),
          const SizedBox(height: 6),
          SelectableText(
            body.trim(),
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}
