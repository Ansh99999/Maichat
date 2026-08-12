import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'models/appearance.dart';
import 'screens/home_screen.dart';
import 'state/app_state.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Draw behind the status and navigation bars so the system chrome takes on
  // the app's colours instead of sitting in an opaque strip.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  runApp(const MaiChatApp());
}

class MaiChatApp extends StatelessWidget {
  const MaiChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<AppState>(
      create: (_) => AppState()..init(),
      // Outside the builder so a late palette does not rebuild app state.
      child: DynamicColorBuilder(
        builder: (ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
          return Consumer<AppState>(
            builder: (context, state, _) {
              final appearance = state.appearance;
              final wanted = appearance.dynamicColor;
              final seed = Color(appearance.seedColor);
              final amoled = appearance.mode == AppThemeMode.amoled;
              return MaterialApp(
                title: 'MaiChat',
                debugShowCheckedModeBanner: false,
                themeMode: _themeMode(appearance.mode),
                theme: _theme(wanted ? lightDynamic : null, Brightness.light,
                    seed, fontFamily: appearance.fontFamily),
                darkTheme: _theme(
                  wanted ? darkDynamic : null,
                  Brightness.dark,
                  seed,
                  amoled: amoled,
                  fontFamily: appearance.fontFamily,
                ),
                home: const HomeScreen(),
              );
            },
          );
        },
      ),
    );
  }

  static ThemeMode _themeMode(AppThemeMode mode) => switch (mode) {
        AppThemeMode.system => ThemeMode.system,
        AppThemeMode.light => ThemeMode.light,
        AppThemeMode.dark => ThemeMode.dark,
        AppThemeMode.amoled => ThemeMode.dark,
      };

  /// [dynamicScheme] is the OS palette when there is one. It is harmonized so
  /// the error and container roles are nudged towards the wallpaper hue rather
  /// than clashing with it. [seed] is the user's chosen colour, used when there
  /// is no dynamic scheme. When [amoled] is set on a dark theme the surfaces are
  /// pushed to true black so OLED panels can switch those pixels off.
  static ThemeData _theme(
    ColorScheme? dynamicScheme,
    Brightness brightness,
    Color seed, {
    bool amoled = false,
    String? fontFamily,
  }) {
    var scheme = dynamicScheme?.harmonized() ??
        ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
    if (amoled && brightness == Brightness.dark) {
      scheme = scheme.copyWith(
        surface: const Color(0xFF000000),
        surfaceContainerLowest: const Color(0xFF000000),
        surfaceContainerLow: const Color(0xFF0A0A0A),
        surfaceContainer: const Color(0xFF101010),
        surfaceContainerHigh: const Color(0xFF161616),
        surfaceContainerHighest: const Color(0xFF1C1C1C),
      );
    }
    final base = ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: amoled && brightness == Brightness.dark
          ? const Color(0xFF000000)
          : null,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: scheme.surfaceTint,
        centerTitle: false,
        systemOverlayStyle: _overlayStyle(scheme.brightness),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
    );
    return _withFont(base, fontFamily);
  }

  /// Applies a Google Fonts [fontFamily] across the whole text theme, leaving
  /// the theme untouched when no font is chosen or the family is unknown (a bad
  /// name must never crash the app at startup).
  static ThemeData _withFont(ThemeData base, String? fontFamily) {
    if (fontFamily == null || fontFamily.trim().isEmpty) return base;
    try {
      final textTheme = GoogleFonts.getTextTheme(fontFamily, base.textTheme);
      return base.copyWith(
        textTheme: textTheme,
        primaryTextTheme:
            GoogleFonts.getTextTheme(fontFamily, base.primaryTextTheme),
      );
    } catch (_) {
      return base;
    }
  }

  /// Transparent bars with icons contrasting against the app's own surface.
  static SystemUiOverlayStyle _overlayStyle(Brightness brightness) {
    final isLight = brightness == Brightness.light;
    final icons = isLight ? Brightness.dark : Brightness.light;
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: icons,
      statusBarBrightness: brightness,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: icons,
      systemNavigationBarContrastEnforced: false,
    );
  }
}
