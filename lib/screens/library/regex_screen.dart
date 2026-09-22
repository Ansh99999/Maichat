import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/regex_rule.dart';
import '../../services/regex_codec.dart';
import '../../state/app_state.dart';
import 'regex_edit_screen.dart';
import 'regex_info.dart';

/// The Regex shelf: find-and-replace rules the user writes to tidy what they
/// type, what the model replies, or what is sent to it.
///
/// Deliberately plain — a list you can reorder (rules run top to bottom, each
/// feeding the next), a switch on every row, and one button to make a new one.
/// Import and the explainer live in the app bar; the JSON it reads and writes is
/// the same shape SillyTavern shares, so rules move between the two.
class RegexScreen extends StatefulWidget {
  const RegexScreen({super.key});

  @override
  State<RegexScreen> createState() => _RegexScreenState();
}

class _RegexScreenState extends State<RegexScreen> {
  void _open(Widget screen) => Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => screen));

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final rules = state.regexRules;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar.large(
            title: const Text('Regex'),
            actions: [
              IconButton(
                tooltip: 'What is this?',
                icon: const Icon(Icons.info_outline),
                onPressed: () => showRegexInfo(context),
              ),
              IconButton(
                tooltip: 'Import',
                icon: const Icon(Icons.file_download_outlined),
                onPressed: _importMenu,
              ),
            ],
          ),
          if (rules.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: _Empty(),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
              sliver: SliverReorderableList(
                itemCount: rules.length,
                onReorderItem: state.reorderRegexRule,
                itemBuilder: (context, index) {
                  final rule = rules[index];
                  return _RuleRow(
                    key: ValueKey(rule.id),
                    rule: rule,
                    index: index,
                    onTap: () => _open(RegexEditScreen(ruleId: rule.id)),
                    onToggle: (on) =>
                        state.setRegexRuleEnabled(rule.id, on),
                    onDuplicate: () => state.duplicateRegexRule(rule),
                    onExport: () => _exportRule(rule),
                    onDelete: () => _confirmDelete(rule),
                  );
                },
              ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _open(const RegexEditScreen()),
        icon: const Icon(Icons.add),
        label: const Text('New rule'),
      ),
    );
  }

  // --- delete --------------------------------------------------------------

  Future<void> _confirmDelete(RegexRule rule) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${rule.displayName}"?'),
        content: const Text(
          'This removes the rule for good. Messages it already changed stay as '
          'they are.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      await context.read<AppState>().deleteRegexRule(rule.id);
    }
  }

  // --- import --------------------------------------------------------------

  Future<void> _importMenu() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: const Text('From a file'),
              subtitle: const Text('A regex .json shared here or by SillyTavern'),
              onTap: () => Navigator.of(context).pop('file'),
            ),
            ListTile(
              leading: const Icon(Icons.content_paste),
              title: const Text('Paste JSON'),
              subtitle: const Text('One rule, or a list of them'),
              onTap: () => Navigator.of(context).pop('paste'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == 'file') {
      await _importFile();
    } else if (choice == 'paste') {
      await _pasteJson();
    }
  }

  Future<void> _importFile() async {
    FilePickerResult? result;
    try {
      result = await FilePicker.pickFiles(
        dialogTitle: 'Import regex',
        // FileType.any: Android greys out a .json whose provider MIME is not
        // application/json. The parser reads contents, so filter in code.
        type: FileType.any,
        allowMultiple: true,
        withData: true,
      );
    } catch (_) {
      result = null;
    }
    final files = result?.files ?? const [];
    if (files.isEmpty) return;
    final rules = <RegexRule>[];
    for (final file in files) {
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) continue;
      rules.addAll(parseRegexRules(utf8.decode(bytes)));
    }
    await _store(rules);
  }

  Future<void> _pasteJson() async {
    final controller = TextEditingController();
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    controller.text = clip?.text ?? '';
    if (!mounted) {
      controller.dispose();
      return;
    }
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Paste regex JSON'),
        content: TextField(
          controller: controller,
          minLines: 5,
          maxLines: 12,
          keyboardType: TextInputType.multiline,
          decoration: const InputDecoration(
            hintText: 'A regex rule object, or a list of them',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Import'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text == null || text.trim().isEmpty) return;
    await _store(parseRegexRules(text));
  }

  Future<void> _store(List<RegexRule> rules) async {
    if (!mounted) return;
    if (rules.isEmpty) {
      _toast('Nothing there looked like a regex rule.');
      return;
    }
    await context.read<AppState>().addRegexRules(rules);
    if (mounted) {
      _toast(rules.length == 1
          ? 'Imported 1 rule.'
          : 'Imported ${rules.length} rules.');
    }
  }

  // --- export --------------------------------------------------------------

  Future<void> _exportRule(RegexRule rule) async {
    final json = encodeRegexRule(rule);
    String? path;
    try {
      path = await FilePicker.saveFile(
        dialogTitle: 'Save regex rule',
        fileName: regexFileName(rule),
        bytes: Uint8List.fromList(utf8.encode(json)),
        type: FileType.custom,
        allowedExtensions: const ['json'],
      );
    } catch (_) {
      path = null;
    }
    if (!mounted) return;
    if (path == null) {
      await Clipboard.setData(ClipboardData(text: json));
      if (mounted) _toast('Copied rule JSON to clipboard.');
    } else {
      _toast('Saved to $path');
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

/// One rule in the list: a drag handle, an enable switch, the name and a plain
/// description of what it touches, and an overflow of the row actions.
class _RuleRow extends StatelessWidget {
  const _RuleRow({
    super.key,
    required this.rule,
    required this.index,
    required this.onTap,
    required this.onToggle,
    required this.onDuplicate,
    required this.onExport,
    required this.onDelete,
  });

  final RegexRule rule;
  final int index;
  final VoidCallback onTap;
  final ValueChanged<bool> onToggle;
  final VoidCallback onDuplicate;
  final VoidCallback onExport;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = !rule.disabled;
    return Card(
      elevation: 0,
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
        leading: ReorderableDragStartListener(
          index: index,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Icon(Icons.drag_indicator, color: scheme.onSurfaceVariant),
          ),
        ),
        title: Text(
          rule.displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: enabled ? null : scheme.onSurfaceVariant,
          ),
        ),
        subtitle: Text(
          rule.blurb,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
        onTap: onTap,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Switch(value: enabled, onChanged: onToggle),
            PopupMenuButton<String>(
              onSelected: (value) {
                switch (value) {
                  case 'edit':
                    onTap();
                  case 'duplicate':
                    onDuplicate();
                  case 'export':
                    onExport();
                  case 'delete':
                    onDelete();
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'edit', child: Text('Edit')),
                PopupMenuItem(value: 'duplicate', child: Text('Duplicate')),
                PopupMenuItem(value: 'export', child: Text('Export')),
                PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 24, 32, 48),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.find_replace_outlined,
              size: 48, color: scheme.onSurfaceVariant),
          const SizedBox(height: 20),
          Text(
            'No regex rules yet',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 10),
          Text(
            'A rule finds a pattern in a message and replaces it — to strip '
            'something the model keeps adding, reformat replies, or clean up the '
            'text before it is sent. Tap New rule to write one, or import a '
            'shared .json.',
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
