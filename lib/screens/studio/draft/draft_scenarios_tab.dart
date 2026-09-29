import 'package:flutter/material.dart';

import '../../../models/character.dart';
import '../../../models/character_scenario.dart';
import '../../../services/studio/studio_controller.dart';
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
      ws.character.scenarios.add(
        CharacterScenario(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          name: name.trim(),
          text: text.trim(),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = controller.session.workspace.character;
    final state = controller.state;
    final locked = controller.running;
    return ListView(
      key: const PageStorageKey('draft-scenarios'),
      padding: draftListPadding(context),
      children: [
        if (locked) const DraftLockedNote(),
        const DraftSectionLabel('The card\'s scenario', first: true),
        DraftCard(
          children: [
            DraftFieldRow(
              key: const ValueKey('draft-card-scenario'),
              label: 'Scenario',
              subtitle:
                  'Sent with every greeting that has no scenario of its own.',
              value: c.scenario,
              tokens: c.scenario.trim().isEmpty
                  ? null
                  : state.estimateTokens(c.scenario),
              onEdit: locked
                  ? null
                  : () async {
                      final next = await editDraftText(
                        context,
                        label: 'Scenario',
                        value: c.scenario,
                      );
                      if (next == null) return;
                      controller.editByHand(
                        'Edited the scenario by hand',
                        (ws) => ws.character.scenario = next,
                      );
                    },
            ),
          ],
        ),
        DraftSectionLabel('By greeting', count: c.scenarios.length),
        if (c.scenarios.isEmpty)
          const DraftEmpty(
            icon: Icons.theaters_outlined,
            text:
                'No per-greeting scenarios. A card whose openings happen in '
                'different places can give each its own.',
          )
        else
          for (final s in c.scenarios) ...[
            if (s != c.scenarios.first) const SizedBox(height: 16),
            _ScenarioCard(
              key: ValueKey('draft-scenario-${s.id}'),
              character: c,
              scenario: s,
              tokens: state.estimateTokens(s.text),
              controller: controller,
              locked: locked,
            ),
          ],
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

  /// The greetings this scenario covers, as a sheet of switches — every one
  /// shown with the first words of the greeting, so "Greeting 3" means
  /// something.
  Future<void> _pick(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) => ListenableBuilder(
      listenable: controller,
      builder: (sheet, _) {
        final current = controller.session.workspace.character.scenarios
            .where((s) => s.id == scenario.id)
            .firstOrNull;
        final greetings = controller.session.workspace.character.greetings;
        final theme = Theme.of(sheet);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(28, 0, 28, 4),
                  child: Text(
                    'Greetings it covers',
                    style: theme.textTheme.titleLarge,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(28, 0, 28, 12),
                  child: Text(
                    'None picked means every greeting.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (var i = 0; i < greetings.length; i++)
                        CheckboxListTile(
                          key: ValueKey('draft-scenario-greeting-$i'),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 28,
                          ),
                          value: current?.greetings.contains(i) ?? false,
                          onChanged: (_) => _toggle(i),
                          title: Text('Greeting ${i + 1}'),
                          subtitle: Text(
                            greetings[i],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final greetings = character.greetings;
    return DraftCard(
      children: [
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
                    (ws) => ws.character.scenarios.removeWhere(
                      (s) => s.id == scenario.id,
                    ),
                  ),
            icon: const Icon(Icons.delete_outline, size: 20),
          ),
        ),
        // Which greetings it covers: one line saying so, and the choice itself
        // behind a tap — a wall of chips on every card was the densest thing on
        // the page.
        InkWell(
          key: ValueKey('draft-scenario-covers-${scenario.id}'),
          onTap: locked || greetings.isEmpty ? null : () => _pick(context),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 12, 14),
            child: Row(
              children: [
                Icon(
                  Icons.waving_hand_outlined,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    greetings.isEmpty
                        ? 'The card has no greetings yet'
                        : scenario.appliesToAll
                        ? 'Covers every greeting'
                        : 'Covers greeting${scenario.greetings.length == 1 ? '' : 's'} '
                              '${scenario.greetings.map((g) => g + 1).join(', ')}',
                    style: theme.textTheme.bodyLarge,
                  ),
                ),
                if (greetings.isNotEmpty)
                  Icon(
                    Icons.chevron_right,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
