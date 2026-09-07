import 'dart:io';

import 'package:image_picker/image_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/character.dart';
import '../../models/gallery_image.dart';
import '../../state/app_state.dart';
import '../../widgets/tag_entry_field.dart';
import 'gallery_actions.dart';

/// How a batch of pictures is pulled off the device: returns the picked
/// pictures, or throws on a picker failure. [pickGalleryImages] is the default;
/// tests hand in a fake so the whole import runs without a device dialog.
typedef GalleryPicker = Future<List<GalleryUpload>> Function();

/// Picks pictures off the device and files them, naming each one first.
///
/// Returns the number added (0 when the picker was dismissed, the sheet cancelled,
/// or nothing could be stored). Nothing is written until the sheet's Add is
/// pressed, so backing out leaves the gallery as it was.
Future<int> showGalleryUploadSheet(
  BuildContext context, {
  String? characterId,
  bool allowChoosingOwner = false,
  GalleryPicker? picker,
}) async {
  final state = context.read<AppState>();
  final messenger = ScaffoldMessenger.of(context);

  List<GalleryUpload> picked;
  try {
    // The system Photo Picker ([pickGalleryImages]) is used instead of
    // file_picker's ACTION_GET_CONTENT intent, which silently came back empty
    // for a multi-pick on Android (the bug this replaces). It hands back
    // temp-file paths, so a batch is never more than a set of file references
    // in memory — the same one-at-a-time rule the rest of the import follows.
    picked = await (picker ?? pickGalleryImages)();
  } catch (error) {
    // Say so. A swallowed failure here is indistinguishable from a tap that did
    // nothing at all, which is exactly how a broken picker gets reported.
    debugPrint('MaiChat: the picture picker failed ($error)');
    messenger.showSnackBar(SnackBar(
      content: Text('The picture picker could not be opened: $error'),
      duration: const Duration(seconds: 6),
    ));
    return 0;
  }
  // Backing out of the picker is normal and stays silent — the Photo Picker
  // answers an empty list for a cancel, so there is no "no files" case to talk
  // about the way ACTION_GET_CONTENT had.
  if (picked.isEmpty) return 0;
  if (!context.mounted) return 0;

  return nameAndFilePictures(
    context,
    picked: picked,
    characterId: characterId,
    characters: allowChoosingOwner ? state.characters : const <Character>[],
  );
}

/// Asks the system Photo Picker for pictures, as [GalleryUpload]s still waiting
/// for their names.
///
/// The system Photo Picker is chosen over file_picker's ACTION_GET_CONTENT
/// route deliberately: that route came back with nothing at all for a multi-pick
/// on Android — "pick several, then nothing" — whereas the Photo Picker is the
/// permission-free, Google-supported path and even recovers its own result if
/// the activity is killed mid-pick. `pickMultiImage` copies each pick into the
/// app's cache and hands back one file path per picture, so the "pictures are
/// files, never base64 in the store" invariant is untouched.
Future<List<GalleryUpload>> pickGalleryImages() async {
  final files = await ImagePicker().pickMultiImage();
  return <GalleryUpload>[
    for (final file in files)
      GalleryUpload(title: '', path: file.path, name: file.name),
  ];
}

/// Everything after the picker: name them, then file them.
///
/// The screen's own path with the picker taken out, so the whole import can be
/// driven without a device dialog in the way.
///
/// The sheet **collects** and this writes. Nothing is written from inside the
/// sheet: it is a route, and a route that goes away mid-write — dismissed by a
/// drag, or by anything that rebuilds the navigator — takes the rest of the import
/// with it. Returns the number added.
Future<int> nameAndFilePictures(
  BuildContext context, {
  required List<GalleryUpload> picked,
  String? characterId,
  List<Character> characters = const <Character>[],
}) async {
  final state = context.read<AppState>();
  final messenger = ScaffoldMessenger.of(context);

  final details = await showGalleryNamingSheet(
    context,
    picked: picked,
    characterId: characterId,
    characters: characters,
  );
  if (details == null) return 0;

  final added = await state.addGalleryPictures(
    details.uploads,
    characterId: details.characterId,
    tags: details.tags,
  );
  if (added.isEmpty) {
    messenger.showSnackBar(
      const SnackBar(content: Text('Those pictures could not be stored.')),
    );
  } else {
    final missed = picked.length - added.length;
    messenger.showSnackBar(SnackBar(
      content: Text([
        if (added.length == 1)
          'Added ${added.single.displayTitle}.'
        else
          'Added ${added.length} pictures.',
        if (missed > 0) '$missed could not be read.',
      ].join(' ')),
    ));
  }
  return added.length;
}

/// What the naming sheet collected: every picture with the name it was given, and
/// the tags and owner they share.
class GalleryNaming {
  const GalleryNaming({
    required this.uploads,
    required this.tags,
    this.characterId,
  });

  final List<GalleryUpload> uploads;
  final List<String> tags;
  final String? characterId;
}

/// The naming step on its own, over pictures that have already been chosen: one
/// row per picture, a box for each name, and the tags and owner they share.
///
/// Answers with what was collected, or null when it was dismissed. It writes
/// nothing — see [nameAndFilePictures].
Future<GalleryNaming?> showGalleryNamingSheet(
  BuildContext context, {
  required List<GalleryUpload> picked,
  String? characterId,
  List<Character> characters = const <Character>[],
}) =>
    showModalBottomSheet<GalleryNaming>(
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

  Future<void> _add() async {
    // A tag typed but never turned into a chip is still a tag. Dropping focus is
    // what commits it (see [TagEntryField]), and the focus manager applies that in
    // a microtask — so this hop is what stops the last tag of "beach, summer"
    // being lost by pressing Add instead of a comma.
    FocusManager.instance.primaryFocus?.unfocus();
    await Future<void>.microtask(() {});
    if (!mounted) return;
    Navigator.of(context).pop(GalleryNaming(
      uploads: <GalleryUpload>[
        for (var i = 0; i < widget.picked.length; i++)
          widget.picked[i].withTitle(_titles[i].text.trim()),
      ],
      tags: _tags,
      characterId: _owner,
    ));
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
            // The rows scroll when there are more than fit; the buttons under them
            // never move. `shrinkWrap` so a single picture does not stretch the
            // sheet to its full height with a hole above Add.
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                children: [
                  for (var i = 0; i < widget.picked.length; i++)
                    _PictureRow(
                      key: ValueKey(_titles[i]),
                      upload: widget.picked[i],
                      title: _titles[i],
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
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      key: const Key('gallery-upload-add'),
                      onPressed: _add,
                      icon: const Icon(Icons.add_photo_alternate_outlined),
                      label: Text(_many ? 'Add all' : 'Add'),
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
  });

  final GalleryUpload upload;
  final TextEditingController title;

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
    // Whatever the pick came with — the picker hands back paths, other callers
    // may hand over bytes instead.
    final bytes = upload.bytes;
    if (bytes != null && bytes.isNotEmpty) {
      return Image.memory(
        bytes,
        fit: BoxFit.cover,
        cacheWidth: pixels,
        errorBuilder: (_, _, _) => broken(),
      );
    }
    final path = upload.path;
    if (path == null || path.isEmpty) return broken();
    return Image.file(
      File(path),
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
    final bytes = upload.bytes;
    final path = upload.path;
    final Widget picture;
    if (bytes != null && bytes.isNotEmpty) {
      picture = Image.memory(bytes, fit: BoxFit.contain, cacheWidth: pixels);
    } else if (path != null && path.isNotEmpty) {
      picture = Image.file(File(path), fit: BoxFit.contain, cacheWidth: pixels);
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
