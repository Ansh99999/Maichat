import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/chat_interface.dart';
import '../screens/studio/shell/liquid_panel.dart';
import '../models/btw_conversation.dart';
import 'btw_settings_panel.dart';
import 'btw_thread_controller.dart';
import 'message_markdown.dart';

export '../models/btw_conversation.dart' show BtwExchange;
export 'btw_thread_controller.dart' show BtwThreadController, BtwThreadAsk;

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
  bool _settingsOpen = false;
  late Widget _settingsContent;
  final Map<BtwExchange, (String, Widget)> _exchangeCache = {};
  String? _renderThreadId;
  ThemeData? _renderTheme;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_repaint);
    _makeSettingsContent();
    widget.controller.addTransientDismissHandler(_dismissSettings);
  }

  void _repaint() => setState(() {});

  bool _dismissSettings() {
    if (!_settingsOpen) return false;
    setState(() => _settingsOpen = false);
    return true;
  }

  void _makeSettingsContent() {
    _settingsContent = BtwSettingsPanel(
      controller: widget.controller,
      onSelected: () {
        _input.clear();
        setState(() => _settingsOpen = false);
      },
      onClose: () => setState(() => _settingsOpen = false),
    );
  }

  @override
  void didUpdateWidget(BtwThread oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeTransientDismissHandler(_dismissSettings);
      widget.controller.addTransientDismissHandler(_dismissSettings);
      _makeSettingsContent();
    }
  }

  Widget _cachedExchange(BtwExchange exchange, int index, ThemeData theme) {
    final signature =
        '${exchange.answer}\u0000${exchange.error}\u0000'
        '${exchange.done}\u0000${exchange.stopped}\u0000$index';
    final cached = _exchangeCache[exchange];
    if (cached != null && cached.$1 == signature) return cached.$2;
    final rendered = RepaintBoundary(child: _exchange(exchange, index, theme));
    _exchangeCache[exchange] = (signature, rendered);
    return rendered;
  }

  @override
  void dispose() {
    widget.controller.removeTransientDismissHandler(_dismissSettings);
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
        builder: (context, _) {
          final threadId = widget.controller.activeThread?.id;
          if (_renderThreadId != threadId || _renderTheme != theme) {
            _exchangeCache.clear();
            _renderThreadId = threadId;
            _renderTheme = theme;
          }
          final exchanges = widget.controller.exchanges;
          return LayoutBuilder(
            builder: (context, constraints) {
              final bottom = math.max(
                MediaQuery.viewInsetsOf(context).bottom,
                MediaQuery.viewPaddingOf(context).bottom,
              );
              final panelWidth = math.min(368.0, constraints.maxWidth - 16);
              final panelHeight = math.min(
                520.0,
                math.max(0.0, constraints.maxHeight - top - bottom - 16),
              );
              final panelTop = math.max(
                top + 8,
                math.min(
                  top + 168,
                  constraints.maxHeight - bottom - panelHeight - 8,
                ),
              );
              return Stack(
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
                          padding: const EdgeInsets.fromLTRB(60, 16, 20, 12),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  widget
                                          .controller
                                          .activeThread
                                          ?.displayTitle ??
                                      'By the way',
                                  key: const Key('btw-thread-title'),
                                  maxLines:
                                      constraints.maxHeight - top - bottom < 400
                                      ? 1
                                      : 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleLarge,
                                ),
                              ),
                              IconButton(
                                tooltip: 'New side thread',
                                onPressed: () {
                                  widget.controller.startThread();
                                  _input.clear();
                                },
                                key: const Key('btw-new-thread'),
                                icon: const Icon(Icons.edit_square),
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: ListView.builder(
                            key: const Key('btw-transcript'),
                            reverse: true,
                            padding: const EdgeInsets.fromLTRB(60, 24, 20, 16),
                            itemCount: exchanges.length,
                            itemBuilder: (context, index) {
                              final i = exchanges.length - index - 1;
                              return _cachedExchange(exchanges[i], i, theme);
                            },
                          ),
                        ),
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxHeight: math.max(
                              48,
                              math.min(
                                240,
                                (constraints.maxHeight - top - bottom) * 0.45,
                              ),
                            ),
                          ),
                          child: SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 20,
                                  ),
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
                        ),
                      ],
                    ),
                  ),
                  Positioned(
                    top: top + 56,
                    left: 0,
                    child: _edgeButton(
                      theme,
                      key: const Key('btw-close'),
                      tooltip: 'Back to chat',
                      icon: Icons.arrow_back,
                      onPressed: () {
                        if (_settingsOpen) {
                          setState(() => _settingsOpen = false);
                        }
                        widget.onClose();
                      },
                    ),
                  ),
                  Positioned(
                    top: top + 112,
                    left: 0,
                    child: _edgeButton(
                      theme,
                      key: const Key('btw-settings'),
                      tooltip: 'Side thread settings',
                      icon: Icons.settings_outlined,
                      onPressed: () {
                        _focus.unfocus();
                        setState(() => _settingsOpen = !_settingsOpen);
                      },
                    ),
                  ),
                  LiquidPanel(
                    open: _settingsOpen,
                    anchor: Offset(24, top + 136),
                    panel: Rect.fromLTWH(8, panelTop, panelWidth, panelHeight),
                    color: scheme.surfaceContainerHigh,
                    onDismiss: () => setState(() => _settingsOpen = false),
                    child: _settingsContent,
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _edgeButton(
    ThemeData theme, {
    required Key key,
    required String tooltip,
    required IconData icon,
    required VoidCallback onPressed,
  }) => Material(
    elevation: 2,
    color: theme.colorScheme.surfaceContainerHigh,
    borderRadius: const BorderRadius.horizontal(right: Radius.circular(12)),
    child: SizedBox(
      width: 48,
      height: 48,
      child: IconButton(
        key: key,
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon),
      ),
    ),
  );

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
