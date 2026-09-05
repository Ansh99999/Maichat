import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/character_scenario.dart';
import '../../services/character_writer.dart';
import '../../widgets/scenario_picker_sheet.dart';
import 'creator_controls.dart';
import 'creator_draft.dart';

/// The situations this character's chats can open in — as many as the card wants,
/// each attached to the greetings it belongs to.
///
/// This is the one place the app goes beyond both ecosystems it reads: a card
/// there has exactly one scenario, which is why a card with six alternate
/// greetings usually has one vague scenario covering all six. Here a scenario says
/// which greetings it is for, and `AppState.scenarioFor` picks the one that
/// matches the greeting a chat actually opened on.
class ScenariosTab extends StatefulWidget {
  const ScenariosTab({super.key});

  @override
  State<ScenariosTab> createState() => _ScenariosTabState();
}

class _ScenariosTabState extends State<ScenariosTab> {
  String? _open;

  @override
  Widget build(BuildContext context) {
    final draft = context.watch<CreatorDraft>();
    final greetings = draft.filledGreetings;

    return CreatorTabBody(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
      children: [
        const CreatorNote(
          'Where a chat starts. A scenario can cover every greeting, or belong to '
          'the ones it was written for — the chat uses whichever matches the '
          'greeting it opened on.',
        ),
        if (draft.scenarios.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 8, 4, 16),
            child: Text('No scenarios yet.'),
          ),
        for (final scenario in draft.scenarios)
          _ScenarioCard(
            key: ValueKey(scenario.id),
            draft: draft,
            scenario: scenario,
            greetings: greetings,
            expanded: _open == scenario.id || draft.scenarios.length == 1,
            onExpand: (open) =>
                setState(() => _open = open ? scenario.id : null),
            onRemove: () async {
              final named = scenario.name.text.trim();
              final gone = await confirmRemoval(
                context,
                title: 'Remove this scenario?',
                message: named.isEmpty
                    ? 'It will be taken off the card, text and all.'
                    : '"$named" will be taken off the card, text and all.',
              );
              if (!gone || !context.mounted) return;
              draft.removeScenario(scenario.id);
              setState(() => _open = null);
            },
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
              key: const Key('creator-add-scenario'),
              onPressed: () {
                final fresh = ScenarioDraft.blank();
                draft.addScenario(fresh);
                setState(() => _open = fresh.id);
              },
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Write a scenario'),
            ),
            OutlinedButton.icon(
              key: const Key('creator-scenario-library'),
              onPressed: () => _fromLibrary(context, draft),
              icon: const Icon(Icons.theater_comedy_outlined, size: 18),
              label: const Text('From the library'),
            ),
          ],
        ),
      ],
    );
  }

  /// Brings one in from the scenario library: the same browse → read → edit →
  /// proceed sheet the character sheet and chat settings use, so there is one
  /// place scenarios are chosen from and it behaves the same everywhere.
  Future<void> _fromLibrary(BuildContext context, CreatorDraft draft) async {
    final pick = await showScenarioPickerSheet(
      context,
      localLabel: draft.name.text.trim().isEmpty
          ? 'this character'
          : draft.name.text.trim(),
    );
    if (pick == null || pick.preview.trim().isEmpty) return;
    final fresh = ScenarioDraft(
      id: 'draft-${DateTime.now().microsecondsSinceEpoch}',
      text: pick.preview.trim(),
      scenarioId: pick.scenarioId,
    );
    draft.addScenario(fresh);
    setState(() => _open = fresh.id);
  }
}

class _ScenarioCard extends StatelessWidget {
  const _ScenarioCard({
    super.key,
    required this.draft,
    required this.scenario,
    required this.greetings,
    required this.expanded,
    required this.onExpand,
    required this.onRemove,
  });

  final CreatorDraft draft;
  final ScenarioDraft scenario;
  final List<String> greetings;
  final bool expanded;
  final ValueChanged<bool> onExpand;
  final VoidCallback onRemove;

  String get _title {
    final name = scenario.name.text.trim();
    if (name.isNotEmpty) return name;
    final body = scenario.text.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (body.isEmpty) return 'Untitled scenario';
    return body.length <= 42 ? body : '${body.substring(0, 42)}…';
  }

  String get _scope {
    if (scenario.greetings.isEmpty) return 'Every greeting';
    final named = scenario.greetings.toList()..sort();
    return named.map(CharacterScenario.greetingLabel).join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: expanded,
          onExpansionChanged: onExpand,
          tilePadding: const EdgeInsets.symmetric(horizontal: 14),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          title: Text(_title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            _scope,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          children: [
            TextField(
              controller: scenario.name,
              textCapitalization: TextCapitalization.sentences,
              onChanged: (_) => draft.touch(),
              decoration: const InputDecoration(
                labelText: 'Name (optional)',
                hintText: 'What you call this opening',
                isDense: true,
              ),
            ),
            const SizedBox(height: 14),
            CreatorField(
              label: 'Scenario',
              aiLabel: 'Scenario',
              slot: 'scenario:${scenario.id}',
              controller: scenario.text,
              draft: draft,
              field: WritableField.scenario,
              hint: 'Where they are, what is happening, why they are together.',
              minLines: 5,
              maxLines: 12,
              onChanged: draft.touch,
            ),
            const CreatorLabel('Applies to'),
            _GreetingChips(
              draft: draft,
              scenario: scenario,
              greetings: greetings,
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: onRemove,
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('Remove'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Which greetings a scenario belongs to. "Every greeting" is the empty set, so a
/// card that has never thought about it behaves exactly as a single-scenario card
/// always did.
class _GreetingChips extends StatelessWidget {
  const _GreetingChips({
    required this.draft,
    required this.scenario,
    required this.greetings,
  });

  final CreatorDraft draft;
  final ScenarioDraft scenario;
  final List<String> greetings;

  @override
  Widget build(BuildContext context) {
    if (greetings.isEmpty) {
      return const CreatorNote(
        'Write a greeting first and you can attach this scenario to it.',
      );
    }
    final all = scenario.greetings.isEmpty;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        FilterChip(
          key: const Key('scenario-scope-all'),
          label: const Text('Every greeting'),
          selected: all,
          onSelected: (_) {
            scenario.greetings.clear();
            draft.touch();
          },
        ),
        for (var i = 0; i < greetings.length; i++)
          FilterChip(
            key: Key('scenario-scope-$i'),
            label: Text(CharacterScenario.greetingLabel(i)),
            selected: scenario.greetings.contains(i),
            onSelected: (on) {
              if (on) {
                scenario.greetings.add(i);
              } else {
                scenario.greetings.remove(i);
              }
              draft.touch();
            },
          ),
      ],
    );
  }
}
