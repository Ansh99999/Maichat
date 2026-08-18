import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/character.dart';
import '../../models/gallery_image.dart';
import '../../services/avatar_store.dart';
import '../../state/app_state.dart';
import '../../widgets/avatar_image.dart';
import '../../widgets/export_sheet.dart';
import '../../widgets/tag_entry_field.dart';

/// Saves a picture out of the app.
///
/// A picture kept on the device is written with the system's own save dialog, the
/// same permission-free path every other export here takes. A picture that is
/// only a URL has no bytes to write, so the link is copied instead — saying so
/// rather than silently writing nothing.
Future<void> exportGalleryImage(
  BuildContext context,
  GalleryImage image,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final file = avatarRefFile(image.image);

  if (file == null || !file.existsSync()) {
    if (avatarIsUrl(image.image)) {
      await Clipboard.setData(ClipboardData(text: image.image));
      messenger.showSnackBar(const SnackBar(
        content: Text('That picture lives online — its link was copied.'),
      ));
      return;
    }
    messenger.showSnackBar(const SnackBar(
      content: Text('That picture could not be found on this device.'),
    ));
    return;
  }

  Uint8List bytes;
  try {
    bytes = await file.readAsBytes();
  } catch (_) {
    messenger.showSnackBar(const SnackBar(
      content: Text('That picture could not be read.'),
    ));
    return;
  }

  final extension = avatarExtensionFor(bytes).replaceFirst('.', '');
  final safe = safeFileName(image.title);
  String? path;
  try {
    path = await FilePicker.saveFile(
      dialogTitle: 'Save picture',
      fileName: '${safe.isEmpty ? 'picture-${image.id}' : safe}.$extension',
      bytes: bytes,
      type: FileType.custom,
      allowedExtensions: [extension],
    );
  } catch (_) {
    path = null;
  }
  messenger.showSnackBar(SnackBar(
    content: Text(path == null ? 'Export cancelled.' : 'Saved to $path'),
  ));
}

/// Saves several pictures, one save dialog each — the platform has no "save these
/// five" call, and zipping them would produce a file nothing on the phone opens.
Future<void> exportGalleryImages(
  BuildContext context,
  List<GalleryImage> images,
) async {
  for (final image in images) {
    if (!context.mounted) return;
    await exportGalleryImage(context, image);
  }
}

/// Edits a picture's title, tags and owner. Returns true when something was
/// saved.
Future<bool> showGalleryEditSheet(
  BuildContext context,
  GalleryImage image, {
  bool allowChoosingOwner = true,
}) async {
  final state = context.read<AppState>();
  final edited = await showModalBottomSheet<GalleryImage>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _EditSheet(
      image: image,
      characters: allowChoosingOwner ? state.characters : const <Character>[],
    ),
  );
  if (edited == null) return false;
  await state.saveGalleryImage(edited);
  return true;
}

class _EditSheet extends StatefulWidget {
  const _EditSheet({required this.image, required this.characters});

  final GalleryImage image;
  final List<Character> characters;

  @override
  State<_EditSheet> createState() => _EditSheetState();
}

class _EditSheetState extends State<_EditSheet> {
  late final TextEditingController _title =
      TextEditingController(text: widget.image.title);
  late List<String> _tags = List<String>.from(widget.image.tags);
  late String? _owner = widget.image.characterId;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    final provider = avatarImage(widget.image.image, displaySize: 160);

    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: media.size.height * 0.85),
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + media.padding.bottom),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Edit picture', style: theme.textTheme.titleLarge),
              const SizedBox(height: 16),
              if (provider != null)
                Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Image(
                      image: provider,
                      height: 140,
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              TextField(
                controller: _title,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Title',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              TagEntryField(
                tags: _tags,
                onChanged: (tags) => setState(() => _tags = tags),
              ),
              if (widget.characters.isNotEmpty) ...[
                const SizedBox(height: 16),
                GalleryOwnerField(
                  characters: widget.characters,
                  value: _owner,
                  onChanged: (id) => setState(() => _owner = id),
                ),
              ],
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.of(context).pop(
                        widget.image.copyWith(
                          title: _title.text.trim(),
                          tags: _tags,
                          characterId: _owner,
                        ),
                      ),
                      child: const Text('Save'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Who a picture belongs to. "Nobody" is a real answer: an unattached picture
/// still shows in the whole-app gallery and can be a chat background — it just
/// cannot become an avatar until it has an owner to be one for.
class GalleryOwnerField extends StatelessWidget {
  const GalleryOwnerField({
    super.key,
    required this.characters,
    required this.value,
    required this.onChanged,
  });

  final List<Character> characters;
  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    // A stored owner whose card has been deleted must not be handed to the
    // dropdown as a value it has no item for — that asserts.
    final known = characters.any((c) => c.id == value) ? value : null;
    return InputDecorator(
      decoration: const InputDecoration(
        labelText: 'Belongs to',
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String?>(
          isExpanded: true,
          value: known,
          items: [
            const DropdownMenuItem<String?>(
              value: null,
              child: Text('Nobody in particular'),
            ),
            for (final character in characters)
              DropdownMenuItem<String?>(
                value: character.id,
                child: Text(
                  character.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }
}
