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
  });

  /// Prefer the platform's Material You palette over the custom [seedColor].
  final bool dynamicColor;

  final AppThemeMode mode;

  /// ARGB value the custom theme is generated from. Applies whenever
  /// [dynamicColor] is off or no system palette is available.
  final int seedColor;

  Appearance copyWith({bool? dynamicColor, AppThemeMode? mode, int? seedColor}) =>
      Appearance(
        dynamicColor: dynamicColor ?? this.dynamicColor,
        mode: mode ?? this.mode,
        seedColor: seedColor ?? this.seedColor,
      );

  Map<String, dynamic> toJson() => {
        'dynamicColor': dynamicColor,
        'mode': mode.name,
        'seedColor': seedColor,
      };

  factory Appearance.fromJson(Map<String, dynamic> json) => Appearance(
        dynamicColor: json['dynamicColor'] as bool? ?? true,
        mode: AppThemeMode.byName(json['mode'] as String?),
        seedColor: (json['seedColor'] as num?)?.toInt() ?? kDefaultSeedColor,
      );

  @override
  bool operator ==(Object other) =>
      other is Appearance &&
      other.dynamicColor == dynamicColor &&
      other.mode == mode &&
      other.seedColor == seedColor;

  @override
  int get hashCode => Object.hash(dynamicColor, mode, seedColor);
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
