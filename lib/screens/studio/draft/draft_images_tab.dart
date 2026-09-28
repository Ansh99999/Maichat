import 'package:flutter/material.dart';

import '../../../services/studio/studio_controller.dart';
import '../../../widgets/avatar_image.dart';
import '../../../widgets/smooth_image.dart';
import '../../gallery/gallery_picker_sheet.dart';
import 'draft_header.dart';
import 'draft_widgets.dart';

/// The character's pictures: the one they wear and the pool they can swipe to
/// in a chat ([Character.avatars]). A picture can be made the main one or taken
/// out, and more can be added from the gallery.
class DraftImagesTab extends StatelessWidget {
  const DraftImagesTab({super.key, required this.controller});

  final StudioController controller;

  Future<void> _actions(BuildContext context, String ref, bool main) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!main)
              ListTile(
                leading: const Icon(Icons.account_circle_outlined),
                title: const Text('Use as main picture'),
                onTap: () => Navigator.of(sheet).pop('main'),
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: Text(main ? 'Remove main picture' : 'Remove from pool'),
              onTap: () => Navigator.of(sheet).pop('remove'),
            ),
          ],
        ),
      ),
    );
    if (action == 'main') {
      controller.editByHand('Made another picture the main one', (ws) {
        final c = ws.character;
        c.avatars.remove(ref);
        if (c.hasAvatar && !c.avatars.contains(c.avatar)) {
          c.avatars.insert(0, c.avatar);
        }
        c.avatar = ref;
      });
    } else if (action == 'remove') {
      controller.editByHand(
        main ? 'Removed the main picture' : 'Removed a picture',
        (ws) {
          final c = ws.character;
          if (main) {
            // The next picture in the pool steps up rather than leaving a gap.
            c.avatar = c.avatars.isEmpty ? '' : c.avatars.removeAt(0);
          } else {
            c.avatars.remove(ref);
          }
        },
      );
    }
  }

  Future<void> _add(BuildContext context) async {
    final c = controller.session.workspace.character;
    final ref = await showGalleryPickerSheet(
      context,
      title: 'Add a picture',
      characterId: c.id,
    );
    if (ref == null || ref.trim().isEmpty) return;
    controller.editByHand('Added a picture', (ws) {
      final c = ws.character;
      if (!c.hasAvatar) {
        c.avatar = ref;
      } else if (c.avatar != ref && !c.avatars.contains(ref)) {
        c.avatars.add(ref);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = controller.session.workspace.character;
    final locked = controller.running;
    final pictures = [
      if (c.hasAvatar) c.avatar,
      ...c.avatars.where((a) => a.trim().isNotEmpty && a != c.avatar),
    ];
    return ListView(
      key: const PageStorageKey('draft-images'),
      padding: EdgeInsets.only(bottom: 24 + MediaQuery.paddingOf(context).bottom),
      children: [
        DraftHeader(character: c),
        if (locked) const DraftLockedNote(),
        DraftSectionLabel('Pictures · ${pictures.length}'),
        if (pictures.isEmpty)
          const DraftEmpty(
            icon: Icons.image_outlined,
            text: 'No pictures yet. Ask the Studio to paint a portrait, or add '
                'one from your gallery.',
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: GridView.count(
              crossAxisCount: 3,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                for (var i = 0; i < pictures.length; i++)
                  _PictureTile(
                    key: ValueKey('draft-picture-$i'),
                    imageRef: pictures[i],
                    main: i == 0 && c.hasAvatar,
                    onTap: locked
                        ? null
                        : () => _actions(context, pictures[i], i == 0 && c.hasAvatar),
                  ),
              ],
            ),
          ),
        DraftAddButton(
          label: 'Add from gallery',
          icon: Icons.add_photo_alternate_outlined,
          onPressed: locked ? null : () => _add(context),
        ),
      ],
    );
  }
}

class _PictureTile extends StatelessWidget {
  const _PictureTile({
    super.key,
    required this.imageRef,
    required this.main,
    this.onTap,
  });

  final String imageRef;
  final bool main;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final image = avatarImage(imageRef, displaySize: 140, devicePixelRatio: dpr);
    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(main ? 28 : 18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (image != null)
              SmoothImage(image: image, fit: BoxFit.cover, gaplessPlayback: true)
            else
              Icon(Icons.broken_image_outlined, color: scheme.outline),
            if (main)
              Positioned(
                left: 8,
                bottom: 8,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    'Main',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: scheme.onPrimaryContainer,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
