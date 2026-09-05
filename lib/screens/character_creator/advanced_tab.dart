import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../services/character_writer.dart';
import '../character_sheet_parts.dart';
import 'creator_controls.dart';
import 'creator_draft.dart';

/// The parts of a card that are instructions rather than description: what the
/// model is told about how to play this character, what it is reminded of last,
/// and what the author wants whoever downloads the card to know.
///
/// Every field here gets the same three things the persona fields do — a live
/// token count, a full-screen editor and the assistant — because these are the
/// fields most likely to be long and fiddly. The creator notes get a fourth: they
/// are the one field on a card that is written *for a human*, and cards routinely
/// design them in HTML and CSS, so there is a preview that renders them the way
/// the sheet will.
class AdvancedTab extends StatelessWidget {  const AdvancedTab({super.key});

  @override
  Widget build(BuildContext context) {
    final draft = context.watch<CreatorDraft>();
    return CreatorTabBody(
      children: [
        const CreatorLabel('Instructions to the model'),
        CreatorField(
          key: const Key('creator-system'),
          label: 'System prompt',
          controller: draft.systemPrompt,
          draft: draft,
          field: WritableField.systemPrompt,
          hint: 'How to play this character, and how to write the roleplay.',
          lines: 8,
        ),
        CreatorField(
          key: const Key('creator-post-history'),
          label: 'Post-history instructions',
          controller: draft.postHistory,
          draft: draft,
          field: WritableField.postHistory,
          hint: 'The reminder placed closest to the reply.',
          lines: 6,
        ),
        const Divider(height: 28),
        CreatorField(
          key: const Key('creator-example'),
          label: 'Example dialogue',
          controller: draft.example,
          draft: draft,
          field: WritableField.exampleDialogue,
          hint: '<START>\n{{char}}: …\n{{user}}: …',
          lines: 8,
        ),
        const Divider(height: 28),
        CreatorField(
          key: const Key('creator-notes'),
          label: 'Creator notes',
          controller: draft.notes,
          draft: draft,
          field: WritableField.creatorNotes,
          hint: 'What this card is, how to play it, what to expect. Never sent '
              'to the model.',
          lines: 8,
          previewKey: const Key('creator-notes-preview'),
          previewTooltip: 'Preview the notes',
          onPreview: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => NotesPreviewScreen(notes: draft.notes.text),
            ),
          ),
        ),
        CreatorLine(
          key: const Key('creator-author'),
          label: 'Creator',
          hint: 'Your name or handle',
          controller: draft.creator,
        ),
        CreatorLine(
          key: const Key('creator-version'),
          label: 'Card version',
          hint: '1.0',
          controller: draft.version,
        ),
      ],
    );
  }
}

/// The creator notes drawn as the sheet draws them — the same [NotesBlock], so
/// the HTML, the CSS, the images and the "read more" fold all behave identically.
class NotesPreviewScreen extends StatelessWidget {
  const NotesPreviewScreen({super.key, required this.notes});

  final String notes;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(
          'Creator notes',
          style: Theme.of(context)
              .textTheme
              .titleSmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ),
      body: SafeArea(
        top: false,
        child: notes.trim().isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    'Nothing written yet.',
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
              )
            : ListView(
                key: const Key('notes-preview-body'),
                padding: const EdgeInsets.only(bottom: 40),
                children: [NotesBlock(notes: notes)],
              ),
      ),
    );
  }
}
