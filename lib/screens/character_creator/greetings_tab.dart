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
/// is eight long texts and only one of them is being worked on at a time. A fold
/// names its greeting **once**, and while it is open its header carries the three
/// things you can do to the words plus the one only a greeting needs — a preview,
/// drawn as the chat will draw it.
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
      children: [
        for (var i = 0; i < draft.greetings.length; i++)
          _GreetingFold(
            key: ValueKey(draft.greetings[i]),
            draft: draft,
            index: i,
            expanded: _open == i,
            onExpand: (open) => setState(() => _open = open ? i : -1),
            onRemove: draft.greetings.length == 1
                ? null
                : () async {
                    final gone = await confirmRemoval(
                      context,
                      title: 'Remove this greeting?',
                      message:
                          '${CharacterScenario.greetingLabel(i)} and what is '
                          'written in it will be gone.',
                    );
                    if (!gone || !context.mounted) return;
                    draft.removeGreeting(i);
                    setState(() => _open = 0);
                  },
          ),
        const SizedBox(height: 14),
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

class _GreetingFold extends StatelessWidget {
  const _GreetingFold({
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
    final controller = draft.greetings[index];
    return CreatorFold(
      title: _label,
      // Only read while the fold is closed, and a closed fold cannot be typed
      // into — so this is right without the tab having to rebuild per keystroke.
      preview: controller.text.replaceAll(RegExp(r'\s+'), ' ').trim(),
      expanded: expanded,
      onExpand: onExpand,
      actions: (progress) => CreatorFieldActions(
        progress: progress,
        title: _label,
        controller: controller,
        draft: draft,
        field: WritableField.greeting,
        slot: 'greeting:$index',
        previewKey: Key('creator-preview-greeting-$index'),
        previewTooltip: 'Preview it as a message',
        onPreview: () => openGreetingPreview(
          context,
          character: draft.snapshot(),
          text: controller.text,
          label: _label,
        ),
      ),
      child: CreatorField(
        controller: controller,
        draft: draft,
        field: WritableField.greeting,
        slot: 'greeting:$index',
        hint: 'How they open the conversation.',
        lines: 9,
        footer: onRemove == null
            ? null
            : TextButton.icon(
                key: Key('creator-remove-greeting-$index'),
                onPressed: onRemove,
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('Remove'),
              ),
      ),
    );
  }
}
