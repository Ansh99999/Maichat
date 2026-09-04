import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../widgets/avatar_image.dart';
import '../gallery/gallery_picker_sheet.dart';
import '../image_gen/image_gen_sheet.dart';
import 'creator_draft.dart';

/// The picture at the top of the creator, at whatever shape it actually is.
///
/// "Free size" means exactly that: the picture is drawn `contain`ed, so a square
/// avatar is a square, a tall portrait is tall, and nothing is cropped to fit a
/// circle it was never composed for — the same decision the character sheet makes
/// about the portrait, in a header that has to be a fixed height because it lives
/// in a [SliverAppBar].
class CreatorAvatarHeader extends StatelessWidget {
  const CreatorAvatarHeader({
    super.key,
    required this.draft,
    required this.characterId,
    required this.height,
  });

  final CreatorDraft draft;

  /// Whose album a generated picture is filed under, or null for a card that has
  /// no id of its own yet.
  final String? characterId;

  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ref = draft.avatar;
    final provider = avatarImage(
      ref,
      displaySize: height,
      devicePixelRatio: MediaQuery.maybeDevicePixelRatioOf(context) ?? 1,
    );

    return SizedBox(
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // A soft wash behind the picture, so a portrait with wide margins does
          // not sit in a grey box.
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  scheme.surfaceContainerHigh,
                  scheme.surfaceContainerLow,
                ],
              ),
            ),
          ),
          if (provider != null)
            Center(
              child: Image(
                image: provider,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => _Empty(height: height),
              ),
            )
          else
            _Empty(height: height),
          Positioned(
            right: 8,
            bottom: 8,
            child: Row(
              children: [
                if (ref.trim().isNotEmpty)
                  _HeaderButton(
                    icon: Icons.close,
                    tooltip: 'Remove picture',
                    onTap: () => draft.setAvatar(''),
                  ),
                const SizedBox(width: 8),
                FilledButton.tonalIcon(
                  key: const Key('creator-avatar-button'),
                  onPressed: () => showAvatarSourceSheet(
                    context,
                    draft: draft,
                    characterId: characterId,
                  ),
                  icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
                  label: Text(ref.trim().isEmpty ? 'Add a picture' : 'Change'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.height});

  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.person_outline,
              size: height * 0.3, color: scheme.onSurfaceVariant),
          const SizedBox(height: 4),
          Text(
            'No picture yet',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _HeaderButton extends StatelessWidget {
  const _HeaderButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface.withValues(alpha: 0.8),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Tooltip(
          message: tooltip,
          child: Padding(
            padding: const EdgeInsets.all(7),
            child: Icon(icon, size: 18, color: scheme.onSurface),
          ),
        ),
      ),
    );
  }
}

/// The four ways a character gets a picture: a link, the app's own gallery, a
/// file on the phone, or one made on the spot in the image studio.
Future<void> showAvatarSourceSheet(
  BuildContext context, {
  required CreatorDraft draft,
  String? characterId,
}) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const Key('creator-avatar-url'),
              leading: const Icon(Icons.link),
              title: const Text('Image URL'),
              subtitle: const Text('Paste a link to a picture'),
              onTap: () async {
                Navigator.of(sheetContext).pop();
                await _askForUrl(context, draft);
              },
            ),
            ListTile(
              key: const Key('creator-avatar-gallery'),
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('App gallery'),
              subtitle: const Text('A picture already in MaiChat'),
              onTap: () async {
                Navigator.of(sheetContext).pop();
                final ref = await showGalleryPickerSheet(
                  context,
                  title: 'Choose a picture',
                  characterId: characterId,
                );
                if (ref != null) draft.setAvatar(ref);
              },
            ),
            ListTile(
              key: const Key('creator-avatar-device'),
              leading: const Icon(Icons.smartphone_outlined),
              title: const Text('This device'),
              subtitle: const Text('Pick a file from the phone'),
              onTap: () async {
                Navigator.of(sheetContext).pop();
                await _pickFromDevice(draft);
              },
            ),
            ListTile(
              key: const Key('creator-avatar-generate'),
              leading: const Icon(Icons.auto_awesome_outlined),
              title: const Text('Generate one'),
              subtitle: const Text('Open the image studio'),
              onTap: () async {
                Navigator.of(sheetContext).pop();
                final ref = await showImageStudio(
                  context,
                  characterId: characterId,
                  picking: true,
                  pickLabel: 'Use as avatar',
                  prompt: _promptFor(draft),
                );
                if (ref != null) draft.setAvatar(ref);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

/// A starting point for the studio's prompt, taken from the card so the first
/// generation is about this character rather than about nothing.
String _promptFor(CreatorDraft draft) {
  final name = draft.name.text.trim();
  final description = draft.description.text
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final clipped = description.length <= 320
      ? description
      : description.substring(0, 320);
  return <String>[
    if (name.isNotEmpty) 'Portrait of $name',
    if (clipped.isNotEmpty) clipped,
  ].join('. ');
}

Future<void> _askForUrl(BuildContext context, CreatorDraft draft) async {
  final controller = TextEditingController(
    text: draft.avatar.startsWith('http') ? draft.avatar : '',
  );
  final url = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Image URL'),
      content: TextField(
        key: const Key('creator-avatar-url-field'),
        controller: controller,
        autofocus: true,
        keyboardType: TextInputType.url,
        decoration: const InputDecoration(
          hintText: 'https://…',
          border: OutlineInputBorder(),
        ),
        onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(controller.text),
          child: const Text('Use'),
        ),
      ],
    ),
  );
  controller.dispose();
  final trimmed = url?.trim() ?? '';
  if (trimmed.isEmpty) return;
  draft.setAvatar(trimmed);
}

/// Reads a file off the phone as base64. It stays base64 only until the card is
/// saved: `AppState.saveCharacter` moves the bytes into the pictures directory,
/// because a picture in the preferences store is what once made the app
/// unopenable.
Future<void> _pickFromDevice(CreatorDraft draft) async {
  final result = await FilePicker.pickFiles(
    type: FileType.image,
    withData: true,
  );
  if (result == null || result.files.isEmpty) return;
  final bytes = result.files.first.bytes;
  if (bytes == null || bytes.isEmpty) return;
  draft.setAvatar(base64Encode(bytes));
}
