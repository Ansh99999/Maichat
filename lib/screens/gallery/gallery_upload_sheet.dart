import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/character.dart';
import '../../state/app_state.dart';
import '../../widgets/tag_entry_field.dart';
import 'gallery_actions.dart';

/// Picks pictures off the device and files them, asking for a title and tags
/// first.
///
/// Returns the number added (0 when the picker was dismissed or nothing could be
/// stored). The pictures are only written once the sheet is confirmed, so backing
/// out leaves nothing behind.
Future<int> showGalleryUploadSheet(
  BuildContext context, {
  String? characterId,
  bool allowChoosingOwner = false,
}) async {
  final state = context.read<AppState>();
  final messenger = ScaffoldMessenger.of(context);

  FilePickerResult? result;
  try {
    result = await FilePicker.pickFiles(
      type: FileType.image,
      allowMultiple: true,
      withData: true,
    );
  } catch (_) {
    result = null;
  }
  if (result == null || result.files.isEmpty) return 0;

  final pictures = <Uint8List>[
    for (final file in result.files)
      if (file.bytes != null && file.bytes!.isNotEmpty) file.bytes!,
  ];
  if (pictures.isEmpty) {
    messenger.showSnackBar(
      const SnackBar(content: Text('Those files could not be read.')),
    );
    return 0;
  }
  if (!context.mounted) return 0;

  final details = await showModalBottomSheet<_UploadDetails>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _UploadSheet(
      pictures: pictures,
      characterId: characterId,
      characters: allowChoosingOwner ? state.characters : const <Character>[],
    ),
  );
  if (details == null) return 0;

  final added = await state.addGalleryImages(
    pictures,
    characterId: details.characterId,
    title: details.title,
    tags: details.tags,
  );
  if (!context.mounted) return added.length;
  if (added.isEmpty) {
    messenger.showSnackBar(
      const SnackBar(content: Text('Those pictures could not be stored.')),
    );
  } else {
    messenger.showSnackBar(SnackBar(
      content: Text(added.length == 1
          ? 'Added ${added.single.displayTitle}.'
          : 'Added ${added.length} pictures.'),
    ));
  }
  return added.length;
}

/// What the sheet collected.
class _UploadDetails {
  const _UploadDetails({
    required this.title,
    required this.tags,
    required this.characterId,
  });

  final String title;
  final List<String> tags;
  final String? characterId;
}

class _UploadSheet extends StatefulWidget {
  const _UploadSheet({
    required this.pictures,
    required this.characterId,
    required this.characters,
  });

  final List<Uint8List> pictures;
  final String? characterId;

  /// Non-empty when the owner may be chosen here (the whole-app gallery).
  final List<Character> characters;

  @override
  State<_UploadSheet> createState() => _UploadSheetState();
}

class _UploadSheetState extends State<_UploadSheet> {
  final TextEditingController _title = TextEditingController();
  List<String> _tags = <String>[];
  String? _owner;

  @override
  void initState() {
    super.initState();
    _owner = widget.characterId;
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  bool get _many => widget.pictures.length > 1;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);

    return Padding(
      // The keyboard pushes the sheet's content up rather than covering the
      // fields it came for.
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: media.size.height * 0.85),
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + media.padding.bottom),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _many
                    ? 'Add ${widget.pictures.length} pictures'
                    : 'Add a picture',
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: 4),
              Text(
                _many
                    ? 'They share these details — each one is numbered, and any '
                        'of them can be edited afterwards.'
                    : 'Give it a name you would search for later.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              _Previews(pictures: widget.pictures),
              const SizedBox(height: 16),
              TextField(
                controller: _title,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: 'Title',
                  hintText: 'e.g. Beach outfit',
                  helperText: _many ? 'Numbered: "Beach outfit 1", "…2"' : null,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
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
                    child: FilledButton.icon(
                      onPressed: () => Navigator.of(context).pop(
                        _UploadDetails(
                          title: _title.text.trim(),
                          tags: _tags,
                          characterId: _owner,
                        ),
                      ),
                      icon: const Icon(Icons.add_photo_alternate_outlined),
                      label: Text(_many ? 'Add all' : 'Add'),
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

/// Thumbnails of what is about to be added, so the sheet is obviously about
/// *these* pictures.
class _Previews extends StatelessWidget {
  const _Previews({required this.pictures});

  final List<Uint8List> pictures;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 96,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: pictures.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) => ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Container(
            width: 96,
            height: 96,
            color: scheme.surfaceContainerHighest,
            child: Image.memory(
              pictures[i],
              fit: BoxFit.cover,
              // Decoded at the size it is drawn: a picture straight off the
              // camera is many megabytes, and a row of them at full resolution
              // is exactly the sort of thing that makes a sheet stutter open.
              cacheWidth: 192,
              errorBuilder: (_, _, _) =>
                  Icon(Icons.broken_image_outlined, color: scheme.outline),
            ),
          ),
        ),
      ),
    );
  }
}

