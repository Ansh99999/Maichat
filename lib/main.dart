// MaiChat — a mobile-first, UI-driven AI chat frontend.
// Copyright (C) 2026 Ansh Raj.
//
// This program is free software: you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free Software
// Foundation, either version 3 of the License, or (at your option) any later
// version. It is distributed WITHOUT ANY WARRANTY; see the GNU General Public
// License for more details. A copy ships with the source, in LICENSE.

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'app_info.dart';
import 'models/appearance.dart';
import 'screens/home_screen.dart';
import 'services/avatar_store.dart';
import 'services/backup_store.dart';
import 'services/embedding_store.dart';
import 'services/image_cache_tuning.dart';
import 'services/studio/studio_store.dart';
import 'state/app_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final imageBudget = imageCacheBudget();
  final decodedImages = PaintingBinding.instance.imageCache;
  decodedImages.maximumSize = imageBudget.maximumSize;
  decodedImages.maximumSizeBytes = imageBudget.maximumSizeBytes;
  // Draw behind the status and navigation bars so the system chrome takes on
  // the app's colours instead of sitting in an opaque strip.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  // Resolved here, once, before anything can be drawn: character pictures are
  // files, and the widget that draws one looks the directory up synchronously.
  // Embedding vectors are files too (never in prefs — see EmbeddingStore); the
  // backups folder lets a scheduled export write without a save dialog; and
  // Studio sessions are files the startup picture sweep has to read. Each is a
  // platform-channel round trip, so they are asked for together rather than
  // one after another in front of the first frame.
  final (avatars, embeddings, backups, studio) = await (
    AvatarStore.open(),
    EmbeddingStore.open(),
    BackupStore.open(),
    StudioStore.open(),
  ).wait;
  runApp(MaiChatApp(
    avatars: avatars,
    embeddings: embeddings,
    backups: backups,
    studio: studio,
    backgroundWarmUp: true,
  ));
}

class MaiChatApp extends StatelessWidget {
  const MaiChatApp({
    super.key,
    this.avatars,
    this.embeddings,
    this.backups,
    this.studio,
    this.backgroundWarmUp = false,
  });

  /// The pictures directory, or null when the platform would not name one.
  final AvatarStore? avatars;

  /// The vectors directory, or null when the platform would not name one.
  final EmbeddingStore? embeddings;

  /// The backups directory, or null when the platform would not name one.
  final BackupStore? backups;

  /// The Studio's sessions directory, or null when the platform would not name
  /// one.
  final StudioStore? studio;

  /// Keep launch work off the first frames (see [AppState.backgroundWarmUp]).
  /// Only the real launch in [main] turns it on; a widget test pumping the app
  /// cannot wait on a background isolate.
  final bool backgroundWarmUp;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<AppState>(
      create: (_) => AppState(
        avatars: avatars,
        embeddings: embeddings,
        backups: backups,
        studio: studio,
        backgroundWarmUp: backgroundWarmUp,
      )..init(),
      // Outside the builder so a late palette does not rebuild app state.
      child: DynamicColorBuilder(
        builder: (ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
          return Consumer<AppState>(
            builder: (context, state, _) {
              final appearance = state.appearance;
              final themes = _themes.resolve(
                appearance,
                lightDynamic: lightDynamic,
                darkDynamic: darkDynamic,
              );
              return MaterialApp(
                title: kAppDisplayName,
                debugShowCheckedModeBanner: false,
                showPerformanceOverlay: state.perfOverlay,
                themeMode: _themeMode(appearance.mode),
                theme: themes.light,
                darkTheme: themes.dark,
                home: const HomeScreen(),
              );
            },
          );
        },
      ),
    );
  }

  /// The two themes for the current appearance, built once per change.
  ///
  /// `MaterialApp` sits under a `Consumer<AppState>`, so it rebuilds on every
  /// notify — a streamed reply notifies dozens of times a second. Building two
  /// whole `ThemeData`s (and, with a font chosen, two Google Fonts text themes)
  /// each time was pure waste, and fresh `ThemeData` objects make the theme
  /// look changed to everything below even when nothing is.
  static final _ThemeCache _themes = _ThemeCache();

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
  ///
  /// [palette] picks how the scheme is drawn from its colour. With a dynamic
  /// scheme other than [AppPalette.tonal] the wallpaper's primary is used as a
  /// seed for that variant, since the OS only hands over its tonal-spot scheme.
  ///
  /// [expressive] turns on Material 3 Expressive: the app's shapes grow rounder
  /// and larger, headings heavier, and components take their 2024+ looks.
  ///
  /// Public because the screenshot generator (`test/screenshots/`) dresses the
  /// screens it photographs in the app's real theme rather than a lookalike.
  static ThemeData themeFor(
    ColorScheme? dynamicScheme,
    Brightness brightness,
    Color seed, {
    bool amoled = false,
    String? fontFamily,
    bool expressive = false,
    AppPalette palette = AppPalette.tonal,
  }) {
    final variant = _variantFor(palette, expressive);
    var scheme = dynamicScheme != null && variant == DynamicSchemeVariant.tonalSpot
        ? dynamicScheme.harmonized()
        : ColorScheme.fromSeed(
            seedColor: dynamicScheme?.primary ?? seed,
            brightness: brightness,
            dynamicSchemeVariant: variant,
          );
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
    final themed = expressive ? _expressive(base, scheme) : base;
    return _withFont(themed, fontFamily);
  }

  /// Expressive asks for the playful variant unless the user picked one.
  static DynamicSchemeVariant _variantFor(AppPalette palette, bool expressive) =>
      switch (palette) {
        AppPalette.tonal => expressive
            ? DynamicSchemeVariant.expressive
            : DynamicSchemeVariant.tonalSpot,
        AppPalette.vibrant => DynamicSchemeVariant.vibrant,
        AppPalette.expressive => DynamicSchemeVariant.expressive,
        AppPalette.fidelity => DynamicSchemeVariant.fidelity,
        AppPalette.neutral => DynamicSchemeVariant.neutral,
      };

  /// The Material 3 Expressive layer over [base].
  ///
  /// Expressive is a shape-and-emphasis system rather than new widgets: larger
  /// corner radii stepped by component size (chips 12, fields 16, cards 24,
  /// sheets and dialogs 28, the FAB a 20 px squircle), heavier emphasised
  /// headings, the 2024 progress indicators and slider, switches that carry an
  /// icon in their thumb, pill-shaped buttons with more padding, and springier,
  /// predictive-back page transitions on Android.
  static ThemeData _expressive(ThemeData base, ColorScheme scheme) {
    final text = base.textTheme;
    TextStyle? emphasise(TextStyle? s, FontWeight w) =>
        s?.copyWith(fontWeight: w, letterSpacing: s.letterSpacing);
    const pill = StadiumBorder();
    RoundedSuperellipseBorder squircle(double r) =>
        RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(r));
    return base.copyWith(
      textTheme: text.copyWith(
        displayLarge: emphasise(text.displayLarge, FontWeight.w600),
        displayMedium: emphasise(text.displayMedium, FontWeight.w600),
        displaySmall: emphasise(text.displaySmall, FontWeight.w600),
        headlineLarge: emphasise(text.headlineLarge, FontWeight.w700),
        headlineMedium: emphasise(text.headlineMedium, FontWeight.w700),
        headlineSmall: emphasise(text.headlineSmall, FontWeight.w700),
        titleLarge: emphasise(text.titleLarge, FontWeight.w700),
        titleMedium: emphasise(text.titleMedium, FontWeight.w600),
        labelLarge: emphasise(text.labelLarge, FontWeight.w600),
      ),
      appBarTheme: base.appBarTheme.copyWith(
        titleTextStyle: emphasise(text.titleLarge, FontWeight.w700)
            ?.copyWith(color: scheme.onSurface),
      ),
      cardTheme: CardThemeData(
        shape: squircle(24),
        clipBehavior: Clip.antiAlias,
      ),
      dialogTheme: DialogThemeData(shape: squircle(28)),
      bottomSheetTheme: const BottomSheetThemeData(
        showDragHandle: true,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
        ),
      ),
      drawerTheme: const DrawerThemeData(
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.horizontal(right: Radius.circular(28)),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        shape: squircle(20),
      ),
      chipTheme: base.chipTheme.copyWith(shape: squircle(12)),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: pill,
          // No textStyle: buttons read labelLarge, already emphasised above.
          // A style set here is lerped against the localized default when
          // the theme animates in, and the two disagree on `inherit`.
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: pill,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(shape: pill),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(shape: pill),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: squircle(16),
      ),
      listTileTheme: ListTileThemeData(shape: squircle(16)),
      popupMenuTheme: PopupMenuThemeData(shape: squircle(16)),
      menuTheme: MenuThemeData(
        style: MenuStyle(shape: WidgetStatePropertyAll(squircle(16))),
      ),
      searchBarTheme: const SearchBarThemeData(
        shape: WidgetStatePropertyAll(StadiumBorder()),
        elevation: WidgetStatePropertyAll(0),
      ),
      // ignore: deprecated_member_use
      progressIndicatorTheme: const ProgressIndicatorThemeData(year2023: false),
      // ignore: deprecated_member_use
      sliderTheme: const SliderThemeData(year2023: false),
      switchTheme: SwitchThemeData(
        thumbIcon: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? const Icon(Icons.check_rounded)
              : null,
        ),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
        },
      ),
    );
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

/// Holds the last pair of themes built and what they were built from.
class _ThemeCache {
  Appearance? _appearance;
  ColorScheme? _lightDynamic;
  ColorScheme? _darkDynamic;
  ({ThemeData light, ThemeData dark})? _themes;

  ({ThemeData light, ThemeData dark}) resolve(
    Appearance appearance, {
    ColorScheme? lightDynamic,
    ColorScheme? darkDynamic,
  }) {
    final cached = _themes;
    if (cached != null &&
        appearance == _appearance &&
        identical(lightDynamic, _lightDynamic) &&
        identical(darkDynamic, _darkDynamic)) {
      return cached;
    }
    final wanted = appearance.dynamicColor;
    final seed = Color(appearance.seedColor);
    final built = (
      light: MaiChatApp.themeFor(
        wanted ? lightDynamic : null,
        Brightness.light,
        seed,
        fontFamily: appearance.fontFamily,
        expressive: appearance.expressive,
        palette: appearance.palette,
      ),
      dark: MaiChatApp.themeFor(
        wanted ? darkDynamic : null,
        Brightness.dark,
        seed,
        amoled: appearance.mode == AppThemeMode.amoled,
        fontFamily: appearance.fontFamily,
        expressive: appearance.expressive,
        palette: appearance.palette,
      ),
    );
    _appearance = appearance;
    _lightDynamic = lightDynamic;
    _darkDynamic = darkDynamic;
    _themes = built;
    return built;
  }
}
