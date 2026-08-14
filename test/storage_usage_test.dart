import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/screens/settings/about_settings_page.dart';
import 'package:maichat/services/storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('usage reports the biggest entry first', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.activeConversation': 'c1',
      'flutter.characters': 'x' * 5000,
      'flutter.conversations': 'y' * 200,
    });
    final usage = await Storage().usage();
    expect(usage.keys.first, 'characters');
    expect(usage['characters'], 5000);
    expect(usage['conversations'], 200);
  });

  testWidgets('About shows what the store is using', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.characters': 'x' * (3 * 1024 * 1024),
    });
    await tester.pumpWidget(
      const MaterialApp(home: AboutSettingsPage()),
    );
    await tester.pumpAndSettle();
    expect(find.text('Using 3.0 MB'), findsOneWidget);
    expect(find.textContaining('characters · 3.0 MB'), findsOneWidget);
  });
}
