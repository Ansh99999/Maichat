import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/character.dart';
import '../services/chat_codec.dart';
import '../state/app_state.dart';
import '../widgets/brand_mark.dart';

/// Brings chats in from the other apps: pick one or more files (or paste), see
/// what was recognised, choose which character the thread belongs to, and file
/// it at the top of the list.
///
/// The character step matters more than it looks. A chat log is only a
/// transcript — the persona that makes a reply sound right lives on the
/// character — so an imported thread is only continuable once it is bound to
/// one. It is optional, because reading an old log is worth something on its own.
///
/// [preselectCharacterId] is the character to offer by default, which is how the
/// per-character chat list imports straight into the character it is showing.
Future<void> importChats(
  BuildContext context, {
  String? preselectCharacterId,
}) async {
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
            child: Text(
              'IMPORT FROM',
              style: Theme.of(sheetContext).textTheme.labelMedium?.copyWith(
                    color: Theme.of(sheetContext).colorScheme.primary,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.insert_drive_file_outlined),
            title: const Text('A chat file'),
            subtitle: const BrandedText('A SillyTavern .jsonl, an Agnai export, '
                'a MaiChat chat, or a log from Risu, Kobold, ooba or CAI Tools'),
            onTap: () => Navigator.of(sheetContext).pop('file'),
          ),
          ListTile(
            leading: const Icon(Icons.content_paste_outlined),
            title: const Text('Paste JSON'),
            subtitle: const Text('Straight from the clipboard'),
            onTap: () => Navigator.of(sheetContext).pop('paste'),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return;
  if (choice == 'file') {
    await _fromFiles(context, preselectCharacterId);
  } else {
    await _fromPaste(context, preselectCharacterId);
  }
}
// APPEND-MARKER

/// Reads every picked file, keeping whichever chats parse. A file that fails does
/// not sink the others — its complaint is reported once at the end.
Future<void> _fromFiles(BuildContext context, String? preselect) async {
  FilePickerResult? result;
  try {
    result = await FilePicker.pickFiles(
      dialogTitle: 'Import chat',
      // FileType.any, not custom: a .jsonl/.json log is often handed out named
      // .txt or with a non-matching MIME, and Android's SAF greys those out
      // under a custom filter. The parser reads the contents, not the name.
      type: FileType.any,
      allowMultiple: true,
      withData: true,
    );
  } catch (_) {
    result = null;
  }
  final files = result?.files ?? const <PlatformFile>[];
  if (files.isEmpty || !context.mounted) return;

  final chats = <ImportedChat>[];
  String? firstError;
  for (final file in files) {
    final bytes = file.bytes;
    if (bytes == null || bytes.isEmpty) continue;
    try {
      chats.addAll(ChatCodec.parse(
        utf8.decode(bytes),
        fileName: _baseName(file.name),
      ));
    } on FormatException catch (e) {
      firstError ??= e.message;
    } catch (_) {
      firstError ??= 'Could not read ${file.name} as a chat.';
    }
  }
  if (!context.mounted) return;
  await _confirm(context, chats, firstError, preselect);
}

/// The clipboard route, for a chat copied out of a browser or another app.
Future<void> _fromPaste(BuildContext context, String? preselect) async {
  final text = await showDialog<String>(
    context: context,
    builder: (context) => const _PasteDialog(),
  );
  if (text == null || text.trim().isEmpty || !context.mounted) return;
  try {
    await _confirm(context, ChatCodec.parse(text), null, preselect);
  } on FormatException catch (e) {
    if (context.mounted) _say(context, e.message);
  }
}

/// The paste box. A widget of its own so the controller lives exactly as long as
/// the field does — disposing one the moment the dialog is dismissed throws while
/// the dialog is still fading out.
class _PasteDialog extends StatefulWidget {
  const _PasteDialog();

  @override
  State<_PasteDialog> createState() => _PasteDialogState();
}

class _PasteDialogState extends State<_PasteDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Pre-filled from the clipboard, because nine times in ten that is what the
    // user meant to paste. Deliberately not awaited: the box opens at once, and a
    // platform that never answers the clipboard channel cannot leave the flow
    // hanging with nothing on screen.
    Clipboard.getData(Clipboard.kTextPlain).then((clip) {
      final text = clip?.text ?? '';
      if (!mounted || text.isEmpty || _controller.text.isNotEmpty) return;
      _controller.text = text;
    }).catchError((Object _) {});
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Paste chat JSON'),
        content: TextField(
          controller: _controller,
          minLines: 5,
          maxLines: 10,
          keyboardType: TextInputType.multiline,
          decoration: const InputDecoration(
            hintText: '{ "messages": … }',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(_controller.text),
            child: const Text('Import'),
          ),
        ],
      );
}
// APPEND-MARKER-2

/// Shows what was found, asks which character it belongs to, then files it.
Future<void> _confirm(
  BuildContext context,
  List<ImportedChat> chats,
  String? error,
  String? preselect,
) async {
  if (chats.isEmpty) {
    _say(context, error ?? 'Nothing in there looked like a chat.');
    return;
  }
  final state = context.read<AppState>();
  final characters = state.characters;
  final binding = await showDialog<_Binding>(
    context: context,
    builder: (context) => _ImportDialog(
      chats: chats,
      characters: characters,
      initial: state.characterById(preselect) ?? _match(characters, chats),
    ),
  );
  if (binding == null || !context.mounted) return;

  await state.importConversations(
    chats.map((c) => c.conversation).toList(),
    bind: binding.character,
  );
  if (!context.mounted) return;
  final done = chats.length == 1
      ? 'Imported "${chats.single.conversation.title}".'
      : 'Imported ${chats.length} chats.';
  _say(context, error == null ? done : '$done One file was skipped: $error');
}

/// The saved character the file is probably about: same name, ignoring case.
/// Auto-selected so the common case — re-importing a chat for a character you
/// already have — needs no thought.
Character? _match(List<Character> characters, List<ImportedChat> chats) {
  for (final chat in chats) {
    final name = chat.characterName?.trim().toLowerCase() ?? '';
    if (name.isEmpty) continue;
    for (final character in characters) {
      if (character.displayName.trim().toLowerCase() == name) return character;
    }
  }
  return null;
}

void _say(BuildContext context, String message) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

/// A picked file's name without its extension — what SillyTavern means by a
/// chat's name, since the file *is* the name there.
String _baseName(String fileName) {
  final dot = fileName.lastIndexOf('.');
  return dot <= 0 ? fileName : fileName.substring(0, dot);
}

/// The dialog's answer. Wrapped because "no character" is a real choice and has
/// to be told apart from dismissing the dialog.
class _Binding {
  const _Binding(this.character);
  final Character? character;
}
// APPEND-MARKER-3

/// The last step: one line per chat found, and the character to attach them to.
class _ImportDialog extends StatefulWidget {
  const _ImportDialog({
    required this.chats,
    required this.characters,
    this.initial,
  });

  final List<ImportedChat> chats;
  final List<Character> characters;
  final Character? initial;

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  String? _characterId;

  @override
  void initState() {
    super.initState();
    _characterId = widget.initial?.id;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final chats = widget.chats;
    return AlertDialog(
      title: Text(chats.length == 1 ? 'Import chat' : 'Import ${chats.length} chats'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final chat in chats)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      chat.conversation.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    BrandedText(
                      '${chat.messageCount} '
                      '${chat.messageCount == 1 ? 'message' : 'messages'} · '
                      '${chat.format.label}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            if (widget.characters.isEmpty)
              Text(
                'No saved characters to attach this to — it will import as a '
                'plain thread.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              )
            else
              DropdownButtonFormField<String?>(
                initialValue: _characterId,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Continue as character',
                  helperText: 'Gives the thread its persona. Optional.',
                  border: OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('No character'),
                  ),
                  for (final character in widget.characters)
                    DropdownMenuItem<String?>(
                      value: character.id,
                      child: Text(
                        character.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) => setState(() => _characterId = value),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            _Binding(
              widget.characters
                  .where((c) => c.id == _characterId)
                  .cast<Character?>()
                  .firstWhere((_) => true, orElse: () => null),
            ),
          ),
          child: const Text('Import'),
        ),
      ],
    );
  }
}
