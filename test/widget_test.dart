import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('first run nudges the user to configure the endpoint',
      (tester) async {
    await tester.pumpWidget(const MaiChatApp());
    await tester.pumpAndSettle();

    // The Home dashboard is titled and prompts setup while unconfigured.
    // A large app bar renders its title in both the collapsed and expanded
    // slots, so more than one match is expected.
    expect(find.text('Home'), findsWidgets);
    expect(find.text('Open settings'), findsOneWidget);

    // Opening a fresh chat lands on the composer with a disabled send button.
    await tester.tap(find.text('New chat'));
    await tester.pumpAndSettle();
    final send = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.arrow_upward),
        matching: find.byType(IconButton),
      ),
    );
    expect(send.onPressed, isNull);
  });

  testWidgets('adding a provider exposes name, URL, key and model fields',
      (tester) async {
    await tester.pumpWidget(const MaiChatApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();

    // The hub lists sections; providers live behind "Providers".
    await tester.tap(find.text('Providers'));
    await tester.pumpAndSettle();

    // No providers yet, so add one to reach the editor fields.
    await tester.tap(find.text('Add provider'));
    await tester.pumpAndSettle();

    expect(find.text('Name'), findsOneWidget);
    expect(find.text('Base URL'), findsOneWidget);
    expect(find.text('API key'), findsOneWidget);
    expect(find.text('Model'), findsOneWidget);
    // The OpenAI default fills the URL field and its hint.
    expect(find.text('https://api.openai.com/v1'), findsWidgets);
  });

  testWidgets('the API key is masked until the reveal toggle is tapped',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.settings':
          '{"baseUrl":"https://host.tld/v1","apiKey":"sk-secret","model":"m"}',
    });
    await tester.pumpWidget(const MaiChatApp());
    await tester.pumpAndSettle();

    // The configured provider shows as a status card on Home; tapping it opens
    // settings, where the Providers page holds the editor.
    await tester.tap(find.text('host.tld'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Providers'));
    await tester.pumpAndSettle();

    // The legacy config migrated into one provider named after its host.
    await tester.tap(find.text('host.tld'));
    await tester.pumpAndSettle();

    TextField keyField() => tester.widget<TextField>(
          find.ancestor(
            of: find.byIcon(Icons.key_outlined),
            matching: find.byType(TextField),
          ),
        );
    expect(keyField().obscureText, isTrue);

    await tester.tap(find.byIcon(Icons.visibility_outlined));
    await tester.pumpAndSettle();
    expect(keyField().obscureText, isFalse);
  });

  testWidgets('the home screen lists saved chats', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.conversations':
          '[{"id":"1","title":"Tides","updatedAt":"2026-01-01T00:00:00.000",'
              '"messages":[{"role":"user","content":"hi"}]}]',
    });
    await tester.pumpWidget(const MaiChatApp());
    await tester.pumpAndSettle();

    // The restored thread shows up as a card under the recent-chats header.
    expect(find.text('Recent chats'), findsOneWidget);
    expect(find.text('Tides'), findsOneWidget);
    expect(find.text('hi'), findsOneWidget);
  });

  testWidgets('a stored dark preference is applied on launch', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.appearance': '{"dynamicColor":true,"mode":"dark"}',
    });
    await tester.pumpWidget(const MaiChatApp());
    await tester.pumpAndSettle();

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.dark);
    expect(
      Theme.of(tester.element(find.byType(Scaffold))).colorScheme.brightness,
      Brightness.dark,
    );
  });

  testWidgets('an AMOLED preference paints surfaces true black',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.appearance': '{"dynamicColor":false,"mode":"amoled"}',
    });
    await tester.pumpWidget(const MaiChatApp());
    await tester.pumpAndSettle();

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.dark);
    final scheme =
        Theme.of(tester.element(find.byType(Scaffold))).colorScheme;
    expect(scheme.brightness, Brightness.dark);
    expect(scheme.surface, const Color(0xFF000000));
  });

  testWidgets('the appearance controls persist what the user picks',
      (tester) async {
    await tester.pumpWidget(const MaiChatApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();

    // Appearance controls live inside their own section now.
    await tester.tap(find.text('Appearance'));
    await tester.pumpAndSettle();

    // The Appearance page now also has a "Show performance overlay" switch, so
    // target the system-colours one specifically rather than "the only switch".
    final systemColours = find.descendant(
      of: find.widgetWithText(SwitchListTile, 'Use system colours'),
      matching: find.byType(Switch),
    );
    expect(tester.widget<Switch>(systemColours).value, isTrue);
    await tester.tap(find.text('Use system colours'));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(systemColours).value, isFalse);

    // Theme mode is a compact dropdown; open it and choose Light.
    await tester.tap(find.text('System'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Light').last);
    await tester.pumpAndSettle();
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.light,
    );

    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString('appearance'),
      '{"dynamicColor":false,"mode":"light","seedColor":4286340351}',
    );
  });

  testWidgets('quick settings lists providers and switches the active one',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.providers': jsonEncode({
        'providers': [
          {
            'id': '1',
            'name': 'First',
            'kind': 'openai',
            'baseUrl': 'https://a/v1',
            'apiKey': '',
            'model': 'm1',
          },
          {
            'id': '2',
            'name': 'Second',
            'kind': 'anthropic',
            'baseUrl': 'https://b/v1',
            'apiKey': '',
            'model': 'm2',
          },
        ],
        'activeId': '1',
      }),
    });
    await tester.pumpWidget(const MaiChatApp());
    await tester.pumpAndSettle();

    // Home reflects the active provider.
    expect(find.text('First'), findsWidgets);

    // Open a chat, then the quick-settings sheet via the chat sidebar. The
    // provider entry sits toward the bottom of the scrollable sidebar.
    await tester.tap(find.text('New chat'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.dragUntilVisible(
      find.text('Provider & model'),
      find.descendant(
        of: find.byType(Drawer),
        matching: find.byType(Scrollable),
      ),
      const Offset(0, -80),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Provider & model'));
    await tester.pumpAndSettle();

    // Both providers are listed; the active one's model shows in the Model row.
    expect(find.text('Second'), findsOneWidget);
    expect(find.text('m1'), findsOneWidget);

    // Switching makes the other provider active and updates the model row.
    await tester.tap(find.text('Second'));
    await tester.pumpAndSettle();
    expect(find.text('m2'), findsWidgets);
  });

  testWidgets('the chat sidebar restarts a conversation', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.conversations':
          '[{"id":"1","title":"Tides","updatedAt":"2026-01-01T00:00:00.000",'
              '"messages":[{"role":"user","content":"hi"}]}]',
    });
    await tester.pumpWidget(const MaiChatApp());
    await tester.pumpAndSettle();

    // Open the saved chat from Home, then its sidebar.
    await tester.tap(find.text('Tides'));
    await tester.pumpAndSettle();
    expect(find.text('hi'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();

    // Restart lives in the footer and asks before clearing.
    await tester.tap(find.byIcon(Icons.restart_alt));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restart'));
    await tester.pumpAndSettle();

    // The message is gone and the composer is back to its empty state.
    expect(find.text('hi'), findsNothing);
  });
}
