import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/btw.dart';
import '../services/chat_client.dart';
import 'message_markdown.dart';

/// Asks a `/btw` side question: given the [BtwRun] to register its cancel on
/// and where to report the answer so far, resolves to the whole answer.
typedef BtwAsk = Future<String> Function(
  BtwRun run,
  void Function(String text) onProgress,
);

/// The `/btw` sheet: the question, its answer as it is written, and a note
/// that none of it is kept. It slides up over the conversation, which it
/// leaves exactly as it was — a reply streaming underneath carries on — and
/// putting it away (Done, a swipe down, Back, a tap outside) cancels a
/// question still being answered. Nothing is saved; the answer can be copied.
Future<void> showBtwSheet(
  BuildContext context, {
  required String question,
  required BtwAsk ask,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (_) => BtwSheet(question: question, ask: ask),
    );

class BtwSheet extends StatefulWidget {
  const BtwSheet({super.key, required this.question, required this.ask});

  final String question;
  final BtwAsk ask;

  @override
  State<BtwSheet> createState() => _BtwSheetState();
}

class _BtwSheetState extends State<BtwSheet> {
  final BtwRun _run = BtwRun();
  String _answer = '';
  String? _error;
  bool _done = false;

  /// The answer arrives a few characters at a time; it is drawn at most this
  /// often, like a streaming reply in the chat.
  static const Duration _paintEvery = Duration(milliseconds: 50);
  Timer? _paint;
  String _pending = '';

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      final answer = await widget.ask(_run, _progress);
      if (!mounted) return;
      _paint?.cancel();
      setState(() {
        _answer = answer;
        _done = true;
      });
    } on ChatApiException catch (e) {
      if (!mounted) return;
      _paint?.cancel();
      setState(() {
        _error = e.message;
        _done = true;
      });
    } catch (e) {
      if (!mounted) return;
      _paint?.cancel();
      setState(() {
        _error = '$e';
        _done = true;
      });
    }
  }

  void _progress(String text) {
    _pending = text;
    if (_paint?.isActive ?? false) return;
    _paint = Timer(_paintEvery, () {
      if (mounted && !_done) setState(() => _answer = _pending);
    });
  }

  @override
  void dispose() {
    _paint?.cancel();
    // Put away before the answer finished: stop paying for it.
    if (!_done) _run.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _answer));
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(
      content: Text('Answer copied'),
      behavior: SnackBarBehavior.floating,
    ));
  }

  MarkdownStyles _styles(ThemeData theme) {
    final scheme = theme.colorScheme;
    final base = (theme.textTheme.bodyLarge ?? const TextStyle())
        .copyWith(color: scheme.onSurface, height: 1.45);
    return MarkdownStyles(
      base: base,
      emphasis: scheme.onSurface,
      quote: scheme.onSurface,
      codeBackground: scheme.surfaceContainerHighest,
      codeForeground: scheme.onSurface,
      link: scheme.primary,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted =
        theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final maxHeight = MediaQuery.sizeOf(context).height * 0.85;

    final Widget answer;
    if (_error != null) {
      answer = Container(
        key: const Key('btw-error'),
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Text(
          _error!,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: scheme.onErrorContainer),
        ),
      );
    } else if (_answer.isEmpty) {
      answer = Container(
        key: const Key('btw-waiting'),
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 22),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(24),
        ),
        child: _done
            ? Text('No answer came back.', style: muted)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Thinking…', style: muted),
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: const LinearProgressIndicator(minHeight: 4),
                  ),
                ],
              ),
      );
    } else {
      answer = Container(
        key: const Key('btw-answer'),
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(24),
        ),
        child: SelectableText.rich(
          TextSpan(children: buildMessageSpans(_answer, _styles(theme))),
        ),
      );
    }

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        child: Column(
          key: const Key('btw-sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: scheme.tertiaryContainer,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.tips_and_updates_outlined,
                      size: 16, color: scheme.onTertiaryContainer),
                  const SizedBox(width: 6),
                  Text(
                    'By the way',
                    style: theme.textTheme.labelLarge
                        ?.copyWith(color: scheme.onTertiaryContainer),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text(
              widget.question,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 20),
            Flexible(
              child: SingleChildScrollView(
                child: AnimatedSize(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topCenter,
                  child: answer,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(Icons.visibility_off_outlined,
                    size: 16, color: scheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Expanded(child: Text('Not added to the conversation', style: muted)),
                if (_done && _error == null && _answer.isNotEmpty)
                  IconButton(
                    tooltip: 'Copy answer',
                    onPressed: _copy,
                    icon: const Icon(Icons.copy_rounded),
                  ),
                const SizedBox(width: 4),
                FilledButton.tonal(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: const Text('Done'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
