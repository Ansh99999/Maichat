import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/appearance.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/chat_interface.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/screens/chat_screen.dart';
import 'package:maichat/services/chat_client.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart' hide Provider;
import 'package:shared_preferences/shared_preferences.dart';

class _Client extends ChatClient {
  final chunks = StreamController<ChatDelta>.broadcast();
  bool requested = false;

  @override
  Future<List<String>> listModels(Provider provider) async => ['m'];

  @override
  Stream<ChatDelta> streamChat({
    required Provider provider,
    required List<ChatMessage> history,
    GenParams params = const GenParams(),
  }) {
    requested = true;
    return chunks.stream;
  }
}

Future<({AppState state, _Client client})> _boot(
  WidgetTester tester, {
  ComposerStyle composer = ComposerStyle.expressive,
  MobileChatMenuStyle menu = MobileChatMenuStyle.slide,
  double width = 412,
}) async {
  tester.view
    ..physicalSize = Size(width, 915)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final client = _Client();
  final state = AppState(client: client);
  await state.init();
  await state.addProvider(
    Provider(
      id: 'p',
      name: 'Local',
      kind: ProviderKind.openai,
      baseUrl: 'https://example.invalid/v1',
      apiKey: 'test',
      model: 'm',
    ),
  );
  final alice = Character(id: 'a', name: 'Alice');
  await state.addCharacter(alice);
  state.startChatWithCharacter(alice);
  state.active.messages.add(
    ChatMessage(role: 'assistant', content: 'The story begins.'),
  );
  await state.updateChatInterface(
    state.chatInterface.copyWith(composerStyle: composer),
  );
  await state.updateAppearance(
    state.appearance.copyWith(mobileChatMenuStyle: menu),
  );
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: const ChatScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  addTearDown(() {
    state.dispose();
    client.chunks.close();
  });
  return (state: state, client: client);
}

final _pane = find.byKey(const Key('chat-drawer-pane'));
final _main = find.byKey(const Key('chat-main-pane'));

Rect _drawer(WidgetTester tester) => tester.getRect(_pane);

Offset _visibleDrawerPoint(WidgetTester tester) =>
    _drawer(tester).intersect(Offset.zero & tester.view.physicalSize).center;

void _expectPosition(
  WidgetTester tester,
  double revealed,
  MobileChatMenuStyle mode,
) {
  expect(_drawer(tester).right, closeTo(revealed, .1));
  expect(
    tester.getRect(_main).left,
    closeTo(mode == MobileChatMenuStyle.slide ? revealed : 0, .1),
  );
}

void main() {
  for (final composer in ComposerStyle.values) {
    for (final mode in MobileChatMenuStyle.values) {
      for (final surface in ['drawer', 'scrim']) {
        testWidgets('$composer $mode reverses from zero using $surface', (
          tester,
        ) async {
          await _boot(tester, composer: composer, menu: mode);
          await tester.tap(find.byKey(chatMenuButtonKey));
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('chat-drawer-close')), findsNothing);
          final start = surface == 'drawer'
              ? _visibleDrawerPoint(tester)
              : const Offset(400, 400);
          final gesture = await tester.startGesture(start);
          await gesture.moveBy(const Offset(-400, 0));
          await tester.pump();
          expect(_pane, findsNothing);
          expect(tester.getRect(_main).left, closeTo(0, .1));
          await tester.pump(const Duration(milliseconds: 400));
          await gesture.moveBy(const Offset(60, 0));
          await tester.pump();
          _expectPosition(tester, 60, mode);
          await tester.pump(const Duration(milliseconds: 400));
          _expectPosition(tester, 60, mode);
          await gesture.moveBy(const Offset(40, 0));
          await tester.pump();
          _expectPosition(tester, 100, mode);
          await gesture.moveBy(const Offset(-40, 0));
          await tester.pump();
          _expectPosition(tester, 60, mode);
          await gesture.up();
          await tester.pumpAndSettle();
          expect(_pane, findsNothing);
        });
      }

      testWidgets(
        '$composer $mode keeps a live stream and held drag independent',
        (tester) async {
          final fixture = await _boot(tester, composer: composer, menu: mode);
          final send = fixture.state.send('Continue the story.');
          for (var i = 0; i < 30 && !fixture.client.requested; i++) {
            await tester.pump(const Duration(milliseconds: 16));
          }
          expect(fixture.client.requested, isTrue);
          fixture.client.chunks.add(const ChatDelta(text: 'Seed'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          final gesture = await tester.startGesture(const Offset(2, 300));
          await gesture.moveBy(const Offset(100, 0));
          await tester.pump();
          _expectPosition(tester, 100, mode);
          final previous = debugOnRebuildDirtyWidget;
          var menuBuilds = 0;
          debugOnRebuildDirtyWidget = (element, builtOnce) {
            previous?.call(element, builtOnce);
            if (element.widget.runtimeType.toString() == '_ChatMenuBody') {
              menuBuilds++;
            }
          };
          try {
            for (var i = 0; i < 4; i++) {
              // Streaming is paced by a real Stopwatch, independent of the
              // widget test's fake frame clock. Advance that cadence first.
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 60)),
              );
              fixture.client.chunks.add(ChatDelta(text: ' step$i'));
              // Deliver the asynchronous delta before rendering its update.
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 100));
              expect(fixture.state.streaming, isTrue);
              _expectPosition(tester, 100, mode);
            }
            expect(
              menuBuilds,
              0,
              reason: 'tokens do not rebuild unchanged menu data',
            );
            expect(
              fixture.state.active.messages.last.content,
              contains('step3'),
            );
            expect(
              find.textContaining('step3', findRichText: true),
              findsWidgets,
            );
            await gesture.moveBy(const Offset(40, 0));
            await tester.pump();
            _expectPosition(tester, 140, mode);
            await gesture.moveBy(const Offset(-40, 0));
            await tester.pump();
            _expectPosition(tester, 100, mode);
            await gesture.up();
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 700));
            expect(_pane, findsNothing);
            expect(fixture.state.streaming, isTrue);
          } finally {
            debugOnRebuildDirtyWidget = previous;
            final closed = fixture.client.chunks.close();
            await tester.pump(const Duration(milliseconds: 200));
            await tester.pumpAndSettle();
            await closed;
            await send;
          }
        },
      );
    }

    testWidgets(
      '$composer Back cancels a held drag and ignores stale updates',
      (tester) async {
        await _boot(tester, composer: composer);
        final gesture = await tester.startGesture(const Offset(2, 300));
        await gesture.moveBy(const Offset(100, 0));
        await tester.pump();
        expect(_pane, findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 700));
        expect(_pane, findsNothing);
        await gesture.moveBy(const Offset(100, 0));
        await tester.pump();
        expect(_pane, findsNothing);
        await gesture.up();
        await tester.pumpAndSettle();
        expect(_pane, findsNothing);
      },
    );
  }

  for (final composer in ComposerStyle.values) {
    testWidgets('$composer wide layout ignores the phone overlay preference', (
      tester,
    ) async {
      await _boot(
        tester,
        composer: composer,
        menu: MobileChatMenuStyle.overlay,
        width: 1280,
      );
      await tester.tap(find.byKey(chatMenuButtonKey));
      await tester.pumpAndSettle();
      expect(_drawer(tester).width, closeTo(320, .1));
      expect(tester.getRect(_main).left, closeTo(320, .1));
      expect(
        find.byKey(const Key('composer-field')).hitTestable(),
        findsOneWidget,
      );
      final gesture = await tester.startGesture(_visibleDrawerPoint(tester));
      await gesture.moveBy(const Offset(-400, 0));
      await tester.pump();
      expect(_pane, findsNothing);
      await gesture.moveBy(const Offset(60, 0));
      await tester.pump();
      _expectPosition(tester, 60, MobileChatMenuStyle.slide);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(_pane, findsNothing);
    });
  }

  testWidgets(
    'menu scrolling keeps its position and leaves the scrim tappable',
    (tester) async {
      await _boot(tester);
      tester.view.physicalSize = const Size(412, 520);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(chatMenuButtonKey));
      await tester.pumpAndSettle();
      final scrollable = tester.state<ScrollableState>(
        find.descendant(of: _pane, matching: find.byType(Scrollable)).first,
      );
      await tester.dragFrom(const Offset(100, 300), const Offset(0, -160));
      await tester.pumpAndSettle();
      expect(scrollable.position.pixels, greaterThan(0));
      expect(_drawer(tester).right, closeTo(412 * .78, .1));
      await tester.tapAt(const Offset(400, 300));
      await tester.pumpAndSettle();
      expect(_pane, findsNothing);
    },
  );

  testWidgets('a short closing fling overrides a mostly open position', (
    tester,
  ) async {
    await _boot(tester);
    await tester.tap(find.byKey(chatMenuButtonKey));
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(_visibleDrawerPoint(tester));
    for (final time in [20, 40, 60]) {
      await gesture.moveBy(
        const Offset(-30, 0),
        timeStamp: Duration(milliseconds: time),
      );
    }
    await gesture.up(timeStamp: const Duration(milliseconds: 70));
    await tester.pumpAndSettle();
    expect(_pane, findsNothing);
  });

  for (final opening in [true, false]) {
    for (final surface in ['drawer', 'scrim']) {
      testWidgets(
        'down-hold freezes ${opening ? 'opening' : 'closing'} on $surface',
        (tester) async {
          await _boot(tester);
          await tester.tap(find.byKey(chatMenuButtonKey));
          if (!opening) {
            await tester.pumpAndSettle();
            await tester.tapAt(tester.getCenter(find.byKey(chatMenuButtonKey)));
          }
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 50));
          final held = _drawer(tester);
          final gesture = await tester.startGesture(
            surface == 'drawer'
                ? _visibleDrawerPoint(tester)
                : const Offset(400, 400),
          );
          await tester.pump(const Duration(milliseconds: 400));
          expect(_drawer(tester), held);
          await gesture.moveBy(Offset(opening ? 200 : -200, 0));
          await tester.pump();
          expect(
            _drawer(tester).right,
            opening ? greaterThan(held.right) : lessThan(held.right),
          );
          await gesture.up();
          await tester.pumpAndSettle();
          if (opening) {
            expect(_drawer(tester).right, closeTo(412 * .78, .1));
          } else {
            expect(_pane, findsNothing);
          }
        },
      );
    }
  }
}
