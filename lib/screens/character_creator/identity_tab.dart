import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../services/character_writer.dart';
import '../../state/app_state.dart';
import '../../widgets/tag_editor_sheet.dart';
import 'creator_ai_sheet.dart';
import 'creator_controls.dart';
import 'creator_draft.dart';

/// Who this character is: the optional one-line catcher, the name they are called
/// by, and the tags they are found under.
class IdentityTab extends StatelessWidget {
  const IdentityTab({super.key});

  @override
  Widget build(BuildContext context) {
    final draft = context.watch<CreatorDraft>();
    return CreatorTabBody(
      children: [
        CreatorLine(
          key: const Key('creator-name'),
          label: 'Character name',
          hint: 'Serina',
          controller: draft.name,
        ),
        _TitleSection(draft: draft),
        const Divider(height: 28),
        const CreatorLabel('Tags'),
        _TagsSection(draft: draft),
      ],
    );
  }
}

/// The title field, behind a switch.
///
/// It is off until it is wanted, because most cards do not have one and a blank
/// field above the name would be the first thing anybody saw. The switch is a
/// single quiet row rather than a dialog or a section of its own — "subtle, sleek
/// and non-disruptive" is the whole brief.
class _TitleSection extends StatelessWidget {
  const _TitleSection({required this.draft});

  final CreatorDraft draft;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          key: const Key('creator-title-toggle'),
          borderRadius: BorderRadius.circular(12),
          onTap: () => draft.setTitleShown(!draft.titleShown),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(Icons.short_text, size: 20, color: scheme.onSurfaceVariant),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Give them a title',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                Switch(
                  value: draft.titleShown,
                  onChanged: draft.setTitleShown,
                ),
              ],
            ),
          ),
        ),
        if (draft.titleShown) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('creator-title'),
                  controller: draft.title,
                  textCapitalization: TextCapitalization.sentences,
                  // One line, fixed: a field that grew to a second line as it was
                  // typed moved everything under it on the way.
                  maxLines: 1,
                  decoration: const InputDecoration(
                    labelText: 'Title',
                    hintText: 'A one-line catcher',
                  ),
                ),
              ),
              IconButton(
                key: const Key('creator-title-ai'),
                tooltip: 'Let the AI write this',
                icon: const Icon(Icons.auto_awesome_outlined),
                onPressed: () => showWriterSheet(
                  context,
                  draft: draft,
                  field: WritableField.title,
                  controller: draft.title,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

/// The tag chips, the way into the tag engine, and the way to have them written.
class _TagsSection extends StatelessWidget {
  const _TagsSection({required this.draft});

  final CreatorDraft draft;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final tags = draft.tags.toList()..sort();
    final known = <String>{
      for (final character in state.characters) ...character.tags,
    }.toList()
      ..sort();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final tag in tags)
              InputChip(
                label: Text(tag),
                onDeleted: () {
                  draft.tags.remove(tag);
                  draft.touch();
                },
              ),
            ActionChip(
              key: const Key('creator-tags-add'),
              avatar: const Icon(Icons.add, size: 18),
              label: const Text('Add'),
              onPressed: () => showTagEditorSheet(
                context,
                known: known,
                selected: draft.tags,
                onChanged: draft.touch,
                title: 'Tags for this character',
              ),
            ),
            ActionChip(
              key: const Key('creator-tags-ai'),
              avatar: const Icon(Icons.auto_awesome_outlined, size: 18),
              label: const Text('Write them for me'),
              onPressed: () => showWriterSheet(
                context,
                draft: draft,
                field: WritableField.tags,
                onList: (values) {
                  draft.tags.addAll(values);
                  draft.touch();
                },
              ),
            ),
          ],
        ),
        if (tags.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 10),
            child: CreatorNote('No tags yet.'),
          ),
      ],
    );
  }
}
