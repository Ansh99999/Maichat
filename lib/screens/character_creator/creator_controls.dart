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

/// How tall a writing box is, for [lines] of body text.
///
/// Every long field in the creator is a box of a **fixed** height that scrolls
/// inside itself, and that is deliberate. A box grown from `minLines` to
/// `maxLines` changes height as words wrap, so every keystroke moved the fields
/// below it and — because the caret then has to be scrolled back into view — the
/// page bobbed up and down under the cursor as it was typed into. A box that
/// never changes size cannot do that: the text scrolls, the layout does not move.
double creatorBoxHeight(BuildContext context, int lines) {
  final style = Theme.of(context).textTheme.bodyLarge;
  final line = (style?.fontSize ?? 16) * (style?.height ?? 1.45);
  return line * lines + 30;
}

/// The live token count for one field.
///
/// Counting is a real BPE pass, and every keystroke produces a string the
/// tokenizer has never seen — so the count is debounced rather than computed per
/// character. A quarter of a second after typing stops is soon enough to read as
/// live and cheap enough that a 4000-word description does not make the field
/// stutter.
///
/// A count is always drawn, zero included, so the row it sits on never changes
/// height as a field is emptied and filled again.
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
  int _tokens = 0;
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
    if (text == _counted) return;
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
    final text =
        '${approximate && tokens > 0 ? '≈' : ''}$tokens '
        '${tokens == 1 ? 'token' : 'tokens'}';
    return Text(
      text,
      style: widget.style ??
          Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
    );
  }
}

/// The three things you can do to a field, as symbols: let the AI write it, look
/// at it drawn the way the app will draw it, and open it on a screen of its own.
///
/// Lives in one widget so it can sit either on a plain field's own label row or on
/// the header of the fold that names it — a greeting is named once, by its fold,
/// and its tools belong up there beside the name rather than on a second row that
/// repeats it.
class CreatorFieldActions extends StatelessWidget {
  const CreatorFieldActions({
    super.key,
    required this.title,
    required this.controller,
    required this.draft,
    this.field,
    this.slot,
    this.onChanged,
    this.onPreview,
    this.previewKey,
    this.previewTooltip = 'Preview',
  });

  /// What the field is called — the assistant's heading and the full-screen
  /// editor's label.
  final String title;

  final TextEditingController controller;
  final CreatorDraft draft;

  /// Which card field this is, for the assistant. Null makes the AI symbol go
  /// away — a creator's own name is not something to generate.
  final WritableField? field;

  /// Which writing conversation this field owns. Fields that exist once can leave
  /// it null; a greeting or a scenario must not share one with its siblings.
  final String? slot;

  final VoidCallback? onChanged;

  /// Given, adds an eye between the assistant and the full-screen button.
  final VoidCallback? onPreview;
  final Key? previewKey;
  final String previewTooltip;

  @override
  Widget build(BuildContext context) {
    final target = field;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
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
              fieldLabel: title,
            ),
          ),
        if (onPreview != null)
          IconButton(
            key: previewKey,
            tooltip: previewTooltip,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.visibility_outlined, size: 20),
            onPressed: onPreview,
          ),
        IconButton(
          tooltip: 'Write full screen',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.open_in_full, size: 20),
          onPressed: () => openFullscreenField(
            context,
            title: title,
            controller: controller,
            draft: draft,
            field: target,
            slot: slot,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}

/// A field of the card: a fixed-height box to write in, and under it the token
/// count and whatever this field can have done to it.
///
/// [label] names it and carries the tools; a field inside a [CreatorFold] passes
/// null, because the fold already names it and holds them.
class CreatorField extends StatelessWidget {
  const CreatorField({
    super.key,
    required this.controller,
    required this.draft,
    this.label,
    this.field,
    this.hint,
    this.lines = 8,
    this.onChanged,
    this.aiLabel,
    this.slot,
    this.onPreview,
    this.previewKey,
    this.previewTooltip = 'Preview',
    this.footer,
  });

  final TextEditingController controller;
  final CreatorDraft draft;

  /// The field's name, drawn above the box with the tools beside it. Null leaves
  /// both out — see [CreatorFold].
  final String? label;

  final WritableField? field;
  final String? hint;

  /// How many lines of text the box shows. It never grows past that; the words
  /// scroll inside it. See [creatorBoxHeight].
  final int lines;

  final VoidCallback? onChanged;

  /// Overrides how the assistant names this field, for a field that appears more
  /// than once (a greeting).
  final String? aiLabel;

  final String? slot;

  /// Given, puts an eye on the label row.
  final VoidCallback? onPreview;
  final Key? previewKey;
  final String previewTooltip;

  /// A control at the right of the token row — where a fold's Remove goes.
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final name = label;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (name != null) ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    name,
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                CreatorFieldActions(
                  title: aiLabel ?? name,
                  controller: controller,
                  draft: draft,
                  field: field,
                  slot: slot,
                  onChanged: onChanged,
                  onPreview: onPreview,
                  previewKey: previewKey,
                  previewTooltip: previewTooltip,
                ),
              ],
            ),
            const SizedBox(height: 4),
          ],
          SizedBox(
            height: creatorBoxHeight(context, lines),
            child: TextField(
              controller: controller,
              // The box is the size it is: `expands` fills the height above and
              // scrolls the words inside it, so nothing below moves as they are
              // typed. See [creatorBoxHeight].
              expands: true,
              maxLines: null,
              minLines: null,
              textAlignVertical: TextAlignVertical.top,
              keyboardType: TextInputType.multiline,
              textCapitalization: TextCapitalization.sentences,
              onChanged: onChanged == null ? null : (_) => onChanged!(),
              decoration: InputDecoration(
                hintText: hint,
                alignLabelWithHint: true,
                contentPadding: const EdgeInsets.all(14),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 2, top: 2),
            child: Row(
              children: [
                TokenCount(controller: controller),
                const Spacer(),
                ?footer,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One thing on a tab, folded away until it is being worked on: a greeting, a
/// scenario.
///
/// Its header is the only place the thing is named, and while it is open the
/// header carries the field's tools too — so an open fold is a name, three
/// symbols, a box, and the count under it. Closed, it shows the first line of what
/// is written in it, which is what tells eight greetings apart.
///
/// Deliberately hand-built rather than an [ExpansionTile]: the tile puts its
/// trailing widget where the chevron goes, has no way to hide its subtitle while
/// it is open, and stores its open/closed **bool** under the page-storage
/// identifier that the [Scrollable] inside the fold's own text field reads as a
/// `double?` scroll offset — which threw out of `restoreScrollOffset` and left the
/// field unlaid-out.
class CreatorFold extends StatelessWidget {
  const CreatorFold({
    super.key,
    required this.title,
    required this.expanded,
    required this.onExpand,
    required this.child,
    this.preview,
    this.actions,
  });

  final String title;

  /// The first line of what is inside, shown only while the fold is closed.
  final String? preview;

  final bool expanded;
  final ValueChanged<bool> onExpand;

  /// The field's tools, shown on the header while the fold is open.
  final Widget? actions;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final summary = preview?.trim() ?? '';
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => onExpand(!expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 6, 4),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Row(
                  children: [
                    AnimatedRotation(
                      turns: expanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOutCubic,
                      child: Icon(
                        Icons.expand_more,
                        size: 22,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          if (!expanded)
                            Text(
                              summary.isEmpty ? 'Empty' : summary,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                        ],
                      ),
                    ),
                    if (expanded) ?actions,
                  ],
                ),
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
              child: child,
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
          maxLines: 1,
          textInputAction: TextInputAction.next,
          textCapitalization: TextCapitalization.words,
          onChanged: onChanged == null ? null : (_) => onChanged!(),
          decoration: InputDecoration(labelText: label, hintText: hint),
        ),
      );
}

/// The frame every creator tab sits in: one scrolling column that starts below the
/// pinned tab bar and keeps clear of the system bars.
class CreatorTabBody extends StatelessWidget {
  const CreatorTabBody({
    super.key,
    required this.children,
    this.padding = const EdgeInsets.fromLTRB(16, 12, 16, 32),
  });

  final List<Widget> children;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => CustomScrollView(
        // Always scrollable, even when the tab is shorter than the display.
        // Without this a short tab (Identity, Lorebooks) refuses the drag
        // outright — `ScrollPhysics.shouldAcceptUserOffset` is false for a list
        // with nothing to scroll — and the portrait above it can then never be
        // pushed off the top, which is the one thing the header is meant to do.
        // The `NestedScrollView` hands whatever the list cannot use to the
        // header, so the drag collapses the picture instead of doing nothing.
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          // How much of this list the pinned tab bar is standing on. Without it
          // the tab bar hangs *over* the top of the tab once the portrait has been
          // scrolled away, and the first thing on the tab — which used to be a
          // paragraph of explanation nobody minded losing, and is now the first
          // field — sits underneath it, unreadable and untappable.
          SliverOverlapInjector(
            handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context),
          ),
          // No room left for the keyboard here: the Scaffold already shrinks the
          // body by exactly that much, so adding the inset again left a
          // keyboard-sized hole under the last field that had to be scrolled past.
          SliverPadding(
            padding: padding,
            sliver: SliverList(
              delegate: SliverChildListDelegate(children),
            ),
          ),
        ],
      );
}
