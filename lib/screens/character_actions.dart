import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/character.dart';
import '../services/character_codec.dart';
import '../state/app_state.dart';
import 'chats_screen.dart';
import 'character_sheet_screen.dart';
import 'character_edit_screen.dart';
import 'chat_screen.dart';
import 'gallery/gallery_screen.dart';

/// The per-character actions, shared by the roster's 3-dot menu (both the
/// avatar card and the list row) and the detail screen, so every entry point
/// behaves identically.
enum CharacterAction {
  newChat('New chat', Icons.chat_bubble_outline),
  download('Download', Icons.download_outlined),
  edit('Edit', Icons.edit_outlined),
  chatList('Chat list', Icons.forum_outlined),
  gallery('Gallery', Icons.photo_library_outlined),
  duplicate('Duplicate', Icons.copy_all_outlined),
  delete('Delete', Icons.delete_outline);

  const CharacterAction(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// The menu items in the order the spec lists them.
List<PopupMenuEntry<CharacterAction>> characterMenuItems() => [
      for (final action in CharacterAction.values)
        PopupMenuItem<CharacterAction>(
          value: action,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: Icon(action.icon),
            title: Text(action.label),
          ),
        ),
    ];

/// Runs [action] for [character]. Everything is null-safe against a character
/// that was deleted mid-gesture.
Future<void> runCharacterAction(
  BuildContext context,
  AppState state,
  Character character,
  CharacterAction action,
) async {
  switch (action) {
    case CharacterAction.newChat:
      startCharacterChat(context, state, character);
    case CharacterAction.download:
      await exportCharacter(context, character);
    case CharacterAction.edit:
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => CharacterEditScreen(character: character),
      ));
    case CharacterAction.chatList:
      Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ChatsScreen(
          characterId: character.id,
          characterName: character.displayName,
        ),
      ));
    case CharacterAction.gallery:
      Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => GalleryScreen(
          mode: GalleryMode.character,
          characterId: character.id,
        ),
      ));
    case CharacterAction.duplicate:
      await state.duplicateCharacter(character);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Character duplicated.')),
        );
      }
    case CharacterAction.delete:
      await confirmDeleteCharacter(context, state, character);
  }
}

/// Starts a fresh chat bound to [character] and opens it.
void startCharacterChat(
    BuildContext context, AppState state, Character character) {
  state.startChatWithCharacter(character);
  Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => const ChatScreen()),
  );
}

/// Opens a character's sheet.
void openCharacterDetail(BuildContext context, String characterId) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => CharacterSheetScreen(characterId: characterId),
    ),
  );
}

/// Confirms, then deletes [character]. Existing chats are left in place.
Future<void> confirmDeleteCharacter(
    BuildContext context, AppState state, Character character) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Delete character?'),
      content: Text('"${character.displayName}" will be removed. Existing '
          'chats with it are kept.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (ok == true) await state.deleteCharacter(character.id);
}

/// Exports [character] as a SillyTavern v2 card, offering a saved `.json` file
/// or a clipboard copy — both permission-free.
Future<void> exportCharacter(BuildContext context, Character character) async {
  final json = CharacterCodec.exportTavernV2(character);
  final safe = _safeName(character.displayName);
  await _offerExport(
    context,
    json: json,
    fileName: '${safe.isEmpty ? 'character' : safe}.json',
    subtitle: 'SillyTavern v2 card',
  );
}

/// Exports several characters as one `.json` array of v2 cards (bulk export
/// that the file importer reads back). A single selection defers to
/// [exportCharacter].
Future<void> exportCharacters(
    BuildContext context, List<Character> characters) async {
  if (characters.isEmpty) return;
  if (characters.length == 1) {
    await exportCharacter(context, characters.single);
    return;
  }
  final json = CharacterCodec.exportTavernV2Many(characters);
  await _offerExport(
    context,
    json: json,
    fileName: 'characters-${characters.length}.json',
    subtitle: '${characters.length} SillyTavern v2 cards',
  );
}

/// The shared save-to-file / copy-to-clipboard chooser for exports.
Future<void> _offerExport(
  BuildContext context, {
  required String json,
  required String fileName,
  required String subtitle,
}) async {
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.save_alt_outlined),
            title: const Text('Save as .json file'),
            subtitle: Text(subtitle),
            onTap: () => Navigator.of(context).pop('file'),
          ),
          ListTile(
            leading: const Icon(Icons.copy_all_outlined),
            title: const Text('Copy JSON to clipboard'),
            onTap: () => Navigator.of(context).pop('clipboard'),
          ),
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return;

  if (choice == 'clipboard') {
    await Clipboard.setData(ClipboardData(text: json));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Copied to clipboard.')),
      );
    }
    return;
  }

  String? path;
  try {
    path = await FilePicker.saveFile(
      dialogTitle: 'Save character card',
      fileName: fileName,
      bytes: Uint8List.fromList(utf8.encode(json)),
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
  } catch (_) {
    path = null;
  }
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(path == null ? 'Export cancelled.' : 'Saved to $path'),
    ),
  );
}

String _safeName(String s) => s
    .replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '')
    .trim()
    .replaceAll(RegExp(r'\s+'), '_');
