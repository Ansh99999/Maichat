import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../../models/chat_interface.dart';
import '../../../models/message_image.dart';
import '../../../services/studio/studio_controller.dart';
import '../../../state/app_state.dart';
import '../../../widgets/avatar_image.dart';
import '../../../widgets/smooth_image.dart';
import '../../gallery/gallery_picker_sheet.dart';

/// The Studio's composer: the same one the user picked for their chats —
/// Legacy's flat send bar or the Expressive rounded box — without what only a
/// chat has (the persona avatar and name, the operations strip). Its ⋯ opens a
/// menu: Add image (gallery or device), and More actions → Show other areas.
///
/// Pictures are files like every other picture in the app: the gallery hands a
/// `local:` ref over as it is, and a picture off the device is written into the
/// pictures directory first, so the turn holds refs and never a blob.
class StudioComposer extends StatefulWidget {
  const StudioComposer({
    super.key,
    required this.controller,
    required this.input,
    required this.areasShown,
    required this.onToggleAreas,
  });

  final StudioController controller;

  /// The text box's controller, held by the shell so the empty state's
  /// example openings can drop text into it.
  final TextEditingController input;

  final bool areasShown;
  final VoidCallback onToggleAreas;

  @override
  State<StudioComposer> createState() => _StudioComposerState();
}

class _StudioComposerState extends State<StudioComposer> {
  final FocusNode _focus = FocusNode();
  final List<MessageImage> _attachments = <MessageImage>[];

  StudioController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  @override
  void dispose() {
    _focus
      ..removeListener(_onFocus)
      ..dispose();
    super.dispose();
  }

  void _onFocus() => setState(() {});

  void _send() {
    final text = widget.input.text.trim();
    if ((text.isEmpty && _attachments.isEmpty) || _c.running) return;
    final images = List<MessageImage>.of(_attachments);
    widget.input.clear();
    setState(_attachments.clear);
    _c.send(text, images: images);
  }

  Future<void> _fromGallery() async {
    final ref = await showGalleryPickerSheet(
      context,
      title: 'Add a picture',
      characterId: _c.session.workspace.character.id,
    );
    if (ref == null || !mounted) return;
    setState(() => _attachments.add(MessageImage(ref: ref, mime: mimeForRef(ref))));
  }

  Future<void> _fromDevice() async {
    final state = context.read<AppState>();
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
    if (result == null || result.files.isEmpty || !mounted) return;
    final chosen = <MessageImage>[];
    for (final file in result.files) {
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) continue;
      final image = await state.storeAttachment(bytes);
      if (image != null) chosen.add(image);
    }
    if (!mounted) return;
    if (chosen.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Those pictures could not be read.'),
      ));
      return;
    }
    setState(() => _attachments.addAll(chosen));
  }

  Widget _menu() => MenuAnchor(
        alignmentOffset: const Offset(-160, 0),
        menuChildren: [
          SubmenuButton(
            key: const Key('studio-composer-add-image'),
            leadingIcon: const Icon(Icons.image_outlined),
            menuChildren: [
              MenuItemButton(
                key: const Key('studio-attach-gallery'),
                leadingIcon: const Icon(Icons.photo_library_outlined),
                onPressed: _fromGallery,
                child: const Text('From gallery'),
              ),
              MenuItemButton(
                key: const Key('studio-attach-device'),
                leadingIcon: const Icon(Icons.add_photo_alternate_outlined),
                onPressed: _fromDevice,
                child: const Text('From device'),
              ),
            ],
            child: const Text('Add image'),
          ),
          SubmenuButton(
            key: const Key('studio-composer-more-actions'),
            leadingIcon: const Icon(Icons.more_horiz),
            menuChildren: [
              MenuItemButton(
                key: const Key('studio-toggle-areas'),
                leadingIcon: Icon(widget.areasShown
                    ? Icons.visibility_off_outlined
                    : Icons.view_carousel_outlined),
                onPressed: widget.onToggleAreas,
                child: Text(widget.areasShown
                    ? 'Hide other areas'
                    : 'Show other areas'),
              ),
            ],
            child: const Text('More actions'),
          ),
        ],
        builder: (context, menu, _) => IconButton(
          key: const Key('studio-composer-ops'),
          tooltip: 'More',
          visualDensity: VisualDensity.compact,
          isSelected: menu.isOpen,
          onPressed: () => menu.isOpen ? menu.close() : menu.open(),
          icon: const Icon(Icons.more_horiz),
        ),
      );

  Widget _sendButton() {
    final scheme = Theme.of(context).colorScheme;
    if (_c.running) {
      return IconButton.filled(
        key: const Key('studio-stop'),
        tooltip: 'Stop',
        onPressed: _c.stop,
        style: IconButton.styleFrom(
          backgroundColor: scheme.error,
          foregroundColor: scheme.onError,
        ),
        icon: const Icon(Icons.stop),
      );
    }
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: widget.input,
      builder: (context, value, _) => IconButton.filled(
        key: const Key('studio-send'),
        tooltip: 'Send',
        onPressed: value.text.trim().isEmpty && _attachments.isEmpty
            ? null
            : _send,
        icon: const Icon(Icons.arrow_upward),
      ),
    );
  }

  Widget _attachmentsRow() {
    if (_attachments.isEmpty) return const SizedBox(width: double.infinity);
    final scheme = Theme.of(context).colorScheme;
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    const side = 72.0;
    return SizedBox(
      key: const Key('studio-attachments'),
      height: side + 12,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        itemCount: _attachments.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final provider = avatarImage(
            _attachments[i].ref,
            displaySize: side,
            devicePixelRatio: dpr,
          );
          return Stack(
            clipBehavior: Clip.none,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox.square(
                  dimension: side,
                  child: provider == null
                      ? ColoredBox(
                          color: scheme.surfaceContainerHighest,
                          child: Icon(Icons.broken_image_outlined,
                              color: scheme.onSurfaceVariant),
                        )
                      : SmoothImage(image: provider, fit: BoxFit.cover),
                ),
              ),
              Positioned(
                top: -6,
                right: -6,
                child: Material(
                  color: scheme.inverseSurface,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => setState(() => _attachments.removeAt(i)),
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: Icon(Icons.close,
                          size: 14, color: scheme.onInverseSurface),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ui = context.select<AppState, ChatInterface>((s) => s.chatInterface);
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) => ui.composerStyle == ComposerStyle.legacy
          ? _legacy()
          : _expressive(ui),
    );
  }

  /// The legacy send bar: a flat slab with a divider on top, a field, ⋯ and
  /// Send in one row.
  Widget _legacy() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            alignment: Alignment.bottomCenter,
            child: _attachmentsRow(),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  key: const Key('studio-composer-field'),
                  controller: widget.input,
                  focusNode: _focus,
                  minLines: 1,
                  maxLines: 5,
                  textInputAction: TextInputAction.newline,
                  keyboardType: TextInputType.multiline,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    hintText: _hint(),
                    isDense: true,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _menu(),
              _sendButton(),
            ],
          ),
        ],
      ),
    );
  }

  /// The Expressive composer: one rounded, optionally outlined box that lifts
  /// into a primary glow on focus, with the field on top and ⋯ + Send beneath.
  Widget _expressive(ChatInterface ui) {
    final scheme = Theme.of(context).colorScheme;
    final focused = _focus.hasFocus;
    const radius = BorderRadius.all(Radius.circular(28));
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: radius,
          border: ui.composerOutline
              ? Border.all(
                  color: focused ? scheme.primary : scheme.outline,
                  width: focused ? 2.5 : 2,
                )
              : null,
          boxShadow: (ui.composerOutline && focused)
              ? [
                  BoxShadow(
                    color: scheme.primary.withValues(alpha: 0.32),
                    blurRadius: 10,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedSize(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                alignment: Alignment.bottomCenter,
                child: _attachmentsRow(),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 132),
                child: TextField(
                  key: const Key('studio-composer-field'),
                  controller: widget.input,
                  focusNode: _focus,
                  minLines: 1,
                  maxLines: null,
                  textInputAction: TextInputAction.newline,
                  keyboardType: TextInputType.multiline,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    hintText: _hint(),
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 8, 8),
                child: Row(
                  children: [
                    const Spacer(),
                    _menu(),
                    _sendButton(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _hint() => _c.running
      ? 'Working — type the next message'
      : 'Describe the vibe, or ask for a change';
}
