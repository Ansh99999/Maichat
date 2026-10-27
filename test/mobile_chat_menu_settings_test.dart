import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/appearance.dart';
import 'package:maichat/screens/settings/appearance_settings_page.dart';
import 'package:maichat/screens/settings/setting_anchors.dart';
import 'package:maichat/screens/settings/setting_highlight.dart';
import 'package:maichat/screens/settings_screen.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// Flutter's widget-test invariant requires debug platform overrides to be
  /// restored before a test body returns, so every override is scoped and saves
  /// the exact nullable value that was there before.
  Future<T> withPlatform<T>(
    TargetPlatform platform,
    Future<T> Function() body,
  ) async {
    final original = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = platform;
    try {
      return await body();
    } finally {
      debugDefaultTargetPlatformOverride = original;
    }
  }

  Future<AppState> makeState() async {
    final state = AppState();
    await state.init();
    addTearDown(state.dispose);
    return state;
  }

  Future<void> pumpSurface(
    WidgetTester tester, {
    required AppState state,
    Widget page = const AppearanceSettingsPage(),
    Size size = const Size(360, 800),
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child ?? const SizedBox.shrink(),
          ),
          home: page,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openSearchAndType(
    WidgetTester tester, {
    required AppState state,
    required Size size,
    required String query,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(home: const SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(SearchBar));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, query);
    await tester.pumpAndSettle();
  }

  test(
    'the chat menu style defaults to slide and unknown values fall back',
    () {
      const appearance = Appearance();
      expect(appearance.mobileChatMenuStyle, MobileChatMenuStyle.slide);
      expect(appearance.toJson().containsKey('mobileChatMenuStyle'), isFalse);
      expect(MobileChatMenuStyle.byName(null), MobileChatMenuStyle.slide);
      expect(MobileChatMenuStyle.byName('nonsense'), MobileChatMenuStyle.slide);
      expect(
        Appearance.fromJson(const <String, dynamic>{}).mobileChatMenuStyle,
        MobileChatMenuStyle.slide,
      );
      expect(
        Appearance.fromJson(
          jsonDecode('{"mobileChatMenuStyle":"nonsense"}')
              as Map<String, dynamic>,
        ).mobileChatMenuStyle,
        MobileChatMenuStyle.slide,
      );
    },
  );

  test('the chat menu style round-trips, copies, and compares', () {
    const original = Appearance(
      mobileChatMenuStyle: MobileChatMenuStyle.overlay,
    );
    final restored = Appearance.fromJson(
      original.toJson()..remove('seedColor'),
    );
    expect(restored, original);
    expect(restored.hashCode, original.hashCode);
    expect(original.toJson()['mobileChatMenuStyle'], 'overlay');
    expect(
      original.copyWith(mobileChatMenuStyle: MobileChatMenuStyle.slide),
      const Appearance(),
    );

    const custom = Appearance(
      fontFamily: 'Inter',
      expressive: true,
      palette: AppPalette.vibrant,
      mobileChatMenuStyle: MobileChatMenuStyle.overlay,
    );
    final customRestored = Appearance.fromJson(custom.toJson());
    expect(customRestored, custom);
    expect(
      customRestored.copyWith(mobileChatMenuStyle: MobileChatMenuStyle.slide),
      const Appearance(
        fontFamily: 'Inter',
        expressive: true,
        palette: AppPalette.vibrant,
      ),
    );
  });

  test('the selector survives a real AppState restart', () async {
    final state = AppState();
    await state.init();
    addTearDown(state.dispose);
    await state.updateAppearance(
      state.appearance.copyWith(
        mobileChatMenuStyle: MobileChatMenuStyle.overlay,
      ),
    );

    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString('appearance');
    expect(stored, isNotNull);
    final decoded = jsonDecode(stored!) as Map<String, dynamic>;
    expect(decoded['mobileChatMenuStyle'], 'overlay');

    final reopened = AppState();
    await reopened.init();
    addTearDown(reopened.dispose);
    expect(
      reopened.appearance.mobileChatMenuStyle,
      MobileChatMenuStyle.overlay,
    );
    expect(reopened.appearance, state.appearance);
  });

  for (final platform in const [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('phone users can choose the menu style ($platform)', (
      tester,
    ) async {
      await withPlatform(platform, () async {
        final state = await makeState();
        await pumpSurface(tester, state: state);

        expect(find.text('Chat menu style'), findsOneWidget);
        expect(find.text('Slide chat'), findsOneWidget);
        final dropdown = find.byType(DropdownButton<MobileChatMenuStyle>);
        expect(
          tester.widget<DropdownButton<MobileChatMenuStyle>>(dropdown).value,
          MobileChatMenuStyle.slide,
        );

        await tester.tap(find.text('Slide chat'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Overlay chat').last);
        await tester.pumpAndSettle();
        expect(
          state.appearance.mobileChatMenuStyle,
          MobileChatMenuStyle.overlay,
        );
        expect(find.text('Overlay chat'), findsOneWidget);
        expect(
          tester.widget<DropdownButton<MobileChatMenuStyle>>(dropdown).value,
          MobileChatMenuStyle.overlay,
        );
      });
    });
  }

  for (final platform in const [TargetPlatform.linux, TargetPlatform.windows]) {
    testWidgets(
      'desktop users do not see the mobile-only control ($platform)',
      (tester) async {
        await withPlatform(platform, () async {
          final state = await makeState();
          await pumpSurface(tester, state: state);

          expect(find.text('Chat menu style'), findsNothing);
          expect(find.text('Slide chat'), findsNothing);
          expect(find.text('Overlay chat'), findsNothing);
        });
      },
    );
  }

  testWidgets('tablet-width mobile users do not see the phone-only control', (
    tester,
  ) async {
    await withPlatform(TargetPlatform.android, () async {
      final state = await makeState();
      await pumpSurface(tester, state: state, size: const Size(720, 1200));

      expect(find.text('Chat menu style'), findsNothing);
    });
  });

  for (final width in const [320, 360]) {
    for (final scale in const [1.0, 1.5, 2.0]) {
      testWidgets('the row stays compact at $width width and ${scale}x text', (
        tester,
      ) async {
        await withPlatform(TargetPlatform.android, () async {
          final state = await makeState();
          await pumpSurface(
            tester,
            state: state,
            size: Size(width.toDouble(), 800),
            textScale: scale,
          );

          final label = find.text('Chat menu style');
          expect(label, findsOneWidget);
          expect(
            MediaQuery.textScalerOf(tester.element(label)).scale(14),
            closeTo(14 * scale, 0.01),
          );
          final row = find.ancestor(of: label, matching: find.byType(Wrap));
          expect(row, findsOneWidget);
          expect(tester.getSize(row).width, lessThanOrEqualTo(width));
        });
      });
    }
  }

  testWidgets('the row deep-links and search opens the Appearance page', (
    tester,
  ) async {
    await withPlatform(TargetPlatform.android, () async {
      final state = await makeState();
      await openSearchAndType(
        tester,
        state: state,
        size: const Size(360, 800),
        query: 'menu drawer',
      );
      expect(find.text('Chat menu style'), findsOneWidget);

      await tester.tap(find.text('Chat menu style'));
      await tester.pumpAndSettle();

      expect(find.byType(AppearanceSettingsPage), findsOneWidget);
      final row = find.text('Chat menu style');
      final wrapper = find.ancestor(
        of: row,
        matching: find.byType(SettingHighlight),
      );
      expect(wrapper, findsOneWidget);
      expect(tester.widget<SettingHighlight>(wrapper).active, isTrue);
      await tester.pump(const Duration(milliseconds: 1200));
    });
  });

  for (final platform in const [TargetPlatform.linux, TargetPlatform.windows]) {
    for (final query in const ['menu drawer', 'slide chat', 'overlay chat']) {
      testWidgets(
        'desktop search omits the phone setting for "$query" ($platform)',
        (tester) async {
          await withPlatform(platform, () async {
            final state = await makeState();
            await openSearchAndType(
              tester,
              state: state,
              size: const Size(360, 800),
              query: query,
            );

            expect(find.text('Chat menu style'), findsNothing);
            expect(find.text('No settings match that'), findsOneWidget);
          });
        },
      );
    }
  }

  testWidgets('tablet-width mobile search omits the phone setting', (
    tester,
  ) async {
    await withPlatform(TargetPlatform.android, () async {
      final state = await makeState();
      await openSearchAndType(
        tester,
        state: state,
        size: const Size(720, 1200),
        query: 'menu drawer',
      );

      expect(find.text('Chat menu style'), findsNothing);
      expect(find.text('No settings match that'), findsOneWidget);
    });
  });

  for (final platform in const [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('phone search finds the setting ($platform)', (tester) async {
      await withPlatform(platform, () async {
        final state = await makeState();
        await openSearchAndType(
          tester,
          state: state,
          size: const Size(360, 800),
          query: 'menu drawer',
        );

        expect(find.text('Chat menu style'), findsOneWidget);
      });
    });
  }

  testWidgets('the persisted overlay choice remains visible and selected', (
    tester,
  ) async {
    await withPlatform(TargetPlatform.android, () async {
      final state = await makeState();
      await state.updateAppearance(
        state.appearance.copyWith(
          mobileChatMenuStyle: MobileChatMenuStyle.overlay,
        ),
      );
      await pumpSurface(
        tester,
        state: state,
        page: const AppearanceSettingsPage(
          highlight: SettingAnchor.chatMenuStyle,
        ),
      );

      final dropdown = find.byType(DropdownButton<MobileChatMenuStyle>);
      expect(find.text('Chat menu style'), findsOneWidget);
      expect(find.text('Overlay chat'), findsOneWidget);
      expect(
        tester.widget<DropdownButton<MobileChatMenuStyle>>(dropdown).value,
        MobileChatMenuStyle.overlay,
      );
      await tester.pump(const Duration(milliseconds: 1200));
    });
  });
}
