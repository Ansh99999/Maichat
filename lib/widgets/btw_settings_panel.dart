import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/btw_conversation.dart';
import '../models/settings.dart';
import '../screens/studio/shell/liquid_panel.dart';
import '../state/app_state.dart';
import 'btw_thread_controller.dart';
import 'export_sheet.dart';

enum _BtwSection { prompt, provider, tools }

/// A retained settings window: reply deltas do not rebuild its saved-thread list.
class BtwSettingsPanel extends StatefulWidget {
  const BtwSettingsPanel({
    super.key,
    required this.controller,
    required this.onSelected,
    required this.onClose,
  });

  final BtwThreadController controller;
  final VoidCallback onSelected;
  final VoidCallback onClose;

  @override
  State<BtwSettingsPanel> createState() => _BtwSettingsPanelState();
}

class _BtwSettingsPanelState extends State<BtwSettingsPanel> {
  final _search = TextEditingController();
  final _prompt = TextEditingController();
  final _promptFocus = FocusNode();
  _BtwSection? _section;
  String _signature = '';
  BtwConversation? _observedThread;
  int _observedExchangeCount = -1;
  String? _observedPrompt;
  String? _observedProvider;
  bool? _observedTools;
  String? _promptThreadId;
  List<BtwConversation> _filtered = const [];
  BtwConversation? _actionsThread;
  Offset _actionsAnchor = Offset.zero;
  bool _actionsOpen = false;
  bool _exportFormats = false;
  bool _promptSaved = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_controllerChanged);
    widget.controller.addTransientDismissHandler(_dismissActions);
    _search.addListener(_filter);
    _refresh();
  }

  @override
  void didUpdateWidget(BtwSettingsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_controllerChanged);
      oldWidget.controller.removeTransientDismissHandler(_dismissActions);
      widget.controller.addListener(_controllerChanged);
      widget.controller.addTransientDismissHandler(_dismissActions);
      _refresh();
    }
  }

  bool _dismissActions() {
    if (!_actionsOpen) return false;
    _closeActions();
    return true;
  }

  void _controllerChanged() {
    final current = widget.controller.activeThread;
    // A streaming answer changes no saved-row data. Skip the list scan on the
    // paint cadence, while still noticing selection and settings changes.
    if (widget.controller.busy &&
        identical(current, _observedThread) &&
        current?.exchanges.length == _observedExchangeCount &&
        current?.systemPrompt == _observedPrompt &&
        current?.providerId == _observedProvider &&
        current?.toolsEnabled == _observedTools) {
      return;
    }
    final next = _dataSignature();
    if (next == _signature || !mounted) return;
    setState(_refresh);
  }

  String _dataSignature() => jsonEncode([
    widget.controller.activeThread?.id,
    widget.controller.activeThread?.systemPrompt,
    widget.controller.activeThread?.providerId,
    widget.controller.activeThread?.toolsEnabled,
    widget.controller.state?.btwSettings.titleMode.name,
    for (final thread in widget.controller.threads)
      [thread.id, thread.displayTitle, thread.exchanges.length],
    for (final provider in widget.controller.state?.providers ?? [])
      [provider.id, provider.name, provider.model],
  ]);

  void _refresh() {
    _signature = _dataSignature();
    final thread = widget.controller.activeThread;
    _observedThread = thread;
    _observedExchangeCount = thread?.exchanges.length ?? -1;
    _observedPrompt = thread?.systemPrompt;
    _observedProvider = thread?.providerId;
    _observedTools = thread?.toolsEnabled;
    if (_promptThreadId != thread?.id || !_promptFocus.hasFocus) {
      _promptThreadId = thread?.id;
      _prompt.text = thread?.systemPrompt ?? '';
    }
    _updateFilter();
  }

  void _filter() => setState(_updateFilter);

  void _updateFilter() {
    final query = _search.text.toLowerCase().trim();
    _filtered = [
      for (final thread in widget.controller.threads)
        if (query.isEmpty ||
            thread.displayTitle.toLowerCase().contains(query) ||
            thread.exchanges.any(
              (exchange) => exchange.question.toLowerCase().contains(query),
            ))
          thread,
    ];
  }

  @override
  void dispose() {
    widget.controller.removeListener(_controllerChanged);
    widget.controller.removeTransientDismissHandler(_dismissActions);
    _search
      ..removeListener(_filter)
      ..dispose();
    _prompt.dispose();
    _promptFocus.dispose();
    super.dispose();
  }

  void _openActions(BtwConversation thread, Offset position) {
    final box = context.findRenderObject()! as RenderBox;
    setState(() {
      _actionsThread = thread;
      _actionsAnchor = box.globalToLocal(position);
      _actionsOpen = true;
      _exportFormats = false;
    });
  }

  void _closeActions() => setState(() => _actionsOpen = false);

  Future<void> _delete() async {
    final thread = _actionsThread;
    if (thread == null) return;
    _closeActions();
    await widget.controller.deleteThread(thread);
  }

  Future<void> _export(bool json) async {
    final thread = _actionsThread;
    if (thread == null) return;
    final text = json
        ? const JsonEncoder.withIndent('  ').convert({
            'format': 'maichat-btw',
            'version': 1,
            'thread': thread.toJson(),
          })
        : [
            thread.displayTitle,
            '',
            for (final exchange in thread.exchanges) ...[
              'You: ${exchange.question}',
              '',
              'Assistant: ${exchange.answer}',
              if (exchange.error != null) 'Error: ${exchange.error}',
              if (exchange.stopped) '[Stopped]',
              '',
            ],
          ].join('\n');
    _closeActions();
    await offerExport(
      context,
      text: text,
      fileName:
          '${safeFileName(thread.displayTitle).isEmpty ? 'side-thread' : safeFileName(thread.displayTitle)}.${json ? 'json' : 'txt'}',
      subtitle: json ? 'MaiChat side thread' : 'Plain text side thread',
      dialogTitle: 'Save side thread',
      extensions: [json ? 'json' : 'txt'],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      scopesRoute: true,
      explicitChildNodes: true,
      label: 'Side thread settings',
      child: Material(
        key: const Key('btw-settings-panel'),
        color: Colors.transparent,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth;
            final h = constraints.maxHeight;
            final compact = h < 280;
            final actionHeight = math.min(h - 16, 208.0);
            final actionWidth = math.min(w - 16, 272.0);
            final actionsRect = Rect.fromLTWH(
              (_actionsAnchor.dx - actionWidth / 2).clamp(
                8.0,
                w - actionWidth - 8,
              ),
              (_actionsAnchor.dy - 24).clamp(8.0, h - actionHeight - 8),
              actionWidth,
              actionHeight,
            );
            return Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (compact)
                        Row(
                          children: [
                            Expanded(child: _searchField(scheme)),
                            _closeButton(),
                          ],
                        )
                      else ...[
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Side threads',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                            _closeButton(),
                          ],
                        ),
                        _searchField(scheme),
                      ],
                      const SizedBox(height: 8),
                      Expanded(
                        child: AnimatedSwitcher(
                          duration: MediaQuery.disableAnimationsOf(context)
                              ? Duration.zero
                              : const Duration(milliseconds: 180),
                          child: _section == null ? _threadList() : _editor(),
                        ),
                      ),
                      const SizedBox(height: 6),
                      _sectionButtons(compact: compact),
                    ],
                  ),
                ),
                LiquidPanel(
                  open: _actionsOpen,
                  anchor: _actionsAnchor,
                  panel: actionsRect,
                  color: scheme.surfaceContainerHighest,
                  onDismiss: _closeActions,
                  child: _threadActions(),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _searchField(ColorScheme scheme) => TextField(
    key: const Key('btw-thread-search'),
    controller: _search,
    decoration: InputDecoration(
      hintText: 'Search saved threads',
      prefixIcon: const Icon(Icons.search),
      filled: true,
      fillColor: scheme.surfaceContainerHighest,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    ),
  );

  Widget _closeButton() => IconButton(
    key: const Key('btw-settings-dismiss'),
    tooltip: 'Close side thread settings',
    onPressed: widget.onClose,
    icon: const Icon(Icons.close),
  );

  Widget _threadList() {
    final state = widget.controller.state;
    return ListView.builder(
      key: const Key('btw-saved-threads'),
      padding: EdgeInsets.zero,
      itemCount: _filtered.isEmpty ? 2 : _filtered.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Row(
            children: [
              Expanded(
                child: Text(
                  'Saved threads',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              if (state != null)
                PopupMenuButton<BtwTitleMode>(
                  key: const Key('btw-title-mode'),
                  tooltip: 'Title new side threads',
                  icon: const Icon(Icons.title),
                  initialValue: state.btwSettings.titleMode,
                  onSelected: (mode) async {
                    await state.updateBtwSettings(
                      state.btwSettings.copyWith(titleMode: mode),
                    );
                    if (mounted) setState(_refresh);
                  },
                  itemBuilder: (context) => [
                    for (final mode in BtwTitleMode.values)
                      CheckedPopupMenuItem(
                        value: mode,
                        checked: state.btwSettings.titleMode == mode,
                        child: Text(mode.label),
                      ),
                  ],
                ),
            ],
          );
        }
        if (_filtered.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              _search.text.trim().isEmpty
                  ? 'Your side threads will appear here.'
                  : 'No threads match your search.',
            ),
          );
        }
        final thread = _filtered[index - 1];
        final selected = widget.controller.activeThread?.id == thread.id;
        return Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Material(
            color: selected
                ? Theme.of(context).colorScheme.secondaryContainer
                : Colors.transparent,
            borderRadius: BorderRadius.circular(16),
            child: GestureDetector(
              onLongPressStart: (details) =>
                  _openActions(thread, details.globalPosition),
              child: ListTile(
                key: Key('btw-saved-${thread.id}'),
                selected: selected,
                contentPadding: const EdgeInsets.only(left: 12),
                title: Text(
                  thread.displayTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${thread.exchanges.length} ${thread.exchanges.length == 1 ? 'question' : 'questions'}',
                ),
                trailing: Builder(
                  builder: (buttonContext) => IconButton(
                    tooltip: 'Actions for ${thread.displayTitle}',
                    icon: const Icon(Icons.more_horiz),
                    onPressed: () {
                      final box =
                          buttonContext.findRenderObject()! as RenderBox;
                      _openActions(
                        thread,
                        box.localToGlobal(box.size.center(Offset.zero)),
                      );
                    },
                  ),
                ),
                onTap: () {
                  widget.controller.selectThread(thread);
                  widget.onSelected();
                },
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _sectionButtons({bool compact = false}) => LayoutBuilder(
    builder: (context, constraints) {
      final sections = _BtwSection.values;
      final expanded = _section != null;
      final available = constraints.maxWidth - 8;
      final otherWidth = math.min(56.0, available / 3);
      return Row(
        children: [
          for (final section in sections) ...[
            if (section != sections.first) const SizedBox(width: 4),
            AnimatedContainer(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              width: expanded && _section == section
                  ? available - otherWidth * 2
                  : expanded
                  ? otherWidth
                  : available / 3,
              child: Tooltip(
                message: _label(section),
                child: FilledButton.tonal(
                  key: Key('btw-section-${section.name}'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    backgroundColor: _section == section
                        ? Theme.of(context).colorScheme.primaryContainer
                        : null,
                  ),
                  onPressed: () {
                    FocusManager.instance.primaryFocus?.unfocus();
                    setState(
                      () => _section = _section == section ? null : section,
                    );
                  },
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(_icon(section), size: 20),
                      if (_section == section) ...[
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            _label(section),
                            maxLines: compact ? 1 : 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      );
    },
  );

  static String _label(_BtwSection section) => switch (section) {
    _BtwSection.prompt => 'System prompt',
    _BtwSection.provider => 'Provider',
    _BtwSection.tools => 'Tools',
  };

  static IconData _icon(_BtwSection section) => switch (section) {
    _BtwSection.prompt => Icons.notes,
    _BtwSection.provider => Icons.hub_outlined,
    _BtwSection.tools => Icons.handyman_outlined,
  };

  Widget _editor() {
    final thread = widget.controller.activeThread;
    final state = widget.controller.state;
    return ListView(
      key: ValueKey('btw-editor-${_section!.name}'),
      padding: EdgeInsets.zero,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            _label(_section!),
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        if (_section == _BtwSection.prompt) ...[
          const Text(
            'Instructions for this side thread. Leave empty to use the chat prompt.',
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('btw-system-prompt'),
            controller: _prompt,
            focusNode: _promptFocus,
            onChanged: (_) {
              if (_promptSaved) setState(() => _promptSaved = false);
            },
            minLines: 3,
            maxLines: 6,
            decoration: const InputDecoration(
              labelText: 'System prompt',
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              key: const Key('btw-save-prompt'),
              onPressed: () async {
                await widget.controller.updateThread(
                  systemPrompt: _prompt.text,
                );
                if (!mounted) return;
                FocusManager.instance.primaryFocus?.unfocus();
                setState(() => _promptSaved = true);
              },
              child: Text(_promptSaved ? 'Saved' : 'Save prompt'),
            ),
          ),
        ],
        if (_section == _BtwSection.provider) ...[
          _choice(
            key: const Key('btw-provider-inherit'),
            title: 'Use chat provider',
            subtitle: 'Follow this chat’s provider and model.',
            selected: thread?.providerId == null,
            onTap: () => widget.controller.updateThread(setProvider: true),
          ),
          for (final provider in state?.providers ?? [])
            _choice(
              key: Key('btw-provider-${provider.id}'),
              title: provider.name,
              subtitle: provider.model,
              selected: thread?.providerId == provider.id,
              onTap: () => widget.controller.updateThread(
                providerId: provider.id,
                setProvider: true,
              ),
            ),
          if (state?.providers.isEmpty ?? true)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('Add a provider in app settings to choose it here.'),
            ),
        ],
        if (_section == _BtwSection.tools) ...[
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text(
              'Use this chat’s configured tools in the side thread. Tool actions can change saved data.',
            ),
          ),
          for (final entry in const <(bool?, String, String)>[
            (
              null,
              'Use chat tools setting',
              'Follow this chat’s tools preference.',
            ),
            (
              true,
              'Tools enabled',
              'Allow the tools configured for this chat.',
            ),
            (false, 'Tools disabled', 'Answer without running tools.'),
          ])
            _choice(
              key: Key(
                'btw-tools-${entry.$1 == null
                    ? 'inherit'
                    : entry.$1!
                    ? 'on'
                    : 'off'}',
              ),
              title: entry.$2,
              subtitle: entry.$3,
              selected: thread?.toolsEnabled == entry.$1,
              onTap: () => widget.controller.updateThread(
                toolsEnabled: entry.$1,
                setTools: true,
              ),
            ),
        ],
      ],
    );
  }

  Widget _choice({
    required Key key,
    required String title,
    required String subtitle,
    required bool selected,
    required VoidCallback onTap,
  }) => Semantics(
    selected: selected,
    child: ListTile(
      key: key,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_off,
      ),
      title: Text(title),
      subtitle: Text(subtitle),
      onTap: onTap,
    ),
  );

  Widget _threadActions() => Material(
    key: const Key('btw-thread-actions'),
    color: Colors.transparent,
    child: SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              _actionsThread?.displayTitle ?? 'Side thread',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          if (!_exportFormats) ...[
            ListTile(
              key: const Key('btw-delete-thread'),
              leading: Icon(
                Icons.delete_outline,
                color: Theme.of(context).colorScheme.error,
              ),
              title: const Text('Delete thread'),
              onTap: _delete,
            ),
            ListTile(
              key: const Key('btw-export-thread'),
              leading: const Icon(Icons.ios_share),
              title: const Text('Export thread'),
              onTap: () => setState(() => _exportFormats = true),
            ),
          ] else ...[
            ListTile(
              key: const Key('btw-export-json'),
              leading: const Icon(Icons.data_object),
              title: const Text('JSON'),
              onTap: () => _export(true),
            ),
            ListTile(
              key: const Key('btw-export-text'),
              leading: const Icon(Icons.subject),
              title: const Text('Plain text'),
              onTap: () => _export(false),
            ),
          ],
        ],
      ),
    ),
  );
}
