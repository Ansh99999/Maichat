import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/summary.dart';
import '../../state/app_state.dart';
import '../../widgets/export_sheet.dart';

/// The full-screen memory page for one chat's summary: its configuration, the
/// manual re-summarise / summarise-now actions, and the accumulated segments —
/// each editable. Edits apply live (no Save button), matching the rest of the
/// per-chat settings; generation runs in the background through [AppState].
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

  String? _providerId;
  final _model = TextEditingController();
  SummaryMethod _method = SummaryMethod.rolling;
  bool _notify = false;
  bool _useCustomPrompt = false;
  bool _configOpen = false;

  @override
  void initState() {
    super.initState();
    final state = context.read<AppState>();
    final cfg = state.conversationById(widget.conversationId)?.summary ??
        ChatSummary();
    _interval.text = '${cfg.interval}';
    _budget.text = cfg.budget?.toString() ?? '';
    _prompt.text = cfg.prompt ?? '';
    _providerId = cfg.providerId;
    _model.text = cfg.model ?? '';
    _method = cfg.method;
    _notify = cfg.notify;
    _useCustomPrompt = cfg.useCustomPrompt;
  }

  @override
  void dispose() {
    _interval.dispose();
    _budget.dispose();
    _prompt.dispose();
    _model.dispose();
    super.dispose();
  }
// APPEND-MARKER
  /// Writes the current form (config only) back onto the chat's summary, keeping
  /// its generated segments and progress intact.
  void _apply() {
    final state = context.read<AppState>();
    final c = state.conversationById(widget.conversationId);
    if (c == null) return;
    final current = c.summary ?? ChatSummary(enabled: true);
    final next = current.copyWith(
      interval: int.tryParse(_interval.text.trim()) ?? current.interval,
      budget: _budget.text.trim().isEmpty
          ? null
          : int.tryParse(_budget.text.trim()),
      providerId: _providerId,
      model: _model.text.trim().isEmpty ? null : _model.text.trim(),
      method: _method,
      notify: _notify,
      useCustomPrompt: _useCustomPrompt,
      prompt: _prompt.text.trim().isEmpty ? null : _prompt.text,
    );
    state.setSummary(c.id, next);
  }

  Future<void> _summarizeNow() async {
    _apply();
    final state = context.read<AppState>();
    final c = state.conversationById(widget.conversationId);
    final cfg = c?.summary;
    if (c == null || cfg == null) return;
    final from = cfg.lastSummarizedIndex;
    final to = c.messages.length;
    if (to <= from && cfg.method == SummaryMethod.incremental) {
      _toast('Nothing new to summarise yet.');
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
    if (mounted) setState(() {});
  }

  Future<void> _resummarize() async {
    _apply();
    final state = context.read<AppState>();
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
    if (mounted) setState(() {});
  }

  Future<void> _export() async {
    final state = context.read<AppState>();
    final c = state.conversationById(widget.conversationId);
    final cfg = c?.summary;
    if (c == null || cfg == null) return;
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
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final imported = ChatSummary.fromJson(json);
      context.read<AppState>().setSummary(widget.conversationId, imported);
      setState(() {
        _interval.text = '${imported.interval}';
        _budget.text = imported.budget?.toString() ?? '';
        _prompt.text = imported.prompt ?? '';
        _providerId = imported.providerId;
        _model.text = imported.model ?? '';
        _method = imported.method;
        _notify = imported.notify;
        _useCustomPrompt = imported.useCustomPrompt;
      });
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

  Future<void> _editSegment(SummarySegment segment) async {
    final title = TextEditingController(text: segment.title);
    final body = TextEditingController(text: segment.content);
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit segment'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: title,
                decoration: const InputDecoration(labelText: 'Title'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: body,
                maxLines: 10,
                minLines: 4,
                decoration: const InputDecoration(
                    labelText: 'Summary', border: OutlineInputBorder()),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Save')),
        ],
      ),
    );
    if (saved != true || !mounted) return;
    final state = context.read<AppState>();
    final c = state.conversationById(widget.conversationId);
    final cfg = c?.summary;
    if (c == null || cfg == null) return;
    final segments = cfg.segments
        .map((s) => s.id == segment.id
            ? s.copyWith(
                title: title.text.trim(),
                content: body.text.trim(),
                tokens: state.estimateTokens(body.text.trim()))
            : s)
        .toList();
    state.setSummary(c.id, cfg.copyWith(segments: segments));
    setState(() {});
  }

  Future<void> _deleteSegment(SummarySegment segment) async {
    final state = context.read<AppState>();
    final c = state.conversationById(widget.conversationId);
    final cfg = c?.summary;
    if (c == null || cfg == null) return;
    final segments =
        cfg.segments.where((s) => s.id != segment.id).toList();
    state.setSummary(c.id, cfg.copyWith(segments: segments));
    setState(() {});
  }

  void _toast(String message) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));

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

    return Scaffold(
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
        ],
      ),
      body: c == null
          ? const Center(child: Text('Chat not found'))
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              children: [
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
                if (busy) ...[
                  const LinearProgressIndicator(),
                  const SizedBox(height: 8),
                  Text('Summarising…',
                      style: theme.textTheme.labelMedium
                          ?.copyWith(color: scheme.onSurfaceVariant)),
                  const SizedBox(height: 12),
                ] else if (cfg != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      '${cfg.totalTokens} tokens · summarised to message '
                      '${cfg.lastSummarizedIndex} of ${c.messages.length}',
                      style: theme.textTheme.labelMedium
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                if (cfg == null || cfg.segments.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Text(
                        'No summary yet.',
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  )
                else
                  for (final segment in cfg.segments)
                    _SegmentCard(
                      segment: segment,
                      onEdit: () => _editSegment(segment),
                      onDelete: () => _deleteSegment(segment),
                    ),
              ],
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
        // Interval
        Row(
          children: [
            const Expanded(child: Text('Every N messages')),
            IconButton(
              icon: const Icon(Icons.remove),
              onPressed: () {
                final v = (int.tryParse(_interval.text) ?? 1) - 1;
                _interval.text = '${v.clamp(1, 100000)}';
                _apply();
                setState(() {});
              },
            ),
            SizedBox(
              width: 64,
              child: TextField(
                controller: _interval,
                textAlign: TextAlign.center,
                keyboardType: TextInputType.number,
                onEditingComplete: _apply,
                onTapOutside: (_) => _apply(),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.add),
              onPressed: () {
                final v = (int.tryParse(_interval.text) ?? 0) + 1;
                _interval.text = '$v';
                _apply();
                setState(() {});
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
            _apply();
          },
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _model,
          decoration: const InputDecoration(
              labelText: 'Model', hintText: 'Same as current'),
          onEditingComplete: _apply,
          onTapOutside: (_) => _apply(),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _budget,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
              labelText: 'Budget (max tokens)',
              hintText: 'Preset default'),
          onEditingComplete: _apply,
          onTapOutside: (_) => _apply(),
        ),
        const SizedBox(height: 8),
        RadioGroup<SummaryMethod>(
          groupValue: _method,
          onChanged: (v) {
            if (v == null) return;
            setState(() => _method = v);
            _apply();
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
            _apply();
          },
        ),
        SwitchListTile(
          value: _useCustomPrompt,
          contentPadding: EdgeInsets.zero,
          title: const Text('Custom summariser prompt'),
          onChanged: (v) {
            setState(() => _useCustomPrompt = v);
            _apply();
          },
        ),
        if (_useCustomPrompt)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: TextField(
              controller: _prompt,
              maxLines: 6,
              minLines: 3,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'Instruction for the summarising model',
              ),
              onEditingComplete: _apply,
              onTapOutside: (_) => _apply(),
            ),
          ),
      ],
    );
  }
}

/// One summary segment, with edit/delete actions.
class _SegmentCard extends StatelessWidget {
  const _SegmentCard({
    required this.segment,
    required this.onEdit,
    required this.onDelete,
  });

  final SummarySegment segment;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    segment.title.trim().isEmpty ? 'Summary' : segment.title,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.edit_outlined, size: 20),
                  onPressed: onEdit,
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.delete_outline, size: 20),
                  onPressed: onDelete,
                ),
              ],
            ),
            if (segment.tokens > 0)
              Text('${segment.tokens} tokens',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 6),
            Text(segment.content, style: theme.textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}



