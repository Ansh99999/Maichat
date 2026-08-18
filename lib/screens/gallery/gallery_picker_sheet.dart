import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/gallery_image.dart';
import '../../services/gallery_group.dart';
import '../../state/app_state.dart';
import '../../widgets/avatar_image.dart';

/// Picks one picture out of the gallery, returning its reference (a `local:` file
/// or a URL) — or null if the sheet was dismissed.
///
/// Used where the app needs *a picture* rather than a gallery record: a chat
/// background, for instance. Deliberately a simple grid: this is a chooser, not
/// somewhere to browse, so it has no date bands, no sort and no pinch.
Future<String?> showGalleryPickerSheet(
  BuildContext context, {
  String title = 'Choose a picture',
  String? characterId,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _PickerSheet(title: title, characterId: characterId),
  );
}

class _PickerSheet extends StatefulWidget {
  const _PickerSheet({required this.title, required this.characterId});

  final String title;

  /// When set, that character's pictures are offered first — the ones most likely
  /// to be wanted — with the rest of the gallery below.
  final String? characterId;

  @override
  State<_PickerSheet> createState() => _PickerSheetState();
}

class _PickerSheetState extends State<_PickerSheet> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<GalleryImage> _matches(AppState state) {
    final q = _query.trim().toLowerCase();
    final pool = sortImages(
      state.gallery.where((image) {
        if (q.isEmpty) return true;
        return image.displayTitle.toLowerCase().contains(q) ||
            image.tags.any((t) => t.toLowerCase().contains(q));
      }).toList(),
      GallerySort.newest,
    );
    final wanted = widget.characterId;
    if (wanted == null) return pool;
    // Theirs first, everything else after — a stable partition, not a sort.
    return [
      ...pool.where((i) => i.characterId == wanted),
      ...pool.where((i) => i.characterId != wanted),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final media = MediaQuery.of(context);
    final images = _matches(state);
    final empty = state.gallery.isEmpty;

    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: media.size.height * 0.8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(widget.title,
                  style: Theme.of(context).textTheme.titleLarge),
            ),
            if (!empty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                child: SearchBar(
                  controller: _search,
                  hintText: 'Search pictures',
                  padding: const WidgetStatePropertyAll(
                    EdgeInsets.symmetric(horizontal: 14),
                  ),
                  leading: const Icon(Icons.search),
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
            Flexible(
              child: empty
                  ? const _NothingInTheGallery()
                  : images.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.fromLTRB(20, 8, 20, 24),
                          child: Text('No pictures match.'),
                        )
                      : GridView.builder(
                          padding: EdgeInsets.fromLTRB(
                              12, 0, 12, 16 + media.padding.bottom),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            mainAxisSpacing: 8,
                            crossAxisSpacing: 8,
                          ),
                          itemCount: images.length,
                          itemBuilder: (context, i) => _PickerTile(
                            image: images[i],
                            onTap: () =>
                                Navigator.of(context).pop(images[i].image),
                          ),
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PickerTile extends StatelessWidget {
  const _PickerTile({required this.image, required this.onTap});

  final GalleryImage image;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final media = MediaQuery.of(context);
    final provider = avatarImage(
      image.image,
      displaySize: media.size.width / 3,
      devicePixelRatio: media.devicePixelRatio,
    );
    return Material(
      color: scheme.surfaceContainerHighest,
      clipBehavior: Clip.antiAlias,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        child: provider == null
            ? Center(
                child: Icon(Icons.broken_image_outlined,
                    color: scheme.outline, size: 20),
              )
            : Image(
                image: provider,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Center(
                  child: Icon(Icons.broken_image_outlined,
                      color: scheme.outline, size: 20),
                ),
              ),
      ),
    );
  }
}

class _NothingInTheGallery extends StatelessWidget {
  const _NothingInTheGallery();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 16, 32, 40),
      child: Column(
        children: [
          Icon(Icons.photo_library_outlined, size: 44, color: scheme.outline),
          const SizedBox(height: 12),
          Text(
            'The gallery is empty',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            'Add pictures from the Gallery section, or choose a file from this '
            'device instead.',
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
