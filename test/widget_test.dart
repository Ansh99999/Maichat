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

    expect(find.text('MaiChat'), findsOneWidget);
    expect(find.text('Open settings'), findsOneWidget);
    // Nothing typed yet, so the send button stays disabled.
    final send = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.arrow_upward),
        matching: find.byType(IconButton),
      ),
    );
    expect(send.onPressed, isNull);
  });

  testWidgets('settings screen exposes URL, key and model fields',
      (tester) async {
    await tester.pumpWidget(const MaiChatApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();

    // The hub lists sections; the endpoint fields live inside "Provider".
    await tester.tap(find.text('Provider'));
    await tester.pumpAndSettle();

    expect(find.text('Base URL'), findsOneWidget);
    expect(find.text('API key'), findsOneWidget);
    expect(find.text('Model'), findsOneWidget);
    // Appears twice: as the field's value and as its hint.
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

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Provider'));
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

  testWidgets('the drawer lists saved chats', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.conversations':
          '[{"id":"1","title":"Tides","updatedAt":"2026-01-01T00:00:00.000",'
              '"messages":[{"role":"user","content":"hi"}]}]',
    });
    await tester.pumpWidget(const MaiChatApp());
    await tester.pumpAndSettle();

    tester.state<ScaffoldState>(find.byType(Scaffold)).openDrawer();
    await tester.pumpAndSettle();

    expect(find.text('Chats'), findsOneWidget);
    // The restored thread is both the app bar title and a drawer entry.
    expect(
      find.descendant(of: find.byType(Drawer), matching: find.text('Tides')),
      findsOneWidget,
    );
    expect(find.text('hi'), findsWidgets);
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

  testWidgets('the appearance controls persist what the user picks',
      (tester) async {
    await tester.pumpWidget(const MaiChatApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();

    // Appearance controls live inside their own section now.
    await tester.tap(find.text('Appearance'));
    await tester.pumpAndSettle();

    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    await tester.tap(find.text('Use system colours'));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);

    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.light,
    );

    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString('appearance'),
      '{"dynamicColor":false,"mode":"light"}',
    );
  });
}
