import 'package:flutter/material.dart';

import '../../../models/character.dart';
import '../../../models/character_scenario.dart';
import '../../../services/studio/studio_controller.dart';
import 'draft_header.dart';
import 'draft_widgets.dart';

/// The situations the card opens in: the card's own scenario (the one every
/// other app understands), then the character's per-greeting scenarios, each
/// naming which greetings it belongs to — tapped on and off as chips.
class DraftScenariosTab extends StatelessWidget {
  const DraftScenariosTab({super.key, required this.controller});

  final StudioController controller;

  Future<void> _add(BuildContext context) async {
    final name = await editDraftText(
      context,
      label: 'Scenario name',
      value: '',
      tall: false,
    );
    if (name == null || name.trim().isEmpty || !context.mounted) return;
    final text = await editDraftText(context, label: name.trim(), value: '');
    if (text == null || text.trim().isEmpty) return;
    controller.editByHand('Added scenario "${name.trim()}" by hand', (ws) {
      ws.character.scenarios.add(CharacterScenario(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: name.trim(),
        text: text.trim(),
      ));
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = controller.session.workspace.character;
    final state = controller.state;
    final locked = controller.running;
    return ListView(
      key: const PageStorageKey('draft-scenarios'),
      padding: EdgeInsets.only(bottom: 24 + MediaQuery.paddingOf(context).bottom),
      children: [
        DraftHeader(character: c),
        if (locked) const DraftLockedNote(),
        const DraftSectionLabel('The card\'s scenario'),
        DraftCard(children: [
          DraftFieldRow(
            key: const ValueKey('draft-card-scenario'),
            label: 'Scenario',
            subtitle: 'Sent with every greeting that has no scenario of its own.',
            value: c.scenario,
            tokens: c.scenario.trim().isEmpty ? null : state.estimateTokens(c.scenario),
            onEdit: locked
                ? null
                : () async {
                    final next = await editDraftText(
                      context,
                      label: 'Scenario',
                      value: c.scenario,
                    );
                    if (next == null) return;
                    controller.editByHand('Edited the scenario by hand',
                        (ws) => ws.character.scenario = next);
                  },
          ),
        ]),
        DraftSectionLabel('By greeting · ${c.scenarios.length}'),
        if (c.scenarios.isEmpty)
          const DraftEmpty(
            icon: Icons.theaters_outlined,
            text: 'No per-greeting scenarios. A card whose openings happen in '
                'different places can give each its own.',
          )
        else
          for (final s in c.scenarios)
            _ScenarioCard(
              key: ValueKey('draft-scenario-${s.id}'),
              character: c,
              scenario: s,
              tokens: state.estimateTokens(s.text),
              controller: controller,
              locked: locked,
            ),
        DraftAddButton(
          label: 'New scenario',
          onPressed: locked ? null : () => _add(context),
        ),
      ],
    );
  }
}

class _ScenarioCard extends StatelessWidget {
  const _ScenarioCard({
    super.key,
    required this.character,
    required this.scenario,
    required this.tokens,
    required this.controller,
    required this.locked,
  });

  final Character character;
  final CharacterScenario scenario;
  final int tokens;
  final StudioController controller;
  final bool locked;

  void _toggle(int greeting) {
    controller.editByHand(
      'Changed which greetings "${scenario.displayName}" covers',
      (ws) {
        for (final s in ws.character.scenarios) {
          if (s.id != scenario.id) continue;
          if (!s.greetings.remove(greeting)) s.greetings.add(greeting);
          s.greetings.sort();
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final greetings = character.greetings;
    return DraftCard(children: [
      DraftFieldRow(
        label: scenario.displayName,
        value: scenario.text,
        tokens: tokens,
        onEdit: locked
            ? null
            : () async {
                final next = await editDraftText(
                  context,
                  label: scenario.displayName,
                  value: scenario.text,
                );
                if (next == null) return;
                controller.editByHand(
                  'Edited scenario "${scenario.displayName}" by hand',
                  (ws) {
                    for (final s in ws.character.scenarios) {
                      if (s.id == scenario.id) s.text = next;
                    }
                  },
                );
              },
        trailing: IconButton(
          tooltip: 'Remove ${scenario.displayName}',
          onPressed: locked
              ? null
              : () => controller.editByHand(
                    'Removed scenario "${scenario.displayName}"',
                    (ws) => ws.character.scenarios
                        .removeWhere((s) => s.id == scenario.id),
                  ),
          icon: const Icon(Icons.delete_outline, size: 20),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              scenario.appliesToAll
                  ? 'Covers every greeting — pick some to narrow it.'
                  : 'Covers the greetings picked below.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 6),
            if (greetings.isEmpty)
              Text('The card has no greetings yet.',
                  style: theme.textTheme.bodySmall)
            else
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (var i = 0; i < greetings.length; i++)
                    FilterChip(
                      label: Text('Greeting ${i + 1}'),
                      selected: scenario.greetings.contains(i),
                      onSelected: locked ? null : (_) => _toggle(i),
                    ),
                ],
              ),
          ],
        ),
      ),
    ]);
  }
}
