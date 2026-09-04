import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/gallery_image.dart';
import '../../models/image_gen.dart';
import '../../models/message_image.dart';
import '../../services/chat_client.dart';
import '../../state/app_state.dart';
import '../../widgets/avatar_image.dart';
import '../../widgets/picture_viewer.dart';
import '../gallery/gallery_actions.dart';
import '../gallery/gallery_picker_sheet.dart';
import 'image_gen_settings.dart';

/// Opens the image studio over a chat: a sheet three quarters of the way up the
/// screen where pictures are made, looked at, kept and shared into the
/// conversation.
///
/// Every chat can do this whatever model it runs on, because generation goes to
/// the studio's own endpoint (see [ImageGenConfig]) rather than to the chat's
/// provider. [prompt] seeds the prompt box — that is how a message's "Generate
/// image" action hands its text over.
///
/// It also opens where there is no chat at all. The character creator makes a
/// portrait here, so [conversationId] is optional (without one there is nowhere
/// to send a picture, and that action goes away), [characterId] says whose album
/// the results belong in, and [picking] adds the button that hands a picture back
/// — which is what the returned ref is. Null means the sheet was dismissed, or
/// was never picking in the first place.
Future<String?> showImageStudio(
  BuildContext context, {
  String? conversationId,
  String? characterId,
  String prompt = '',
  bool picking = false,
  String pickLabel = 'Use picture',
}) =>
    showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      // Three quarters: enough for a picture to be worth looking at, little
      // enough that the conversation it belongs to is still visible behind it.
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.75,
      ),
      builder: (_) => ImageStudioSheet(
        conversationId: conversationId,
        characterId: characterId,
        initialPrompt: prompt,
        picking: picking,
        pickLabel: pickLabel,
      ),
    );

class ImageStudioSheet extends StatefulWidget {
  const ImageStudioSheet({
    super.key,
    this.conversationId,
    this.characterId,
    this.initialPrompt = '',
    this.picking = false,
    this.pickLabel = 'Use picture',
  });

  /// The chat the studio was opened over, or null when it was opened from
  /// somewhere that has no chat (the character creator).
  final String? conversationId;

  /// Whose gallery the pictures are filed under. Defaults to the chat's
  /// character when there is a chat.
  final String? characterId;

  final String initialPrompt;

  /// Whether the sheet is being used to *choose* a picture, in which case it pops
  /// with the chosen reference.
  final bool picking;

  final String pickLabel;

  @override
  State<ImageStudioSheet> createState() => _ImageStudioSheetState();
}

class _ImageStudioSheetState extends State<ImageStudioSheet> {
  late final TextEditingController _prompt =
      TextEditingController(text: widget.initialPrompt);

  /// Which face the sheet is showing: the studio, or its settings. The settings
  /// page replaces the studio *inside* the sheet rather than being pushed as a
  /// route, so backing out of it returns here with the sheet still open — the
  /// same trick the chat drawer's panels use.
  bool _settingsOpen = false;

  /// The pictures this session has made, newest first, as gallery records. They
  /// are filed in the gallery the moment they arrive, so this is a view of real
  /// records rather than a scratch buffer.
  final List<String> _madeIds = <String>[];

  /// Which of [_madeIds] is on show.
  int _shown = 0;

  /// Pictures handed to the endpoint as a starting point.
  final List<MessageImage> _references = <MessageImage>[];

  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  GalleryImage? _current(AppState state) {
    if (_madeIds.isEmpty) return null;
    final id = _madeIds[_shown.clamp(0, _madeIds.length - 1)];
    return state.galleryImageById(id);
  }

  Future<void> _generate(AppState state) async {
    if (_busy) return;
    final prompt = _prompt.text.trim();
    if (prompt.isEmpty) {
      setState(() => _error = 'Type what the picture should show.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final made = await state.generateImages(
        prompt: prompt,
        conversationId: widget.conversationId,
        characterId: widget.characterId,
        references: _references,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _madeIds.insertAll(0, made.map((i) => i.id));
        _shown = 0;
      });
    } on ChatApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$e';
      });
    }
  }

  Future<void> _addReference() async {
    final ref = await showGalleryPickerSheet(
      context,
      title: 'Use a picture as reference',
    );
    if (ref == null || !mounted) return;
    setState(() =>
        _references.add(MessageImage(ref: ref, mime: mimeForRef(ref))));
  }

  /// Saves the shown picture out of the app with the system's own save dialog —
  /// the permission-free path every other download here takes.
  Future<void> _download(AppState state) async {
    final image = _current(state);
    if (image == null) return;
    await exportGalleryImage(context, image);
  }

  /// Deletes the shown picture, gallery record and file together — the studio
  /// files everything it makes, so "delete" has to mean it.
  Future<void> _delete(AppState state) async {
    final image = _current(state);
    if (image == null) return;
    await state.deleteGalleryImage(image.id);
    if (!mounted) return;
    setState(() {
      _madeIds.remove(image.id);
      if (_shown >= _madeIds.length) _shown = _madeIds.length - 1;
      if (_shown < 0) _shown = 0;
    });
  }

  /// Puts the shown picture into the conversation as a turn of its own. It is
  /// then part of the transcript, so it rides along with the next request the way
  /// any attached picture does.
  Future<void> _share(AppState state) async {
    final image = _current(state);
    final conversationId = widget.conversationId;
    if (image == null || conversationId == null) return;
    await state.postImageToChat(
      conversationId,
      MessageImage(ref: image.image, mime: mimeForRef(image.image)),
    );
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  /// Hands the shown picture back to whoever opened the sheet to choose one.
  void _pick(AppState state) {
    final image = _current(state);
    if (image == null) return;
    Navigator.of(context).pop(image.image);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (_settingsOpen) {
      return ImageGenSettingsPage(
        onBack: () => setState(() => _settingsOpen = false),
      );
    }
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final image = _current(state);

    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Header(
              subtitle: state.imageGen.model.trim().isEmpty
                  ? 'No image model set'
                  : '${state.imageGen.kind.label} · ${state.imageGen.model}',
              onSettings: () => setState(() => _settingsOpen = true),
            ),
            const Divider(height: 1),
            // The picture is the point of the screen, so it takes whatever room
            // is left once the prompt box and the actions have theirs.
            Expanded(
              child: _Stage(
                busy: _busy,
                error: _error,
                image: image,
                count: _madeIds.length,
                index: _shown,
                onStep: (next) => setState(
                    () => _shown = next.clamp(0, _madeIds.length - 1)),
                onOpen: image == null
                    ? null
                    : () => showPictureViewer(
                          context,
                          refs: [
                            for (final id in _madeIds)
                              ?state.galleryImageById(id)?.image,
                          ],
                          index: _shown,
                          title: image.displayTitle,
                        ),
              ),
            ),
            if (image != null)
              _PictureActions(
                onDownload: () => _download(state),
                onDelete: () => _delete(state),
                onShare:
                    widget.conversationId == null ? null : () => _share(state),
                onPick: widget.picking ? () => _pick(state) : null,
                pickLabel: widget.pickLabel,
              ),
            if (_references.isNotEmpty)
              _ReferenceStrip(
                references: _references,
                onRemove: (i) => setState(() => _references.removeAt(i)),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _prompt,
                      minLines: 1,
                      maxLines: 4,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        hintText: 'Describe the picture',
                        isDense: true,
                        filled: true,
                        fillColor: scheme.surfaceContainerHigh,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    key: const Key('imagegen-reference-button'),
                    tooltip: 'Send a picture as reference',
                    visualDensity: VisualDensity.compact,
                    onPressed: _addReference,
                    icon: const Icon(Icons.more_horiz),
                  ),
                  IconButton.filled(
                    key: const Key('imagegen-send-button'),
                    tooltip: 'Generate',
                    onPressed: _busy ? null : () => _generate(state),
                    icon: const Icon(Icons.arrow_upward),
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

/// The studio's title row: what it is, what it is pointed at, and the way into
/// its settings.
class _Header extends StatelessWidget {
  const _Header({required this.subtitle, required this.onSettings});

  final String subtitle;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Image studio', style: theme.textTheme.titleMedium),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          IconButton(
            key: const Key('imagegen-settings-button'),
            tooltip: 'Image settings',
            onPressed: onSettings,
            icon: const Icon(Icons.tune),
          ),
        ],
      ),
    );
  }
}

/// Where the picture lives: the generated picture, a progress state while one is
/// being made, the failure when one could not be, and an invitation before
/// anything has been asked for.
class _Stage extends StatelessWidget {
  const _Stage({
    required this.busy,
    required this.error,
    required this.image,
    required this.count,
    required this.index,
    required this.onStep,
    required this.onOpen,
  });

  final bool busy;
  final String? error;
  final GalleryImage? image;

  /// How many pictures this session has made, and which is on show — a request
  /// for four returns four, and all of them are worth flipping through.
  final int count;
  final int index;
  final ValueChanged<int> onStep;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    Widget centred(Widget child) => Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
            child: child,
          ),
        );

    if (busy) {
      return centred(Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text('Making the picture…', style: theme.textTheme.bodyMedium),
        ],
      ));
    }
    if (error != null) {
      return centred(Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 40, color: scheme.error),
          const SizedBox(height: 12),
          Text(
            error!,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: scheme.error),
          ),
        ],
      ));
    }
    final current = image;
    if (current == null) {
      return centred(Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_awesome_outlined, size: 44, color: scheme.outline),
          const SizedBox(height: 12),
          Text(
            'Describe a picture and send. Everything made here is kept in the '
            'gallery, filed under this chat’s character.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ));
    }

    return LayoutBuilder(
      builder: (context, box) {
        final provider = avatarImage(
          current.image,
          displaySize: box.biggest.longestSide,
          devicePixelRatio: MediaQuery.maybeDevicePixelRatioOf(context) ?? 1,
        );
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: onOpen,
                child: provider == null
                    ? Center(
                        child: Icon(Icons.broken_image_outlined,
                            size: 40, color: scheme.outline),
                      )
                    : Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        child: Image(image: provider, fit: BoxFit.contain),
                      ),
              ),
            ),
            if (count > 1)
              Positioned(
                left: 4,
                right: 4,
                top: 0,
                bottom: 0,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _StepButton(
                      icon: Icons.chevron_left,
                      onTap: index > 0 ? () => onStep(index - 1) : null,
                    ),
                    _StepButton(
                      icon: Icons.chevron_right,
                      onTap: index < count - 1 ? () => onStep(index + 1) : null,
                    ),
                  ],
                ),
              ),
            if (count > 1)
              Positioned(
                top: 6,
                right: 12,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: scheme.surface.withValues(alpha: 0.8),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text('${index + 1} / $count',
                      style: theme.textTheme.labelSmall),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Opacity(
      opacity: onTap == null ? 0.25 : 1,
      child: Material(
        color: scheme.surface.withValues(alpha: 0.8),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: IconButton(
          visualDensity: VisualDensity.compact,
          onPressed: onTap,
          icon: Icon(icon),
        ),
      ),
    );
  }
}

/// What can be done with the picture on show, at the bottom-right of it: keep it
/// on the device, throw it away, or put it in the conversation.
class _PictureActions extends StatelessWidget {
  const _PictureActions({
    required this.onDownload,
    required this.onDelete,
    required this.onShare,
    this.onPick,
    this.pickLabel = 'Use picture',
  });

  final VoidCallback onDownload;
  final VoidCallback onDelete;

  /// Null when the studio was not opened over a chat — there is nowhere to send
  /// a picture, so the button is not there rather than there and inert.
  final VoidCallback? onShare;

  /// Set when the sheet is choosing a picture for its caller.
  final VoidCallback? onPick;
  final String pickLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          IconButton(
            key: const Key('imagegen-download'),
            tooltip: 'Save to this device',
            onPressed: onDownload,
            icon: const Icon(Icons.download_outlined),
          ),
          IconButton(
            key: const Key('imagegen-delete'),
            tooltip: 'Delete picture',
            color: scheme.error,
            onPressed: onDelete,
            icon: const Icon(Icons.delete_outline),
          ),
          if (onPick != null)
            FilledButton.tonalIcon(
              key: const Key('imagegen-pick'),
              onPressed: onPick,
              icon: const Icon(Icons.check, size: 18),
              label: Text(pickLabel),
            ),
          if (onShare != null)
            Padding(
              padding: EdgeInsets.only(left: onPick == null ? 0 : 8),
              child: FilledButton.tonalIcon(
                key: const Key('imagegen-share'),
                onPressed: onShare,
                icon: const Icon(Icons.send_outlined, size: 18),
                label: const Text('Send to chat'),
              ),
            ),
        ],
      ),
    );
  }
}

/// The reference pictures a generation will start from, each with its own ✕.
class _ReferenceStrip extends StatelessWidget {
  const _ReferenceStrip({required this.references, required this.onRemove});

  final List<MessageImage> references;
  final ValueChanged<int> onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 12, 0),
      child: Row(
        children: [
          Text('Reference', style: theme.textTheme.labelMedium),
          const SizedBox(width: 10),
          Expanded(
            child: SizedBox(
              height: 48,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: references.length,
                separatorBuilder: (_, _) => const SizedBox(width: 6),
                itemBuilder: (context, i) {
                  final provider = avatarImage(
                    references[i].ref,
                    displaySize: 48,
                    devicePixelRatio:
                        MediaQuery.maybeDevicePixelRatioOf(context) ?? 1,
                  );
                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                          width: 48,
                          height: 48,
                          child: provider == null
                              ? const ColoredBox(color: Colors.black26)
                              : Image(image: provider, fit: BoxFit.cover),
                        ),
                      ),
                      Positioned(
                        top: -8,
                        right: -8,
                        child: IconButton(
                          tooltip: 'Remove',
                          iconSize: 14,
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                              minWidth: 24, minHeight: 24),
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.black54,
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () => onRemove(i),
                          icon: const Icon(Icons.close),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
