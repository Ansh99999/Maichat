/// How loudly a character's own theme paints.
///
/// Material 3's default scheme (`tonalSpot`) deliberately desaturates a seed
/// into a calm, mostly-neutral palette — which is right for an app and wrong for
/// a character. A card whose art is all crimson and gold should feel like it,
/// and the M3 answer to that is a *scheme variant*: the same tonal machinery,
/// asked for stronger chroma. These are the four worth offering, in the order
/// they get louder, so "a stronger theme" is a choice a user makes rather than a
/// hand-mixed palette they have to balance themselves.
///
/// The names are the user's words; [variant] is the framework's. Kept as a plain
/// string mapping in [CharacterThemeScope] rather than here, so the model layer
/// stays free of Flutter (the same line [Appearance] draws around `ThemeMode`).
enum CharacterThemeStrength {
  /// The ordinary Material palette — a character who should not stand out.
  calm('Calm'),

  /// Stronger chroma throughout: the default, and what "stronger colours
  /// instead of the minimalist approach" means in practice.
  vivid('Vivid'),

  /// Material's expressive variant — shifted hues and high chroma, the loudest
  /// of the four.
  expressive('Expressive'),

  /// Keeps the chosen colour as it was picked rather than re-deriving a hue for
  /// it, for a theme taken straight off a character's artwork.
  faithful('Faithful');

  const CharacterThemeStrength(this.label);

  final String label;

  static CharacterThemeStrength byName(Object? name) {
    for (final s in values) {
      if (s.name == name) return s;
    }
    return CharacterThemeStrength.vivid;
  }
}

/// A character's own theme: one seed colour and how strongly to project it.
///
/// A theme is *optional* and absent by default — [seedColor] null means "wear
/// the app's colours", which is what every character imported before this
/// existed does. Nothing derives a theme implicitly: a card only looks different
/// once somebody chose a colour for it, so an upgrade cannot repaint a roster.
class CharacterTheme {
  const CharacterTheme({
    this.seedColor,
    this.strength = CharacterThemeStrength.vivid,
  });

  /// ARGB seed the character's palette is generated from, or null for none.
  final int? seedColor;

  final CharacterThemeStrength strength;

  /// Whether this character actually has a theme of its own.
  bool get isSet => seedColor != null;

  static const CharacterTheme none = CharacterTheme();

  CharacterTheme copyWith({
    Object? seedColor = _unset,
    CharacterThemeStrength? strength,
  }) =>
      CharacterTheme(
        seedColor: identical(seedColor, _unset)
            ? this.seedColor
            : seedColor as int?,
        strength: strength ?? this.strength,
      );

  /// Sentinel so [copyWith] can tell "leave the colour" from "clear it".
  static const Object _unset = Object();

  /// Written only when there is something to write, so a character without a
  /// theme costs no bytes in the store or in an export.
  Map<String, dynamic>? toJson() {
    if (!isSet) return null;
    return <String, dynamic>{
      'seedColor': seedColor,
      if (strength != CharacterThemeStrength.vivid) 'strength': strength.name,
    };
  }

  factory CharacterTheme.fromJson(Object? json) {
    if (json is! Map) return CharacterTheme.none;
    final seed = json['seedColor'];
    return CharacterTheme(
      seedColor: seed is num ? seed.toInt() : int.tryParse('$seed'),
      strength: CharacterThemeStrength.byName(json['strength']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CharacterTheme &&
      other.seedColor == seedColor &&
      other.strength == strength;

  @override
  int get hashCode => Object.hash(seedColor, strength);
}
