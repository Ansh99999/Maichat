import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/scenario.dart';
import '../../models/view_prefs.dart';
import '../../services/scenario_codec.dart';
import '../../state/app_state.dart';
import '../../widgets/brand_mark.dart';
import '../../widgets/export_sheet.dart';
import '../../widgets/library_drawer.dart';
import '../../widgets/tag_filter_sheet.dart';
import 'scenario_edit_screen.dart';
import 'scenario_info.dart';

/// How the shelf is ordered.
enum ScenarioSort {
  recent('Recently updated'),
  added('Recently added'),
  name('Name (A–Z)'),
  longest('Longest first');

  const ScenarioSort(this.label);
  final String label;
}

/// The Scenarios shelf: reusable openings, browsed the way the Characters roster
/// and the Lorebooks shelf are browsed, because a user who has learnt one of
/// those should not have to learn a third.
///
/// The title is a large one that scrolls away — this is a place to read and
/// choose, not a tool bar — and the "i" beside it goes to a plain-English
/// explainer, since "scenario" means three slightly different things across the
/// apps this one talks to. Import and multi-select live in the app bar; making a
/// new one is the button under your thumb.
class ScenariosScreen extends StatefulWidget {
  const ScenariosScreen({super.key});

  @override
  State<ScenariosScreen> createState() => _ScenariosScreenState();
}

class _ScenariosScreenState extends State<ScenariosScreen> {
  final TextEditingController _search = TextEditingController();
  String _query = '';
  ScenarioSort _sort = ScenarioSort.recent;
  final Set<String> _tagFilter = <String>{};
  bool _selecting = false;
  final Set<String> _selection = <String>{};

  /// Cards or rows, read live from the stored preference rather than mirrored in
  /// a field — the choice outlives the screen, so the screen must not own it.
  bool _cardView(AppState state) =>
      state.browseLayout(BrowseSection.scenarios) == BrowseLayout.grid;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  // --- filtering / sorting -------------------------------------------------

  List<String> _allTags(List<Scenario> scenarios) {
    final tags = <String>{};
    for (final s in scenarios) {
      tags.addAll(s.tags);
    }
    final sorted = tags.toList()..sort();
    return sorted;
  }

  /// Applies the text query and tag filter (tags match on AND), then the sort.
  List<Scenario> _visible(List<Scenario> scenarios) {
    final result = scenarios.where((s) {
      if (_tagFilter.isNotEmpty &&
          !_tagFilter.every((t) => s.tags.contains(t))) {
        return false;
      }
      return s.matches(_query);
    }).toList();

    switch (_sort) {
      case ScenarioSort.recent:
        result.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      case ScenarioSort.added:
        result.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      case ScenarioSort.name:
        result.sort((a, b) =>
            a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
      case ScenarioSort.longest:
        result.sort((a, b) => b.text.length.compareTo(a.text.length));
    }
    return result;
  }

  // --- selection -----------------------------------------------------------

  void _toggleSelect(String id) {
    setState(() {
      if (_selection.contains(id)) {
        _selection.remove(id);
      } else {
        _selection.add(id);
      }
    });
  }

  void _exitSelection() => setState(() {
        _selecting = false;
        _selection.clear();
      });

  Future<void> _deleteSelected(AppState state) async {
    if (_selection.isEmpty) return;
    final count = _selection.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete $count scenario${count == 1 ? '' : 's'}?'),
        content: const Text('Chats using them fall back to the character\'s own '
            'scenario. A chat that had edited one keeps its own copy.'),
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
    if (ok != true) return;
    for (final id in _selection.toList()) {
      await state.deleteScenario(id);
    }
    if (mounted) _exitSelection();
  }

  Future<void> _exportSelected(AppState state) async {
    final chosen =
        state.scenarios.where((s) => _selection.contains(s.id)).toList();
    if (chosen.isEmpty) return;
    // One file for the whole selection: the importer reads an array back as a
    // bundle, so a multi-selection round-trips as a single document.
    await offerExport(
      context,
      text: ScenarioCodec.exportManyNative(chosen),
      fileName: 'scenarios-${chosen.length}.json',
      subtitle: '${chosen.length} scenarios, MaiChat format',
      dialogTitle: 'Save scenarios',
    );
  }
  // --- create / import -----------------------------------------------------

  Future<void> _createNew() async {
    await Navigator.of(context).push(
      MaterialPageRoute<Scenario>(builder: (_) => const ScenarioEditScreen()),
    );
  }

  Future<void> _open(Scenario scenario) async {
    await Navigator.of(context).push(
      MaterialPageRoute<Scenario>(
        builder: (_) => ScenarioEditScreen(scenario: scenario),
      ),
    );
  }

  /// The import sheet. Three routes in, because a scenario arrives as a file from
  /// Agnai, as prose pasted out of a chat, or sitting inside a character card
  /// you already like.
  void _showImportSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('Write a new scenario'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _createNew();
              },
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Text(
                'IMPORT FROM',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                    ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: const Text('A file'),
              subtitle: const BrandedText('An Agnai scenario, a character card, '
                  'a MaiChat export, or a plain .txt'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _importFile();
              },
            ),
            ListTile(
              leading: const Icon(Icons.content_paste_outlined),
              title: const Text('Paste it'),
              subtitle: const Text('Prose or JSON, straight from the clipboard'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _pasteText();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// Picks one or more files and imports every scenario in them.
  Future<void> _importFile() async {
    FilePickerResult? result;
    try {
      result = await FilePicker.pickFiles(
        dialogTitle: 'Import scenario',
        // FileType.any, not custom: Android greys out a .json whose provider
        // MIME isn't application/json. The parser reads contents, so filter in
        // code instead.
        type: FileType.any,
        allowMultiple: true,
        withData: true,
      );
    } catch (_) {
      result = null;
    }
    final files = result?.files ?? const [];
    if (files.isEmpty) return;
    final scenarios = <Scenario>[];
    String? firstError;
    for (final file in files) {
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) continue;
      try {
        scenarios.addAll(ScenarioCodec.parse(
          utf8.decode(bytes),
          fileName: _baseName(file.name),
        ));
      } on FormatException catch (e) {
        firstError ??= e.message;
      } catch (_) {
        firstError ??= 'Could not read ${file.name} as a scenario.';
      }
    }
    await _store(scenarios, firstError);
  }

  /// The clipboard path, for an opening copied out of a browser or another app.
  Future<void> _pasteText() async {
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
        title: const Text('Paste a scenario'),
        content: TextField(
          controller: controller,
          minLines: 5,
          maxLines: 10,
          keyboardType: TextInputType.multiline,
          decoration: const InputDecoration(
            hintText: 'The opening, or the JSON it came in',
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
    try {
      await _store(ScenarioCodec.parse(text), null);
    } on FormatException catch (e) {
      _say(e.message);
    } catch (_) {
      _say('Could not read that as a scenario.');
    }
  }
  /// Adds [scenarios] to the library and reports what happened. [error] is the
  /// first parse failure, shown only when nothing at all could be read.
  ///
  /// An Agnai scenario can carry triggered events, which this app has nowhere to
  /// fire. They are kept (so an export is unchanged) but the message says so —
  /// silently importing half a scenario as if it were whole is worse than
  /// admitting which half arrived.
  Future<void> _store(List<Scenario> scenarios, String? error) async {
    if (scenarios.isEmpty) {
      _say(error ?? 'Could not read that as a scenario.');
      return;
    }
    final state = context.read<AppState>();
    await state.addScenarios(scenarios);
    if (!mounted) return;
    final events = scenarios.fold<int>(
        0, (sum, s) => sum + ScenarioCodec.eventCount(s));
    final what = scenarios.length == 1
        ? 'Imported "${scenarios.single.displayName}".'
        : 'Imported ${scenarios.length} scenarios.';
    _say(events == 0
        ? what
        : '$what $events triggered event${events == 1 ? '' : 's'} came along '
            'and were kept, but they do not fire here.');
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // --- per-scenario actions ------------------------------------------------

  Future<void> _runAction(
      AppState state, Scenario scenario, _ScenarioAction action) async {
    switch (action) {
      case _ScenarioAction.edit:
        await _open(scenario);
      case _ScenarioAction.copyText:
        await Clipboard.setData(ClipboardData(text: scenario.text));
        _say('Scenario copied.');
      case _ScenarioAction.download:
        await _exportOne(scenario);
      case _ScenarioAction.duplicate:
        await state.duplicateScenario(scenario);
        _say('Scenario duplicated.');
      case _ScenarioAction.delete:
        await _confirmDelete(state, scenario);
    }
  }

  /// Offers the two export shapes, then hands the text to the file / clipboard
  /// chooser. This app's own is the lossless one; Agnai's exists for moving a
  /// scenario back to where it came from.
  Future<void> _exportOne(Scenario scenario) async {
    final format = await showModalBottomSheet<ScenarioExportFormat>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final f in ScenarioExportFormat.values)
              ListTile(
                leading: f == ScenarioExportFormat.native
                    ? const MaiChatMark()
                    : const Icon(Icons.smart_toy_outlined),
                title: Text(f.label),
                subtitle: Text(f.blurb),
                onTap: () => Navigator.of(context).pop(f),
              ),
          ],
        ),
      ),
    );
    if (format == null || !mounted) return;
    final safe = _safeName(scenario.displayName);
    await offerExport(
      context,
      text: format.write(scenario),
      fileName: '${safe.isEmpty ? 'scenario' : safe}.json',
      subtitle: format.label,
      dialogTitle: 'Save scenario',
    );
  }

  Future<void> _confirmDelete(AppState state, Scenario scenario) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete scenario?'),
        content: Text('"${scenario.displayName}" will be removed, and unplugged '
            'from any chat running it.'),
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
    if (ok == true) await state.deleteScenario(scenario.id);
  }

  // --- tag filter / sort ---------------------------------------------------

  void _showTagFilter(List<String> tags) {
    if (tags.isEmpty) {
      _say('No tags on any scenario yet.');
      return;
    }
    showTagFilterSheet(
      context,
      tags: tags,
      selected: _tagFilter,
      onChanged: () => setState(() {}),
    );
  }

  Future<void> _pickSort() async {
    final picked = await showModalBottomSheet<ScenarioSort>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final s in ScenarioSort.values)
              ListTile(
                title: Text(s.label),
                trailing: _sort == s ? const Icon(Icons.check) : null,
                onTap: () => Navigator.of(context).pop(s),
              ),
          ],
        ),
      ),
    );
    if (picked != null) setState(() => _sort = picked);
  }

  void _onItemTap(Scenario scenario) {
    if (_selecting) {
      _toggleSelect(scenario.id);
    } else {
      _open(scenario);
    }
  }

  void _onItemLongPress(Scenario scenario) {
    setState(() {
      _selecting = true;
      _selection.add(scenario.id);
    });
  }
  // --- build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (!state.ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final all = state.scenarios;
    final tags = _allTags(all);
    final visible = _visible(all);
    final starred = visible.where((s) => s.starred).toList();
    final others = visible.where((s) => !s.starred).toList();
    final hasStar = starred.isNotEmpty;
    final bottom = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      drawer: _selecting
          ? null
          : const LibraryDrawer(selected: LibrarySection.scenarios),
      floatingActionButton: _selecting
          ? null
          : FloatingActionButton.extended(
              onPressed: _createNew,
              icon: const Icon(Icons.add),
              label: const Text('New scenario'),
            ),
      body: CustomScrollView(
        slivers: [
          if (_selecting) _selectionAppBar(state) else _mainAppBar(),
          SliverToBoxAdapter(child: _searchAndControls(state, tags)),
          if (all.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _EmptyShelf(onCreate: _createNew),
            )
          else if (visible.isEmpty)
            const SliverFillRemaining(hasScrollBody: false, child: _NoMatches())
          else ...[
            if (hasStar) ...[
              _header('Starred'),
              _shelf(state, starred),
            ],
            if (others.isNotEmpty) ...[
              if (hasStar) _header('All scenarios'),
              _shelf(state, others),
            ],
            SliverToBoxAdapter(child: SizedBox(height: 96 + bottom)),
          ],
        ],
      ),
    );
  }

  /// The unhurried header: a large title that scrolls away, the explainer, and
  /// the two things you do to the shelf as a whole.
  Widget _mainAppBar() => SliverAppBar.large(
        title: const Text('Scenarios'),
        actions: [
          IconButton(
            tooltip: 'About scenarios',
            icon: const Icon(Icons.info_outline),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                  builder: (_) => const ScenarioInfoScreen()),
            ),
          ),
          IconButton(
            tooltip: 'Import',
            icon: const Icon(Icons.upload_file_outlined),
            onPressed: _showImportSheet,
          ),
          IconButton(
            tooltip: 'Select multiple',
            icon: const Icon(Icons.checklist),
            onPressed: () => setState(() => _selecting = true),
          ),
        ],
      );

  Widget _selectionAppBar(AppState state) => SliverAppBar(
        pinned: true,
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: _exitSelection,
        ),
        title: Text('${_selection.length} selected'),
        actions: [
          IconButton(
            tooltip: 'Export selected',
            icon: const Icon(Icons.download_outlined),
            onPressed: _selection.isEmpty ? null : () => _exportSelected(state),
          ),
          IconButton(
            tooltip: 'Delete selected',
            icon: const Icon(Icons.delete_outline),
            onPressed: _selection.isEmpty ? null : () => _deleteSelected(state),
          ),
        ],
      );

  Widget _searchAndControls(AppState state, List<String> tags) {
    final cardView = _cardView(state);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
      child: Column(
        children: [
          SearchBar(
            controller: _search,
            hintText: 'Search scenarios',
            padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 14),
            ),
            leading: const Icon(Icons.search),
            trailing: [
              if (_query.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    _search.clear();
                    setState(() => _query = '');
                  },
                ),
            ],
            onChanged: (v) => setState(() => _query = v),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _ControlChip(
                icon: Icons.sort,
                label: _sort.label,
                onTap: _pickSort,
              ),
              const SizedBox(width: 8),
              _ControlChip(
                icon: Icons.label_outline,
                label: _tagFilter.isEmpty
                    ? 'Tags'
                    : '${_tagFilter.length} tag'
                        '${_tagFilter.length == 1 ? '' : 's'}',
                selected: _tagFilter.isNotEmpty,
                onTap: () => _showTagFilter(tags),
              ),
              const Spacer(),
              IconButton(
                tooltip: cardView ? 'Show as list' : 'Show as grid',
                icon: Icon(cardView
                    ? Icons.view_list_outlined
                    : Icons.grid_view_outlined),
                onPressed: () => state.setBrowseLayout(
                  BrowseSection.scenarios,
                  cardView ? BrowseLayout.list : BrowseLayout.grid,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _header(String text) => SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            text,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
      );

  /// One section of scenarios, as cards or as rows. A scenario has no picture, so
  /// a card shows the thing itself — as much of the opening as fits.
  Widget _shelf(AppState state, List<Scenario> list) {
    if (_cardView(state)) {
      return SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        sliver: SliverGrid.builder(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 240,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 0.86,
          ),
          itemCount: list.length,
          itemBuilder: (context, i) => _ScenarioCard(
            scenario: list[i],
            selecting: _selecting,
            selected: _selection.contains(list[i].id),
            onTap: () => _onItemTap(list[i]),
            onLongPress: () => _onItemLongPress(list[i]),
            onToggleStar: () => state.toggleScenarioStar(list[i].id),
            onAction: (a) => _runAction(state, list[i], a),
          ),
        ),
      );
    }
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      sliver: SliverList.builder(
        itemCount: list.length,
        itemBuilder: (context, i) => _ScenarioTile(
          scenario: list[i],
          selecting: _selecting,
          selected: _selection.contains(list[i].id),
          onTap: () => _onItemTap(list[i]),
          onLongPress: () => _onItemLongPress(list[i]),
          onToggleStar: () => state.toggleScenarioStar(list[i].id),
          onAction: (a) => _runAction(state, list[i], a),
        ),
      ),
    );
  }
}
/// The per-scenario actions, shared by the card's and the row's 3-dot menu so
/// both entry points behave identically.
enum _ScenarioAction {
  edit('Edit', Icons.edit_outlined),
  copyText('Copy text', Icons.copy_outlined),
  download('Download', Icons.download_outlined),
  duplicate('Duplicate', Icons.copy_all_outlined),
  delete('Delete', Icons.delete_outline);

  const _ScenarioAction(this.label, this.icon);
  final String label;
  final IconData icon;
}

List<PopupMenuEntry<_ScenarioAction>> _scenarioMenuItems() => [
      for (final action in _ScenarioAction.values)
        PopupMenuItem<_ScenarioAction>(
          value: action,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: Icon(action.icon),
            title: Text(action.label),
          ),
        ),
    ];

/// A small pill button used for the sort and tag controls under the search bar.
class _ControlChip extends StatelessWidget {
  const _ControlChip({
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ActionChip(
      avatar: Icon(
        icon,
        size: 18,
        color: selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant,
      ),
      label: Text(label),
      backgroundColor: selected ? scheme.secondaryContainer : null,
      side: selected ? BorderSide.none : null,
      onPressed: onTap,
    );
  }
}

/// How a scenario relates to the character it is used with, in two words.
String _modeLabel(Scenario scenario) =>
    scenario.overwriteCharacterScenario ? 'Replaces' : 'Adds to';

/// A scenario in the card grid. There is no picture to show, so the card shows
/// the opening itself — the only thing that distinguishes one scenario from
/// another at a glance.
class _ScenarioCard extends StatelessWidget {
  const _ScenarioCard({
    required this.scenario,
    required this.selecting,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    required this.onToggleStar,
    required this.onAction,
  });

  final Scenario scenario;
  final bool selecting;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onToggleStar;
  final ValueChanged<_ScenarioAction> onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: selected
            ? BorderSide(color: scheme.primary, width: 2)
            : BorderSide.none,
      ),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 2, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      scenario.displayName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (selecting)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Icon(
                        selected
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        size: 20,
                        color: selected ? scheme.primary : scheme.onSurface,
                      ),
                    )
                  else
                    SizedBox(
                      width: 32,
                      child: PopupMenuButton<_ScenarioAction>(
                        padding: EdgeInsets.zero,
                        icon: const Icon(Icons.more_vert, size: 20),
                        tooltip: 'Actions',
                        onSelected: onAction,
                        itemBuilder: (context) => _scenarioMenuItems(),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                child: Text(
                  scenario.blurb.isEmpty ? 'Nothing written yet' : scenario.blurb,
                  overflow: TextOverflow.fade,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        height: 1.35,
                      ),
                ),
              ),
            ),
            // The footer carries the two facts a card cannot show in prose: how
            // it combines with a character, and whether it is starred.
            Container(
              color: scheme.surfaceContainerHighest,
              padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _modeLabel(scenario),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                  ),
                  IconButton(
                    tooltip: scenario.starred ? 'Unstar' : 'Star',
                    visualDensity: VisualDensity.compact,
                    iconSize: 18,
                    icon: Icon(
                      scenario.starred ? Icons.star : Icons.star_border,
                      color: scenario.starred ? Colors.amber : null,
                    ),
                    onPressed: onToggleStar,
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
/// A scenario in the names list: a glyph, the title, the opening's first line,
/// and the star / actions affordances.
class _ScenarioTile extends StatelessWidget {
  const _ScenarioTile({
    required this.scenario,
    required this.selecting,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    required this.onToggleStar,
    required this.onAction,
  });

  final Scenario scenario;
  final bool selecting;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onToggleStar;
  final ValueChanged<_ScenarioAction> onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: selected
            ? BorderSide(color: scheme.primary, width: 2)
            : BorderSide.none,
      ),
      child: ListTile(
        onTap: onTap,
        onLongPress: onLongPress,
        leading: selecting
            ? Icon(
                selected ? Icons.check_circle : Icons.radio_button_unchecked,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              )
            : Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: Icon(Icons.theater_comedy_outlined,
                    size: 22, color: scheme.onSecondaryContainer),
              ),
        title: Text(
          scenario.displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              scenario.blurb.isEmpty ? 'Nothing written yet' : scenario.blurb,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Text(
              [
                _modeLabel(scenario),
                if (scenario.tags.isNotEmpty) scenario.tags.take(3).join(', '),
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
        trailing: selecting
            ? null
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: scenario.starred ? 'Unstar' : 'Star',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      scenario.starred ? Icons.star : Icons.star_border,
                      color: scenario.starred ? Colors.amber : null,
                    ),
                    onPressed: onToggleStar,
                  ),
                  PopupMenuButton<_ScenarioAction>(
                    tooltip: 'Actions',
                    icon: const Icon(Icons.more_vert),
                    onSelected: onAction,
                    itemBuilder: (context) => _scenarioMenuItems(),
                  ),
                ],
              ),
      ),
    );
  }
}

/// Shown when there are no scenarios at all — a nudge, and what one is for.
class _EmptyShelf extends StatelessWidget {
  const _EmptyShelf({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 0, 32, 64),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.theater_comedy_outlined, size: 56, color: scheme.outline),
            const SizedBox(height: 16),
            Text('No scenarios yet',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'A scenario is the situation a chat starts in — where you both '
              'are and what is happening. Write one here and plug it into any '
              'character, or into a single chat.',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            FilledButton.tonalIcon(
              onPressed: onCreate,
              icon: const Icon(Icons.add),
              label: const Text('Write a scenario'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown when a search / tag filter matches nothing.
class _NoMatches extends StatelessWidget {
  const _NoMatches();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 0, 32, 64),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off_outlined, size: 48, color: scheme.outline),
            const SizedBox(height: 12),
            Text(
              'No scenarios match your search.',
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

String _safeName(String s) => s
    .replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '')
    .trim()
    .replaceAll(RegExp(r'\s+'), '_');

/// A picked file's name without its extension.
String _baseName(String fileName) {
  final dot = fileName.lastIndexOf('.');
  return dot <= 0 ? fileName : fileName.substring(0, dot);
}
