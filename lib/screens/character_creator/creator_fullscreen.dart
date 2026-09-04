import 'package:flutter/material.dart';

import '../../services/character_writer.dart';
import 'creator_ai_sheet.dart';
import 'creator_controls.dart';
import 'creator_draft.dart';

/// Opens one field on a screen of its own, so a long description can be written
/// without the rest of the card, the tab bar and the portrait competing for the
/// display.
///
/// It edits the **same** controller the tab does, which is the whole trick: there
/// is nothing to apply and nothing to lose, and backing out is just backing out.
/// The token count and the assistant come along, because those are the two things
/// you want while you are actually writing.
Future<void> openFullscreenField(
  BuildContext context, {
  required String title,
  required TextEditingController controller,
  required CreatorDraft draft,
  WritableField? field,
  String? slot,
  VoidCallback? onChanged,
}) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FullscreenFieldScreen(
          title: title,
          controller: controller,
          draft: draft,
          field: field,
          slot: slot,
          onChanged: onChanged,
        ),
      ),
    );

class FullscreenFieldScreen extends StatelessWidget {
  const FullscreenFieldScreen({
    super.key,
    required this.title,
    required this.controller,
    required this.draft,
    this.field,
    this.slot,
    this.onChanged,
  });

  final String title;
  final TextEditingController controller;
  final CreatorDraft draft;
  final WritableField? field;
  final String? slot;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    final target = field;
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Center(child: TokenCount(controller: controller)),
          ),
          if (target != null)
            IconButton(
              tooltip: 'Let the AI write this',
              icon: const Icon(Icons.auto_awesome_outlined),
              onPressed: () => showWriterSheet(
                context,
                draft: draft,
                field: target,
                controller: controller,
                slot: slot,
                fieldLabel: title,
              ),
            ),
          IconButton(
            tooltip: 'Done',
            icon: const Icon(Icons.check),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: TextField(
            key: const Key('creator-fullscreen-field'),
            controller: controller,
            autofocus: true,
            // The field *is* the screen: it takes all the room there is and
            // scrolls inside itself, so the cursor never leaves the display.
            expands: true,
            maxLines: null,
            minLines: null,
            keyboardType: TextInputType.multiline,
            textCapitalization: TextCapitalization.sentences,
            textAlignVertical: TextAlignVertical.top,
            onChanged: (_) => onChanged?.call(),
            decoration: const InputDecoration(
              border: InputBorder.none,
              hintText: 'Write here.',
            ),
          ),
        ),
      ),
    );
  }
}
