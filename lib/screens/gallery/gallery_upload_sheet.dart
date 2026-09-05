import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/character.dart';
import '../../models/gallery_image.dart';
import '../../state/app_state.dart';
import '../../widgets/tag_entry_field.dart';
import 'gallery_actions.dart';

/// Picks pictures off the device and files them, naming each one first.
///
/// Returns the number added (0 when the picker was dismissed, the sheet cancelled,
/// or nothing could be stored). Nothing is written until the sheet's Add is
/// pressed, so backing out leaves the gallery as it was.
Future<int> showGalleryUploadSheet(
  BuildContext context, {
  String? characterId,
  bool allowChoosingOwner = false,
}) async {
  final state = context.read<AppState>();
  final messenger = ScaffoldMessenger.of(context);

  FilePickerResult? result;
  try {
    // Deliberately **without** `withData`: that reads every selected photo into
    // memory before the sheet has even opened, which for a couple of dozen camera
    // pictures is hundreds of megabytes. The sheet only needs to draw them, and it
    // draws them from their paths at thumbnail size.
    result = await FilePicker.pickFiles(
      type: FileType.image,
      allowMultiple: true,
    );
  } catch (_) {
    result = null;
  }
  if (result == null || result.files.isEmpty) return 0;

  final picked = <GalleryUpload>[
    for (final file in result.files)
      if (file.path != null || (file.bytes?.isNotEmpty ?? false))
        GalleryUpload(
          title: '',
          path: file.path,
          bytes: file.path == null ? file.bytes : null,
          name: file.name,
        ),
  ];
  if (picked.isEmpty) {
    messenger.showSnackBar(
      const SnackBar(content: Text('Those files could not be read.')),
    );
    return 0;
  }
  if (!context.mounted) return 0;

  final added = await showGalleryNamingSheet(
    context,
    picked: picked,
    characterId: characterId,
    characters: allowChoosingOwner ? state.characters : const <Character>[],
  );
  if (added == null) return 0;
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

/// The naming step on its own, over pictures that have already been chosen: one
/// row per picture, a box for each name, and the tags and owner they share.
///
/// It files what it collected itself rather than handing the details back, because
/// the pictures are written one at a time and this sheet is what draws how far it
/// has got — so it has to still be on screen while that happens. Answers with the
/// records it added, or null when it was dismissed.
Future<List<GalleryImage>?> showGalleryNamingSheet(
  BuildContext context, {
  required List<GalleryUpload> picked,
  String? characterId,
  List<Character> characters = const <Character>[],
}) =>
    showModalBottomSheet<List<GalleryImage>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _UploadSheet(
        picked: picked,
        characterId: characterId,
        characters: characters,
      ),
    );

class _UploadSheet extends StatefulWidget {
  const _UploadSheet({
    required this.picked,
    required this.characterId,
    required this.characters,
  });

  final List<GalleryUpload> picked;
  final String? characterId;

  /// Non-empty when the owner may be chosen here (the whole-app gallery).
  final List<Character> characters;

  @override
  State<_UploadSheet> createState() => _UploadSheetState();
}

class _UploadSheetState extends State<_UploadSheet> {
  /// One controller per picture — the whole point of the sheet. A shared title
  /// with a number stuck on the end is not a name for a photo.
  late final List<TextEditingController> _titles = [
    for (final _ in widget.picked) TextEditingController(),
  ];

  List<String> _tags = <String>[];
  String? _owner;

  /// How many have been written so far, while Add is running; null when it is not.
  int? _done;

  @override
  void initState() {
    super.initState();
    _owner = widget.characterId;
  }

  @override
  void dispose() {
    for (final controller in _titles) {
      controller.dispose();
    }
    super.dispose();
  }

  bool get _many => widget.picked.length > 1;
  bool get _working => _done != null;

  Future<void> _add() async {
    if (_working) return;
    setState(() => _done = 0);
    // A tag typed but never turned into a chip is still a tag. Dropping focus is
    // what commits it (see [TagEntryField]), and the focus manager applies that in
    // a microtask — so this hop is what stops the last tag of "beach, summer"
    // being lost by pressing Add instead of a comma.
    FocusManager.instance.primaryFocus?.unfocus();
    await Future<void>.microtask(() {});
    if (!mounted) return;
    final uploads = <GalleryUpload>[
      for (var i = 0; i < widget.picked.length; i++)
        widget.picked[i].withTitle(_titles[i].text.trim()),
    ];
    final added = await context.read<AppState>().addGalleryPictures(
          uploads,
          characterId: _owner,
          tags: _tags,
          onProgress: (done, _) {
            if (mounted) setState(() => _done = done);
          },
        );
    if (!mounted) return;
    Navigator.of(context).pop(added);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final size = MediaQuery.sizeOf(context);
    final safeBottom = MediaQuery.viewPaddingOf(context).bottom;

    return Padding(
      // The keyboard pushes the sheet's content up rather than covering the field
      // it came for.
      padding: EdgeInsets.only(bottom: keyboard),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: size.height * 0.85),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text(
                _many ? 'Name ${widget.picked.length} pictures' : 'Add a picture',
                style: theme.textTheme.titleLarge,
              ),
            ),
            // The rows scroll; the buttons under them do not, so Add is always
            // where the thumb left it however many pictures were picked.
            Flexible(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                children: [
                  for (var i = 0; i < widget.picked.length; i++)
                    _PictureRow(
                      key: ValueKey(_titles[i]),
                      upload: widget.picked[i],
                      title: _titles[i],
                      enabled: !_working,
                    ),
                  const SizedBox(height: 8),
                  const Divider(),
                  const SizedBox(height: 8),
                  // Tags and the owner are genuinely shared: a run of pictures
                  // picked together is one subject, and tagging thirty of them one
                  // at a time is not a feature.
                  TagEntryField(
                    tags: _tags,
                    onChanged: (tags) => setState(() => _tags = tags),
                  ),
                  if (widget.characters.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    GalleryOwnerField(
                      characters: widget.characters,
                      value: _owner,
                      onChanged: (id) => setState(() => _owner = id),
                    ),
                  ],
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(20, 8, 20, 16 + safeBottom),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed:
                          _working ? null : () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      key: const Key('gallery-upload-add'),
                      onPressed: _working ? null : _add,
                      icon: _working
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.add_photo_alternate_outlined),
                      label: Text(_working
                          ? 'Adding ${_done! + 1} of ${widget.picked.length}'
                          : (_many ? 'Add all' : 'Add')),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One picked picture: what it looks like, and the box its name goes in.
///
/// The thumbnail is decoded at the size it is drawn at *in device pixels* — the
/// number that was missing before, which is why a preview on a 3× phone was a
/// third of the resolution it needed and looked like a JPEG from 2004. Tapping it
/// opens the picture full size, because a photo among twenty photos often cannot be
/// told apart at 80dp.
class _PictureRow extends StatelessWidget {
  const _PictureRow({
    super.key,
    required this.upload,
    required this.title,
    required this.enabled,
  });

  final GalleryUpload upload;
  final TextEditingController title;
  final bool enabled;

  static const double _side = 80;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          GestureDetector(
            onTap: () => _openFullSize(context),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Container(
                width: _side,
                height: _side,
                color: scheme.surfaceContainerHighest,
                child: _thumbnail(context),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: title,
              enabled: enabled,
              maxLines: 1,
              textInputAction: TextInputAction.next,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: 'Title',
                // Kept up on the border rather than sitting in the box, so the
                // hint under it is readable while the box is still empty — which
                // is the only reason the hint is there.
                floatingLabelBehavior: FloatingLabelBehavior.always,
                // The file name, so a picture can be told apart before it has a
                // name of its own — and so leaving the box empty is an obvious
                // choice rather than a mystery.
                hintText: upload.name.isEmpty ? 'Optional' : upload.name,
                hintMaxLines: 1,
                // Faded well down: a file name at full strength reads as a title
                // that has already been filled in.
                hintStyle: TextStyle(
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.55),
                ),
                isDense: true,
                border: const OutlineInputBorder(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _thumbnail(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    final pixels = (_side * (dpr <= 0 ? 1 : dpr)).round();
    Widget broken() =>
        Icon(Icons.broken_image_outlined, color: scheme.outline);
    final path = upload.path;
    if (path != null && path.isNotEmpty) {
      return Image.file(
        File(path),
        fit: BoxFit.cover,
        cacheWidth: pixels,
        errorBuilder: (_, _, _) => broken(),
      );
    }
    final bytes = upload.bytes;
    if (bytes == null || bytes.isEmpty) return broken();
    return Image.memory(
      bytes,
      fit: BoxFit.cover,
      cacheWidth: pixels,
      errorBuilder: (_, _, _) => broken(),
    );
  }

  /// The picture on its own, at the size the display can actually show.
  void _openFullSize(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    final pixels = (size.width * (dpr <= 0 ? 1 : dpr)).round();
    final path = upload.path;
    final bytes = upload.bytes;
    final Widget picture;
    if (path != null && path.isNotEmpty) {
      picture = Image.file(File(path), fit: BoxFit.contain, cacheWidth: pixels);
    } else if (bytes != null && bytes.isNotEmpty) {
      picture = Image.memory(bytes, fit: BoxFit.contain, cacheWidth: pixels);
    } else {
      return;
    }
    showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (dialog) => GestureDetector(
        onTap: () => Navigator.of(dialog).pop(),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Center(child: picture),
        ),
      ),
    );
  }
}
