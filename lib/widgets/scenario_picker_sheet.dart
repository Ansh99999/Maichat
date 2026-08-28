import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/scenario.dart';
import '../state/app_state.dart';

/// What the scenario picker hands back.
///
/// The three fields say the same thing three ways because the two callers want
/// different halves of it: a chat stores the *link* ([scenarioId]) so later
/// library edits reach it, plus a [text] when the user wanted this chat's wording
/// to differ; a character only ever stores plain prose, which is [preview].
class ScenarioPick {
  const ScenarioPick({this.scenarioId, this.text = '', this.preview = ''});

  /// A blank pick — "go back to the character's own scenario".
  const ScenarioPick.clear()
      : scenarioId = null,
        text = '',
        preview = '';

  /// The library scenario this came from, or null when it was written on the spot.
  final String? scenarioId;

  /// A wording that belongs to where it is being used rather than to the library.
  /// Empty means "follow the library scenario named by [scenarioId]".
  final String text;

  /// What the scenario reads as right now, whichever route it came by.
  final String preview;

  bool get isClear => scenarioId == null && text.trim().isEmpty;
}

/// Opens the scenario picker over the bottom three-quarters of the screen and
/// returns what the user settled on, or null if they backed out.
///
/// One sheet, three stages: browse, preview, edit. Everything happens in place —
/// choosing a scenario, reading it, changing it, deciding whether the change
/// belongs to the library or only to here, and finally committing with Proceed.
/// Nothing takes effect until Proceed, which is what makes reading and editing
/// safe to do while you are still making up your mind.
///
/// [localLabel] names the place a "here only" save applies to ("this chat",
/// "Aria"); [cardScenario] is what the character's own card says, so an
/// "adds to" scenario can be previewed as it will actually be sent.
Future<ScenarioPick?> showScenarioPickerSheet(
  BuildContext context, {
  required String localLabel,
  String? currentScenarioId,
  String currentText = '',
  String cardScenario = '',
}) =>
    showModalBottomSheet<ScenarioPick>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => ScenarioPickerSheet(
        localLabel: localLabel,
        currentScenarioId: currentScenarioId,
        currentText: currentText,
        cardScenario: cardScenario,
      ),
    );

/// The body of [showScenarioPickerSheet], exposed for tests.
class ScenarioPickerSheet extends StatefulWidget {
  const ScenarioPickerSheet({
    super.key,
    required this.localLabel,
    this.currentScenarioId,
    this.currentText = '',
    this.cardScenario = '',
  });

  final String localLabel;
  final String? currentScenarioId;
  final String currentText;
  final String cardScenario;

  @override
  State<ScenarioPickerSheet> createState() => _ScenarioPickerSheetState();
}

/// Which of the three faces the sheet is wearing.
enum _Stage { list, preview, edit }

/// Where a saved edit goes.
enum _SaveTarget { library, hereOnly }

class _ScenarioPickerSheetState extends State<ScenarioPickerSheet> {
  final TextEditingController _search = TextEditingController();
  final TextEditingController _title = TextEditingController();
  final TextEditingController _body = TextEditingController();

  _Stage _stage = _Stage.list;

  /// Whether the movement between stages is a drill-in or a step back, so the
  /// transition slides the way the navigation went.
  bool _forward = true;

  final Set<String> _tagFilter = <String>{};

  /// The library scenario being looked at, or null while writing a fresh one.
  Scenario? _selected;

  /// A wording that has been saved "here only" — the library copy is untouched.
  String _draft = '';

  /// Set while writing a scenario that is not in the library (yet).
  bool _writingNew = false;

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _search.dispose();
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  void _go(_Stage stage, {bool forward = true}) => setState(() {
        _forward = forward;
        _stage = stage;
      });
  // --- what is on screen ---------------------------------------------------

  /// The text the preview shows and Proceed hands back: a "here only" edit if
  /// there is one, else whatever the chosen library scenario says.
  String get _effectiveText =>
      _draft.trim().isNotEmpty ? _draft.trim() : (_selected?.text.trim() ?? '');

  /// What the model will actually be told, once the chosen scenario has been
  /// combined with the character's own the way it asks to be.
  String get _asSent {
    final scenario = _selected;
    if (scenario == null || _draft.trim().isNotEmpty) return _effectiveText;
    return scenario.appliedOver(widget.cardScenario);
  }

  List<Scenario> _visible(List<Scenario> scenarios) {
    final result = scenarios
        .where((s) =>
            (_tagFilter.isEmpty ||
                _tagFilter.every((t) => s.tags.contains(t))) &&
            s.matches(_search.text))
        .toList();
    // Starred first, then freshest — the same order the shelf reads in, so a
    // scenario is where the user last saw it.
    result.sort((a, b) {
      if (a.starred != b.starred) return a.starred ? -1 : 1;
      return b.updatedAt.compareTo(a.updatedAt);
    });
    return result;
  }

  List<String> _allTags(List<Scenario> scenarios) {
    final tags = <String>{};
    for (final s in scenarios) {
      tags.addAll(s.tags);
    }
    final sorted = tags.toList()..sort();
    return sorted;
  }

  // --- moving between stages -----------------------------------------------

  void _choose(Scenario scenario) {
    setState(() {
      _selected = scenario;
      _writingNew = false;
      // A wording saved for this chat only survives re-opening the picker on the
      // same scenario; choosing a different one starts clean.
      _draft = scenario.id == widget.currentScenarioId ? widget.currentText : '';
      _forward = true;
      _stage = _Stage.preview;
    });
  }

  void _writeNew() {
    setState(() {
      _selected = null;
      _writingNew = true;
      _draft = '';
      _title.text = '';
      _body.text = '';
      _forward = true;
      _stage = _Stage.edit;
    });
  }

  void _startEditing() {
    _title.text = _selected?.name ?? '';
    _body.text = _effectiveText;
    _go(_Stage.edit);
  }

  /// Asks the question the spec insists on: does this edit belong to the library
  /// copy, or only to where it is being used?
  Future<_SaveTarget?> _askWhereToSave() => showDialog<_SaveTarget>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Save this scenario where?'),
          content: Text(
            'You can update the copy in your library, so every future use gets '
            'the change — or keep it to ${widget.localLabel}, leaving the '
            'library alone.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(_SaveTarget.hereOnly),
              child: Text('Just ${widget.localLabel}'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(_SaveTarget.library),
              child: const Text('The library'),
            ),
          ],
        ),
      );

  Future<void> _saveEdit() async {
    final text = _body.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          content: Text('Write the opening first.'),
        ));
      return;
    }
    final target = await _askWhereToSave();
    if (target == null || !mounted) return;
    final state = context.read<AppState>();
    final title = _title.text.trim();

    switch (target) {
      case _SaveTarget.library:
        if (_selected == null) {
          final fresh = Scenario(
            id: DateTime.now().microsecondsSinceEpoch.toString(),
            name: title,
            text: text,
          );
          await state.addScenario(fresh);
          if (!mounted) return;
          setState(() {
            _selected = fresh;
            _writingNew = false;
            _draft = '';
          });
        } else {
          final updated = _selected!.copyWith(
            name: title.isEmpty ? _selected!.name : title,
            text: text,
            updatedAt: DateTime.now(),
          );
          await state.saveScenario(updated);
          if (!mounted) return;
          setState(() {
            _selected = updated;
            // The library now says this, so there is nothing local left to hold.
            _draft = '';
          });
        }
      case _SaveTarget.hereOnly:
        setState(() {
          _draft = text;
          // A brand-new scenario kept out of the library has no id to link to;
          // its text travels on its own.
          _writingNew = _selected == null;
        });
    }
    if (mounted) _go(_Stage.preview, forward: false);
  }

  void _proceed() {
    final text = _effectiveText;
    if (text.isEmpty) {
      Navigator.of(context).pop(const ScenarioPick.clear());
      return;
    }
    Navigator.of(context).pop(ScenarioPick(
      scenarioId: _selected?.id,
      // Only a wording that differs from the library's travels as an override;
      // otherwise the link alone is stored and the library stays authoritative.
      text: _draft.trim().isNotEmpty ? _draft.trim() : '',
      preview: _asSent,
    ));
  }
  // --- build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final size = MediaQuery.sizeOf(context);
    final insets = MediaQuery.viewInsetsOf(context).bottom;
    // Three-quarters of the screen, as specified — but never taller than what is
    // left above the keyboard, or the editor would type into a hidden field.
    final height =
        math.min(size.height * 0.75, math.max(280.0, size.height - insets - 80));

    final Widget body = switch (_stage) {
      _Stage.list => _listStage(state),
      _Stage.preview => _previewStage(state),
      _Stage.edit => _editStage(state),
    };

    return Padding(
      padding: EdgeInsets.only(bottom: insets),
      child: SizedBox(
        height: height,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) {
            final incoming = child.key == ValueKey(_stage);
            final dir = _forward ? 1.0 : -1.0;
            final begin = Offset((incoming ? dir : -dir) * 0.1, 0);
            return FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween<Offset>(begin: begin, end: Offset.zero)
                    .animate(animation),
                child: child,
              ),
            );
          },
          layoutBuilder: (currentChild, previousChildren) => Stack(
            fit: StackFit.expand,
            alignment: Alignment.topCenter,
            children: [...previousChildren, ?currentChild],
          ),
          child: KeyedSubtree(key: ValueKey(_stage), child: body),
        ),
      ),
    );
  }

  /// The sheet's own header: an optional back arrow, a title, and the actions
  /// that belong to this stage.
  Widget _header(String title, {VoidCallback? onBack, List<Widget> actions = const []}) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(onBack == null ? 20 : 4, 0, 8, 4),
      child: Row(
        children: [
          if (onBack != null)
            IconButton(
              tooltip: 'Back',
              icon: const Icon(Icons.arrow_back),
              onPressed: onBack,
            ),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
  // --- stage 1: browse -----------------------------------------------------

  Widget _listStage(AppState state) {
    final scheme = Theme.of(context).colorScheme;
    final all = state.scenarios;
    final tags = _allTags(all);
    final visible = _visible(all);
    final hasOne =
        widget.currentScenarioId != null || widget.currentText.trim().isNotEmpty;

    return Column(
      children: [
        _header('Choose a scenario'),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: SearchBar(
            controller: _search,
            hintText: 'Search scenarios',
            leading: const Icon(Icons.search),
            padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 14),
            ),
            trailing: [
              if (_search.text.isNotEmpty)
                IconButton(
                  tooltip: 'Clear',
                  icon: const Icon(Icons.close),
                  onPressed: _search.clear,
                ),
            ],
          ),
        ),
        if (tags.isNotEmpty)
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                for (final tag in tags)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text(tag),
                      selected: _tagFilter.contains(tag),
                      onSelected: (on) => setState(() {
                        if (on) {
                          _tagFilter.add(tag);
                        } else {
                          _tagFilter.remove(tag);
                        }
                      }),
                    ),
                  ),
              ],
            ),
          ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
            children: [
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: scheme.primaryContainer,
                  child: Icon(Icons.edit_outlined,
                      color: scheme.onPrimaryContainer, size: 20),
                ),
                title: const Text('Write a new one'),
                subtitle: const Text('Just for now, or keep it in the library'),
                onTap: _writeNew,
              ),
              if (hasOne)
                ListTile(
                  leading: CircleAvatar(
                    backgroundColor: scheme.surfaceContainerHighest,
                    child: Icon(Icons.backspace_outlined,
                        color: scheme.onSurfaceVariant, size: 18),
                  ),
                  title: const Text("Use the character's own"),
                  subtitle: const Text('Clears the scenario set here'),
                  onTap: () =>
                      Navigator.of(context).pop(const ScenarioPick.clear()),
                ),
              const Divider(height: 16),
              if (all.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
                  child: Text(
                    'Your library has no scenarios yet. Write one above, or make '
                    'some in Library ▸ Scenarios.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                )
              else if (visible.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
                  child: Text(
                    'Nothing matches that.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                )
              else
                for (final scenario in visible)
                  _PickerRow(
                    scenario: scenario,
                    inUse: scenario.id == widget.currentScenarioId,
                    onTap: () => _choose(scenario),
                  ),
            ],
          ),
        ),
      ],
    );
  }
  // --- stage 2: preview ----------------------------------------------------

  Widget _previewStage(AppState state) {
    final scheme = Theme.of(context).colorScheme;
    // Read the live library copy: an edit saved to the library a moment ago
    // should be what the preview shows.
    final scenario = _selected == null ? null : state.scenarioById(_selected!.id);
    if (scenario != null) _selected = scenario;
    final local = _draft.trim().isNotEmpty;
    final title = local && scenario == null
        ? 'Your scenario'
        : (scenario?.displayName ?? 'Your scenario');
    final tokens = state.estimateTokens(_asSent);

    return Column(
      children: [
        _header(
          title,
          onBack: () => _go(_Stage.list, forward: false),
          actions: [
            IconButton(
              tooltip: 'Edit',
              icon: const Icon(Icons.edit_outlined),
              onPressed: _startEditing,
            ),
          ],
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _MetaChip(
                    icon: Icons.data_usage_outlined,
                    label: '$tokens token${tokens == 1 ? '' : 's'}',
                  ),
                  if (scenario != null)
                    _MetaChip(
                      icon: scenario.overwriteCharacterScenario
                          ? Icons.swap_horiz
                          : Icons.add,
                      label: scenario.overwriteCharacterScenario
                          ? "Replaces the character's"
                          : "Adds to the character's",
                    ),
                  if (local)
                    _MetaChip(
                      icon: Icons.bookmark_border,
                      label: 'Edited for ${widget.localLabel}',
                      tinted: true,
                    ),
                ],
              ),
              const SizedBox(height: 16),
              SelectableText(
                _asSent.isEmpty ? 'Nothing written yet.' : _asSent,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(height: 1.45),
              ),
              if (local && scenario != null) ...[
                const SizedBox(height: 18),
                Text(
                  'The copy in your library still says what it said before.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ],
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: Row(
            children: [
              TextButton(
                onPressed: () => _go(_Stage.list, forward: false),
                child: const Text('Back'),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: _effectiveText.isEmpty ? null : _proceed,
                icon: const Icon(Icons.check),
                label: const Text('Proceed'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // --- stage 3: edit, in the same place ------------------------------------

  Widget _editStage(AppState state) {
    final tokens = state.estimateTokens(_body.text);
    return Column(
      children: [
        _header(
          _writingNew && _selected == null ? 'Write a scenario' : 'Edit scenario',
          onBack: () => _go(
            _selected == null && _draft.isEmpty ? _Stage.list : _Stage.preview,
            forward: false,
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
            children: [
              TextField(
                controller: _title,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Title',
                  hintText: 'Snowed in at the station',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _body,
                minLines: 6,
                maxLines: null,
                autofocus: true,
                keyboardType: TextInputType.multiline,
                textCapitalization: TextCapitalization.sentences,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                  labelText: 'The scenario',
                  hintText: 'Where are you both, and what is happening?',
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '$tokens token${tokens == 1 ? '' : 's'}, on every turn',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: Row(
            children: [
              TextButton(
                onPressed: () => _go(
                  _selected == null && _draft.isEmpty
                      ? _Stage.list
                      : _Stage.preview,
                  forward: false,
                ),
                child: const Text('Cancel'),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: _saveEdit,
                icon: const Icon(Icons.save_outlined),
                label: const Text('Save'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
/// A scenario in the picker's list: its title, the opening's first line, and a
/// tick when it is the one already in force.
class _PickerRow extends StatelessWidget {
  const _PickerRow({
    required this.scenario,
    required this.inUse,
    required this.onTap,
  });

  final Scenario scenario;
  final bool inUse;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: scheme.secondaryContainer,
        child: Icon(Icons.theater_comedy_outlined,
            color: scheme.onSecondaryContainer, size: 20),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              scenario.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          if (scenario.starred)
            const Padding(
              padding: EdgeInsets.only(left: 6),
              child: Icon(Icons.star, size: 15, color: Colors.amber),
            ),
        ],
      ),
      subtitle: Text(
        scenario.blurb.isEmpty ? 'Nothing written yet' : scenario.blurb,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: inUse ? Icon(Icons.check, color: scheme.primary) : null,
      onTap: onTap,
    );
  }
}

/// A small read-only fact about the scenario being previewed.
class _MetaChip extends StatelessWidget {
  const _MetaChip({
    required this.icon,
    required this.label,
    this.tinted = false,
  });

  final IconData icon;
  final String label;
  final bool tinted;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = tinted ? scheme.onSecondaryContainer : scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 5, 12, 5),
      decoration: BoxDecoration(
        color: tinted
            ? scheme.secondaryContainer
            : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: fg),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(color: fg),
          ),
        ],
      ),
    );
  }
}
