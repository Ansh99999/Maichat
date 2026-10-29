// flutter test test/screenshots/btw_settings_preview.dart --update-goldens
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/main.dart';
import 'package:maichat/models/chat_interface.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/state/app_state.dart';
import 'package:maichat/widgets/btw_thread.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'shot.dart';

void main() {
  setUpAll(loadShotFonts);
  for (final view in [
    'btw-settings',
    'btw-settings-tools',
    'btw-thread-actions',
    'btw-settings-large-text',
    'btw-settings-landscape',
  ]) {
    testWidgets(view, (tester) async {
      usePhone(tester);
      addTearDown(() => debugDisableShadows = true);
      if (view == 'btw-settings-landscape') {
        tester.view
          ..physicalSize = const Size(2340, 1080)
          ..devicePixelRatio = 3;
      }
      SharedPreferences.setMockInitialValues({});
      final state = AppState();
      await tester.runAsync(state.init);
      await tester.runAsync(
        () => state.addProvider(
          Provider(
            id: 'writer',
            name: 'Writing provider',
            kind: ProviderKind.openai,
            baseUrl: 'https://preview.example',
            model: 'Story model',
            apiKey: 'preview',
          ),
        ),
      );
      final controller = BtwThreadController(
        ask: (_, _, _, _) async =>
            'Wren is Maren’s sister. She stayed at the old lighthouse while Maren met you at the harbour.\n\n'
            'The letter with the blue seal was the last you heard from her.',
      );
      controller.bind(state, state.active.id);
      for (final question in [
        'Where are we headed?',
        'What did the blue seal mean?',
        'Who is Wren again?',
      ]) {
        await tester.runAsync(() async {
          controller.startThread();
          await controller.submit(question);
        });
      }
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme:
              MaiChatApp.themeFor(
                null,
                Brightness.light,
                Colors.teal,
                expressive: true,
              ).copyWith(
                textTheme: shotTheme().textTheme,
                primaryTextTheme: shotTheme().primaryTextTheme,
              ),
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: view == 'btw-settings-large-text'
                    ? const TextScaler.linear(1.7)
                    : TextScaler.noScaling,
              ),
              child: Scaffold(
                resizeToAvoidBottomInset: false,
                body: BtwThread(
                  controller: controller,
                  ui: const ChatInterface(
                    composerStyle: ComposerStyle.expressive,
                  ),
                  onClose: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('btw-settings')));
      await tester.pumpAndSettle();
      if (view == 'btw-settings-tools') {
        await tester.tap(find.byKey(const Key('btw-section-tools')));
        await tester.pumpAndSettle();
      }
      if (view == 'btw-thread-actions') {
        await tester.longPress(
          find.byKey(Key('btw-saved-${controller.activeThread!.id}')),
        );
        await tester.pumpAndSettle();
      }
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('../../docs/previews/$view.png'),
      );
      debugDisableShadows = true;
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      state.dispose();
    });
  }
}
