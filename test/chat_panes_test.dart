import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/chat_interface.dart';
import 'package:maichat/models/conversation.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/screens/chat_screen.dart';
import 'package:maichat/services/btw.dart';
import 'package:maichat/services/chat_client.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart' hide Provider;
import 'package:shared_preferences/shared_preferences.dart';

class _Client extends ChatClient {
  @override
  Future<List<String>> listModels(Provider provider) async => ['m'];
}

class _State extends AppState {
  _State() : super(client: _Client());
  Completer<String>? reply;
  BtwRun? run;
  void Function(String)? progress;
  List<ChatMessage> side = [];

  @override
  Future<String> askAside(
    String question, {
    Conversation? conversation,
    List<ChatMessage> sideHistory = const [],
    ChatClient? client,
    BtwRun? run,
    void Function(String)? onProgress,
  }) async {
    this.run = run;
    progress = onProgress;
    side = sideHistory;
    onProgress?.call('A partial answer');
    return reply?.future ?? 'A complete answer';
  }
}

Future<_State> _boot(ComposerStyle style) async {
  SharedPreferences.setMockInitialValues({});
  final state = _State();
  await state.init();
  await state.addProvider(
    Provider(
      id: 'p',
      name: 'local',
      kind: ProviderKind.openai,
      baseUrl: 'https://host.tld/v1',
      model: 'm',
      apiKey: 'k',
    ),
  );
  final character = Character(id: 'a', name: 'Alice');
  await state.addCharacter(character);
  state.startChatWithCharacter(character);
  state.active.messages.add(
    ChatMessage(role: 'assistant', content: 'The main story'),
  );
  await state.updateChatInterface(
    state.chatInterface.copyWith(composerStyle: style),
  );
  return state;
}

Widget _host(AppState state) => ChangeNotifierProvider<AppState>.value(
  value: state,
  child: const MaterialApp(home: ChatScreen()),
);

Future<void> _ask(WidgetTester tester, String question) async {
  await tester.enterText(
    find.byKey(const Key('composer-field')),
    '/btw $question',
  );
  await tester.pump();
  await tester.tap(find.byKey(const Key('chat-ask-aside')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  for (final width in [412.0, 800.0, 1280.0]) {
    for (final style in ComposerStyle.values) {
      testWidgets('menu and side thread at $width with $style', (tester) async {
        tester.view
          ..physicalSize = Size(width, 915)
          ..devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final state = await _boot(style);
        await tester.pumpWidget(_host(state));
        await tester.pumpAndSettle();
        final main = find.byKey(const Key('chat-main-pane'));
        final before = tester.getRect(main);
        await tester.tap(find.byKey(chatMenuButtonKey));
        await tester.pumpAndSettle();
        final menu = tester.getRect(find.byKey(const Key('chat-drawer-pane')));
        final shifted = tester.getRect(main);
        expect(shifted.left, closeTo(menu.right, 1));
        if (width < 720) {
          expect(shifted.width, before.width);
          expect(menu.width / width, inInclusiveRange(.6, .8));
          expect(
            find.byKey(const Key('composer-field')).hitTestable(),
            findsNothing,
          );
        } else {
          expect(menu.width / width, inInclusiveRange(.2, .3));
          expect(
            find.byKey(const Key('composer-field')).hitTestable(),
            findsOneWidget,
          );
        }
        await tester.tapAt(tester.getCenter(find.byKey(chatMenuButtonKey)));
        await tester.pumpAndSettle();
        final turns = state.active.messages.length;
        await _ask(tester, 'First side question');
        expect(find.byKey(const Key('btw-thread')), findsOneWidget);
        expect(find.text('First side question'), findsOneWidget);
        expect(
          find.textContaining('A complete answer', findRichText: true),
          findsOneWidget,
        );
        final pane = tester.getRect(find.byKey(const Key('btw-thread')));
        if (width < 720) {
          expect(pane.width, closeTo(width, 1));
          expect(
            find.byKey(const Key('composer-field')).hitTestable(),
            findsNothing,
          );
        } else {
          expect(pane.left, greaterThan(tester.getRect(main).left));
          final handle = find.byKey(const Key('btw-resize-handle'));
          await tester.drag(handle, const Offset(-60, 0));
          await tester.pumpAndSettle();
          expect(
            tester.getSize(find.byKey(const Key('btw-thread'))).width,
            greaterThan(pane.width + 30),
          );
          // All three panes fit even at tablet width, and the menu can close.
          await tester.tap(find.byKey(chatMenuButtonKey));
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('btw-thread')), findsOneWidget);
          expect(
            find.byKey(const Key('composer-field')).hitTestable(),
            findsOneWidget,
          );
          await tester.tapAt(tester.getCenter(find.byKey(chatMenuButtonKey)));
          await tester.pumpAndSettle();
        }
        final side = find.byKey(const Key('btw-thread'));
        expect(
          find.descendant(
            of: side,
            matching: find.byKey(const Key('composer-persona')),
          ),
          findsNothing,
        );
        await tester.enterText(
          find.byKey(const Key('btw-composer-field')),
          'And then?',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('btw-send')));
        await tester.pumpAndSettle();
        expect(state.side.map((m) => m.content), [
          'First side question',
          'A complete answer',
        ]);
        expect(state.active.messages, hasLength(turns));
        await tester.tap(find.byKey(const Key('btw-close')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('btw-thread')), findsNothing);
        expect(tester.getRect(main), before);
        await tester.pumpWidget(const SizedBox.shrink());
        state.dispose();
      });
    }
  }

  for (final width in [720.0, 800.0, 1280.0, 1920.0, 2560.0, 3840.0]) {
    testWidgets('wide drawer keeps 25% at $width with all panes', (
      tester,
    ) async {
      tester.view
        ..physicalSize = Size(width, 915)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = await _boot(ComposerStyle.expressive);
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();

      // Menu + main chat: the pane is proportional on every wide layout,
      // including ultrawide desktops, and the chat keeps its minimum space.
      await tester.tap(find.byKey(chatMenuButtonKey));
      await tester.pumpAndSettle();
      final expectedDrawer = width * .25;
      final menu = tester.getRect(find.byKey(const Key('chat-drawer-pane')));
      expect(menu.width, closeTo(expectedDrawer, .1));
      expect(
        tester.getSize(find.byKey(const Key('chat-main-pane'))).width,
        greaterThanOrEqualTo(280),
      );

      // Menu + main chat + side thread, including resize clamping.
      await _ask(tester, 'Check every wide layout');
      final maximumAside = width - expectedDrawer - 280;
      final minimumAside = maximumAside.clamp(0.0, 280.0);
      final expectedAside = 360.0.clamp(minimumAside, maximumAside);
      final aside = find.byKey(const Key('btw-thread'));
      // The resize handle occupies 12px at the pane's left edge.
      expect(tester.getSize(aside).width, closeTo(expectedAside - 12, .1));
      expect(
        tester.getSize(find.byKey(const Key('chat-main-pane'))).width,
        greaterThanOrEqualTo(280),
      );

      // A mouse drag avoids touch slop so the exact resize delta is asserted.
      final handleCenter = tester.getCenter(
        find.byKey(const Key('btw-resize-handle')),
      );
      final resize = await tester.startGesture(
        handleCenter,
        kind: PointerDeviceKind.mouse,
      );
      await resize.moveBy(const Offset(-100, 0));
      await resize.up();
      await tester.pumpAndSettle();
      expect(
        tester.getSize(aside).width,
        closeTo(
          (expectedAside + 100).clamp(minimumAside, maximumAside) - 12,
          .1,
        ),
      );

      await tester.tapAt(tester.getCenter(find.byKey(chatMenuButtonKey)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chat-drawer-pane')), findsNothing);
      expect(aside, findsOneWidget);
      await tester.tap(find.byKey(const Key('btw-close')));
      await tester.pumpAndSettle();
      expect(aside, findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    });
  }

  testWidgets('streaming, stop, back and chat switching isolate side answers', (
    tester,
  ) async {
    final state = await _boot(ComposerStyle.expressive);
    state.reply = Completer<String>();
    await tester.pumpWidget(_host(state));
    await tester.pumpAndSettle();
    await _ask(tester, 'Keep answering');
    expect(
      find.textContaining('A partial answer', findRichText: true),
      findsOneWidget,
    );
    expect(find.byKey(const Key('btw-stop')), findsOneWidget);
    await tester.tap(find.byKey(const Key('btw-stop')));
    await tester.pumpAndSettle();
    expect(state.run!.cancelled, isTrue);
    expect(find.text('Stopped'), findsOneWidget);
    state.reply!.complete('Late answer must not replace stopped text');
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Late answer', findRichText: true),
      findsNothing,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('btw-thread')), findsNothing);
    state.reply = null;
    await _ask(tester, 'Next answer');
    state.startChatWithCharacter(Character(id: 'b', name: 'Bob'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('btw-thread')), findsNothing);
    await _ask(tester, 'A fresh chat');
    expect(state.side, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets(
    'close cancels a side request and errors leave follow-up usable',
    (tester) async {
      final state = await _boot(ComposerStyle.expressive);
      state.reply = Completer<String>();
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();
      await _ask(tester, 'An unfinished answer');
      await tester.tap(find.byKey(const Key('btw-close')));
      await tester.pumpAndSettle();
      expect(state.run!.cancelled, isTrue);
      state.reply!.complete('');
      state.reply = Completer<String>();
      await _ask(tester, 'A request that fails');
      state.reply!.completeError(ChatApiException('Try again later'));
      await tester.pumpAndSettle();
      expect(find.text('Try again later'), findsOneWidget);
      expect(find.byKey(const Key('btw-composer-field')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );
}
