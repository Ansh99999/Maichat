import 'package:flutter/material.dart';

import '../../models/character.dart';
import '../../models/lorebook.dart';
import '../../services/studio/studio_controller.dart';
import '../../widgets/character_avatar.dart';
import 'studio_text_dialog.dart';

/// The draft as it stands: the card's fields with their token counts, the
/// greetings, scenarios, lorebooks and documents. Every text can be opened and
/// edited by hand; an edit is recorded as a change like the agent's own, so it
/// can be rewound, and the agent is told to re-read the draft before it builds
/// on anything.
class StudioDraftView extends StatelessWidget {
  const StudioDraftView({super.key, required this.controller});

  final StudioController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final ws = controller.session.workspace;
        final c = ws.character;
        final theme = Theme.of(context);
        final muted = theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
        final state = controller.state;
        final permanent = state.estimateTokens([
          c.description,
          c.personality,
          c.scenario,
          c.mesExample,
          c.systemPrompt,
          c.postHistoryInstructions,
        ].join('\n'));
        final locked = controller.running;

        Future<void> edit(
          String label,
          String value,
          void Function(Character c, String v) write,
        ) async {
          final next = await _editText(context, label, value);
          if (next == null || next == value) return;
          controller.editByHand('Edited the ${label.toLowerCase()} by hand',
              (ws) => write(ws.character, next));
        }

        Widget field(
          String label,
          String value,
          void Function(Character c, String v) write,
        ) =>
            _FieldTile(
              label: label,
              value: value,
              tokens: value.trim().isEmpty ? null : state.estimateTokens(value),
              onEdit: locked ? null : () => edit(label, value, write),
            );

        return ListView(
          padding: EdgeInsets.fromLTRB(
            0,
            12,
            0,
            24 + MediaQuery.paddingOf(context).bottom,
          ),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  CharacterAvatar(character: c, radius: 36),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          c.name.trim().isEmpty ? 'Not named yet' : c.name,
                          style: theme.textTheme.titleLarge,
                        ),
                        if (c.title.trim().isNotEmpty)
                          Text(c.title, style: muted),
                        const SizedBox(height: 4),
                        Text(
                          '$permanent permanent tokens · sent with every message',
                          style: muted,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (c.tags.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final t in c.tags)
                      Chip(label: Text(t), visualDensity: VisualDensity.compact),
                  ],
                ),
              ),
            if (locked)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Text('Hand edits wait until the Studio finishes.',
                    style: muted),
              ),
            const _Section('Card'),
            field('Name', c.name, (c, v) => c.name = v.trim()),
            field('Title', c.title, (c, v) {
              c.title = v.trim();
              c.titleShown = c.title.isNotEmpty;
            }),
            field('Description', c.description, (c, v) => c.description = v),
            field('Personality', c.personality, (c, v) => c.personality = v),
            field('Scenario', c.scenario, (c, v) => c.scenario = v),
            field('Example dialogue', c.mesExample, (c, v) => c.mesExample = v),
            field('System prompt', c.systemPrompt, (c, v) => c.systemPrompt = v),
            field('Post-history instructions', c.postHistoryInstructions,
                (c, v) => c.postHistoryInstructions = v),
            field('Creator notes', c.creatorNotes, (c, v) => c.creatorNotes = v),
            const _Section('Greetings'),
            field('First message', c.firstMes, (c, v) => c.firstMes = v),
            for (var i = 0; i < c.alternateGreetings.length; i++)
              field('Alternate greeting ${i + 1}', c.alternateGreetings[i],
                  (c, v) => c.alternateGreetings[i] = v),
            if (c.scenarios.isNotEmpty) ...[
              const _Section('Scenarios'),
              for (final s in c.scenarios)
                _FieldTile(
                  label: s.displayName,
                  subtitle: s.appliesToAll
                      ? 'Every greeting'
                      : 'Greetings ${s.greetings.map((g) => g + 1).join(', ')}',
                  value: s.text,
                  tokens: state.estimateTokens(s.text),
                  onEdit: locked
                      ? null
                      : () async {
                          final next =
                              await _editText(context, s.displayName, s.text);
                          if (next == null || next == s.text) return;
                          controller.editByHand(
                            'Edited scenario "${s.displayName}" by hand',
                            (ws) {
                              for (final x in ws.character.scenarios) {
                                if (x.id == s.id) x.text = next;
                              }
                            },
                          );
                        },
                ),
            ],
            const _Section('Lorebooks'),
            if (ws.lorebooks.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text('None yet.', style: muted),
              ),
            for (final book in ws.lorebooks)
              _BookTile(book: book, controller: controller, locked: locked),
            if (ws.documents.isNotEmpty) ...[
              const _Section('Documents'),
              for (final doc in ws.documents)
                _FieldTile(
                  label: doc.name,
                  subtitle: doc.libraryId == null ? 'Not indexed yet' : 'Indexed',
                  value: doc.text,
                  tokens: state.estimateTokens(doc.text),
                  onEdit: locked
                      ? null
                      : () async {
                          final next = await _editText(context, doc.name, doc.text);
                          if (next == null || next == doc.text) return;
                          controller.editByHand(
                            'Edited document "${doc.name}" by hand',
                            (ws) => ws.document(doc.id)?.text = next,
                          );
                        },
                ),
            ],
          ],
        );
      },
    );
  }
}

/// Opens [value] for editing and returns the new text, or null when cancelled.
Future<String?> _editText(BuildContext context, String label, String value) =>
    showStudioTextDialog(context, title: label, initial: value, tall: true);

class _Section extends StatelessWidget {
  const _Section(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Text(
        title.toUpperCase(),
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

/// One text of the draft: collapsed to a few lines, opened to all of it.
class _FieldTile extends StatefulWidget {
  const _FieldTile({
    required this.label,
    required this.value,
    this.subtitle,
    this.tokens,
    this.onEdit,
  });

  final String label;
  final String value;
  final String? subtitle;
  final int? tokens;
  final VoidCallback? onEdit;

  @override
  State<_FieldTile> createState() => _FieldTileState();
}

class _FieldTileState extends State<_FieldTile> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final empty = widget.value.trim().isEmpty;
    return InkWell(
      onTap: empty ? widget.onEdit : () => setState(() => _open = !_open),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(widget.label,
                            style: theme.textTheme.titleSmall,
                            overflow: TextOverflow.ellipsis),
                      ),
                      if (widget.tokens != null) ...[
                        const SizedBox(width: 8),
                        Text('${widget.tokens} tok', style: muted),
                      ],
                    ],
                  ),
                  if (widget.subtitle != null) Text(widget.subtitle!, style: muted),
                  const SizedBox(height: 2),
                  Text(
                    empty ? 'Empty' : widget.value.trim(),
                    maxLines: _open ? null : 3,
                    overflow: _open ? null : TextOverflow.ellipsis,
                    style: empty
                        ? muted?.copyWith(fontStyle: FontStyle.italic)
                        : theme.textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Edit ${widget.label.toLowerCase()}',
              icon: const Icon(Icons.edit_outlined, size: 20),
              onPressed: widget.onEdit,
            ),
          ],
        ),
      ),
    );
  }
}

class _BookTile extends StatelessWidget {
  const _BookTile({
    required this.book,
    required this.controller,
    required this.locked,
  });

  final Lorebook book;
  final StudioController controller;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final state = controller.state;
    final fromLibrary = state.lorebookById(book.id) != null;
    return ExpansionTile(
      leading: const Icon(Icons.menu_book_outlined),
      title: Text(book.displayName),
      subtitle: Text(
        '${book.entries.length} entr${book.entries.length == 1 ? 'y' : 'ies'}'
        '${fromLibrary ? ' · from your library' : ''}',
        style: muted,
      ),
      childrenPadding: const EdgeInsets.only(left: 8),
      children: [
        if (book.description.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(book.description, style: muted),
          ),
        for (final entry in book.entries)
          _FieldTile(
            label: entry.displayName,
            subtitle: entry.constant
                ? 'Always on'
                : 'Keys: ${entry.keys.join(', ')}'
                    '${entry.enabled ? '' : ' · off'}',
            value: entry.content,
            tokens: state.estimateTokens(entry.content),
            onEdit: locked
                ? null
                : () async {
                    final next =
                        await _editText(context, entry.displayName, entry.content);
                    if (next == null || next == entry.content) return;
                    controller.editByHand(
                      'Edited lore entry "${entry.displayName}" by hand',
                      (ws) {
                        for (final e in ws.lorebook(book.id)?.entries ??
                            const <LorebookEntry>[]) {
                          if (e.uid == entry.uid) e.content = next;
                        }
                      },
                    );
                  },
          ),
      ],
    );
  }
}
