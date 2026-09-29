import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../../models/chat_interface.dart';
import '../../../models/message_image.dart';
import '../../../services/studio/studio_controller.dart';
import '../../../state/app_state.dart';
import '../../../widgets/avatar_image.dart';
import '../../../widgets/smooth_image.dart';

/// The Studio's composer: the same one the user picked for their chats —
/// Legacy's flat send bar or the Expressive rounded box — without what only a
/// chat has (the persona avatar and name, the operations strip). Its ⋯ raises
/// the actions capsule above it ([onToggleActions]); the pictures that capsule
/// adds are held by the shell in [attachments] and previewed here.
///
/// The Expressive box floats: nothing is drawn around it, so the page shows
/// through on every side, as it does in a chat.
class StudioComposer extends StatefulWidget {
  const StudioComposer({
    super.key,
    required this.controller,
    required this.input,
    required this.attachments,
    required this.actionsOpen,
    required this.onToggleActions,
  });

  final StudioController controller;

  /// The text box's controller, held by the shell so the empty state's
  /// example openings can drop text into it.
  final TextEditingController input;

  /// Pictures waiting to go with the next message, as `local:`/URL refs.
  final ValueNotifier<List<MessageImage>> attachments;

  final bool actionsOpen;
  final VoidCallback onToggleActions;

  @override
  State<StudioComposer> createState() => _StudioComposerState();
}

class _StudioComposerState extends State<StudioComposer> {
  final FocusNode _focus = FocusNode();

  StudioController get _c => widget.controller;
  List<MessageImage> get _attachments => widget.attachments.value;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
    widget.attachments.addListener(_onAttachments);
  }

  @override
  void didUpdateWidget(StudioComposer old) {
    super.didUpdateWidget(old);
    if (old.attachments != widget.attachments) {
      old.attachments.removeListener(_onAttachments);
      widget.attachments.addListener(_onAttachments);
    }
  }

  @override
  void dispose() {
    widget.attachments.removeListener(_onAttachments);
    _focus
      ..removeListener(_onFocus)
      ..dispose();
    super.dispose();
  }

  void _onFocus() => setState(() {});
  void _onAttachments() => setState(() {});

  void _send() {
    final text = widget.input.text.trim();
    if ((text.isEmpty && _attachments.isEmpty) || _c.running) return;
    final images = List<MessageImage>.of(_attachments);
    widget.input.clear();
    widget.attachments.value = const <MessageImage>[];
    _c.send(text, images: images);
  }

  void _remove(int i) =>
      widget.attachments.value = List<MessageImage>.of(_attachments)..removeAt(i);

  Widget _menu() => IconButton(
        key: const Key('studio-composer-ops'),
        tooltip: widget.actionsOpen ? 'Close actions' : 'Actions',
        visualDensity: VisualDensity.compact,
        isSelected: widget.actionsOpen,
        onPressed: widget.onToggleActions,
        icon: AnimatedRotation(
          turns: widget.actionsOpen ? 0.25 : 0,
          duration: const Duration(milliseconds: 260),
          curve: Easing.emphasizedDecelerate,
          child: const Icon(Icons.more_horiz),
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
                    onTap: () => _remove(i),
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
