import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/provider.dart';
import '../../state/app_state.dart';
import '../../widgets/app_drawer.dart';
import 'provider_edit_screen.dart';
import 'providers_io.dart';

/// The Providers section: every endpoint the app can talk to, with the active
/// one marked.
///
/// Deliberately the Characters roster wearing a different object — search on
/// top, long-press for selection, the same export and delete actions in the
/// same places. A user who has learnt one roster should not have to learn
/// another.
class ProvidersScreen extends StatefulWidget {
  const ProvidersScreen({super.key});

  @override
  State<ProvidersScreen> createState() => _ProvidersScreenState();
}

class _ProvidersScreenState extends State<ProvidersScreen> {
  final TextEditingController _search = TextEditingController();
  String _query = '';
  bool _selecting = false;
  final Set<String> _selection = <String>{};

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Providers matching the search, which looks at the name, the format label,
  /// the host and the model — everything the row actually shows.
  List<Provider> _visible(List<Provider> all) {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return all;
    return all.where((p) {
      final host = Uri.tryParse(p.baseUrl)?.host ?? p.baseUrl;
      return p.displayName.toLowerCase().contains(query) ||
          p.kind.label.toLowerCase().contains(query) ||
          host.toLowerCase().contains(query) ||
          p.model.toLowerCase().contains(query);
    }).toList();
  }

  void _edit([Provider? provider]) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ProviderEditScreen(providerId: provider?.id),
      ),
    );
  }

  void _enterSelection(String id) {
    setState(() {
      _selecting = true;
      _selection.add(id);
    });
  }

  void _toggle(String id) {
    setState(() {
      if (!_selection.remove(id)) _selection.add(id);
      // Emptying the selection by hand leaves selection mode, which is what the
      // rosters do and what the back gesture would otherwise have to undo.
      if (_selection.isEmpty) _selecting = false;
    });
  }

  void _leaveSelection() {
    setState(() {
      _selecting = false;
      _selection.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final providers = state.providers;
    final visible = _visible(providers);
    final activeId = state.activeProvider?.id;
    final bottom = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      drawer: _selecting ? null : const AppDrawer(selected: DrawerSection.providers),
      appBar: _selecting ? _selectionBar(state) : null,
      floatingActionButton: _selecting
          ? null
          : FloatingActionButton.extended(
              onPressed: _edit,
              icon: const Icon(Icons.add),
              label: const Text('Add provider'),
            ),
      body: CustomScrollView(
        slivers: [
          if (!_selecting)
            SliverAppBar.large(
              title: const Text('Providers'),
              actions: [
                IconButton(
                  tooltip: 'Select',
                  icon: const Icon(Icons.checklist),
                  onPressed: providers.isEmpty
                      ? null
                      : () => setState(() => _selecting = true),
                ),
                IconButton(
                  tooltip: 'Import',
                  icon: const Icon(Icons.file_download_outlined),
                  onPressed: _import,
                ),
              ],
            ),
          SliverToBoxAdapter(child: _searchBar(context)),
          if (providers.isEmpty)
            const SliverFillRemaining(hasScrollBody: false, child: _EmptyList())
          else if (visible.isEmpty)
            const SliverFillRemaining(hasScrollBody: false, child: _NoMatches())
          else
            SliverPadding(
              padding: EdgeInsets.fromLTRB(12, 4, 12, 96 + bottom),
              sliver: SliverList.builder(
                itemCount: visible.length,
                itemBuilder: (context, index) {
                  final provider = visible[index];
                  return _ProviderCard(
                    provider: provider,
                    active: provider.id == activeId,
                    selecting: _selecting,
                    selected: _selection.contains(provider.id),
                    onActivate: () => state.selectProvider(provider.id),
                    onTap: _selecting
                        ? () => _toggle(provider.id)
                        : () => _edit(provider),
                    onLongPress: _selecting
                        ? null
                        : () => _enterSelection(provider.id),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  /// The app bar selection mode swaps in: a count, and the two things that can
  /// be done to a set of providers.
  AppBar _selectionBar(AppState state) {
    final count = _selection.length;
    return AppBar(
      leading: IconButton(
        tooltip: 'Cancel',
        icon: const Icon(Icons.close),
        onPressed: _leaveSelection,
      ),
      title: Text('$count selected'),
      actions: [
        IconButton(
          tooltip: 'Export',
          icon: const Icon(Icons.file_upload_outlined),
          onPressed: count == 0 ? null : () => _exportSelected(state),
        ),
        IconButton(
          tooltip: 'Delete',
          icon: const Icon(Icons.delete_outline),
          onPressed: count == 0 ? null : () => _deleteSelected(state),
        ),
      ],
    );
  }

  Widget _searchBar(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: SearchBar(
          controller: _search,
          hintText: 'Search providers',
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 14),
          ),
          leading: const Icon(Icons.search),
          trailing: [
            if (_query.isNotEmpty)
              IconButton(
                tooltip: 'Clear',
                icon: const Icon(Icons.close),
                onPressed: () {
                  _search.clear();
                  setState(() => _query = '');
                },
              ),
          ],
          onChanged: (value) => setState(() => _query = value),
        ),
      );

  Future<void> _deleteSelected(AppState state) async {
    final count = _selection.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(count == 1 ? 'Delete provider?' : 'Delete $count providers?'),
        content: Text(
          count == 1
              ? 'It will be removed, along with its keys and prices.'
              : 'They will be removed, along with their keys and prices.',
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
    if (!(confirmed ?? false)) return;
    for (final id in _selection.toList()) {
      await state.deleteProvider(id);
    }
    if (mounted) _leaveSelection();
  }

  Future<void> _exportSelected(AppState state) async {
    final chosen = <Provider>[
      for (final provider in state.providers)
        if (_selection.contains(provider.id)) provider,
    ];
    if (chosen.isEmpty) return;
    await exportProviders(context, chosen);
    if (mounted) _leaveSelection();
  }

  Future<void> _import() async {
    final state = context.read<AppState>();
    final imported = await importProviders(context);
    if (imported.isEmpty || !mounted) return;
    for (final provider in imported) {
      await state.addProvider(provider);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          imported.length == 1
              ? 'Added ${imported.first.displayName}.'
              : 'Added ${imported.length} providers.',
        ),
      ),
    );
  }
}

/// One provider in the list.
///
/// The leading circle is the active marker and the control that sets it: filled
/// for the globally active provider, a hollow ring for the rest. It is a
/// separate tap target from the row, so activating a provider and opening it to
/// edit are two different gestures rather than a trip through the editor.
class _ProviderCard extends StatelessWidget {
  const _ProviderCard({
    required this.provider,
    required this.active,
    required this.selecting,
    required this.selected,
    required this.onActivate,
    required this.onTap,
    this.onLongPress,
  });

  final Provider provider;
  final bool active;
  final bool selecting;
  final bool selected;
  final VoidCallback onActivate;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final host = Uri.tryParse(provider.baseUrl)?.host ?? provider.baseUrl;
    final model = provider.model.trim();
    final keyCount = provider.usableKeys.length;
    final parts = <String>[
      provider.kind.label,
      if (host.isNotEmpty) host,
      if (model.isEmpty) 'no model' else model,
      if (keyCount > 1) '$keyCount keys',
    ];

    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: selected
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: scheme.primary, width: 2),
            )
          : null,
      child: ListTile(
        onTap: onTap,
        onLongPress: onLongPress,
        leading: selecting
            ? Icon(
                selected ? Icons.check_circle : Icons.radio_button_unchecked,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              )
            : _ActiveRing(active: active, onTap: onActivate),
        title: Text(
          provider.displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontWeight: active ? FontWeight.w600 : null),
        ),
        subtitle: Text(
          parts.join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: selecting ? null : const Icon(Icons.chevron_right),
      ),
    );
  }
}

/// The "O" beside a provider: a ring that fills when this is the one replies
/// come from. Tapping an inactive one makes it active.
class _ActiveRing extends StatelessWidget {
  const _ActiveRing({required this.active, required this.onTap});

  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      selected: active,
      button: !active,
      label: active ? 'Active provider' : 'Make active',
      child: Tooltip(
        message: active ? 'Active' : 'Make active',
        child: InkResponse(
          onTap: active ? null : onTap,
          radius: 24,
          containedInkWell: false,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: active ? scheme.primary : Colors.transparent,
                border: Border.all(
                  color: active ? scheme.primary : scheme.outline,
                  width: 2,
                ),
              ),
              child: active
                  ? Icon(Icons.check, size: 14, color: scheme.onPrimary)
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}

/// Nothing configured yet — the one state where the section has to explain
/// itself rather than list something.
class _EmptyList extends StatelessWidget {
  const _EmptyList();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 0, 32, 96),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.cloud_outlined, size: 56, color: scheme.outline),
            const SizedBox(height: 16),
            Text('No providers yet',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'A provider is where replies come from. Add an OpenAI-compatible, '
              'Anthropic or Gemini endpoint — or point one at a model running on '
              'your own machine.',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// The search matched nothing. One quiet line, as in the other rosters.
class _NoMatches extends StatelessWidget {
  const _NoMatches();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 0, 32, 96),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off, size: 48, color: scheme.outline),
            const SizedBox(height: 12),
            Text(
              'No provider matches that.',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
