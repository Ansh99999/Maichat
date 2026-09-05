import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../services/character_writer.dart';
import '../../state/app_state.dart';
import 'creator_ai_sheet.dart';
import 'creator_draft.dart';
import 'creator_fullscreen.dart';

/// Asks before something is taken away, and answers whether it should be.
///
/// One dialog behind every removal in the creator — a greeting, a scenario, a
/// picture, a lorebook's link — because all of them used to happen on a single
/// tap next to a text field somebody was typing in, and none of them could be
/// undone. [action] names the button, so a detach does not offer to "remove".
Future<bool> confirmRemoval(
  BuildContext context, {
  required String title,
  required String message,
  String action = 'Remove',
}) async {
  final yes = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(action),
        ),
      ],
    ),
  );
  return yes ?? false;
}

/// A tinted heading inside a creator tab — the one heading style the tabs use.
class CreatorLabel extends StatelessWidget {
  const CreatorLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 6),
        child: Text(
          text.toUpperCase(),
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
        ),
      );
}

/// A paragraph of quiet explanation, in the voice the settings pages use.
class CreatorNote extends StatelessWidget {
  const CreatorNote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
        child: Text(
          text,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      );
}

/// The live token count for one field.
///
/// Counting is a real BPE pass, and every keystroke produces a string the
/// tokenizer has never seen — so the count is debounced rather than computed per
/// character. A quarter of a second after typing stops is soon enough to read as
/// live and cheap enough that a 4000-word description does not make the field
/// stutter.
class TokenCount extends StatefulWidget {
  const TokenCount({
    super.key,
    required this.controller,
    this.style,
  });

  final TextEditingController controller;
  final TextStyle? style;

  @override
  State<TokenCount> createState() => _TokenCountState();
}

class _TokenCountState extends State<TokenCount> {
  Timer? _debounce;
  int? _tokens;
  String _counted = '';

  static const Duration _wait = Duration(milliseconds: 250);

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_schedule);
    // The first count happens after the frame: building a page must not wait on
    // a tokenizer warming its vocabulary up.
    WidgetsBinding.instance.addPostFrameCallback((_) => _count());
  }

  @override
  void didUpdateWidget(TokenCount old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_schedule);
      widget.controller.addListener(_schedule);
      _schedule();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    widget.controller.removeListener(_schedule);
    super.dispose();
  }

  void _schedule() {
    _debounce?.cancel();
    _debounce = Timer(_wait, _count);
  }

  void _count() {
    if (!mounted) return;
    final text = widget.controller.text;
    if (text == _counted && _tokens != null) return;
    final tokens = text.trim().isEmpty
        ? 0
        : context.read<AppState>().estimateTokens(text);
    setState(() {
      _counted = text;
      _tokens = tokens;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = _tokens;
    final approximate = context.read<AppState>().tokenizerIsApproximate;
    final text = tokens == null
        ? ''
        : '${approximate ? '≈' : ''}$tokens ${tokens == 1 ? 'token' : 'tokens'}';
    return Text(
      text,
      style: widget.style ??
          Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
    );
  }
}

/// A field of the card: its name, its token count, the way to write it
/// full-screen, the way to ask the assistant for it, and the box itself.
///
/// Every long field in the creator is one of these, so "expand it and write in
/// peace" and "let the AI write it" are in the same place on every tab rather
/// than being remembered per field.
class CreatorField extends StatelessWidget {
  const CreatorField({
    super.key,
    required this.label,
    required this.controller,
    required this.draft,
    this.field,
    this.hint,
    this.minLines = 4,
    this.maxLines = 10,
    this.trailing,
    this.onChanged,
    this.aiLabel,
    this.slot,
  });

  final String label;
  final TextEditingController controller;
  final CreatorDraft draft;

  /// Which card field this is, for the assistant. Null makes the AI button go
  /// away — a creator's own name is not something to generate.
  final WritableField? field;

  final String? hint;
  final int minLines;
  final int maxLines;

  /// An extra control on the header row, left of the expand and AI buttons.
  final Widget? trailing;

  final VoidCallback? onChanged;

  /// Overrides how the assistant names this field, for a field that appears more
  /// than once (a greeting).
  final String? aiLabel;

  /// Which writing conversation this field owns. Fields that exist once can leave
  /// it null; a greeting or a scenario must not share one with its siblings.
  final String? slot;

  @override
  Widget build(BuildContext context) {
    final target = field;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              TokenCount(controller: controller),
              ?trailing,
              if (target != null)
                IconButton(
                  tooltip: 'Let the AI write this',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.auto_awesome_outlined, size: 20),
                  onPressed: () => showWriterSheet(
                    context,
                    draft: draft,
                    field: target,
                    controller: controller,
                    slot: slot,
                    fieldLabel: aiLabel,
                  ),
                ),
              IconButton(
                tooltip: 'Write full screen',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.open_in_full, size: 20),
                onPressed: () => openFullscreenField(
                  context,
                  title: aiLabel ?? label,
                  controller: controller,
                  draft: draft,
                  field: target,
                  slot: slot,
                  onChanged: onChanged,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          TextField(
            controller: controller,
            minLines: minLines,
            maxLines: maxLines,
            keyboardType: TextInputType.multiline,
            textCapitalization: TextCapitalization.sentences,
            onChanged: (_) => onChanged?.call(),
            decoration: InputDecoration(
              hintText: hint,
              alignLabelWithHint: true,
            ),
          ),
        ],
      ),
    );
  }
}

/// A single-line field, for the short ones (a name, a creator, a version).
class CreatorLine extends StatelessWidget {
  const CreatorLine({
    super.key,
    required this.label,
    required this.controller,
    this.hint,
    this.onChanged,
    this.autofocus = false,
  });

  final String label;
  final TextEditingController controller;
  final String? hint;
  final VoidCallback? onChanged;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: TextField(
          controller: controller,
          autofocus: autofocus,
          textInputAction: TextInputAction.next,
          textCapitalization: TextCapitalization.words,
          onChanged: (_) => onChanged?.call(),
          decoration: InputDecoration(labelText: label, hintText: hint),
        ),
      );
}

/// The frame every creator tab sits in: one scrolling column that keeps clear of
/// the keyboard and of the system bars.
class CreatorTabBody extends StatelessWidget {
  const CreatorTabBody({
    super.key,
    required this.children,
    this.padding = const EdgeInsets.fromLTRB(16, 12, 16, 32),
  });

  final List<Widget> children;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => ListView(
        // Always scrollable, even when the tab is shorter than the display.
        // Without this a short tab (Identity, Lorebooks) refuses the drag
        // outright — `ScrollPhysics.shouldAcceptUserOffset` is false for a list
        // with nothing to scroll — and the portrait above it can then never be
        // pushed off the top, which is the one thing the header is meant to do.
        // The `NestedScrollView` hands whatever the list cannot use to the
        // header, so the drag collapses the picture instead of doing nothing.
        physics: const AlwaysScrollableScrollPhysics(),
        padding: padding.copyWith(
          bottom: padding.bottom + MediaQuery.viewInsetsOf(context).bottom,
        ),
        children: children,
      );
}
