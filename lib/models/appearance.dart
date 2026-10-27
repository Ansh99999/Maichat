/// MaiChat's own brand seed — used when system colours are off or the platform
/// offers no Material You palette, and the starting point for a custom theme.
const int kDefaultSeedColor = 0xFF7C5CFF;

/// How the app should colour itself.
///
/// Light/dark and the palette both follow the phone by default: [mode] defers
/// to the system setting and [dynamicColor] asks for the Material You palette
/// the OS derives from the wallpaper. When system colours are off (or the OS
/// has no palette to offer) the theme is seeded from [seedColor], which the
/// user can set to any colour to build their own theme.
class Appearance {
  const Appearance({
    this.dynamicColor = true,
    this.mode = AppThemeMode.system,
    this.seedColor = kDefaultSeedColor,
    this.fontFamily,
    this.expressive = false,
    this.palette = AppPalette.tonal,
    this.mobileChatMenuStyle = MobileChatMenuStyle.slide,
  });

  /// Prefer the platform's Material You palette over the custom [seedColor].
  final bool dynamicColor;

  final AppThemeMode mode;

  /// ARGB value the custom theme is generated from. Applies whenever
  /// [dynamicColor] is off or no system palette is available.
  final int seedColor;

  /// A Google Fonts family applied app-wide to the text theme, or null to keep
  /// the platform default font.
  final String? fontFamily;

  /// Material 3 Expressive: bolder type, rounder and larger shapes, livelier
  /// surfaces and the newer component looks (wavy progress, iconed switches,
  /// springier page transitions) — in light and dark alike. Off keeps the
  /// calmer baseline Material 3 the app has always had.
  final bool expressive;

  /// How a palette is drawn out of the wallpaper or the seed colour.
  final AppPalette palette;

  /// How the chat menu occupies a phone while it is open. Tablets and desktops
  /// keep their side-pane layout whatever this says.
  final MobileChatMenuStyle mobileChatMenuStyle;

  Appearance copyWith({
    bool? dynamicColor,
    AppThemeMode? mode,
    int? seedColor,
    Object? fontFamily = _unset,
    bool? expressive,
    AppPalette? palette,
    MobileChatMenuStyle? mobileChatMenuStyle,
  }) => Appearance(
    dynamicColor: dynamicColor ?? this.dynamicColor,
    mode: mode ?? this.mode,
    seedColor: seedColor ?? this.seedColor,
    fontFamily: identical(fontFamily, _unset)
        ? this.fontFamily
        : fontFamily as String?,
    expressive: expressive ?? this.expressive,
    palette: palette ?? this.palette,
    mobileChatMenuStyle: mobileChatMenuStyle ?? this.mobileChatMenuStyle,
  );

  // Sentinel so copyWith can tell "leave the font" from "clear it to null".
  static const Object _unset = Object();

  Map<String, dynamic> toJson() => {
    'dynamicColor': dynamicColor,
    'mode': mode.name,
    'seedColor': seedColor,
    if (fontFamily != null) 'fontFamily': fontFamily,
    // Written only when changed, so a store from before these existed and
    // one that never touched them read — and compare — the same.
    if (expressive) 'expressive': true,
    if (palette != AppPalette.tonal) 'palette': palette.name,
    if (mobileChatMenuStyle != MobileChatMenuStyle.slide)
      'mobileChatMenuStyle': mobileChatMenuStyle.name,
  };

  factory Appearance.fromJson(Map<String, dynamic> json) => Appearance(
    dynamicColor: json['dynamicColor'] as bool? ?? true,
    mode: AppThemeMode.byName(json['mode'] as String?),
    seedColor: (json['seedColor'] as num?)?.toInt() ?? kDefaultSeedColor,
    fontFamily: (json['fontFamily'] as String?)?.trim().isEmpty ?? true
        ? null
        : (json['fontFamily'] as String).trim(),
    expressive: json['expressive'] as bool? ?? false,
    palette: AppPalette.byName(json['palette'] as String?),
    mobileChatMenuStyle: MobileChatMenuStyle.byName(
      json['mobileChatMenuStyle'] as String?,
    ),
  );

  @override
  bool operator ==(Object other) =>
      other is Appearance &&
      other.dynamicColor == dynamicColor &&
      other.mode == mode &&
      other.seedColor == seedColor &&
      other.fontFamily == fontFamily &&
      other.expressive == expressive &&
      other.palette == palette &&
      other.mobileChatMenuStyle == mobileChatMenuStyle;

  @override
  int get hashCode => Object.hash(
    dynamicColor,
    mode,
    seedColor,
    fontFamily,
    expressive,
    palette,
    mobileChatMenuStyle,
  );
}

/// How the chat menu opens on a phone. [slide] pushes the chat aside; [overlay]
/// draws the menu over the chat without moving it. Wide layouts always use the
/// side-pane behaviour and ignore this preference.
enum MobileChatMenuStyle {
  slide('Slide chat'),
  overlay('Overlay chat');

  const MobileChatMenuStyle(this.label);

  final String label;

  /// Unknown or missing names keep the new layout as the default.
  static MobileChatMenuStyle byName(String? name) {
    for (final style in values) {
      if (style.name == name) return style;
    }
    return MobileChatMenuStyle.slide;
  }
}

/// Mirrors Flutter's ThemeMode without dragging the framework into the model
/// layer; [MaiChatApp] maps it across. [amoled] is a dark variant that paints
/// surfaces true black to save power on OLED panels.
enum AppThemeMode {
  system('System'),
  light('Light'),
  dark('Dark'),
  amoled('AMOLED');

  const AppThemeMode(this.label);

  final String label;

  /// Whether this mode resolves to a dark theme without consulting the system.
  bool get isDark => this == AppThemeMode.dark || this == AppThemeMode.amoled;

  /// Unknown or missing names fall back to following the system.
  static AppThemeMode byName(String? name) {
    for (final mode in values) {
      if (mode.name == name) return mode;
    }
    return AppThemeMode.system;
  }
}

/// The ways a palette can be generated from one colour, after Material's own
/// scheme variants. [MaiChatApp] maps each to a `DynamicSchemeVariant`.
enum AppPalette {
  /// Material's default: calm, the colour softened into tones.
  tonal('Tonal', 'Calm and soft — Material\'s default'),

  /// The colour at full strength, in light and dark alike.
  vibrant('Vibrant', 'The colour at full strength'),

  /// Neighbouring hues mixed in for a playful, Expressive feel.
  expressive('Playful', 'Neighbouring hues mixed in'),

  /// Stays faithful to the exact colour picked.
  fidelity('Faithful', 'Keeps the exact colour'),

  /// Greys only, the colour kept for a few accents.
  neutral('Muted', 'Nearly grey, quiet accents');

  const AppPalette(this.label, this.blurb);

  final String label;
  final String blurb;

  static AppPalette byName(String? name) {
    for (final p in values) {
      if (p.name == name) return p;
    }
    return AppPalette.tonal;
  }
}
