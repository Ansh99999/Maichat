import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/character_scenario.dart';
import '../../services/character_writer.dart';
import 'creator_controls.dart';
import 'creator_draft.dart';
import 'greeting_preview_screen.dart';

/// The opening lines. The first is `first_mes`; the rest are the alternates a
/// chat swipes between.
///
/// Kept as folds rather than a wall of boxes, because a card with eight greetings
/// is eight long texts and only one of them is being worked on at a time. Each
/// fold carries the same three affordances every long field has, plus the one that
/// only a greeting needs: a preview, drawn as the chat will draw it.
class GreetingsTab extends StatefulWidget {
  const GreetingsTab({super.key});

  @override
  State<GreetingsTab> createState() => _GreetingsTabState();
}

class _GreetingsTabState extends State<GreetingsTab> {
  /// Which fold was opened last. It decides how a fold *being built* comes up —
  /// the greeting just added, or one the list scrolled away and had to rebuild —
  /// while a fold already on screen keeps whatever the reader last did to it.
  int _open = 0;

  @override
  Widget build(BuildContext context) {
    final draft = context.watch<CreatorDraft>();
    return CreatorTabBody(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
      children: [
        const CreatorNote(
          'The first one is what a new chat opens with. Add more and the chat can '
          'swipe between them — and a scenario can be attached to each.',
        ),
        for (var i = 0; i < draft.greetings.length; i++)
          _GreetingCard(
            key: ValueKey(draft.greetings[i]),
            draft: draft,
            index: i,
            expanded: _open == i,
            onExpand: (open) => setState(() => _open = open ? i : -1),
            onRemove: draft.greetings.length == 1
                ? null
                : () {
                    draft.removeGreeting(i);
                    setState(() => _open = 0);
                  },
          ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            key: const Key('creator-add-greeting'),
            onPressed: () {
              draft.addGreeting();
              setState(() => _open = draft.greetings.length - 1);
            },
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add a greeting'),
          ),
        ),
      ],
    );
  }
}

class _GreetingCard extends StatelessWidget {
  const _GreetingCard({
    super.key,
    required this.draft,
    required this.index,
    required this.expanded,
    required this.onExpand,
    required this.onRemove,
  });

  final CreatorDraft draft;
  final int index;
  final bool expanded;
  final ValueChanged<bool> onExpand;
  final VoidCallback? onRemove;

  String get _label => CharacterScenario.greetingLabel(index);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final controller = draft.greetings[index];
    final preview = controller.text.replaceAll(RegExp(r'\s+'), ' ').trim();

    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          // Deliberately no PageStorageKey, however idiomatic one looks on an
          // ExpansionTile: the tile stores its open/closed **bool** under the
          // page-storage identifier built from the keys above it, and every
          // consumer inside it resolves to that same identifier — including the
          // Scrollable inside the greeting's own text field, which reads the slot
          // as a `double?` scroll offset. With the key in place, opening a fold by
          // hand threw `type 'bool' is not a subtype of type 'double?'` out of
          // ScrollPosition.restoreScrollOffset and left the field unlaid-out.
          initiallyExpanded: expanded,
          onExpansionChanged: onExpand,
          tilePadding: const EdgeInsets.symmetric(horizontal: 14),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          title: Text(_label),
          subtitle: Text(
            preview.isEmpty ? 'Empty' : preview,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          children: [
            CreatorField(
              label: _label,
              aiLabel: _label,
              slot: 'greeting:$index',
              controller: controller,
              draft: draft,
              field: WritableField.greeting,
              hint: 'How they open the conversation.',
              minLines: 6,
              maxLines: 14,
              onChanged: draft.touch,
            ),
            Row(
              children: [
                FilledButton.tonalIcon(
                  key: Key('creator-preview-greeting-$index'),
                  onPressed: () => openGreetingPreview(
                    context,
                    character: draft.snapshot(),
                    text: controller.text,
                    label: _label,
                  ),
                  icon: const Icon(Icons.visibility_outlined, size: 18),
                  label: const Text('Preview'),
                ),
                const Spacer(),
                if (onRemove != null)
                  TextButton.icon(
                    key: Key('creator-remove-greeting-$index'),
                    onPressed: onRemove,
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Remove'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
