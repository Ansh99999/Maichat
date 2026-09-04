import 'dart:collection';

import 'package:flutter/material.dart';

import '../models/character.dart';
import '../models/character_theme.dart';

/// A character's theme, as Material 3 sees it.
///
/// The whole feature is one framework call — [ColorScheme.fromSeed] with a
/// *scheme variant* other than the default — and one decision: which variant a
/// user's "stronger" means. Material's `tonalSpot` (the app-wide default) pulls
/// chroma out of a seed on purpose so an interface stays quiet; `vibrant` and
/// `expressive` keep it, and `fidelity` keeps the seed itself. So a character
/// theme is still an ordinary, contrast-checked M3 scheme with real
/// on-colours — it is not a hand-mixed palette, and light/dark/AMOLED keep
/// working — it simply stops apologising for the colour it was given.
DynamicSchemeVariant _variantFor(CharacterThemeStrength strength) =>
    switch (strength) {
      CharacterThemeStrength.calm => DynamicSchemeVariant.tonalSpot,
      CharacterThemeStrength.vivid => DynamicSchemeVariant.vibrant,
      CharacterThemeStrength.expressive => DynamicSchemeVariant.expressive,
      CharacterThemeStrength.faithful => DynamicSchemeVariant.fidelity,
    };

/// Schemes already generated, keyed by seed + strength + brightness.
///
/// Deriving a scheme is a full HCT pass over thirty-odd tones. That is nothing
/// once, and it is not nothing on a roster of two hundred cards being scrolled —
/// so the answer is remembered. Bounded, because a large library could otherwise
/// pin one entry per character for the life of the process.
final LinkedHashMap<String, ColorScheme> _schemes =
    LinkedHashMap<String, ColorScheme>();

const int _maxSchemes = 96;

/// The [ColorScheme] [theme] resolves to at [brightness], or null when the
/// character has no theme of its own (the caller should keep the app's).
ColorScheme? characterScheme(CharacterTheme theme, Brightness brightness) {
  final seed = theme.seedColor;
  if (seed == null) return null;
  final key = '$seed/${theme.strength.name}/${brightness.name}';
  final cached = _schemes.remove(key);
  if (cached != null) {
    _schemes[key] = cached; // most recently used last
    return cached;
  }
  final scheme = ColorScheme.fromSeed(
    seedColor: Color(seed),
    brightness: brightness,
    dynamicSchemeVariant: _variantFor(theme.strength),
  );
  _schemes[key] = scheme;
  while (_schemes.length > _maxSchemes) {
    _schemes.remove(_schemes.keys.first);
  }
  return scheme;
}

/// Drops the memoised schemes — for tests that want a cold derivation.
void clearCharacterSchemeCache() => _schemes.clear();

/// [base] rebuilt around [theme]'s palette, or [base] unchanged when the
/// character has none.
///
/// Only the colours move. The font, the shapes, the input decoration and every
/// other decision the app has already made are inherited, so a themed page is
/// recognisably the same app in different colours rather than a different app.
ThemeData characterThemeData(ThemeData base, CharacterTheme theme) {
  final scheme = characterScheme(theme, base.brightness);
  if (scheme == null) return base;
  return base.copyWith(
    colorScheme: scheme,
    // An AMOLED install paints its surfaces true black; a character theme must
    // not quietly undo that, so the scaffold colour is only replaced when the
    // app was not overriding it in the first place.
    scaffoldBackgroundColor:
        base.scaffoldBackgroundColor == const Color(0xFF000000)
            ? base.scaffoldBackgroundColor
            : scheme.surface,
    appBarTheme: base.appBarTheme.copyWith(
      backgroundColor: scheme.surface,
      surfaceTintColor: scheme.surfaceTint,
      foregroundColor: scheme.onSurface,
    ),
  );
}

/// Wraps [child] in [theme]'s colours. A no-op when the character has no theme,
/// so it is safe to put around anything unconditionally.
class CharacterThemeScope extends StatelessWidget {
  const CharacterThemeScope({
    super.key,
    required this.theme,
    required this.child,
  });

  /// Convenience for the common case: a character's own theme, or none when the
  /// character is not there yet.
  CharacterThemeScope.of({
    super.key,
    required Character? character,
    required this.child,
  }) : theme = character?.theme ?? CharacterTheme.none;

  final CharacterTheme theme;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!theme.isSet) return child;
    return Theme(
      data: characterThemeData(Theme.of(context), theme),
      child: child,
    );
  }
}

/// Three swatches that say what a theme will look like without applying it —
/// used by the theme sheet's preview and by the roster row that reports one.
class CharacterThemeSwatch extends StatelessWidget {
  const CharacterThemeSwatch({
    super.key,
    required this.theme,
    this.size = 22,
  });

  final CharacterTheme theme;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = characterScheme(theme, Theme.of(context).brightness) ??
        Theme.of(context).colorScheme;
    final colors = <Color>[
      scheme.primary,
      scheme.secondary,
      scheme.tertiary,
    ];
    return SizedBox(
      width: size * 2.1,
      height: size,
      child: Stack(
        children: [
          for (var i = 0; i < colors.length; i++)
            Positioned(
              left: i * size * 0.55,
              child: Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  color: colors[i],
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Theme.of(context).colorScheme.surface,
                    width: 1.5,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
