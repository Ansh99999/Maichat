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

    return CreatorTabBody(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
      children: [
        if (draft.scenarios.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 8, 4, 16),
            child: Text('No scenarios yet.'),
          ),
        for (var i = 0; i < draft.scenarios.length; i++)
          _ScenarioFold(
            key: ValueKey(draft.scenarios[i].id),
            draft: draft,
            scenario: draft.scenarios[i],
            index: i,
            expanded: _open == draft.scenarios[i].id ||
                draft.scenarios.length == 1,
            onExpand: (open) =>
                setState(() => _open = open ? draft.scenarios[i].id : null),
            onRemove: () async {
              final scenario = draft.scenarios[i];
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

class _ScenarioFold extends StatelessWidget {
  const _ScenarioFold({
    super.key,
    required this.draft,
    required this.scenario,
    required this.index,
    required this.expanded,
    required this.onExpand,
    required this.onRemove,
  });

  final CreatorDraft draft;
  final ScenarioDraft scenario;
  final int index;
  final bool expanded;
  final ValueChanged<bool> onExpand;
  final VoidCallback onRemove;

  /// What it is called, or where it sits. Deliberately *not* the first words of
  /// the scenario itself: a title taken from the body would have to be recomputed
  /// on every keystroke, which means rebuilding the whole tab to keep a heading in
  /// step with the box under it.
  String get _title {
    final name = scenario.name.text.trim();
    return name.isEmpty ? 'Scenario ${index + 1}' : name;
  }

  @override
  Widget build(BuildContext context) {
    const label = 'Scenario';
    return CreatorFold(
      title: _title,
      preview: scenario.text.text.replaceAll(RegExp(r'\s+'), ' ').trim(),
      expanded: expanded,
      onExpand: onExpand,
      actions: CreatorFieldActions(
        title: label,
        controller: scenario.text,
        draft: draft,
        field: WritableField.scenario,
        slot: 'scenario:${scenario.id}',
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: scenario.name,
            maxLines: 1,
            textCapitalization: TextCapitalization.sentences,
            // The one field here that does notify: the fold's own heading is this
            // text, so it has to be redrawn as the name is typed.
            onChanged: (_) => draft.touch(),
            decoration: const InputDecoration(
              labelText: 'Name (optional)',
              hintText: 'What you call this opening',
              isDense: true,
            ),
          ),
          const CreatorLabel('Applies to'),
          _GreetingChips(draft: draft, scenario: scenario),
          const SizedBox(height: 12),
          CreatorField(
            controller: scenario.text,
            draft: draft,
            field: WritableField.scenario,
            slot: 'scenario:${scenario.id}',
            hint: 'Where they are, what is happening, why they are together.',
            lines: 8,
            footer: TextButton.icon(
              key: Key('creator-remove-scenario-$index'),
              onPressed: onRemove,
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('Remove'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Which greetings a scenario belongs to. "Every greeting" is the empty set, so a
/// card that has never thought about it behaves exactly as a single-scenario card
/// always did.
///
/// The chips follow the greetings live — through the greeting controllers
/// themselves rather than through a notification from the draft, so writing a
/// greeting on the tab before this one costs a rebuild of these chips and nothing
/// else.
class _GreetingChips extends StatelessWidget {
  const _GreetingChips({required this.draft, required this.scenario});

  final CreatorDraft draft;
  final ScenarioDraft scenario;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: Listenable.merge(draft.greetings),
        builder: (context, _) {
          final greetings = draft.filledGreetings;
          if (greetings.isEmpty) {
            return const CreatorNote(
              'Write a greeting first and you can attach this scenario to it.',
            );
          }
          return Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilterChip(
                key: const Key('scenario-scope-all'),
                label: const Text('Every greeting'),
                selected: scenario.greetings.isEmpty,
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
        },
      );
}
