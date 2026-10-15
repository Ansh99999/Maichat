/// The edit-mode bottom sheets for the Home screen: adding a widget, picking a
/// quick-open target, a tile's own settings, the grid, and the overall look.
///
/// Every sheet here is a thin, generic shell over the contract in
/// `home_spec.dart` and `home_layout.dart` — it does not know what a widget
/// draws, only how to ask the user for the values its [HomeOption]s describe.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/home_layout.dart';
import '../../services/chat_graph.dart';
import '../../state/app_state.dart';
import '../../widgets/avatar_image.dart';
import '../../widgets/character_avatar.dart';
import '../chats_screen.dart' show relativeTime;
import '../gallery/gallery_picker_sheet.dart';
import 'home_icon_shape.dart';
import 'home_spec.dart';
import 'home_widgets.dart';
import 'quick_targets.dart';

const double _kMaxSheetHeightFraction = 0.85;

/// A plain titled scrollable sheet frame shared by every sheet below: a drag
/// handle (via [showModalBottomSheet]'s own), a titleLarge heading, optional
/// subtitle, and scrollable body that respects the bottom safe area.
class _SheetFrame extends StatelessWidget {
  const _SheetFrame({
    required this.title,
    this.subtitle,
    required this.children,
  });

  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final bottomSafe = media.padding.bottom;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: media.size.height * _kMaxSheetHeightFraction,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
            child: Text(title, style: Theme.of(context).textTheme.titleLarge),
          ),
          if (subtitle != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
              child: Text(
                subtitle!,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ),
          Flexible(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(20, 12, 20, 16 + bottomSafe),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: children,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Future<T?> _showSheet<T>(BuildContext context, WidgetBuilder builder) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: builder,
  );
}

// ---------------------------------------------------------------------------
// 1. Add a widget
// ---------------------------------------------------------------------------

/// Lets the user pick a kind of widget to add to the Home grid. Picking
/// [HomeWidgetKind.quickOpen] goes straight on to [showQuickTargetPicker]; the
/// result's config is `spec.initialConfig` merged with whatever that picker
/// (or a future kind-specific step) produced.
Future<({HomeWidgetKind kind, Map<String, Object?> config})?> showAddWidgetSheet(
  BuildContext context,
) {
  return _showSheet(context, (sheetContext) => const _AddWidgetSheet());
}

class _AddWidgetSheet extends StatelessWidget {
  const _AddWidgetSheet();

  @override
  Widget build(BuildContext context) {
    return _SheetFrame(
      title: 'Add a widget',
      children: [
        for (final kind in kHomeWidgetOrder) ...[
          _WidgetKindCard(kind: kind),
          const SizedBox(height: 10),
        ],
      ],
    );
  }
}

class _WidgetKindCard extends StatelessWidget {
  const _WidgetKindCard({required this.kind});

  final HomeWidgetKind kind;

  Future<void> _pick(BuildContext context) async {
    final spec = specFor(kind);
    if (kind == HomeWidgetKind.quickOpen) {
      final target = await showQuickTargetPicker(context);
      if (target == null || !context.mounted) return;
      Navigator.of(context).pop((
        kind: kind,
        config: {...spec.initialConfig, 'target': target.name},
      ));
      return;
    }
    Navigator.of(context).pop((kind: kind, config: spec.initialConfig));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final spec = specFor(kind);
    final featured = kind == HomeWidgetKind.studio;
    final shape = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(24),
    );
    return Material(
      color: featured ? scheme.primaryContainer : scheme.surfaceContainerHigh,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        customBorder: shape,
        onTap: () => _pick(context),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: ShapeDecoration(
                  color: featured
                      ? scheme.primary.withValues(alpha: 0.18)
                      : scheme.secondaryContainer,
                  shape: RoundedSuperellipseBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                child: Icon(
                  spec.icon,
                  color: featured ? scheme.onPrimaryContainer : scheme.onSecondaryContainer,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            spec.title,
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                  color: featured ? scheme.onPrimaryContainer : null,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                        ),
                        if (featured) ...[
                          const SizedBox(width: 8),
                          Chip(
                            label: const Text('Featured'),
                            labelStyle: Theme.of(context).textTheme.labelSmall?.copyWith(
                                  color: scheme.onPrimary,
                                ),
                            backgroundColor: scheme.primary,
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      spec.description,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: featured
                                ? scheme.onPrimaryContainer.withValues(alpha: 0.85)
                                : scheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 2. Quick-target picker
// ---------------------------------------------------------------------------

/// Lets the user choose a [QuickTarget], grouped under [QuickGroup] headings,
/// in a 4-column icon grid. [current] (if given) is drawn selected.
Future<QuickTarget?> showQuickTargetPicker(
  BuildContext context, {
  QuickTarget? current,
}) {
  return _showSheet<QuickTarget>(
    context,
    (sheetContext) => _QuickTargetSheet(current: current),
  );
}

class _QuickTargetSheet extends StatelessWidget {
  const _QuickTargetSheet({required this.current});

  final QuickTarget? current;

  @override
  Widget build(BuildContext context) {
    final byGroup = <QuickGroup, List<QuickTarget>>{};
    for (final target in QuickTarget.values) {
      final info = quickTargetInfo(target);
      (byGroup[info.group] ??= <QuickTarget>[]).add(target);
    }
    return _SheetFrame(
      title: 'Choose a shortcut',
      children: [
        for (final group in QuickGroup.values)
          if (byGroup[group] case final targets?) ...[
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 8),
              child: Text(
                group.label,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: EdgeInsets.zero,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                mainAxisSpacing: 12,
                crossAxisSpacing: 8,
                mainAxisExtent: 84,
              ),
              itemCount: targets.length,
              itemBuilder: (context, i) {
                final target = targets[i];
                return _QuickTargetCell(
                  target: target,
                  selected: target == current,
                );
              },
            ),
            const SizedBox(height: 8),
          ],
      ],
    );
  }
}

class _QuickTargetCell extends StatelessWidget {
  const _QuickTargetCell({required this.target, required this.selected});

  final QuickTarget target;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final info = quickTargetInfo(target);
    return InkWell(
      key: ValueKey('quick-target-${target.name}'),
      borderRadius: BorderRadius.circular(16),
      onTap: () => Navigator.of(context).pop(target),
      child: Semantics(
        button: true,
        selected: selected,
        label: info.label,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: ShapeDecoration(
                color: selected ? scheme.primary : scheme.secondaryContainer,
                shape: const CircleBorder(),
              ),
              child: Icon(
                info.icon,
                size: 22,
                color: selected ? scheme.onPrimary : scheme.onSecondaryContainer,
              ),
            ),
            const SizedBox(height: 4),
            Flexible(
              child: Text(
                info.label,
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      fontWeight: selected ? FontWeight.w700 : null,
                      color: selected ? scheme.primary : null,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 3. Tile settings
// ---------------------------------------------------------------------------

/// Renders `specFor(tile.kind).options(tile)` generically and calls
/// [onChanged] with the updated tile on every change.
Future<void> showTileSettingsSheet(
  BuildContext context, {
  required HomeTile tile,
  required ValueChanged<HomeTile> onChanged,
}) {
  return _showSheet<void>(
    context,
    (sheetContext) => _TileSettingsSheet(tile: tile, onChanged: onChanged),
  );
}

class _TileSettingsSheet extends StatefulWidget {
  const _TileSettingsSheet({required this.tile, required this.onChanged});

  final HomeTile tile;
  final ValueChanged<HomeTile> onChanged;

  @override
  State<_TileSettingsSheet> createState() => _TileSettingsSheetState();
}

class _TileSettingsSheetState extends State<_TileSettingsSheet> {
  late HomeTile _tile;

  @override
  void initState() {
    super.initState();
    _tile = widget.tile;
  }

  void _apply(HomeTile next) {
    setState(() => _tile = next);
    widget.onChanged(next);
  }

  void _set(String key, Object? value) => _apply(_tile.withConfig(key, value));

  Future<void> _openPicker(HomePickOption option) async {
    switch (option.pick) {
      case HomePickKind.chat:
        final picked = await _showChatPicker(
          context,
          allowNone: option.allowNone,
          noneLabel: option.noneLabel,
        );
        if (picked != null) _set(option.key, picked.id);
      case HomePickKind.provider:
        final picked = await _showProviderPicker(
          context,
          allowNone: option.allowNone,
          noneLabel: option.noneLabel,
        );
        if (picked != null) _set(option.key, picked.id);
      case HomePickKind.character:
        final picked = await _showCharacterPicker(
          context,
          allowNone: option.allowNone,
          noneLabel: option.noneLabel,
        );
        if (picked != null) _set(option.key, picked.id);
      case HomePickKind.picture:
        if (_tile.str(option.key) != null && option.allowNone) {
          final action = await _showPictureActionSheet(context);
          if (action == _PictureAction.clear) {
            _set(option.key, null);
            return;
          }
          if (action != _PictureAction.choose) return;
          if (!mounted) return;
        }
        final ref = await showGalleryPickerSheet(context);
        if (ref != null) _set(option.key, ref);
      case HomePickKind.target:
        final current = QuickTarget.byName(_tile.str(option.key));
        final target = await showQuickTargetPicker(context, current: current);
        if (target != null) _set(option.key, target.name);
    }
  }

  @override
  Widget build(BuildContext context) {
    final spec = specFor(_tile.kind);
    final options = spec.options(_tile);
    return _SheetFrame(
      title: spec.title,
      subtitle: '${_tile.w} × ${_tile.h}',
      children: [
        if (options.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text(
              'Nothing to set on this widget.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          )
        else
          for (final option in options) ...[
            _OptionTile(
              option: option,
              tile: _tile,
              onChoice: (v) => _set(option.key, v),
              onToggle: (v) => _set(option.key, v),
              onStep: (v) => _set(option.key, v),
              onText: (v) => _set(option.key, v.isEmpty ? null : v),
              onPickTap: () {
                if (option is HomePickOption) _openPicker(option);
              },
            ),
            const SizedBox(height: 16),
          ],
      ],
    );
  }
}

/// Marks "the sheet was dismissed without a choice" from the pickers below,
/// distinct from "none" (which is `null`).
/// What a picker sheet answered: dismissed (null), "none" ([id] null), or an
/// id.
typedef _Picked = ({String? id});

enum _PictureAction { choose, clear }

Future<_PictureAction?> _showPictureActionSheet(BuildContext context) {
  return showModalBottomSheet<_PictureAction>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.image_outlined),
            title: const Text('Choose a different picture'),
            onTap: () => Navigator.of(sheetContext).pop(_PictureAction.choose),
          ),
          ListTile(
            leading: const Icon(Icons.clear),
            title: const Text('Clear'),
            onTap: () => Navigator.of(sheetContext).pop(_PictureAction.clear),
          ),
        ],
      ),
    ),
  );
}

/// A single option row, dispatched by its runtime type (the sealed [HomeOption]
/// family), with its own label/help line above the control.
class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.option,
    required this.tile,
    required this.onChoice,
    required this.onToggle,
    required this.onStep,
    required this.onText,
    required this.onPickTap,
  });

  final HomeOption option;
  final HomeTile tile;
  final ValueChanged<String> onChoice;
  final ValueChanged<bool> onToggle;
  final ValueChanged<int> onStep;
  final ValueChanged<String> onText;
  final VoidCallback onPickTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    Widget labelBlock() => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(option.label, style: theme.textTheme.titleSmall),
              if (option.help != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    option.help!,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
            ],
          ),
        );

    switch (option) {
      case HomeChoiceOption(choices: final choices):
        final current = tile.str(option.key) ?? choices.keys.first;
        final shortAndFew = choices.length <= 3 &&
            choices.values.every((label) => label.length <= 10);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            labelBlock(),
            shortAndFew
                ? SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: [
                      for (final entry in choices.entries)
                        ButtonSegment<String>(
                          value: entry.key,
                          label: Text(entry.value),
                        ),
                    ],
                    selected: <String>{current},
                    onSelectionChanged: (set) => onChoice(set.first),
                  )
                : Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final entry in choices.entries)
                        ChoiceChip(
                          label: Text(entry.value),
                          selected: entry.key == current,
                          onSelected: (_) => onChoice(entry.key),
                        ),
                    ],
                  ),
          ],
        );

      case HomeToggleOption(fallback: final fallback):
        final value = tile.flag(option.key, fallback);
        return SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(option.label),
          subtitle: option.help == null ? null : Text(option.help!),
          value: value,
          onChanged: onToggle,
        );

      case HomeStepperOption(min: final min, max: final max, fallback: final fallback, unit: final unit):
        final value = tile.integer(option.key, fallback).clamp(min, max);
        final divisions = max > min ? max - min : null;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            labelBlock(),
            Row(
              children: [
                Expanded(
                  child: Slider(
                    value: value.toDouble(),
                    min: min.toDouble(),
                    max: max.toDouble(),
                    divisions: divisions,
                    label: '$value$unit',
                    onChanged: (v) => onStep(v.round()),
                  ),
                ),
                SizedBox(
                  width: 56,
                  child: Text(
                    '$value$unit',
                    textAlign: TextAlign.end,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          ],
        );

      case HomeTextOption(hint: final hint):
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            labelBlock(),
            TextField(
              controller: TextEditingController(text: tile.str(option.key) ?? '')
                ..selection = TextSelection.collapsed(
                  offset: (tile.str(option.key) ?? '').length,
                ),
              decoration: InputDecoration(
                hintText: hint,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: onText,
            ),
          ],
        );

      case HomePickOption pick:
        return _PickOptionTile(option: pick, tile: tile, onTap: onPickTap);
    }
  }
}

class _PickOptionTile extends StatelessWidget {
  const _PickOptionTile({
    required this.option,
    required this.tile,
    required this.onTap,
  });

  final HomePickOption option;
  final HomeTile tile;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final value = tile.str(option.key);

    Widget leading = const Icon(Icons.chevron_right);
    String current = option.noneLabel;

    switch (option.pick) {
      case HomePickKind.chat:
        if (value != null) {
          final convo = state.conversations.where((c) => c.id == value).firstOrNull;
          current = convo?.title.trim().isNotEmpty == true
              ? convo!.title
              : 'A chat that no longer exists';
        }
      case HomePickKind.provider:
        if (value != null) {
          final provider = state.providers.where((p) => p.id == value).firstOrNull;
          current = provider?.displayName ?? 'A provider that no longer exists';
        }
      case HomePickKind.character:
        if (value != null) {
          final character = state.characters.where((c) => c.id == value).firstOrNull;
          current = character?.displayName ?? 'A character that no longer exists';
          if (character != null) {
            leading = CharacterAvatar(character: character, radius: 16);
          }
        }
      case HomePickKind.picture:
        if (value != null) {
          final provider = avatarImage(value, displaySize: 32);
          current = 'A picture';
          if (provider != null) {
            leading = CircleAvatar(radius: 16, backgroundImage: provider);
          }
        }
      case HomePickKind.target:
        final target = QuickTarget.byName(value);
        final info = quickTargetInfo(target);
        current = info.label;
        leading = Icon(info.icon);
    }

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: leading,
      title: Text(option.label),
      subtitle: Text(current),
      onTap: onTap,
    );
  }
}

Future<_Picked?> _showChatPicker(
  BuildContext context, {
  required bool allowNone,
  required String noneLabel,
}) {
  return showModalBottomSheet<Object?>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (sheetContext) => _ChatPickerSheet(
      allowNone: allowNone,
      noneLabel: noneLabel,
    ),
  ).then((v) => v == null ? null : (id: v == '' ? null : v as String));
}

class _ChatPickerSheet extends StatelessWidget {
  const _ChatPickerSheet({required this.allowNone, required this.noneLabel});

  final bool allowNone;
  final String noneLabel;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final trees = collapseForks(state.conversations.where((c) => !c.isEmpty));
    return _SheetFrame(
      title: 'Choose a chat',
      children: [
        if (allowNone)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.block),
            title: Text(noneLabel),
            onTap: () => Navigator.of(context).pop(''),
          ),
        if (trees.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text(
              'No chats yet.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          )
        else
          for (final tree in trees)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.forum_outlined),
              title: Text(
                tree.root.title.trim().isEmpty ? 'Untitled chat' : tree.root.title,
              ),
              subtitle: Text(relativeTime(tree.latest.updatedAt)),
              onTap: () => Navigator.of(context).pop(tree.root.id),
            ),
      ],
    );
  }
}

Future<_Picked?> _showProviderPicker(
  BuildContext context, {
  required bool allowNone,
  required String noneLabel,
}) {
  return showModalBottomSheet<Object?>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (sheetContext) => _ProviderPickerSheet(
      allowNone: allowNone,
      noneLabel: noneLabel,
    ),
  ).then((v) => v == null ? null : (id: v == '' ? null : v as String));
}

class _ProviderPickerSheet extends StatelessWidget {
  const _ProviderPickerSheet({required this.allowNone, required this.noneLabel});

  final bool allowNone;
  final String noneLabel;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final providers = state.providers;
    return _SheetFrame(
      title: 'Choose a provider',
      children: [
        if (allowNone)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.block),
            title: Text(noneLabel),
            onTap: () => Navigator.of(context).pop(''),
          ),
        if (providers.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text(
              'No providers yet.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          )
        else
          for (final provider in providers)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.dns_outlined),
              title: Text(provider.displayName),
              subtitle: Text(provider.model),
              onTap: () => Navigator.of(context).pop(provider.id),
            ),
      ],
    );
  }
}

Future<_Picked?> _showCharacterPicker(
  BuildContext context, {
  required bool allowNone,
  required String noneLabel,
}) {
  return showModalBottomSheet<Object?>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (sheetContext) => _CharacterPickerSheet(
      allowNone: allowNone,
      noneLabel: noneLabel,
    ),
  ).then((v) => v == null ? null : (id: v == '' ? null : v as String));
}

class _CharacterPickerSheet extends StatelessWidget {
  const _CharacterPickerSheet({required this.allowNone, required this.noneLabel});

  final bool allowNone;
  final String noneLabel;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final characters = state.characters;
    return _SheetFrame(
      title: 'Choose a character',
      children: [
        if (allowNone)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.block),
            title: Text(noneLabel),
            onTap: () => Navigator.of(context).pop(''),
          ),
        if (characters.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text(
              'No characters yet.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          )
        else
          for (final character in characters)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: CharacterAvatar(character: character, radius: 18),
              title: Text(character.displayName),
              onTap: () => Navigator.of(context).pop(character.id),
            ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 4. Grid sheet
// ---------------------------------------------------------------------------

const List<({int c, int r})> _kGridPresets = [
  (c: 4, r: 5),
  (c: 4, r: 6),
  (c: 5, r: 6),
  (c: 5, r: 7),
  (c: 6, r: 8),
  (c: 8, r: 9),
];

/// Lets the user resize the grid, always computed from the layout the sheet
/// was *opened* with so switching presets back and forth restores the
/// original placement rather than compounding reflows.
Future<void> showGridSheet(
  BuildContext context, {
  required HomeLayout layout,
  required ValueChanged<HomeLayout> onChanged,
}) {
  return _showSheet<void>(
    context,
    (sheetContext) => _GridSheet(original: layout, onChanged: onChanged),
  );
}

class _GridSheet extends StatefulWidget {
  const _GridSheet({required this.original, required this.onChanged});

  final HomeLayout original;
  final ValueChanged<HomeLayout> onChanged;

  @override
  State<_GridSheet> createState() => _GridSheetState();
}

class _GridSheetState extends State<_GridSheet> {
  late int _columns;
  late int _rows;
  late HomeLayout _preview;

  @override
  void initState() {
    super.initState();
    _columns = widget.original.columns;
    _rows = widget.original.rows;
    _preview = widget.original;
  }

  void _apply(int columns, int rows) {
    final next = widget.original.withGrid(columns, rows);
    setState(() {
      _columns = columns;
      _rows = rows;
      _preview = next;
    });
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _SheetFrame(
      title: 'Grid',
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final preset in _kGridPresets)
              ChoiceChip(
                label: Text('${preset.c} × ${preset.r}'),
                selected: _columns == preset.c && _rows == preset.r,
                onSelected: (_) => _apply(preset.c, preset.r),
              ),
          ],
        ),
        const SizedBox(height: 20),
        Text('Columns', style: Theme.of(context).textTheme.titleSmall),
        Row(
          children: [
            Expanded(
              child: Slider(
                value: _columns.toDouble(),
                min: kHomeMinColumns.toDouble(),
                max: kHomeMaxColumns.toDouble(),
                divisions: kHomeMaxColumns - kHomeMinColumns,
                label: '$_columns',
                onChanged: (v) => _apply(v.round(), _rows),
              ),
            ),
            SizedBox(
              width: 32,
              child: Text('$_columns', textAlign: TextAlign.end),
            ),
          ],
        ),
        Text('Rows', style: Theme.of(context).textTheme.titleSmall),
        Row(
          children: [
            Expanded(
              child: Slider(
                value: _rows.toDouble(),
                min: kHomeMinRows.toDouble(),
                max: kHomeMaxRows.toDouble(),
                divisions: kHomeMaxRows - kHomeMinRows,
                label: '$_rows',
                onChanged: (v) => _apply(_columns, v.round()),
              ),
            ),
            SizedBox(
              width: 32,
              child: Text('$_rows', textAlign: TextAlign.end),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Center(
          child: AspectRatio(
            aspectRatio: 9 / 16,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 220),
              decoration: BoxDecoration(
                border: Border.all(color: scheme.outlineVariant),
                borderRadius: BorderRadius.circular(24),
              ),
              padding: const EdgeInsets.all(8),
              child: _GridPreview(layout: _preview),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Widgets keep their place where they can; anything that no longer '
          'fits moves to the next page.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
        ),
      ],
    );
  }
}

class _GridPreview extends StatelessWidget {
  const _GridPreview({required this.layout});

  final HomeLayout layout;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tiles = layout.pages.first.tiles;
    return LayoutBuilder(
      builder: (context, constraints) {
        final cellW = constraints.maxWidth / layout.columns;
        final cellH = constraints.maxHeight / layout.rows;
        return Stack(
          children: [
            for (var y = 0; y < layout.rows; y++)
              for (var x = 0; x < layout.columns; x++)
                Positioned(
                  left: x * cellW,
                  top: y * cellH,
                  width: cellW,
                  height: cellH,
                  child: Container(
                    margin: const EdgeInsets.all(1),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
            for (final tile in tiles)
              Positioned(
                left: tile.x * cellW,
                top: tile.y * cellH,
                width: tile.w * cellW,
                height: tile.h * cellH,
                child: Container(
                  margin: const EdgeInsets.all(1.5),
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.65),
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// 5. Look (home style) sheet
// ---------------------------------------------------------------------------

/// Lets the user pick the icon shape, toggle labels, set a wallpaper and its
/// fade. Every change is pushed immediately through [onChanged].
Future<void> showHomeStyleSheet(
  BuildContext context, {
  required HomeLayout layout,
  required ValueChanged<HomeLayout> onChanged,
}) {
  return _showSheet<void>(
    context,
    (sheetContext) => _HomeStyleSheet(layout: layout, onChanged: onChanged),
  );
}

class _HomeStyleSheet extends StatefulWidget {
  const _HomeStyleSheet({required this.layout, required this.onChanged});

  final HomeLayout layout;
  final ValueChanged<HomeLayout> onChanged;

  @override
  State<_HomeStyleSheet> createState() => _HomeStyleSheetState();
}

class _HomeStyleSheetState extends State<_HomeStyleSheet> {
  late HomeLayout _layout;

  @override
  void initState() {
    super.initState();
    _layout = widget.layout;
  }

  void _apply(HomeLayout next) {
    setState(() => _layout = next);
    widget.onChanged(next);
  }

  Future<void> _pickWallpaper() async {
    final ref = await showGalleryPickerSheet(context, title: 'Choose a wallpaper');
    if (ref != null) _apply(_layout.withStyle(wallpaper: ref));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasWallpaper = _layout.wallpaper != null;
    return _SheetFrame(
      title: 'Look',
      children: [
        Text('Icon shape', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 10),
        Row(
          children: [
            for (final shape in HomeIconShape.values) ...[
              Expanded(child: _ShapePreview(
                shape: shape,
                selected: shape == _layout.iconShape,
                onTap: () => _apply(_layout.withStyle(iconShape: shape)),
              )),
              if (shape != HomeIconShape.values.last) const SizedBox(width: 8),
            ],
          ],
        ),
        const SizedBox(height: 20),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Show names under shortcuts'),
          value: _layout.showLabels,
          onChanged: (v) => _apply(_layout.withStyle(showLabels: v)),
        ),
        const SizedBox(height: 12),
        Text('Wallpaper', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 10),
        Row(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(14),
                image: hasWallpaper
                    ? DecorationImage(
                        image: avatarImage(_layout.wallpaper!, displaySize: 56) ??
                            const AssetImage('assets/transparent.png'),
                        fit: BoxFit.cover,
                        onError: (_, _) {},
                      )
                    : null,
              ),
              child: hasWallpaper
                  ? null
                  : Icon(Icons.image_outlined, color: scheme.outline),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: _pickWallpaper,
                    child: const Text('Choose from gallery'),
                  ),
                  if (hasWallpaper)
                    TextButton(
                      onPressed: () => _apply(_layout.withStyle(wallpaper: '')),
                      child: const Text('Remove'),
                    ),
                ],
              ),
            ),
          ],
        ),
        if (hasWallpaper) ...[
          const SizedBox(height: 12),
          Text('Fade wallpaper', style: Theme.of(context).textTheme.titleSmall),
          Slider(
            value: _layout.wallpaperDim,
            min: 0,
            max: 0.9,
            divisions: 18,
            label: _layout.wallpaperDim.toStringAsFixed(2),
            onChanged: (v) => _apply(_layout.withStyle(wallpaperDim: v)),
          ),
        ],
      ],
    );
  }
}

class _ShapePreview extends StatelessWidget {
  const _ShapePreview({
    required this.shape,
    required this.selected,
    required this.onTap,
  });

  final HomeIconShape shape;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Semantics(
        button: true,
        selected: selected,
        label: shape.label,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 48,
              height: 48,
              padding: const EdgeInsets.all(2.5),
              decoration: ShapeDecoration(
                color: selected ? scheme.primary : Colors.transparent,
                shape: homeIconBorder(shape, 48),
              ),
              child: Container(
                decoration: ShapeDecoration(
                  color: scheme.primaryContainer,
                  shape: homeIconBorder(shape, 43),
                ),
                child: Icon(Icons.star_outline, color: scheme.onPrimaryContainer),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              shape.label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    fontWeight: selected ? FontWeight.w700 : null,
                    color: selected ? scheme.primary : null,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
