import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/chat_interface.dart';
import '../models/interface_preset.dart';
import '../services/avatar_store.dart';
import '../services/interface_preset_io.dart';
import '../state/app_state.dart';

/// Raises the looks sheet: the shipped looks, then whatever has been saved, with
/// the one in force marked — plus saving the current look, importing one, and per
/// saved look renaming, exporting and deleting it.
///
/// [conversationId] is the thread the sheet was opened over, if any. Picking a
/// look from inside a chat asks once whether it is for every chat or only this
/// one, the way the scenario picker asks; opened from Settings there is no thread
/// in view, so it goes straight to the app-wide settings.
Future<void> showInterfacePresetSheet(
  BuildContext context, {
  String? conversationId,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _PresetSheet(conversationId: conversationId),
    );

class _PresetSheet extends StatelessWidget {
  const _PresetSheet({this.conversationId});

  final String? conversationId;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final presets = state.interfacePresets;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.75,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Header(conversationId: conversationId),
            const Divider(height: 1),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final preset in presets)
                    _PresetRow(
                      preset: preset,
                      conversationId: conversationId,
                      active: state.isInterfacePresetActive(
                        preset,
                        conversationId: conversationId,
                      ),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            _Footer(conversationId: conversationId),
          ],
        ),
      ),
    );
  }
}
class _Header extends StatelessWidget {
  const _Header({this.conversationId});

  final String? conversationId;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 12, 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Looks', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 2),
                  Text(
                    conversationId == null
                        ? 'A whole chat interface, saved under a name'
                        : 'Switch this chat, or every chat, to a saved look',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
}

class _Footer extends StatelessWidget {
  const _Footer({this.conversationId});

  final String? conversationId;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Row(
          children: [
            FilledButton.tonalIcon(
              onPressed: () => _saveCurrent(context, conversationId),
              icon: const Icon(Icons.bookmark_add_outlined),
              label: const Text('Save this look'),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: () => _import(context),
              icon: const Icon(Icons.file_open_outlined),
              label: const Text('Import'),
            ),
          ],
        ),
      );
}
/// One look: its swatch, its name, whether it is in force, and — when it is one
/// of the saved ones — the menu that renames, exports or drops it.
class _PresetRow extends StatelessWidget {
  const _PresetRow({
    required this.preset,
    required this.active,
    this.conversationId,
  });

  final InterfacePreset preset;
  final bool active;
  final String? conversationId;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: LookSwatch(ui: preset.ui),
      title: Text(preset.name),
      subtitle: Text(_describe(preset.ui)),
      selected: active,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (active)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Icon(Icons.check, color: scheme.primary, size: 20),
            ),
          if (!preset.isBuiltIn)
            PopupMenuButton<String>(
              tooltip: 'More',
              onSelected: (choice) => switch (choice) {
                'rename' => _rename(context, preset),
                'export' => _export(context, preset),
                _ => _delete(context, preset),
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'rename', child: Text('Rename')),
                PopupMenuItem(value: 'export', child: Text('Export to a file')),
                PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
        ],
      ),
      onTap: () => _apply(context, preset, conversationId),
    );
  }
}

/// A look in one line, so two saved looks are told apart without applying them.
String _describe(ChatInterface ui) => [
      ui.bubbles ? 'Bubbles' : 'Document',
      ui.textPlacement.label,
      if (ui.botAvatar.show || ui.userAvatar.show)
        '${ui.botAvatar.size.round()} px avatars'
      else
        'no avatars',
      if (ui.showNames) 'names',
      '${ui.fontSize.round()} px text',
    ].join(' · ');
/// A look drawn small: its background, a turn from each side in that look's
/// bubble colours, and an avatar in its shape. Enough to recognise a look you
/// saved without reading the summary under it.
class LookSwatch extends StatelessWidget {
  const LookSwatch({super.key, required this.ui, this.size = 44});

  final ChatInterface ui;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = ui.backgroundColor != null
        ? Color(ui.backgroundColor!)
        : scheme.surfaceContainerHighest;
    final botBubble = ui.botBubbleColor != null
        ? Color(ui.botBubbleColor!)
        : scheme.surfaceContainerHigh;
    final userBubble = ui.userBubbleColor != null
        ? Color(ui.userBubbleColor!)
        : scheme.primaryContainer;
    final avatar = ui.botAvatar;
    final dot = size * 0.22;

    Widget turn(Color colour, Alignment align, double width) => Align(
          alignment: align,
          child: Container(
            width: width,
            height: size * 0.15,
            decoration: BoxDecoration(
              color: ui.bubbles ? colour : Colors.transparent,
              border: ui.bubbles
                  ? null
                  : Border.all(color: colour.withValues(alpha: 0.9)),
              borderRadius: BorderRadius.circular(size * 0.06),
            ),
          ),
        );

    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * 0.12),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(size * 0.2),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          Row(
            children: [
              if (avatar.show)
                Container(
                  width: dot,
                  height: dot,
                  margin: EdgeInsets.only(right: size * 0.06),
                  decoration: BoxDecoration(
                    color: scheme.onSurfaceVariant,
                    borderRadius: BorderRadius.circular(
                        avatar.shape.radiusFor(dot, rounding: avatar.corner)),
                  ),
                ),
              Expanded(child: turn(botBubble, Alignment.centerLeft, size * 0.5)),
            ],
          ),
          turn(userBubble, Alignment.centerRight, size * 0.44),
        ],
      ),
    );
  }
}
/// Puts a look in force. From inside a chat that means asking once who it is for:
/// the distinction is real (a per-chat copy stops following later app-wide
/// changes) and guessing wrong either way is annoying to undo.
Future<void> _apply(
  BuildContext context,
  InterfacePreset preset,
  String? conversationId,
) async {
  final state = context.read<AppState>();
  var target = conversationId;
  if (conversationId != null) {
    final scope = await _askScope(context, preset.name);
    if (scope == null) return;
    target = scope == _ApplyScope.thisChat ? conversationId : null;
  }
  await state.applyInterfacePreset(preset, conversationId: target);
  if (!context.mounted) return;
  Navigator.of(context).pop();
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(target == null
          ? '“${preset.name}” is now the look for every chat.'
          : '“${preset.name}” is now this chat\'s own look.'),
    ),
  );
}

enum _ApplyScope { everyChat, thisChat }

Future<_ApplyScope?> _askScope(BuildContext context, String name) =>
    showDialog<_ApplyScope>(
      context: context,
      builder: (context) => _ScopeDialog(name: name),
    );

class _ScopeDialog extends StatefulWidget {
  const _ScopeDialog({required this.name});

  final String name;

  @override
  State<_ScopeDialog> createState() => _ScopeDialogState();
}

class _ScopeDialogState extends State<_ScopeDialog> {
  _ApplyScope _scope = _ApplyScope.everyChat;

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('Apply “${widget.name}”'),
        content: RadioGroup<_ApplyScope>(
          groupValue: _scope,
          onChanged: (v) => setState(() => _scope = v!),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RadioListTile<_ApplyScope>(
                value: _ApplyScope.everyChat,
                title: Text('Every chat'),
                subtitle: Text('The app-wide look'),
              ),
              RadioListTile<_ApplyScope>(
                value: _ApplyScope.thisChat,
                title: Text('This chat only'),
                subtitle: Text(
                    'Gives this thread its own copy, which later app-wide '
                    'changes will not reach'),
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
            onPressed: () => Navigator.of(context).pop(_scope),
            child: const Text('Apply'),
          ),
        ],
      );
}
/// Saves whatever look is in force under a name. From inside a chat that is the
/// chat's own look, which is the one on screen.
Future<void> _saveCurrent(BuildContext context, String? conversationId) async {
  final state = context.read<AppState>();
  final from = conversationId == null
      ? state.chatInterface
      : state.interfaceFor(state.conversationById(conversationId));
  final name = await _askName(context, 'Save this look', '');
  if (name == null || !context.mounted) return;
  final saved = await state.saveInterfacePreset(name, from: from);
  if (!context.mounted || saved == null) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('Saved as “${saved.name}”.')),
  );
}

Future<void> _rename(BuildContext context, InterfacePreset preset) async {
  final state = context.read<AppState>();
  final name = await _askName(context, 'Rename look', preset.name);
  if (name == null) return;
  await state.renameInterfacePreset(preset.id, name);
}

Future<String?> _askName(
  BuildContext context,
  String title,
  String initial,
) async {
  final name = await showDialog<String>(
    context: context,
    builder: (_) => _NameDialog(title: title, initial: initial),
  );
  final trimmed = name?.trim();
  return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
}

/// The dialog owns its controller rather than the function that shows it: a
/// controller disposed the instant `showDialog` returns is still being depended
/// on by the field's focus scope, which trips an assertion on the way out.
class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.title, required this.initial});

  final String title;
  final String initial;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: TextField(
          controller: _controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'Name',
            hintText: 'Night reading',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.of(context).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(_controller.text),
            child: const Text('Save'),
          ),
        ],
      );
}
Future<void> _delete(BuildContext context, InterfacePreset preset) async {
  final state = context.read<AppState>();
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Delete “${preset.name}”?'),
      content: const Text(
          'The look is dropped. Whatever is on screen right now stays as it is.'),
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
  if (ok != true) return;
  await state.deleteInterfacePreset(preset.id);
}

/// Writes a look out as one self-contained file, pictures and all.
Future<void> _export(BuildContext context, InterfacePreset preset) async {
  final json = jsonEncode(exportInterfacePreset(
    preset,
    read: (ref) {
      final file = avatarRefFile(ref);
      if (file == null || !file.existsSync()) return null;
      return file.readAsBytesSync();
    },
  ));
  final safe = preset.name
      .replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '')
      .trim()
      .replaceAll(RegExp(r'\s+'), '_');
  String? path;
  try {
    path = await FilePicker.saveFile(
      dialogTitle: 'Save look',
      fileName: '${safe.isEmpty ? 'look' : safe}.maichat-look.json',
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
/// Reads a look back in, filing its pictures as it goes. The file is small (a
/// look and one or two pictures), so this is the one import here that may read
/// with `withData` rather than working from a path.
Future<void> _import(BuildContext context) async {
  final state = context.read<AppState>();
  void say(String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  final result = await FilePicker.pickFiles(
    dialogTitle: 'Import a look',
    type: FileType.custom,
    allowedExtensions: const ['json'],
    withData: true,
  );
  final bytes =
      (result != null && result.files.isNotEmpty) ? result.files.first.bytes : null;
  if (bytes == null) return;

  try {
    final decoded = jsonDecode(utf8.decode(bytes));
    final preset = await importInterfacePreset(
      decoded,
      store: state.storePicture,
    );
    final filed = await state.addInterfacePreset(preset);
    say('Imported “${filed.name}”.');
  } on InterfacePresetFormatException catch (error) {
    say(error.message);
  } catch (_) {
    say('That file could not be read as a look.');
  }
}







