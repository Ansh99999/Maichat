import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/chat_interface.dart';
import '../models/message.dart';
import '../services/btw.dart';
import '../services/chat_client.dart';
import 'message_markdown.dart';

typedef BtwThreadAsk =
    Future<String> Function(
      String question,
      List<ChatMessage> history,
      BtwRun run,
      void Function(String) onProgress,
    );

class BtwExchange {
  BtwExchange(this.question);

  final String question;
  String answer = '';
  String? error;
  bool done = false;
  bool stopped = false;
}

/// Screen-local side conversation. Nothing here enters the saved RP transcript.
class BtwThreadController extends ChangeNotifier {
  BtwThreadController({required this.ask});

  final BtwThreadAsk ask;
  final List<BtwExchange> _exchanges = [];
  List<BtwExchange> get exchanges => List.unmodifiable(_exchanges);
  BtwRun? _run;
  Timer? _paint;
  String _pending = '';
  bool _disposed = false;

  bool get busy => _run != null;

  Future<void> submit(String text) async {
    final question = text.trim();
    if (question.isEmpty || busy || _disposed) return;
    final history = <ChatMessage>[
      for (final exchange in _exchanges)
        if (exchange.done && exchange.error == null && !exchange.stopped) ...[
          ChatMessage(role: 'user', content: exchange.question),
          ChatMessage(role: 'assistant', content: exchange.answer),
        ],
    ];
    final exchange = BtwExchange(question);
    final run = _run = BtwRun();
    _pending = '';
    _exchanges.add(exchange);
    notifyListeners();
    try {
      final answer = await ask(question, history, run, (text) {
        if (_disposed || _run != run) return;
        _pending = text;
        _paint ??= Timer(const Duration(milliseconds: 50), () {
          _paint = null;
          if (_disposed || _run != run) return;
          exchange.answer = _pending;
          notifyListeners();
        });
      });
      if (_disposed || _run != run) return;
      exchange.answer = answer;
    } catch (error) {
      if (_disposed || _run != run) return;
      exchange.answer = _pending;
      exchange.error = error is ChatApiException ? error.message : '$error';
    } finally {
      if (!_disposed && _run == run) {
        _paint?.cancel();
        _paint = null;
        _run = null;
        exchange.done = true;
        notifyListeners();
      }
    }
  }

  void stop({bool notify = true}) {
    final run = _run;
    if (run == null) return;
    _run = null;
    _paint?.cancel();
    _paint = null;
    final exchange = _exchanges.last;
    exchange
      ..answer = _pending
      ..done = true
      ..stopped = true;
    run.cancel();
    if (notify && !_disposed) notifyListeners();
  }

  void reset({bool notify = false}) {
    stop(notify: false);
    _exchanges.clear();
    _pending = '';
    if (notify && !_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    stop(notify: false);
    super.dispose();
  }
}

/// Flat Document-style transcript with the Studio's simple composer shape.
class BtwThread extends StatefulWidget {
  const BtwThread({
    super.key,
    required this.controller,
    required this.ui,
    required this.onClose,
    this.actionsEnabled = false,
  });

  final BtwThreadController controller;
  final ChatInterface ui;
  final VoidCallback onClose;
  final bool actionsEnabled;

  @override
  State<BtwThread> createState() => _BtwThreadState();
}

class _BtwThreadState extends State<BtwThread> {
  final TextEditingController _input = TextEditingController();
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(_repaint);
  }

  void _repaint() => setState(() {});

  @override
  void dispose() {
    _input.dispose();
    _focus
      ..removeListener(_repaint)
      ..dispose();
    super.dispose();
  }

  void _send() {
    if (widget.controller.busy || _input.text.trim().isEmpty) return;
    final text = _input.text;
    _input.clear();
    unawaited(widget.controller.submit(text));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final top = MediaQuery.viewPaddingOf(context).top;
    return Material(
      key: const Key('btw-thread'),
      color: scheme.surface,
      child: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) => Stack(
          children: [
            Padding(
              padding: EdgeInsets.only(
                top: top,
                bottom: MediaQuery.viewInsetsOf(context).bottom > 0
                    ? MediaQuery.viewInsetsOf(context).bottom
                    : MediaQuery.viewPaddingOf(context).bottom,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'By the way',
                            style: theme.textTheme.titleLarge,
                          ),
                        ),
                        IconButton(
                          tooltip: 'New side thread',
                          onPressed: () {
                            widget.controller.reset(notify: true);
                            _input.clear();
                          },
                          icon: const Icon(Icons.edit_square),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      key: const Key('btw-transcript'),
                      reverse: true,
                      padding: const EdgeInsets.fromLTRB(20, 40, 20, 16),
                      itemCount: widget.controller.exchanges.length,
                      itemBuilder: (context, index) {
                        final exchanges = widget.controller.exchanges;
                        final i = exchanges.length - index - 1;
                        return _exchange(exchanges[i], i, theme);
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Text(
                      widget.actionsEnabled
                          ? 'Outside the story. Tool changes are saved.'
                          : 'Not added to the conversation',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  _composer(theme),
                ],
              ),
            ),
            Positioned(
              top: top + 56,
              right: 0,
              child: Material(
                elevation: 2,
                color: scheme.surfaceContainerHigh,
                borderRadius: const BorderRadius.horizontal(
                  left: Radius.circular(12),
                ),
                child: IconButton(
                  key: const Key('btw-close'),
                  tooltip: 'Back to chat',
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.arrow_back),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _exchange(BtwExchange exchange, int index, ThemeData theme) {
    final scheme = theme.colorScheme;
    final label = theme.textTheme.labelMedium?.copyWith(
      color: scheme.onSurfaceVariant,
      fontWeight: FontWeight.w600,
      fontSize: 13,
    );
    final styles = MarkdownStyles(
      base: (theme.textTheme.bodyLarge ?? const TextStyle()).copyWith(
        color: scheme.onSurface,
        height: 1.45,
      ),
      emphasis: scheme.onSurface,
      quote: scheme.onSurface,
      codeBackground: scheme.surfaceContainerHighest,
      codeForeground: scheme.onSurface,
      link: scheme.primary,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('You', style: label),
          const SizedBox(height: 6),
          SelectableText(exchange.question, style: styles.base),
          const SizedBox(height: 20),
          Text('Assistant', style: label),
          const SizedBox(height: 6),
          if (exchange.answer.isNotEmpty)
            SelectableText.rich(
              key: Key('btw-answer-$index'),
              TextSpan(children: buildMessageSpans(exchange.answer, styles)),
            ),
          if (!exchange.done && exchange.answer.isEmpty)
            const Text('Thinking…', key: Key('btw-waiting')),
          if (!exchange.done)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          if (exchange.error != null)
            Text(
              exchange.error!,
              key: const Key('btw-error'),
              style: theme.textTheme.bodyMedium?.copyWith(color: scheme.error),
            ),
          if (exchange.stopped) Text('Stopped', style: label),
          if (exchange.done &&
              exchange.answer.isEmpty &&
              exchange.error == null &&
              !exchange.stopped)
            Text('No answer came back.', style: label),
          if (exchange.answer.isNotEmpty)
            IconButton(
              tooltip: 'Copy answer',
              onPressed: () =>
                  Clipboard.setData(ClipboardData(text: exchange.answer)),
              icon: const Icon(Icons.copy_rounded, size: 18),
            ),
        ],
      ),
    );
  }

  Widget _composer(ThemeData theme) {
    final scheme = theme.colorScheme;
    final expressive = widget.ui.composerStyle == ComposerStyle.expressive;
    final field = TextField(
      key: const Key('btw-composer-field'),
      controller: _input,
      focusNode: _focus,
      minLines: 1,
      maxLines: expressive ? null : 5,
      keyboardType: TextInputType.multiline,
      textCapitalization: TextCapitalization.sentences,
      decoration: InputDecoration(
        hintText: 'Ask a follow-up…',
        border: expressive ? InputBorder.none : null,
        isDense: true,
        contentPadding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
      ),
    );
    final send = ValueListenableBuilder<TextEditingValue>(
      valueListenable: _input,
      builder: (context, value, _) => IconButton.filled(
        key: const Key('btw-send'),
        tooltip: 'Send side question',
        onPressed: widget.controller.busy || value.text.trim().isEmpty
            ? null
            : _send,
        icon: const Icon(Icons.arrow_upward),
      ),
    );
    final stop = IconButton.filledTonal(
      key: const Key('btw-stop'),
      tooltip: 'Stop side answer',
      onPressed: widget.controller.stop,
      icon: const Icon(Icons.stop_rounded),
    );
    if (!expressive) {
      return Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: scheme.outlineVariant)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(child: field),
            widget.controller.busy ? stop : send,
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(28),
          border: widget.ui.composerOutline
              ? Border.all(
                  color: _focus.hasFocus ? scheme.primary : scheme.outline,
                  width: _focus.hasFocus ? 2.5 : 2,
                )
              : null,
          boxShadow: widget.ui.composerOutline && _focus.hasFocus
              ? [
                  BoxShadow(
                    color: scheme.primary.withValues(alpha: 0.32),
                    blurRadius: 10,
                  ),
                ]
              : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 132),
              child: field,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 8, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [widget.controller.busy ? stop : send],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
