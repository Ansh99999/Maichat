import 'package:flutter/material.dart';

import '../../../models/character.dart';
import '../../../services/studio/studio_controller.dart';
import 'draft_header.dart';
import 'draft_widgets.dart';

/// A text field of the card as the Character tab lists it.
class _Field {
  const _Field(this.label, this.read, this.write, {this.long = true});

  final String label;
  final String Function(Character c) read;
  final void Function(Character c, String v) write;
  final bool long;
}

/// The fields after Title, Tags and Name, in the order the card is read.
final List<_Field> _fields = [
  _Field('Personality', (c) => c.personality, (c, v) => c.personality = v),
  _Field('Description', (c) => c.description, (c, v) => c.description = v),
  _Field('Scenario', (c) => c.scenario, (c, v) => c.scenario = v),
  _Field('First message', (c) => c.firstMes, (c, v) => c.firstMes = v),
];

final List<_Field> _laterFields = [
  _Field('Example dialogue', (c) => c.mesExample, (c, v) => c.mesExample = v),
  _Field('System prompt', (c) => c.systemPrompt, (c, v) => c.systemPrompt = v),
  _Field('Post-history instructions', (c) => c.postHistoryInstructions,
      (c, v) => c.postHistoryInstructions = v),
  _Field('Creator notes', (c) => c.creatorNotes, (c, v) => c.creatorNotes = v),
  _Field('Creator', (c) => c.creator, (c, v) => c.creator = v.trim(),
      long: false),
  _Field('Version', (c) => c.characterVersion,
      (c, v) => c.characterVersion = v.trim(), long: false),
];

/// The card itself: the picture and identity at the top, then Title, Tags,
/// Name, Personality and every other field of the card, each folded to a line
/// with a chevron to open it and a pencil to edit it. Lorebooks, scenarios and
/// documents have tabs of their own.
class DraftCharacterTab extends StatelessWidget {
  const DraftCharacterTab({super.key, required this.controller});

  final StudioController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller.session.workspace.character;
    final state = controller.state;
    final locked = controller.running;
    int? tokens(String text) =>
        text.trim().isEmpty ? null : state.estimateTokens(text);

    VoidCallback? edit(_Field f) => locked
        ? null
        : () async {
            final next = await editDraftText(
              context,
              label: f.label,
              value: f.read(c),
              tall: f.long,
            );
            if (next == null) return;
            controller.editByHand(
              'Edited the ${f.label.toLowerCase()} by hand',
              (ws) => f.write(ws.character, next),
            );
          };

    Widget row(_Field f) => DraftFieldRow(
          key: ValueKey('draft-field-${f.label}'),
          label: f.label,
          value: f.read(c),
          tokens: f.long ? tokens(f.read(c)) : null,
          foldable: f.long,
          onEdit: edit(f),
        );

    final title = _Field('Title', (c) => c.title, (c, v) {
      c.title = v.trim();
      c.titleShown = c.title.isNotEmpty;
    }, long: false);
    final name = _Field('Name', (c) => c.name, (c, v) => c.name = v.trim(),
        long: false);

    final permanent = state.estimateTokens([
      c.description,
      c.personality,
      c.scenario,
      c.mesExample,
      c.systemPrompt,
      c.postHistoryInstructions,
    ].join('\n'));

    return ListView(
      key: const PageStorageKey('draft-character'),
      padding: EdgeInsets.only(bottom: 24 + MediaQuery.paddingOf(context).bottom),
      children: [
        DraftHeader(character: c),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
          child: Text(
            '$permanent permanent tokens · sent with every message',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ),
        if (locked) const DraftLockedNote(),
        const SizedBox(height: 8),
        DraftCard(children: [
          row(title),
          _TagsRow(controller: controller, locked: locked),
          row(name),
        ]),
        const SizedBox(height: 8),
        DraftCard(children: [for (final f in _fields) row(f)]),
        if (c.alternateGreetings.isNotEmpty) ...[
          const DraftSectionLabel('Alternate greetings'),
          DraftCard(children: [
            for (var i = 0; i < c.alternateGreetings.length; i++)
              DraftFieldRow(
                key: ValueKey('draft-greeting-$i'),
                label: 'Alternate greeting ${i + 1}',
                value: c.alternateGreetings[i],
                tokens: tokens(c.alternateGreetings[i]),
                onEdit: locked
                    ? null
                    : () async {
                        final next = await editDraftText(
                          context,
                          label: 'Alternate greeting ${i + 1}',
                          value: c.alternateGreetings[i],
                        );
                        if (next == null) return;
                        controller.editByHand(
                          'Edited alternate greeting ${i + 1} by hand',
                          (ws) {
                            final list = ws.character.alternateGreetings;
                            if (i < list.length) list[i] = next;
                          },
                        );
                      },
              ),
          ]),
        ],
        const SizedBox(height: 8),
        DraftCard(children: [for (final f in _laterFields) row(f)]),
      ],
    );
  }
}

/// The Tags row: the chips as one sliding line, and a pencil that edits them as
/// a comma-separated list.
class _TagsRow extends StatelessWidget {
  const _TagsRow({required this.controller, required this.locked});

  final StudioController controller;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tags = controller.session.workspace.character.tags;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Tags',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                tooltip: 'Edit tags',
                onPressed: locked
                    ? null
                    : () async {
                        final next = await editDraftText(
                          context,
                          label: 'Tags (comma-separated)',
                          value: tags.join(', '),
                          tall: false,
                        );
                        if (next == null) return;
                        final list = next
                            .split(',')
                            .map((t) => t.trim().toLowerCase())
                            .where((t) => t.isNotEmpty)
                            .toSet()
                            .toList();
                        controller.editByHand(
                          'Edited the tags by hand',
                          (ws) => ws.character.tags = list,
                        );
                      },
                icon: const Icon(Icons.edit_outlined, size: 20),
              ),
            ],
          ),
          if (tags.isEmpty)
            Text(
              'Empty',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: DraftTagStrip(tags: tags),
            ),
        ],
      ),
    );
  }
}
