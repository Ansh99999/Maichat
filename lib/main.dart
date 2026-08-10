import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  /// Used when the platform has no palette to offer, or when the user turns
  /// system colours off.
  static const Color _seed = Color(0xFF7C5CFF);

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
              return MaterialApp(
                title: 'MaiChat',
                debugShowCheckedModeBanner: false,
                themeMode: _themeMode(appearance.mode),
                theme: _theme(wanted ? lightDynamic : null, Brightness.light),
                darkTheme: _theme(wanted ? darkDynamic : null, Brightness.dark),
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
      };

  /// [dynamicScheme] is the OS palette when there is one. It is harmonized so
  /// the error and container roles are nudged towards the wallpaper hue rather
  /// than clashing with it.
  static ThemeData _theme(ColorScheme? dynamicScheme, Brightness brightness) {
    final scheme = dynamicScheme?.harmonized() ??
        ColorScheme.fromSeed(seedColor: _seed, brightness: brightness);
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
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
