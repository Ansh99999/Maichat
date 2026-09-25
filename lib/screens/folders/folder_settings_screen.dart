import 'package:flutter/material.dart';

import '../../models/folder.dart';

/// Behaviour switches for a folder draft. Changes are committed by the editor.
class FolderSettingsScreen extends StatefulWidget {
  const FolderSettingsScreen({super.key, required this.folder});

  final Folder folder;

  @override
  State<FolderSettingsScreen> createState() => _FolderSettingsScreenState();
}

class _FolderSettingsScreenState extends State<FolderSettingsScreen> {
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Folder settings')),
    body: ListView(
      children: [
        SwitchListTile(
          value: widget.folder.autoLorebooks,
          title: const Text('Use folder lorebooks automatically'),
          subtitle: const Text(
            'New chats in this folder start with its lorebooks selected.',
          ),
          onChanged: (value) => setState(() {
            widget.folder.autoLorebooks = value;
          }),
        ),
        SwitchListTile(
          value: widget.folder.propagateLorebookEdits,
          title: const Text('Share lorebook edits'),
          subtitle: const Text(
            'Edits update the shared library book used by every folder chat.',
          ),
          onChanged: (value) => setState(() {
            widget.folder.propagateLorebookEdits = value;
          }),
        ),
        SwitchListTile(
          value: widget.folder.sharedSummary,
          title: const Text('Share summaries'),
          subtitle: const Text(
            'Chats in this folder can use one rolling summary for continuity.',
          ),
          onChanged: (value) => setState(() {
            widget.folder.sharedSummary = value;
          }),
        ),
        SwitchListTile(
          value: widget.folder.sharedEmbeddings,
          title: const Text('Share semantic memory'),
          subtitle: const Text(
            'Folder chats can retrieve from the same embedding collection.',
          ),
          onChanged: (value) => setState(() {
            widget.folder.sharedEmbeddings = value;
          }),
        ),
      ],
    ),
  );
}
