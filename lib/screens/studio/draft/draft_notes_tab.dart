import 'package:flutter/material.dart';

import '../../../services/studio/studio_controller.dart';
import '../../../widgets/message_markdown.dart';
import 'draft_widgets.dart';

/// The session's notes: the writing area where the agents — and the user —
/// keep research, findings, decisions and open questions while a character is
/// built. Read here in full and edited by hand like any other part of the
/// draft (a change, rewindable), but never applied: the notes are the
/// workbench, not the card.
class DraftNotesTab extends StatelessWidget {
  const DraftNotesTab({super.key, required this.controller});

  final StudioController controller;

  Future<void> _edit(BuildContext context) async {
    final next = await editDraftText(
      context,
      label: 'Notes',
      value: controller.session.workspace.notes,
    );
    if (next == null) return;
    controller.editByHand(
      'Edited the notes by hand',
      (ws) => ws.notes = next.trim(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final notes = controller.session.workspace.notes;
    final locked = controller.running;
    final empty = notes.trim().isEmpty;
    return ListView(
      key: const PageStorageKey('draft-notes'),
      padding: draftListPadding(context),
      children: [
        if (locked) const DraftLockedNote(),
        DraftSectionLabel(
          'Notes',
          count: empty ? null : controller.state.estimateTokens(notes),
          first: true,
        ),
        if (empty)
          const DraftEmpty(
            icon: Icons.edit_note,
            text: 'Research, findings and decisions land here as the Studio '
                'works — its sub-agents too. Write your own as well. The '
                'notes are never part of the character.',
          )
        else
          DraftCard(
            children: [
              Padding(
                key: const Key('draft-notes-body'),
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
                child: _NotesText(text: notes),
              ),
            ],
          ),
        DraftAddButton(
          key: const Key('draft-notes-edit'),
          label: empty ? 'Write notes' : 'Edit notes',
          icon: Icons.edit_outlined,
          onPressed: locked ? null : () => _edit(context),
        ),
      ],
    );
  }
}

/// Markdown notes, drawn calmly: headings as titles, the rest as message text.
class _NotesText extends StatelessWidget {
  const _NotesText({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final styles = MarkdownStyles(
      base: (theme.textTheme.bodyMedium ?? const TextStyle())
          .copyWith(color: scheme.onSurface, height: 1.5),
      emphasis: scheme.onSurface,
      quote: scheme.onSurfaceVariant,
      codeBackground: scheme.surfaceContainerHighest,
      codeForeground: scheme.onSurface,
      link: scheme.primary,
    );
    final heading = RegExp(r'^(#{1,6})\s+(.*)$');
    final blocks = <Widget>[];
    final para = <String>[];
    void flush() {
      final body = para.join('\n').trim();
      para.clear();
      if (body.isEmpty) return;
      blocks.add(Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: SelectableText.rich(
          TextSpan(children: buildMessageSpans(body, styles)),
        ),
      ));
    }

    for (final line in text.split('\n')) {
      final m = heading.firstMatch(line);
      if (m == null) {
        para.add(line);
        continue;
      }
      flush();
      final level = m.group(1)!.length;
      blocks.add(Padding(
        padding: EdgeInsets.only(top: blocks.isEmpty ? 0 : 10, bottom: 6),
        child: Text(
          m.group(2)!.trim(),
          style: (level <= 2
                  ? theme.textTheme.titleMedium
                  : theme.textTheme.titleSmall)
              ?.copyWith(color: scheme.onSurface),
        ),
      ));
    }
    flush();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: blocks,
    );
  }
}
