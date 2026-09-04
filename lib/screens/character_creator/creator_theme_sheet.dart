import 'package:flutter/material.dart';

import '../../models/character_theme.dart';
import '../../widgets/character_theme_scope.dart';
import '../../widgets/color_picker.dart';
import 'creator_draft.dart';

/// Picks a character's own theme: a colour, and how loudly to wear it.
///
/// The preview is the point. A seed colour tells you almost nothing about the
/// palette Material will derive from it, and the difference between the four
/// strengths is exactly the difference this feature exists for — so the sheet
/// draws a real card in the real scheme, and changing either control redraws it.
Future<void> showCharacterThemeSheet(
  BuildContext context, {
  required CreatorDraft draft,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => CharacterThemeSheet(draft: draft),
    );

/// The body of [showCharacterThemeSheet], exposed for tests.
class CharacterThemeSheet extends StatefulWidget {
  const CharacterThemeSheet({super.key, required this.draft});

  final CreatorDraft draft;

  @override
  State<CharacterThemeSheet> createState() => _CharacterThemeSheetState();
}

class _CharacterThemeSheetState extends State<CharacterThemeSheet> {
  late CharacterTheme _theme = widget.draft.theme;

  void _set(CharacterTheme next) {
    setState(() => _theme = next);
    widget.draft.setTheme(next);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final seed = _theme.seedColor ?? scheme.primary.toARGB32();

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text("This character's theme",
                      style: theme.textTheme.titleMedium),
                ),
                if (_theme.isSet)
                  TextButton(
                    key: const Key('character-theme-clear'),
                    onPressed: () => _set(const CharacterTheme()),
                    child: const Text('Use the app\'s'),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              'A theme of their own, painted stronger than the app\'s: their '
              'sheet and their creator wear it. Material still works out the '
              'palette, so light, dark and AMOLED all keep behaving.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            _Preview(theme: _theme),
            const SizedBox(height: 18),
            Text('Colour', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final swatch in kThemeSwatches)
                  _Swatch(
                    color: swatch,
                    selected: _theme.seedColor == swatch.toARGB32(),
                    onTap: () => _set(_theme.copyWith(
                      seedColor: swatch.toARGB32(),
                    )),
                  ),
                _CustomSwatch(
                  color: Color(seed),
                  onTap: () async {
                    final picked =
                        await showCustomColorDialog(context, Color(seed));
                    if (picked == null) return;
                    _set(_theme.copyWith(seedColor: picked.toARGB32()));
                  },
                ),
              ],
            ),
            const SizedBox(height: 18),
            Text('Strength', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<CharacterThemeStrength>(
                showSelectedIcon: false,
                segments: [
                  for (final strength in CharacterThemeStrength.values)
                    ButtonSegment<CharacterThemeStrength>(
                      value: strength,
                      label: Text(strength.label),
                    ),
                ],
                selected: {_theme.strength},
                // Choosing a strength before a colour would change nothing
                // visible, so it also turns the theme on with the app's own
                // primary as the seed.
                onSelectionChanged: (picked) => _set(
                  _theme.copyWith(
                    strength: picked.first,
                    seedColor: _theme.seedColor ?? seed,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _explain(_theme.strength),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  static String _explain(CharacterThemeStrength strength) => switch (strength) {
        CharacterThemeStrength.calm =>
          'The ordinary Material palette — quiet, mostly neutral surfaces.',
        CharacterThemeStrength.vivid =>
          'Stronger colour throughout, on every surface as well as the accents.',
        CharacterThemeStrength.expressive =>
          'The loudest: shifted hues and high chroma, for a card that should '
              'announce itself.',
        CharacterThemeStrength.faithful =>
          'Keeps the colour you picked as it is, instead of deriving a hue from '
              'it.',
      };
}

/// A card drawn in the theme being chosen — the same widgets the creator itself
/// is built from, so the preview is the thing rather than a picture of it.
class _Preview extends StatelessWidget {
  const _Preview({required this.theme});

  final CharacterTheme theme;

  @override
  Widget build(BuildContext context) {
    return CharacterThemeScope(
      theme: theme,
      child: Builder(
        builder: (context) {
          final scheme = Theme.of(context).colorScheme;
          return Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: scheme.primaryContainer,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(Icons.person,
                          color: scheme.onPrimaryContainer),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Their name',
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(color: scheme.onSurface),
                          ),
                          Text(
                            'and the line under it',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    CharacterThemeSwatch(theme: theme),
                  ],
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton(onPressed: () {}, child: const Text('Chat')),
                    FilledButton.tonal(
                        onPressed: () {}, child: const Text('Edit')),
                    Chip(
                      label: const Text('tag'),
                      backgroundColor: scheme.secondaryContainer,
                      side: BorderSide.none,
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      customBorder: const CircleBorder(),
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? scheme.onSurface : scheme.outlineVariant,
            width: selected ? 3 : 1,
          ),
        ),
        child: selected
            ? const Icon(Icons.check, size: 18, color: Colors.white)
            : null,
      ),
    );
  }
}

class _CustomSwatch extends StatelessWidget {
  const _CustomSwatch({required this.color, required this.onTap});

  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      key: const Key('character-theme-custom'),
      customBorder: const CircleBorder(),
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: const Icon(Icons.colorize, size: 18, color: Colors.white),
      ),
    );
  }
}
