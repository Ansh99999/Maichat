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
          _ChatInfoCard(state: state),
          _ExpandableSection('Description', character.description),
          _ExpandableSection('Personality', character.personality),
          _ExpandableSection('Scenario', character.scenario),
          _ExpandableSection('Greeting', character.firstMes),
          if (character.alternateGreetings.isNotEmpty)
            _ExpandableSection(
              'Alternate greetings',
              character.alternateGreetings
                  .asMap()
                  .entries
                  .map((e) => '${e.key + 1}. ${e.value}')
                  .join('\n\n'),
            ),
          _ExpandableSection('Example dialogue', character.mesExample),
          _ExpandableSection('System prompt', character.systemPrompt),
          _ExpandableSection(
              'Post-history instructions', character.postHistoryInstructions),
          _ExpandableSection('Creator notes', character.creatorNotes),
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

/// A compact "For this chat" summary: which provider (and preset) a chat
/// started from this character will run under.
class _ChatInfoCard extends StatelessWidget {
  const _ChatInfoCard({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = state.activeProvider;
    final model = active?.model.trim() ?? '';
    final providerText = active == null
        ? 'No provider set up'
        : '${active.displayName}${model.isEmpty ? '' : ' · $model'}';

    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Card(
        elevation: 0,
        color: scheme.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'FOR THIS CHAT',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                    ),
              ),
              const SizedBox(height: 10),
              _row(context, Icons.dns_outlined, 'Provider', providerText),
              const SizedBox(height: 8),
              _row(context, Icons.tune_outlined, 'Preset', 'Default'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(
      BuildContext context, IconData icon, String label, String value) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, size: 18, color: scheme.onSurfaceVariant),
        const SizedBox(width: 10),
        Text('$label: ',
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: scheme.onSurfaceVariant)),
        Expanded(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

/// A titled block of body text, hidden entirely when [body] is empty. Long text
/// collapses to a few lines behind a "Read more" toggle so one field can't take
/// over the whole page.
class _ExpandableSection extends StatefulWidget {
  const _ExpandableSection(this.title, this.body);

  final String title;
  final String body;

  @override
  State<_ExpandableSection> createState() => _ExpandableSectionState();
}

class _ExpandableSectionState extends State<_ExpandableSection> {
  bool _expanded = false;

  static const int _collapsedLines = 5;
  static const int _threshold = 200;

  @override
  Widget build(BuildContext context) {
    final body = widget.body.trim();
    if (body.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final isLong = body.length > _threshold ||
        '\n'.allMatches(body).length >= _collapsedLines;
    final collapsed = isLong && !_expanded;

    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.title.toUpperCase(),
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
          ),
          const SizedBox(height: 6),
          AnimatedSize(
            duration: const Duration(milliseconds: 150),
            alignment: Alignment.topCenter,
            child: Text(
              body,
              maxLines: collapsed ? _collapsedLines : null,
              overflow:
                  collapsed ? TextOverflow.ellipsis : TextOverflow.clip,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          if (isLong)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () => setState(() => _expanded = !_expanded),
                child: Text(_expanded ? 'Read less' : 'Read more'),
              ),
            ),
        ],
      ),
    );
  }
}
