import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/summary.dart';
import '../../state/app_state.dart';
import '../../widgets/brand_mark.dart';
import '../../widgets/export_sheet.dart';

/// The full-screen memory page for one chat's summary: its configuration, the
/// manual re-summarise / summarise-now actions, and the accumulated segments,
/// each editable inline like a prompt box. Edits are held as a draft and written
/// with the Save button (so typing never rewrites the whole store).
class SummaryEditScreen extends StatefulWidget {
  const SummaryEditScreen({super.key, required this.conversationId});

  final String conversationId;

  @override
  State<SummaryEditScreen> createState() => _SummaryEditScreenState();
}

class _SummaryEditScreenState extends State<SummaryEditScreen> {
  final _interval = TextEditingController();
  final _budget = TextEditingController();
  final _prompt = TextEditingController();
  final _model = TextEditingController();
  final _title = TextEditingController();

  String? _providerId;
  SummaryMethod _method = SummaryMethod.rolling;
  bool _notify = false;
  bool _useCustomPrompt = false;
  bool _configOpen = false;
  bool _dirty = false;

  /// Draft segments (metadata) with a controller pair each, kept aligned.
  final List<SummarySegment> _segments = [];
  final List<TextEditingController> _segTitle = [];
  final List<TextEditingController> _segBody = [];

  /// Which segment indices are currently in edit mode (typing in place).
  final Set<int> _editing = {};

  /// Which segment indices are collapsed (body hidden — the dropdown behaviour).
  final Set<int> _collapsed = {};

  @override
  void initState() {
    super.initState();
    final cfg = context.read<AppState>().conversationById(widget.conversationId)
            ?.summary ??
        ChatSummary(enabled: true);
    _loadFrom(cfg);
  }

  void _loadFrom(ChatSummary cfg) {
    _title.text = cfg.title;
    _interval.text = '${cfg.interval}';
    _budget.text = cfg.budget?.toString() ?? '';
    _prompt.text = cfg.prompt ?? '';
    _model.text = cfg.model ?? '';
    _providerId = cfg.providerId;
    _method = cfg.method;
    _notify = cfg.notify;
    _useCustomPrompt = cfg.useCustomPrompt;
    _disposeSegments();
    _segments
      ..clear()
      ..addAll(cfg.segments.map((s) => s.copyWith()));
    for (final s in _segments) {
      _segTitle.add(TextEditingController(text: s.title));
      _segBody.add(TextEditingController(text: s.content));
    }
    _editing.clear();
    _collapsed.clear();
    for (var i = 0; i < _segments.length; i++) {
      if (_segments[i].collapsed) _collapsed.add(i);
    }
    _dirty = false;
  }

  void _disposeSegments() {
    for (final c in _segTitle) {
      c.dispose();
    }
    for (final c in _segBody) {
      c.dispose();
    }
    _segTitle.clear();
    _segBody.clear();
  }

  @override
  void dispose() {
    _interval.dispose();
    _budget.dispose();
    _prompt.dispose();
    _model.dispose();
    _title.dispose();
    _disposeSegments();
    super.dispose();
  }

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }
// APPEND-MARKER
  /// Builds a [ChatSummary] from the current draft, preserving the live progress
  /// (lastSummarizedIndex, enabled, title) from the stored config.
  ChatSummary _draftSummary(AppState state) {
    final c = state.conversationById(widget.conversationId);
    final current = c?.summary ?? ChatSummary(enabled: true);
    final segs = <SummarySegment>[
      for (var i = 0; i < _segments.length; i++)
        _segments[i].copyWith(
          title: _segTitle[i].text.trim(),
          content: _segBody[i].text.trim(),
          tokens: state.estimateTokens(_segBody[i].text.trim()),
        ),
    ];
    final title = _title.text.trim().isEmpty
        ? '${c?.title ?? 'Chat'} summary'
        : _title.text.trim();
    return current.copyWith(
      title: title,
      interval: int.tryParse(_interval.text.trim()) ?? current.interval,
      budget:
          _budget.text.trim().isEmpty ? null : int.tryParse(_budget.text.trim()),
      providerId: _providerId,
      model: _model.text.trim().isEmpty ? null : _model.text.trim(),
      method: _method,
      notify: _notify,
      useCustomPrompt: _useCustomPrompt,
      prompt: _prompt.text.trim().isEmpty ? null : _prompt.text,
      segments: segs,
    );
  }

  Future<void> _save() async {
    final state = context.read<AppState>();
    await state.setSummary(widget.conversationId, _draftSummary(state));
    if (!mounted) return;
    setState(() => _dirty = false);
    _toast('Saved.');
  }

  Future<void> _summarizeNow() async {
    final state = context.read<AppState>();
    // Persist the draft (config + any manual edits) so the run uses it.
    await state.setSummary(widget.conversationId, _draftSummary(state));
    if (!mounted) return;
    final c = state.conversationById(widget.conversationId);
    final cfg = c?.summary;
    if (c == null || cfg == null) return;
    // Work from what the memory actually covers now — not the stored high-water
    // mark — so deleting a block (or adding a single message) leaves something to
    // do. A manual run ignores the "every N messages" threshold on purpose.
    final from = cfg.method == SummaryMethod.incremental
        ? state.summaryCoverage(c.id)
        : 0;
    final to = c.messages.length;
    if (cfg.method == SummaryMethod.incremental && to <= from) {
      _toast('The memory already covers every message.');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Summarise now'),
        content: Text(cfg.method == SummaryMethod.rolling
            ? 'Re-condense the whole chat (messages 1–$to) into the summary now?'
            : 'Summarise messages ${from + 1}–$to and add them to the memory now?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Summarise')),
        ],
      ),
    );
    if (ok != true) return;
    await state.summarizeNow(c.id);
    _afterRun(state);
  }

  Future<void> _resummarize() async {
    final state = context.read<AppState>();
    await state.setSummary(widget.conversationId, _draftSummary(state));
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Re-summarise from the start?'),
        content: const Text(
          'This deletes the current summary and rebuilds it from the very first '
          'message. Any manual edits you made to the segments will be lost.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Re-summarise')),
        ],
      ),
    );
    if (ok != true) return;
    await state.resummarize(widget.conversationId);
    _afterRun(state);
  }

  /// After a run: reload the draft from the (updated) stored summary and report
  /// any error the run surfaced.
  void _afterRun(AppState state) {
    if (!mounted) return;
    final cfg = state.conversationById(widget.conversationId)?.summary;
    setState(() {
      if (cfg != null) _loadFrom(cfg);
    });
    final err = state.lastSummaryError;
    if (err != null) _toast('Summary failed: $err');
  }
// ACTIONS-MARKER
  Future<void> _export() async {
    final state = context.read<AppState>();
    final c = state.conversationById(widget.conversationId);
    if (c == null || c.summary == null) return;
    final cfg = _draftSummary(state);
    final name = cfg.title.trim().isEmpty ? c.title : cfg.title;
    await offerExport(
      context,
      text: const JsonEncoder.withIndent('  ').convert(cfg.toJson()),
      fileName: '${_safe(name)}_summary.json',
      subtitle: 'MaiChat summary',
      dialogTitle: 'Save summary',
    );
  }

  Future<void> _import() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: const Text('Open .json file'),
              onTap: () => Navigator.of(context).pop('file'),
            ),
            ListTile(
              leading: const Icon(Icons.content_paste_outlined),
              title: const Text('Paste JSON'),
              onTap: () => Navigator.of(context).pop('paste'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    String? raw;
    if (choice == 'file') {
      FilePickerResult? result;
      try {
        result = await FilePicker.pickFiles(
            dialogTitle: 'Import summary', type: FileType.any, withData: true);
      } catch (_) {
        result = null;
      }
      final bytes = result?.files.firstOrNull?.bytes;
      if (bytes != null) raw = utf8.decode(bytes);
    } else {
      final clip = await Clipboard.getData(Clipboard.kTextPlain);
      if (!mounted) return;
      raw = await _pastePrompt(clip?.text ?? '');
    }
    if (raw == null || raw.trim().isEmpty || !mounted) return;
    try {
      final imported = ChatSummary.fromJson(
          jsonDecode(raw) as Map<String, dynamic>);
      await context.read<AppState>().setSummary(widget.conversationId, imported);
      if (!mounted) return;
      setState(() => _loadFrom(imported));
      _toast('Summary imported.');
    } catch (_) {
      _toast('That file is not a MaiChat summary.');
    }
  }

  Future<String?> _pastePrompt(String initial) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Paste summary JSON'),
        content: TextField(
          controller: controller,
          maxLines: 8,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: const Text('Import')),
        ],
      ),
    );
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete summary?'),
        content: const Text('This removes the summary and its memory from this '
            'chat. It cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await context.read<AppState>().deleteSummary(widget.conversationId);
    if (mounted) Navigator.of(context).pop();
  }

  void _deleteSegment(int i) {
    setState(() {
      _segTitle.removeAt(i).dispose();
      _segBody.removeAt(i).dispose();
      _segments.removeAt(i);
      // Indices shifted; rebuild the edit/collapse sets from the segments that
      // remain (collapse rides on the segment itself, so it is preserved).
      _editing.clear();
      _collapsed.clear();
      for (var j = 0; j < _segments.length; j++) {
        if (_segments[j].collapsed) _collapsed.add(j);
      }
      _dirty = true;
    });
  }

  /// Adds an empty, hand-written block (the pencil button) and drops straight
  /// into editing it. It is treated exactly like a generated block, but is never
  /// wiped by a re-summarise.
  void _addManual() {
    setState(() {
      _segments.add(SummarySegment(
        id: 'm${DateTime.now().microsecondsSinceEpoch}',
        manual: true,
      ));
      _segTitle.add(TextEditingController());
      _segBody.add(TextEditingController());
      _editing.add(_segments.length - 1);
      _dirty = true;
    });
  }

  /// A snackbar. [BrandedText] so "not a MaiChat summary" carries the mark, the
  /// same as the export sheet that wrote the file.
  void _toast(String message) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: BrandedText(message)));

  static String _safe(String s) => s
      .replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '')
      .trim()
      .replaceAll(RegExp(r'\s+'), '_');
// BUILD-MARKER
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final c = state.conversationById(widget.conversationId);
    final cfg = c?.summary;
    final busy = c != null && state.isSummarizing(c);

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        final discard = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Discard changes?'),
            content: const Text('You have unsaved edits to this summary.'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Keep editing')),
              FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Discard')),
            ],
          ),
        );
        if (discard == true) navigator.pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Summary'),
          actions: [
            IconButton(
              icon: const Icon(Icons.upload_file_outlined),
              tooltip: 'Import',
              onPressed: _import,
            ),
            IconButton(
              icon: const Icon(Icons.download_outlined),
              tooltip: 'Export',
              onPressed: cfg == null ? null : _export,
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete',
              onPressed: cfg == null ? null : _delete,
            ),
            TextButton(
              onPressed: _dirty ? _save : null,
              child: const Text('Save'),
            ),
          ],
        ),
        body: c == null
            ? const Center(child: Text('Chat not found'))
            : ListView(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
                children: [
                  TextField(
                    controller: _title,
                    onChanged: (_) => _markDirty(),
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      labelText: 'Summary title',
                      hintText: '${c.title} summary',
                    ),
                  ),
                  const SizedBox(height: 8),
                  _configPanel(state),
                  const SizedBox(height: 8),
                  const Divider(height: 1),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: busy ? null : _resummarize,
                          icon: const Icon(Icons.restart_alt),
                          label: const Text('Re-summarise'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: busy ? null : _summarizeNow,
                          icon: const Icon(Icons.bolt_outlined),
                          label: const Text('Summarise now'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeInOut,
                    alignment: Alignment.topCenter,
                    child: busy
                        ? Column(
                            children: const [
                              LinearProgressIndicator(),
                              SizedBox(height: 24),
                            ],
                          )
                        : _segmentsView(theme, scheme),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _segmentsView(ThemeData theme, ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: _addManual,
            icon: const Icon(Icons.edit_outlined, size: 18),
            label: const Text('Write your own'),
          ),
        ),
        const SizedBox(height: 4),
        if (_segments.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text(
                'No summary yet — tap “Summarise now”, or write your own.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          )
        else
          for (var i = 0; i < _segments.length; i++)
            _segmentCard(i, theme, scheme),
      ],
    );
  }

  Widget _segmentCard(int i, ThemeData theme, ColorScheme scheme) {
    final editing = _editing.contains(i);
    final manual = _segments[i].manual;
    final collapsed = _collapsed.contains(i) && !editing;
    void toggleCollapse() {
      final next = !_collapsed.contains(i);
      setState(() {
        if (next) {
          _collapsed.add(i);
        } else {
          _collapsed.remove(i);
        }
        // Keep the draft segment in step so a later Save carries the state too.
        _segments[i].collapsed = next;
      });
      // Persist the fold immediately, independent of the Save button — it is a
      // view preference, so it should survive leaving the page without saving.
      context
          .read<AppState>()
          .setSummarySegmentCollapsed(widget.conversationId, _segments[i].id, next);
    }
    return Card(
      key: ValueKey(_segments[i].id),
      elevation: 0,
      color: scheme.surfaceContainerLow,
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 6, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: collapsed ? 'Expand' : 'Collapse',
                  icon: AnimatedRotation(
                    turns: collapsed ? -0.25 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: const Icon(Icons.expand_more, size: 22),
                  ),
                  onPressed: editing ? null : toggleCollapse,
                ),
                Expanded(
                  child: editing
                      ? TextField(
                          controller: _segTitle[i],
                          onChanged: (_) => _markDirty(),
                          style: theme.textTheme.titleSmall,
                          decoration: const InputDecoration(
                            isDense: true,
                            border: InputBorder.none,
                            hintText: 'Title',
                          ),
                        )
                      : InkWell(
                          onTap: toggleCollapse,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Text(
                              _segTitle[i].text.trim().isEmpty
                                  ? (manual ? 'Your note' : 'Summary')
                                  : _segTitle[i].text,
                              style: theme.textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                          ),
                        ),
                ),
                if (manual)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Text('Custom',
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: scheme.primary)),
                  ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: editing ? 'Done' : 'Edit',
                  icon: Icon(editing ? Icons.check : Icons.edit_outlined,
                      size: 20),
                  onPressed: () => setState(() {
                    if (editing) {
                      _editing.remove(i);
                    } else {
                      _editing.add(i);
                    }
                  }),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Delete',
                  icon: const Icon(Icons.delete_outline, size: 20),
                  onPressed: () => _deleteSegment(i),
                ),
              ],
            ),
            const SizedBox(height: 4),
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeInOut,
              alignment: Alignment.topCenter,
              child: editing
                  ? TextField(
                      controller: _segBody[i],
                      onChanged: (_) => _markDirty(),
                      maxLines: null,
                      minLines: 3,
                      autofocus: _segBody[i].text.isEmpty,
                      style: theme.textTheme.bodyMedium,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        hintText: 'Type the memory here, like a prompt.',
                      ),
                    )
                  : Padding(
                      padding: const EdgeInsets.only(left: 12, right: 8, bottom: 2),
                      child: Text(
                        _segBody[i].text.trim().isEmpty
                            ? 'Empty — tap the pencil to write.'
                            : _segBody[i].text,
                        maxLines: collapsed ? 1 : null,
                        overflow:
                            collapsed ? TextOverflow.ellipsis : TextOverflow.clip,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: _segBody[i].text.trim().isEmpty
                              ? scheme.onSurfaceVariant
                              : null,
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
// CONFIG-MARKER
  Widget _configPanel(AppState state) {
    final providerIds = state.providers.map((p) => p.id).toSet();
    final providerValue =
        (_providerId != null && providerIds.contains(_providerId))
            ? _providerId
            : null;

    return ExpansionTile(
      initiallyExpanded: _configOpen,
      onExpansionChanged: (v) => _configOpen = v,
      leading: const Icon(Icons.tune),
      title: const Text('Configuration'),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      children: [
        Row(
          children: [
            const Expanded(child: Text('Every N messages')),
            IconButton(
              icon: const Icon(Icons.remove),
              onPressed: () {
                final v = (int.tryParse(_interval.text) ?? 1) - 1;
                _interval.text = '${v.clamp(1, 100000)}';
                _markDirty();
              },
            ),
            SizedBox(
              width: 64,
              child: TextField(
                controller: _interval,
                textAlign: TextAlign.center,
                keyboardType: TextInputType.number,
                onChanged: (_) => _markDirty(),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.add),
              onPressed: () {
                final v = (int.tryParse(_interval.text) ?? 0) + 1;
                _interval.text = '$v';
                _markDirty();
              },
            ),
          ],
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String?>(
          initialValue: providerValue,
          decoration: const InputDecoration(labelText: 'Provider'),
          items: [
            const DropdownMenuItem<String?>(
                value: null, child: Text('Same as current')),
            for (final p in state.providers)
              DropdownMenuItem<String?>(
                  value: p.id, child: Text(p.displayName)),
          ],
          onChanged: (v) {
            setState(() => _providerId = v);
            _markDirty();
          },
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _model,
          decoration: const InputDecoration(
              labelText: 'Model', hintText: 'Same as current'),
          onChanged: (_) => _markDirty(),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _budget,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
              labelText: 'Budget (max tokens)', hintText: 'Preset default'),
          onChanged: (_) => _markDirty(),
        ),
        const SizedBox(height: 8),
        RadioGroup<SummaryMethod>(
          groupValue: _method,
          onChanged: (v) {
            if (v == null) return;
            setState(() => _method = v);
            _markDirty();
          },
          child: const Column(
            children: [
              RadioListTile<SummaryMethod>(
                value: SummaryMethod.rolling,
                contentPadding: EdgeInsets.zero,
                title: Text('Re-summarise from the start'),
                subtitle: Text(
                    'Every interval, condense the whole chat into one summary.'),
              ),
              RadioListTile<SummaryMethod>(
                value: SummaryMethod.incremental,
                contentPadding: EdgeInsets.zero,
                title: Text('Continue from where it left off'),
                subtitle: Text(
                    'Every interval, summarise only the newest messages and '
                    'keep the earlier summaries.'),
              ),
            ],
          ),
        ),
        SwitchListTile(
          value: _notify,
          contentPadding: EdgeInsets.zero,
          title: const Text('Notify when a summary is made'),
          onChanged: (v) {
            setState(() => _notify = v);
            _markDirty();
          },
        ),
        SwitchListTile(
          value: _useCustomPrompt,
          contentPadding: EdgeInsets.zero,
          title: const Text('Custom summariser prompt'),
          onChanged: (v) {
            setState(() => _useCustomPrompt = v);
            _markDirty();
          },
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          alignment: Alignment.topCenter,
          child: _useCustomPrompt
              ? Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: TextField(
                    controller: _prompt,
                    maxLines: 6,
                    minLines: 3,
                    onChanged: (_) => _markDirty(),
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: 'Instruction for the summarising model',
                    ),
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}




