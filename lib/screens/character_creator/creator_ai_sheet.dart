import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../services/chat_client.dart';
import '../../services/character_writer.dart';
import '../../state/app_state.dart';
import 'creator_draft.dart';

/// Opens the assistant over one field: say what you want, read what it says, and
/// find the field already written when you go back.
///
/// The conversation is kept on the [draft] under [slot], so closing the sheet and
/// opening it again continues where it left off — "make her colder" after "now in
/// third person" means what it should, because the model still has both.
///
/// [controller] is the field the answer lands in. [onList] replaces it for the one
/// field that is not text (the tags), which arrives as a list.
Future<void> showWriterSheet(
  BuildContext context, {
  required CreatorDraft draft,
  required WritableField field,
  TextEditingController? controller,
  void Function(List<String> values)? onList,
  String? slot,
  String? fieldLabel,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      // The keyboard is going to be up for most of this, so the sheet is given
      // room rather than being squeezed into a quarter of the screen.
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.86,
      ),
      builder: (_) => WriterSheet(
        draft: draft,
        field: field,
        controller: controller,
        onList: onList,
        slot: slot ?? field.name,
        fieldLabel: fieldLabel ?? field.label,
      ),
    );

/// The body of [showWriterSheet], exposed for tests.
class WriterSheet extends StatefulWidget {
  const WriterSheet({
    super.key,
    required this.draft,
    required this.field,
    required this.slot,
    required this.fieldLabel,
    this.controller,
    this.onList,
  });

  final CreatorDraft draft;
  final WritableField field;
  final String slot;
  final String fieldLabel;
  final TextEditingController? controller;
  final void Function(List<String> values)? onList;

  @override
  State<WriterSheet> createState() => _WriterSheetState();
}

class _WriterSheetState extends State<WriterSheet> {
  final TextEditingController _ask = TextEditingController();
  final ScrollController _scroll = ScrollController();

  /// The reply as it arrives, so the sheet fills in rather than sitting blank.
  String _streaming = '';
  bool _busy = false;
  String? _error;

  List<WriterTurn> get _turns =>
      widget.draft.conversations[widget.slot] ??= <WriterTurn>[];

  @override
  void dispose() {
    _ask.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final ask = _ask.text.trim();
    if (ask.isEmpty || _busy) return;
    final state = context.read<AppState>();
    final controller = widget.controller;
    final previous = controller?.text ?? '';

    setState(() {
      _turns.add(WriterTurn.user(ask));
      _ask.clear();
      _busy = true;
      _error = null;
      _streaming = '';
    });
    _toBottom();

    try {
      final reply = await state.askAssistant(
        messages: CharacterWriter.messagesFor(
          field: widget.field,
          draft: widget.draft.snapshot(),
          currentValue: previous,
          // The turn just added is the ask, so the history is everything before
          // it — sending it twice would have the model answer itself.
          history: _turns.sublist(0, _turns.length - 1),
          ask: ask,
          userName: state.defaultPersona?.displayName ?? 'User',
        ),
        onProgress: (text) {
          if (!mounted) return;
          setState(() => _streaming = text);
        },
      );
      if (!mounted) return;
      final result = CharacterWriter.parse(reply);
      final wrote = _apply(result, previous);
      setState(() {
        _busy = false;
        _streaming = '';
        _turns.add(WriterTurn.assistant(_noteFor(result, wrote)));
      });
      widget.draft.touch();
      _toBottom();
    } on ChatApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _streaming = '';
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _streaming = '';
        _error = '$e';
      });
    }
  }

  /// Puts the answer in the field. Returns whether anything was actually written —
  /// a reply that only talked leaves the field alone.
  bool _apply(WriterResult result, String previous) {
    if (!result.wroteField) return false;
    final text = result.fieldText!;
    if (widget.field.isList) {
      final values = CharacterWriter.parseTags(text);
      if (values.isEmpty) return false;
      widget.onList?.call(values);
      return true;
    }
    final controller = widget.controller;
    if (controller == null) return false;
    widget.draft.undo[widget.slot] = previous;
    controller.text = text;
    return true;
  }

  /// What the assistant's bubble says. Its own remark when it made one; otherwise
  /// a plain statement of what happened, because a bubble that says nothing looks
  /// like a failure.
  String _noteFor(WriterResult result, bool wrote) {
    final note = result.note.trim();
    if (note.isNotEmpty) return note;
    if (wrote) return 'Written into ${widget.fieldLabel}.';
    return 'Nothing came back.';
  }

  void _undo() {
    final previous = widget.draft.undo.remove(widget.slot);
    final controller = widget.controller;
    if (previous == null || controller == null) return;
    controller.text = previous;
    widget.draft.touch();
    setState(() {});
  }

  void _clear() {
    setState(() {
      widget.draft.conversations.remove(widget.slot);
      _error = null;
    });
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final state = context.watch<AppState>();
    final turns = _turns;
    final model = state.activeProvider?.model.trim() ?? '';
    final canUndo = widget.draft.undo.containsKey(widget.slot);

    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Write ${widget.fieldLabel.toLowerCase()}',
                            style: theme.textTheme.titleMedium),
                        Text(
                          model.isEmpty
                              ? 'No model set — pick one in Settings'
                              : model,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  if (canUndo)
                    TextButton.icon(
                      key: const Key('writer-undo'),
                      onPressed: _undo,
                      icon: const Icon(Icons.undo, size: 18),
                      label: const Text('Undo'),
                    ),
                  if (turns.isNotEmpty)
                    IconButton(
                      key: const Key('writer-clear'),
                      tooltip: 'Start over',
                      icon: const Icon(Icons.restart_alt),
                      onPressed: _busy ? null : _clear,
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                children: [
                  if (turns.isEmpty && !_busy)
                    _Opening(field: widget.field, label: widget.fieldLabel),
                  for (final turn in turns)
                    _Bubble(text: turn.text, fromUser: turn.fromUser),
                  if (_busy)
                    _Bubble(
                      text: _streaming.isEmpty ? 'Thinking…' : _streaming,
                      fromUser: false,
                      pending: true,
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _error!,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.error),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('writer-ask'),
                      controller: _ask,
                      minLines: 1,
                      maxLines: 4,
                      textCapitalization: TextCapitalization.sentences,
                      onSubmitted: (_) => _send(),
                      decoration: InputDecoration(
                        hintText: turns.isEmpty
                            ? 'What should it say?'
                            : 'Ask for a change',
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
                  const SizedBox(width: 6),
                  IconButton.filled(
                    key: const Key('writer-send'),
                    tooltip: 'Send',
                    onPressed: _busy ? null : _send,
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

/// What the sheet says before anything has been asked: what this field is, and
/// two examples of the kind of thing that works.
class _Opening extends StatelessWidget {
  const _Opening({required this.field, required this.label});

  final WritableField field;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Say what you want in $label and it will be written straight into the '
          'field. Ask for changes afterwards — this conversation is kept, so you '
          'can come back to it.',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        Text(
          'For example: "${_example(field)}"',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
            fontStyle: FontStyle.italic,
          ),
        ),
      ],
    );
  }

  static String _example(WritableField field) => switch (field) {
        WritableField.title =>
          'a line that hints she used to be family, without saying it outright',
        WritableField.description =>
          'a retired duellist running a tea house in a rain-soaked port city',
        WritableField.personality => 'warm in public, ruthless when it counts',
        WritableField.scenario =>
          'we meet again at her sister\'s funeral, twelve years on',
        WritableField.greeting =>
          'she opens by pretending not to recognise me',
        WritableField.exampleDialogue =>
          'two exchanges that show she deflects with jokes',
        WritableField.systemPrompt =>
          'keep replies to two paragraphs and never write my lines',
        WritableField.postHistory => 'remind it to stay in the past tense',
        WritableField.creatorNotes =>
          'a short note saying this card is slow-burn and needs a long context',
        WritableField.tags => 'tags for a noir fantasy slow-burn romance',
      };
}

/// One turn of the conversation.
class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.text,
    required this.fromUser,
    this.pending = false,
  });

  final String text;
  final bool fromUser;
  final bool pending;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: fromUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.82,
        ),
        decoration: BoxDecoration(
          color: fromUser
              ? scheme.primaryContainer
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (pending) ...[
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 10),
            ],
            Flexible(
              child: Text(
                text,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: fromUser
                          ? scheme.onPrimaryContainer
                          : scheme.onSurface,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
