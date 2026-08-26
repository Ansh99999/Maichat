import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/provider.dart';
import '../../state/app_state.dart';
import 'provider_advanced_tab.dart';
import 'provider_basic_tab.dart';
import 'provider_costs_tab.dart';
import 'provider_draft.dart';
import 'providers_io.dart';

/// Editor for one provider, in three tabs.
///
/// Basic is what you need to talk to a host at all. Advanced is what you set
/// once and forget — prices, a fallback chain, headers. Costs is the read-only
/// consequence of the other two, and reads *saved* state rather than the draft,
/// because a price being typed has not been charged against anything yet.
///
/// Opened by id rather than by object so it survives the provider being changed
/// elsewhere (the chat's quick-switch can set the model while this is open).
class ProviderEditScreen extends StatefulWidget {
  const ProviderEditScreen({super.key, this.providerId});

  /// The provider to edit, or null to create one.
  final String? providerId;

  @override
  State<ProviderEditScreen> createState() => _ProviderEditScreenState();
}

class _ProviderEditScreenState extends State<ProviderEditScreen> {
  late ProviderDraft _draft;
  bool _dirty = false;
  bool _saved = false;

  bool get _isNew => widget.providerId == null;

  @override
  void initState() {
    super.initState();
    final existing =
        context.read<AppState>().providerById(widget.providerId);
    _draft = existing == null
        ? ProviderDraft.blank()
        : ProviderDraft.from(existing);
  }

  @override
  void dispose() {
    _draft.dispose();
    super.dispose();
  }

  /// Marks the draft dirty. Every tab calls this instead of `setState` directly,
  /// so "are there unsaved edits" has one answer rather than three.
  void _touch() => setState(() => _dirty = true);

  Future<void> _save() async {
    final state = context.read<AppState>();
    final provider = _draft.toProvider();
    if (_isNew || state.providerById(provider.id) == null) {
      await state.addProvider(provider);
    } else {
      await state.updateProvider(provider);
    }
    if (!mounted) return;
    _saved = true;
    setState(() => _dirty = false);
    Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final existing = context.read<AppState>().providerById(widget.providerId);
    if (existing == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete provider?'),
        content: Text(
          '"${existing.displayName}" will be removed, along with its keys, '
          'prices and budgets. Its recorded usage is kept.',
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
    if (!(confirmed ?? false) || !mounted) return;
    await context.read<AppState>().deleteProvider(existing.id);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _export() async =>
      exportProviders(context, <Provider>[_draft.toProvider()]);

  /// Asked when leaving with unsaved edits. With three tabs and a save button
  /// that scrolls out of reach, walking away mid-edit is easy to do by accident.
  Future<bool> _confirmDiscard() async {
    final answer = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text('Your edits to this provider have not been saved.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep editing'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return answer ?? false;
  }

  @override
  Widget build(BuildContext context) {
    // Costs reads saved state; a provider being created has none yet.
    final saved = context.watch<AppState>().providerById(widget.providerId);

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || _saved) return;
        // Captured before the dialog, so popping afterwards does not reach for a
        // context that may no longer be mounted.
        final navigator = Navigator.of(context);
        final discard = await _confirmDiscard();
        if (!discard || !mounted) return;
        setState(() => _dirty = false);
        navigator.pop();
      },
      child: DefaultTabController(
        length: 3,
        child: Scaffold(
          appBar: AppBar(
            title: Text(_isNew ? 'Add provider' : _draft.name.text.trim().isEmpty
                ? _draft.kind.label
                : _draft.name.text.trim()),
            actions: [
              IconButton(
                tooltip: 'Export',
                icon: const Icon(Icons.file_upload_outlined),
                onPressed: _export,
              ),
              if (!_isNew)
                IconButton(
                  tooltip: 'Delete',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: _delete,
                ),
            ],
            bottom: const TabBar(
              tabs: [
                Tab(text: 'Basic'),
                Tab(text: 'Advanced'),
                Tab(text: 'Costs'),
              ],
            ),
          ),
          floatingActionButton: FloatingActionButton(
            onPressed: _save,
            tooltip: 'Save',
            child: const Icon(Icons.check),
          ),
          body: TabBarView(
            children: [
              ProviderBasicTab(draft: _draft, onChanged: _touch),
              ProviderAdvancedTab(draft: _draft, onChanged: _touch),
              ProviderCostsTab(draft: _draft, saved: saved, onChanged: _touch),
            ],
          ),
        ),
      ),
    );
  }
}
