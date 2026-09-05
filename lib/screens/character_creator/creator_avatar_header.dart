import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../widgets/avatar_dots.dart';
import '../../widgets/avatar_image.dart';
import '../gallery/gallery_picker_sheet.dart';
import '../image_gen/image_gen_sheet.dart';
import 'creator_controls.dart';
import 'creator_draft.dart';

/// The pictures at the top of the creator, at whatever shape they actually are.
///
/// "Free size" means exactly that: a picture is drawn `contain`ed, so a square
/// avatar is a square, a tall portrait is tall, and nothing is cropped to fit a
/// circle it was never composed for — the same decision the character sheet makes
/// about the portrait, in a header that has to be a fixed height because it scrolls
/// away above the tabs.
///
/// A card can wear more than one picture, so the header is a run of them with dots
/// under it: swipe, and the one you stop on is the one the card wears. That write
/// is silent by design — see [CreatorDraft.setDefaultPicture].
class CreatorAvatarHeader extends StatefulWidget {
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
  State<CreatorAvatarHeader> createState() => _CreatorAvatarHeaderState();
}

class _CreatorAvatarHeaderState extends State<CreatorAvatarHeader> {
  late final PageController _pages =
      PageController(initialPage: widget.draft.defaultPicture);

  /// The run the pager is showing. Held here as well as on the draft so a rebuild
  /// that only changed *which* picture is worn does not disturb the pager, while
  /// one that added or removed a picture does.
  late List<String> _pictures = List<String>.of(widget.draft.pictures);

  late int _index = widget.draft.defaultPicture;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _onPage(int page) {
    setState(() => _index = page);
    widget.draft.setDefaultPicture(page);
  }

  /// Follows a run that changed under us — a picture added by the sheet, or the
  /// one on show taken away.
  void _adopt(List<String> pool) {
    _pictures = List<String>.of(pool);
    _index = widget.draft.defaultPicture.clamp(0, _pictures.length);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pages.hasClients) return;
      _pages.jumpToPage(_index);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pool = widget.draft.pictures;
    if (!listEquals(pool, _pictures)) _adopt(pool);
    final height = widget.height;

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
          if (pool.isEmpty)
            _Empty(height: height)
          else
            PageView.builder(
              controller: _pages,
              itemCount: pool.length,
              onPageChanged: _onPage,
              itemBuilder: (context, i) => _Picture(ref: pool[i], height: height),
            ),
          if (pool.length > 1)
            Positioned(
              left: 0,
              right: 0,
              bottom: 10,
              child: Center(
                child: AvatarDots(count: pool.length, index: _index),
              ),
            ),
          // One quiet pencil, and nothing else: the sheet behind it is where
          // adding, swapping and removing a picture live, so the header stays a
          // picture rather than a toolbar.
          Positioned(
            right: 8,
            bottom: 8,
            child: _HeaderButton(
              key: const Key('creator-avatar-button'),
              icon: Icons.edit_outlined,
              tooltip: pool.isEmpty ? 'Add a picture' : 'Change the picture',
              onTap: () => showAvatarSourceSheet(
                context,
                draft: widget.draft,
                characterId: widget.characterId,
                index: pool.isEmpty ? null : _index,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One picture in the run, at its own shape inside the header's box.
class _Picture extends StatelessWidget {
  const _Picture({required this.ref, required this.height});

  final String ref;
  final double height;

  @override
  Widget build(BuildContext context) {
    final provider = avatarImage(
      ref,
      displaySize: height,
      devicePixelRatio: MediaQuery.maybeDevicePixelRatioOf(context) ?? 1,
    );
    if (provider == null) return _Empty(height: height);
    return Center(
      child: Image(
        image: provider,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => _Empty(height: height),
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
    super.key,
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

/// Where a picture comes from — a link, the app's own gallery, a file on the
/// phone, or one made on the spot in the image studio — and the way back out
/// again.
///
/// Every source *adds*: a card can wear several pictures, so picking one puts it
/// on without throwing away the one that was there. [index] is the picture on
/// show, the one Remove would take away; null when there is nothing to remove
/// yet.
Future<void> showAvatarSourceSheet(
  BuildContext context, {
  required CreatorDraft draft,
  String? characterId,
  int? index,
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
                if (ref != null) draft.addPicture(ref);
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
                if (ref != null) draft.addPicture(ref);
              },
            ),
            if (index != null)
              ListTile(
                key: const Key('creator-avatar-remove'),
                leading: const Icon(Icons.delete_outline),
                title: const Text('Remove this picture'),
                subtitle: Text(draft.pictures.length > 1
                    ? 'The others stay'
                    : 'The card goes back to no picture'),
                onTap: () async {
                  final removed = await confirmRemoval(
                    context,
                    title: 'Remove this picture?',
                    message: draft.pictures.length > 1
                        ? 'The rest of this card\'s pictures stay as they are.'
                        : 'The card will have no picture until you add one.',
                  );
                  if (!removed) return;
                  draft.removePictureAt(index);
                  if (sheetContext.mounted) Navigator.of(sheetContext).pop();
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
  draft.addPicture(trimmed);
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
  draft.addPicture(base64Encode(bytes));
}
