import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/view_prefs.dart';
import 'package:maichat/screens/settings/browse_appearance_settings_page.dart';
import 'package:maichat/screens/settings/setting_anchors.dart';
import 'package:maichat/screens/settings/setting_highlight.dart';
import 'package:maichat/screens/settings_screen.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Widget host(AppState state, Widget page) =>
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(home: page),
      );

  Future<void> pump(WidgetTester tester, AppState state, Widget page) async {
    tester.view.physicalSize = const Size(1000, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host(state, page));
    await tester.pumpAndSettle();
  }

  SwitchListTile switchFor(WidgetTester tester, String title) =>
      tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, title));

  testWidgets('offers three independent switches, all off by default', (
    tester,
  ) async {
    final state = AppState();
    await pump(tester, state, const BrowseAppearanceSettingsPage());

    for (final title in const ['Characters', 'Gallery', 'Discover']) {
      expect(switchFor(tester, title).value, isFalse);
    }

    await tester.tap(find.widgetWithText(SwitchListTile, 'Characters'));
    await tester.pumpAndSettle();
    expect(state.freeSizeCards(BrowseSection.characters), isTrue);
    expect(state.freeSizeCards(BrowseSection.gallery), isFalse);
    expect(state.freeSizeCards(BrowseSection.discover), isFalse);

    await tester.tap(find.widgetWithText(SwitchListTile, 'Gallery'));
    await tester.pumpAndSettle();
    expect(state.freeSizeCards(BrowseSection.characters), isTrue);
    expect(state.freeSizeCards(BrowseSection.gallery), isTrue);
    expect(state.freeSizeCards(BrowseSection.discover), isFalse);

    await tester.tap(find.widgetWithText(SwitchListTile, 'Discover'));
    await tester.pumpAndSettle();
    expect(state.freeSizeCards(BrowseSection.characters), isTrue);
    expect(state.freeSizeCards(BrowseSection.gallery), isTrue);
    expect(state.freeSizeCards(BrowseSection.discover), isTrue);

    await tester.tap(find.widgetWithText(SwitchListTile, 'Gallery'));
    await tester.pumpAndSettle();
    expect(state.freeSizeCards(BrowseSection.characters), isTrue);
    expect(state.freeSizeCards(BrowseSection.gallery), isFalse);
    expect(state.freeSizeCards(BrowseSection.discover), isTrue);
  });

  testWidgets('character artwork labels wait for character free-size mode', (
    tester,
  ) async {
    final state = AppState();
    await pump(tester, state, const BrowseAppearanceSettingsPage());

    final labels = find.widgetWithText(SwitchListTile, 'Labels over artwork');
    expect(labels, findsOneWidget);
    expect(switchFor(tester, 'Labels over artwork').value, isFalse);
    expect(switchFor(tester, 'Labels over artwork').onChanged, isNull);
    await tester.tap(labels);
    await tester.pumpAndSettle();
    expect(state.characterImageOverlay, isFalse);

    await tester.tap(find.widgetWithText(SwitchListTile, 'Characters'));
    await tester.pumpAndSettle();
    expect(switchFor(tester, 'Labels over artwork').onChanged, isNotNull);
    await tester.tap(labels);
    await tester.pumpAndSettle();
    expect(state.characterImageOverlay, isTrue);

    await tester.tap(find.widgetWithText(SwitchListTile, 'Characters'));
    await tester.pumpAndSettle();
    expect(state.characterImageOverlay, isTrue);
    expect(switchFor(tester, 'Labels over artwork').onChanged, isNull);
  });

  for (final entry in const [
    (SettingAnchor.charactersFreeSize, 'Characters'),
    (SettingAnchor.characterImageOverlay, 'Labels over artwork'),
    (SettingAnchor.galleryFreeSize, 'Gallery'),
    (SettingAnchor.discoverFreeSize, 'Discover'),
  ]) {
    testWidgets('${entry.$2} deep link highlights only its switch', (
      tester,
    ) async {
      final state = AppState();
      await pump(
        tester,
        state,
        BrowseAppearanceSettingsPage(highlight: entry.$1),
      );

      for (final title in const [
        'Characters',
        'Labels over artwork',
        'Gallery',
        'Discover',
      ]) {
        final row = find.widgetWithText(SwitchListTile, title);
        final wrapper = find.ancestor(
          of: row,
          matching: find.byType(SettingHighlight),
        );
        expect(wrapper, findsOneWidget);
        expect(
          tester.widget<SettingHighlight>(wrapper).active,
          title == entry.$2,
        );
      }
      await tester.pump(const Duration(milliseconds: 1200));
      await tester.pumpAndSettle();
    });
  }

  testWidgets('hub opens Browse appearance', (tester) async {
    final state = AppState();
    await pump(tester, state, const SettingsScreen());

    expect(find.text('Browse appearance'), findsOneWidget);
    await tester.tap(find.text('Browse appearance'));
    await tester.pumpAndSettle();

    expect(find.byType(BrowseAppearanceSettingsPage), findsOneWidget);
    expect(find.widgetWithText(SwitchListTile, 'Characters'), findsOneWidget);
  });

  for (final entry in const [
    ('character mosaic', 'Characters free-size cards', 'Characters'),
    (
      'character vignette',
      'Character labels over artwork',
      'Labels over artwork',
    ),
    ('gallery natural size', 'Gallery free-size cards', 'Gallery'),
    ('discover pinterest', 'Discover free-size cards', 'Discover'),
  ]) {
    testWidgets('search "${entry.$1}" deep-links to ${entry.$3}', (
      tester,
    ) async {
      final state = AppState();
      await pump(tester, state, const SettingsScreen());

      await tester.tap(find.byType(SearchBar));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, entry.$1);
      await tester.pumpAndSettle();
      expect(find.text(entry.$2), findsOneWidget);

      await tester.tap(find.text(entry.$2));
      await tester.pumpAndSettle();

      final row = find.widgetWithText(SwitchListTile, entry.$3);
      final wrapper = find.ancestor(
        of: row,
        matching: find.byType(SettingHighlight),
      );
      expect(tester.widget<SettingHighlight>(wrapper).active, isTrue);
      await tester.pump(const Duration(milliseconds: 1200));
      await tester.pumpAndSettle();
    });
  }
}
