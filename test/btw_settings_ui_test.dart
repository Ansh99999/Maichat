import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/chat_interface.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/models/settings.dart';
import 'package:maichat/state/app_state.dart';
import 'package:maichat/widgets/btw_thread.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<(AppState, BtwThreadController)> boot() async {
    final state = AppState();
    await state.init();
    await state.addProvider(
      Provider(
        id: 'p',
        name: 'Writing model',
        kind: ProviderKind.openai,
        baseUrl: 'https://example.test',
        model: 'writer',
        apiKey: 'key',
      ),
    );
    final controller = BtwThreadController(
      ask: (_, _, _, _) async => 'Side answer',
    );
    controller.bind(state, state.active.id);
    controller.startThread();
    await controller.submit('Lighthouse question');
    controller.startThread();
    await controller.submit('Harbour question');
    addTearDown(() {
      controller.dispose();
      state.dispose();
    });
    return (state, controller);
  }

  Widget host(
    BtwThreadController controller, {
    TextScaler scaler = TextScaler.noScaling,
    double keyboard = 0,
    bool reduceMotion = false,
    ComposerStyle composer = ComposerStyle.expressive,
  }) => MaterialApp(
    theme: ThemeData(useMaterial3: true),
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: scaler,
          viewInsets: EdgeInsets.only(bottom: keyboard),
          disableAnimations: reduceMotion,
        ),
        child: Scaffold(
          resizeToAvoidBottomInset: false,
          body: BtwThread(
            controller: controller,
            ui: ChatInterface(composerStyle: composer),
            onClose: () {},
          ),
        ),
      ),
    ),
  );

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('btw-settings')));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'saved threads search, select and create without losing prior threads',
    (tester) async {
      final (_, controller) = await boot();
      final first = controller.threads.firstWhere(
        (t) => t.displayTitle.startsWith('Lighthouse'),
      );
      await tester.pumpWidget(host(controller));
      await open(tester);
      await tester.enterText(
        find.byKey(const Key('btw-thread-search')),
        'lighthouse',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(Key('btw-saved-${first.id}')), findsOneWidget);
      expect(
        find.byKey(Key('btw-saved-${controller.activeThread!.id}')),
        findsNothing,
      ); // transcript header behind window
      await tester.tap(find.byKey(Key('btw-saved-${first.id}')));
      await tester.pumpAndSettle();
      expect(controller.activeThread, same(first));
      expect(
        tester.widget<Text>(find.byKey(const Key('btw-thread-title'))).data,
        'Lighthouse question',
      );
      await tester.tap(find.byKey(const Key('btw-new-thread')));
      await tester.pumpAndSettle();
      expect(controller.exchanges, isEmpty);
      expect(controller.threads, hasLength(3));
    },
  );

  testWidgets(
    'prompt, provider, tools and title mode edit functional settings and persist',
    (tester) async {
      final (state, controller) = await boot();
      final selected = controller.activeThread!;
      await tester.pumpWidget(host(controller));
      await open(tester);
      await tester.tap(find.byKey(const Key('btw-title-mode')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byWidgetPredicate(
          (widget) =>
              widget is CheckedPopupMenuItem<BtwTitleMode> &&
              widget.value == BtwTitleMode.generated,
        ),
      );
      await tester.pumpAndSettle();
      expect(state.btwSettings.titleMode, BtwTitleMode.generated);
      await tester.tap(find.byKey(const Key('btw-section-prompt')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('btw-system-prompt')),
        'Answer in one paragraph.',
      );
      await tester.ensureVisible(find.byKey(const Key('btw-save-prompt')));
      await tester.tap(find.byKey(const Key('btw-save-prompt')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('btw-section-provider')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('btw-provider-p')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('btw-section-tools')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('btw-tools-off')),
        100,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('btw-editor-tools')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(find.byKey(const Key('btw-tools-off')));
      await tester.pumpAndSettle();
      expect(selected.systemPrompt, 'Answer in one paragraph.');
      expect(selected.providerId, 'p');
      expect(selected.toolsEnabled, isFalse);
      final restored = AppState();
      await restored.init();
      addTearDown(restored.dispose);
      final saved = restored.btwThreadById(selected.id)!;
      expect(saved.systemPrompt, selected.systemPrompt);
      expect(saved.providerId, 'p');
      expect(saved.toolsEnabled, isFalse);
      expect(restored.btwSettings.titleMode, BtwTitleMode.generated);
    },
  );

  for (final json in [true, false]) {
    testWidgets(
      'long-press export ${json ? 'JSON' : 'text'} contains only the chosen thread',
      (tester) async {
        final (_, controller) = await boot();
        final chosen = controller.threads.firstWhere(
          (t) => t.displayTitle.startsWith('Lighthouse'),
        );
        String? clipboard;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              clipboard = (call.arguments as Map)['text'] as String;
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await tester.pumpWidget(host(controller));
        await open(tester);
        await tester.longPress(find.byKey(Key('btw-saved-${chosen.id}')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('btw-thread-actions')), findsOneWidget);
        await tester.tap(find.byKey(const Key('btw-export-thread')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(Key(json ? 'btw-export-json' : 'btw-export-text')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Copy to clipboard'));
        await tester.pumpAndSettle();
        expect(clipboard, contains('Lighthouse question'));
        expect(clipboard, contains('Side answer'));
        expect(clipboard, isNot(contains('Harbour question')));
        if (json) {
          expect((jsonDecode(clipboard!) as Map)['thread']['id'], chosen.id);
        }
      },
    );
  }

  for (final json in [true, false]) {
    testWidgets(
      'save exports ${json ? 'JSON' : 'text'} bytes through the file picker',
      (tester) async {
        final (_, controller) = await boot();
        final chosen = controller.threads.firstWhere(
          (thread) => thread.displayTitle.startsWith('Lighthouse'),
        );
        String? written;
        String? fileName;
        const channel = MethodChannel('miguelruivo.flutter.plugins.filepicker');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async {
            if (call.method == 'save') {
              final arguments = call.arguments as Map;
              written = utf8.decode(arguments['bytes'] as List<int>);
              fileName = arguments['fileName'] as String;
              return '/saved/side-thread';
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );
        await tester.pumpWidget(host(controller));
        await open(tester);
        await tester.longPress(find.byKey(Key('btw-saved-${chosen.id}')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('btw-export-thread')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(Key(json ? 'btw-export-json' : 'btw-export-text')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save as .${json ? 'json' : 'txt'} file'));
        await tester.pumpAndSettle();
        expect(written, contains('Lighthouse question'));
        expect(written, isNot(contains('Harbour question')));
        expect(fileName, endsWith(json ? '.json' : '.txt'));
        if (json) {
          expect((jsonDecode(written!) as Map)['thread']['id'], chosen.id);
        }
      },
    );
  }

  testWidgets(
    'long-press delete removes only chosen thread and updates selection',
    (tester) async {
      final (state, controller) = await boot();
      final chosen = controller.activeThread!;
      final retained = controller.threads.firstWhere((t) => t.id != chosen.id);
      await tester.pumpWidget(host(controller));
      await open(tester);
      await tester.longPress(find.byKey(Key('btw-saved-${chosen.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('btw-delete-thread')));
      await tester.pumpAndSettle();
      expect(state.btwThreadById(chosen.id), isNull);
      expect(controller.activeThread, same(retained));
      expect(find.byKey(Key('btw-saved-${chosen.id}')), findsNothing);
    },
  );

  testWidgets(
    'Back dismisses actions before settings and releases hidden controls',
    (tester) async {
      final (_, controller) = await boot();
      await tester.pumpWidget(host(controller));
      await open(tester);
      await tester.longPress(
        find.byKey(Key('btw-saved-${controller.activeThread!.id}')),
      );
      await tester.pumpAndSettle();
      expect(controller.dismissTransientUi(), isTrue);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('btw-thread-actions')), findsNothing);
      expect(find.byKey(const Key('btw-settings-panel')), findsOneWidget);
      expect(controller.dismissTransientUi(), isTrue);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('btw-settings-panel')), findsNothing);
      expect(controller.dismissTransientUi(), isFalse);
    },
  );

  for (final scenario in <(Size, double, double)>[
    (const Size(320, 640), 1, 0),
    (const Size(320, 640), 2, 260),
    (const Size(640, 360), 1, 160),
    (const Size(640, 360), 2, 160),
    (const Size(320, 360), 2, 100),
  ]) {
    for (final composer in ComposerStyle.values) {
      testWidgets(
        'settings fit ${scenario.$1} at ${scenario.$2}x with keyboard ${scenario.$3} $composer',
        (tester) async {
          tester.view
            ..physicalSize = scenario.$1
            ..devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final (_, controller) = await boot();
          await tester.pumpWidget(
            host(
              controller,
              scaler: TextScaler.linear(scenario.$2),
              keyboard: scenario.$3,
              reduceMotion: true,
              composer: composer,
            ),
          );
          await open(tester);
          expect(tester.takeException(), isNull);
          expect(
            tester.getSize(find.byKey(const Key('btw-close'))),
            const Size(48, 48),
          );
          expect(
            tester.getSize(find.byKey(const Key('btw-settings'))),
            const Size(48, 48),
          );
          await tester.tap(find.byKey(const Key('btw-section-provider')));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final panel = tester.getRect(
            find.byKey(const Key('btw-settings-panel')),
          );
          expect(
            panel.bottom,
            lessThanOrEqualTo(scenario.$1.height - scenario.$3),
          );
        },
      );
    }
  }
}
