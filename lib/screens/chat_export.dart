import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/conversation.dart';
import '../services/chat_codec.dart';
import '../state/app_state.dart';
import '../widgets/export_sheet.dart';

/// Writes a chat out as a file: pick the shape, then save it or copy it.
///
/// Three of the four shapes are read by SillyTavern *and* Agnai, which is the
/// point of offering more than one — the choice is really "how much of this
/// thread do I want to survive", not "which app is this for". See
/// [ChatExportFormat].
Future<void> exportChat(BuildContext context, Conversation conversation) async {
  final format = await showModalBottomSheet<ChatExportFormat>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
            child: Text(
              'EXPORT AS',
              style: Theme.of(sheetContext).textTheme.labelMedium?.copyWith(
                    color: Theme.of(sheetContext).colorScheme.primary,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
            ),
          ),
          for (final f in ChatExportFormat.values)
            ListTile(
              leading: Icon(switch (f) {
                ChatExportFormat.native => Icons.data_object_outlined,
                ChatExportFormat.sillyTavern => Icons.public_outlined,
                ChatExportFormat.agnai => Icons.smart_toy_outlined,
                ChatExportFormat.text => Icons.subject_outlined,
              }),
              title: Text(f.label),
              subtitle: Text(f.blurb),
              onTap: () => Navigator.of(sheetContext).pop(f),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (format == null || !context.mounted) return;

  // A bound character's own name beats the one denormalised onto the thread, and
  // an impersonated identity is what the user's turns are signed with — both
  // ecosystems put a display name on every single turn.
  final state = context.read<AppState>();
  final character = state.characterById(conversation.characterId);
  final safe = safeFileName(conversation.title);
  await offerExport(
    context,
    text: format.write(
      conversation,
      characterName: character?.displayName,
      userName: state.impersonationFor(conversation)?.displayName,
    ),
    fileName: '${safe.isEmpty ? 'chat' : safe}.${format.extension}',
    subtitle: format.label,
    dialogTitle: 'Save chat',
    extensions: [format.extension],
  );
}
