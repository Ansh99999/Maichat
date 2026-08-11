import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/character.dart';
import '../services/character_codec.dart';
import '../state/app_state.dart';
import 'chats_screen.dart';
import 'character_detail_screen.dart';
import 'character_edit_screen.dart';
import 'chat_screen.dart';
import 'section_screen.dart';

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
        builder: (_) => const SectionScreen(
          title: 'Gallery',
          icon: Icons.photo_library_outlined,
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

/// Opens a character's page.
void openCharacterDetail(BuildContext context, String characterId) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => CharacterDetailScreen(characterId: characterId),
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
            subtitle: const Text('SillyTavern v2 card'),
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
        const SnackBar(content: Text('Card JSON copied to clipboard.')),
      );
    }
    return;
  }

  final safeName = character.displayName
      .replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '')
      .trim()
      .replaceAll(RegExp(r'\s+'), '_');
  String? path;
  try {
    path = await FilePicker.saveFile(
      dialogTitle: 'Save character card',
      fileName: '${safeName.isEmpty ? 'character' : safeName}.json',
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
