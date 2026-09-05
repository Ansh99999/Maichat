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
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      // As bare as a bar can be while still holding a back arrow. This screen
      // exists to leave you alone with the words: the field's name is a quiet
      // label rather than a title, the token count has moved to the foot of the
      // page, and there is no Done button because backing out *is* done — the
      // controller is the tab's own, so there was never anything to apply.
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        titleSpacing: 0,
        title: Text(
          title,
          style: Theme.of(context)
              .textTheme
              .titleSmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
        actions: [
          if (target != null)
            IconButton(
              tooltip: 'Let the AI write this',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.auto_awesome_outlined, size: 20),
              onPressed: () => showWriterSheet(
                context,
                draft: draft,
                field: target,
                controller: controller,
                slot: slot,
                fieldLabel: title,
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
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
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 2, 20, 6),
              child: Align(
                alignment: Alignment.centerRight,
                child: TokenCount(controller: controller),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
