/// How the app should colour itself.
///
/// Light/dark and the palette both follow the phone by default: [mode] defers
/// to the system setting and [dynamicColor] asks for the Material You palette
/// the OS derives from the wallpaper. Neither is available everywhere, so the
/// theme layer falls back to MaiChat's own seed colour.
class Appearance {
  const Appearance({
    this.dynamicColor = true,
    this.mode = AppThemeMode.system,
  });

  /// Prefer the platform's Material You palette over MaiChat's seed colour.
  final bool dynamicColor;

  final AppThemeMode mode;

  Appearance copyWith({bool? dynamicColor, AppThemeMode? mode}) => Appearance(
        dynamicColor: dynamicColor ?? this.dynamicColor,
        mode: mode ?? this.mode,
      );

  Map<String, dynamic> toJson() => {
        'dynamicColor': dynamicColor,
        'mode': mode.name,
      };

  factory Appearance.fromJson(Map<String, dynamic> json) => Appearance(
        dynamicColor: json['dynamicColor'] as bool? ?? true,
        mode: AppThemeMode.byName(json['mode'] as String?),
      );

  @override
  bool operator ==(Object other) =>
      other is Appearance &&
      other.dynamicColor == dynamicColor &&
      other.mode == mode;

  @override
  int get hashCode => Object.hash(dynamicColor, mode);
}

/// Mirrors Flutter's ThemeMode without dragging the framework into the model
/// layer; [MaiChatApp] maps it across.
enum AppThemeMode {
  system('System'),
  light('Light'),
  dark('Dark');

  const AppThemeMode(this.label);

  final String label;

  /// Unknown or missing names fall back to following the system.
  static AppThemeMode byName(String? name) {
    for (final mode in values) {
      if (mode.name == name) return mode;
    }
    return AppThemeMode.system;
  }
}
