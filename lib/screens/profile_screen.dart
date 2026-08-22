import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../models/character.dart';
import '../models/chat_interface.dart';
import '../models/gallery_image.dart';
import '../state/app_state.dart';
import '../widgets/character_avatar.dart';
import 'gallery/gallery_actions.dart';
import 'persona_picker_sheet.dart';

/// The user's main profile: the roster character designated as the default
/// persona, shown as "you". Its picture, name and (optionally) its persona
/// description are edited here, and the default persona itself can be swapped
/// from the picker at the bottom. Reached from the persona avatar beside the
/// app name in the navigation drawer.
///
/// A profile is only meaningful once a persona is chosen, so with none set the
/// screen is an invitation to pick or create one rather than an empty form.
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final persona = context.watch<AppState>().defaultPersona;
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: persona == null
          ? const _NoPersona()
          : _PersonaProfile(key: ValueKey(persona.id), character: persona),
    );
  }
}
// APPEND-HERE

/// The choose-or-create state shown when no default persona is set yet.
class _NoPersona extends StatelessWidget {
  const _NoPersona();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.person_outline, size: 72, color: scheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text('No persona yet',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Choose a character to be your persona. It becomes "you" in new '
              'chats.',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => showPersonaPickerSheet(context),
              icon: const Icon(Icons.badge_outlined),
              label: const Text('Choose persona'),
            ),
          ],
        ),
      ),
    );
  }
}
// APPEND-2

/// The profile of a chosen persona: picture, name and an optional "about you"
/// description, keyed by the persona's id so switching persona rebuilds it with
/// fresh fields (and persists the outgoing one on the way out).
class _PersonaProfile extends StatefulWidget {
  const _PersonaProfile({super.key, required this.character});

  final Character character;

  @override
  State<_PersonaProfile> createState() => _PersonaProfileState();
}

class _PersonaProfileState extends State<_PersonaProfile> {
  late final TextEditingController _name =
      TextEditingController(text: widget.character.name);
  late final TextEditingController _desc =
      TextEditingController(text: widget.character.description);
  final FocusNode _nameFocus = FocusNode();
  final FocusNode _descFocus = FocusNode();
  AppState? _state;

  @override
  void initState() {
    super.initState();
    _nameFocus.addListener(_onFocusChange);
    _descFocus.addListener(_onFocusChange);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _state = context.read<AppState>();
  }

  /// Persists once both fields have lost focus (so tabbing between them does not
  /// write twice); the dispose-time save is the catch-all for leaving the screen.
  void _onFocusChange() {
    if (!_nameFocus.hasFocus && !_descFocus.hasFocus) _save();
  }

  @override
  void dispose() {
    _save();
    _nameFocus.dispose();
    _descFocus.dispose();
    _name.dispose();
    _desc.dispose();
    super.dispose();
  }

  /// Writes the current name/description back onto the persona and persists, but
  /// only when something changed — so opening the screen and leaving it never
  /// rewrites the roster.
  void _save() {
    final c = widget.character;
    final name = _name.text.trim();
    final desc = _desc.text.trim();
    if (name == c.name.trim() && desc == c.description.trim()) return;
    c
      ..name = name
      ..description = desc;
    _state?.saveCharacter(c);
  }
// APPEND-3

  /// Picks a new picture off the device, stores it as the persona's avatar.
  Future<void> _importPicture() async {
    final result =
        await FilePicker.pickFiles(type: FileType.image, withData: true);
    if (result == null || result.files.isEmpty) return;
    final bytes = result.files.first.bytes;
    if (bytes == null || bytes.isEmpty) return;
    widget.character.avatar = base64Encode(bytes);
    await _state?.saveCharacter(widget.character);
    if (mounted) setState(() {});
  }

  /// Exports the persona's picture through the app's shared save path.
  Future<void> _exportPicture() async {
    final c = widget.character;
    if (c.avatar.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No picture to export.')),
      );
      return;
    }
    await exportGalleryImage(
      context,
      GalleryImage.create(image: c.avatar, title: c.displayName),
    );
  }

  Future<void> _deletePicture() async {
    widget.character.avatar = '';
    await _state?.saveCharacter(widget.character);
    if (mounted) setState(() {});
  }

  /// The classic gallery-style corner menu: import, export, delete.
  void _pictureMenu() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.image_outlined),
              title: const Text('Import picture'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _importPicture();
              },
            ),
            ListTile(
              leading: const Icon(Icons.ios_share),
              title: const Text('Export picture'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _exportPicture();
              },
            ),
            if (widget.character.avatar.trim().isNotEmpty)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Delete picture'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _deletePicture();
                },
              ),
          ],
        ),
      ),
    );
  }
// APPEND-4

  @override
  Widget build(BuildContext context) {
    final c = widget.character;
    final scheme = Theme.of(context).colorScheme;
    final side =
        (MediaQuery.sizeOf(context).width * 0.62).clamp(160.0, 280.0);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
      children: [
        // Big square picture with a gallery-style action button in the corner.
        Center(
          child: Stack(
            children: [
              CharacterAvatar(
                character: c,
                size: side,
                shape: AvatarShape.rounded,
                corner: CornerRounding.l,
                fit: AvatarFit.cover,
              ),
              Positioned(
                right: 8,
                bottom: 8,
                child: Material(
                  color: scheme.secondaryContainer,
                  shape: const CircleBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: IconButton(
                    tooltip: 'Picture options',
                    icon: Icon(Icons.more_horiz,
                        color: scheme.onSecondaryContainer),
                    onPressed: _pictureMenu,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        // Name — editable in place.
        TextField(
          controller: _name,
          focusNode: _nameFocus,
          textAlign: TextAlign.center,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.done,
          style: Theme.of(context).textTheme.headlineSmall,
          decoration: const InputDecoration(
            hintText: 'Your name',
            border: InputBorder.none,
          ),
          onSubmitted: (_) => _save(),
        ),
        const SizedBox(height: 12),
        const Divider(height: 1),
        const SizedBox(height: 16),
        // Optional persona description — what reaches the model as the user
        // persona. Left blank unless the user wants it.
        TextField(
          controller: _desc,
          focusNode: _descFocus,
          minLines: 2,
          maxLines: 6,
          decoration: const InputDecoration(
            labelText: 'About you (persona)',
            hintText: 'Optional — describe who you are in chats',
            alignLabelWithHint: true,
          ),
        ),
        const SizedBox(height: 16),
        const Divider(height: 1),
        // Swap which character is the default persona.
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.badge_outlined),
          title: const Text('Default persona'),
          subtitle: Text('${c.displayName} • applies to new chats'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => showPersonaPickerSheet(context),
        ),
      ],
    );
  }
}




