import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/btw_conversation.dart';
import 'package:maichat/models/chat_interface.dart';
import 'package:maichat/models/conversation.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/screens/chat_screen.dart';
import 'package:maichat/services/chat_client.dart';
import 'package:maichat/services/btw.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart' hide Provider;
import 'package:shared_preferences/shared_preferences.dart';

class _Client extends ChatClient {
  @override
  Future<List<String>> listModels(Provider provider) async => ['m'];

  @override
  Stream<ChatDelta> streamChat({
    required Provider provider,
    required List<ChatMessage> history,
    GenParams params = const GenParams(),
  }) async* {
    yield ChatDelta(text: 'The saved side answer.');
  }
}

class _State extends AppState {
  _State() : super(client: _Client());

  @override
  Future<String> askAside(
    String question, {
    Conversation? conversation,
    BtwConversation? thread,
    List<ChatMessage> sideHistory = const [],
    ChatClient? client,
    BtwRun? run,
    void Function(String)? onProgress,
  }) async => 'The saved side answer.';
}

Future<AppState> _boot(
  WidgetTester tester, {
  double width = 412,
  ComposerStyle style = ComposerStyle.expressive,
  bool reducedMotion = false,
}) async {
  tester.view
    ..physicalSize = Size(width, 915)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final state = _State();
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
    ChatMessage(role: 'assistant', content: 'The story.'),
  );
  await state.updateChatInterface(
    state.chatInterface.copyWith(composerStyle: style),
  );
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: reducedMotion),
          child: child!,
        ),
        home: const ChatScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  addTearDown(state.dispose);
  return state;
}

final _main = find.byKey(const Key('chat-main-pane'));
final _side = find.byKey(const Key('btw-thread'));
final _reopen = find.byKey(const Key('btw-reopen'));
final _close = find.byKey(const Key('btw-close'));

Future<void> _ask(
  WidgetTester tester, [
  String question = 'Who is Wren?',
]) async {
  await tester.enterText(
    find.byKey(const Key('composer-field')),
    '/btw $question',
  );
  await tester.pump();
  await tester.tap(find.byKey(const Key('chat-ask-aside')));
  await tester.pump();
  await tester.pumpAndSettle();
}

void _expectOffset(WidgetTester tester, double width, double left) {
  expect(tester.getRect(_side).left, closeTo(left, .1));
  expect(tester.getRect(_side).width, closeTo(width, .1));
  expect(tester.getRect(_main).left, closeTo(left - width, .1));
  expect(tester.getRect(_main).width, closeTo(width, .1));
}

void main() {
  for (final width in [320.0, 412.0, 719.0]) {
    for (final style in ComposerStyle.values) {
      testWidgets('side cutouts and tap slides at $width with $style', (
        tester,
      ) async {
        await _boot(tester, width: width, style: style);
        expect(_reopen, findsNothing);
        await _ask(tester);
        _expectOffset(tester, width, 0);
        final back = tester.getRect(_close);
        expect(back.left, 0);
        expect(back.size, const Size(48, 48));
        await tester.tap(_close);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 48));
        final leaving = tester.getRect(_side).left;
        expect(leaving, greaterThan(0));
        expect(leaving, lessThan(width));
        _expectOffset(tester, width, leaving);
        expect(
          find.byKey(const Key('composer-field')).hitTestable(),
          findsNothing,
        );
        await tester.pumpAndSettle();
        expect(_side, findsNothing);
        final reopen = tester.getRect(_reopen);
        expect(reopen.right, width);
        expect(reopen.top, back.top);
        expect(reopen.size, const Size(48, 48));
        await tester.tap(_reopen);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 48));
        final entering = tester.getRect(_side).left;
        expect(entering, greaterThan(0));
        expect(entering, lessThan(width));
        _expectOffset(tester, width, entering);
        await tester.pumpAndSettle();
        expect(
          find.textContaining('The saved side answer.', findRichText: true),
          findsOneWidget,
        );
        _expectOffset(tester, width, 0);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  testWidgets('edge drag holds, reverses and preserves rendered content', (
    tester,
  ) async {
    await _boot(tester);
    await _ask(tester);
    final drag = await tester.startGesture(tester.getCenter(_close));
    await drag.moveBy(const Offset(100, 0));
    await tester.pump();
    await tester.pump();
    _expectOffset(tester, 412, 100);
    final transcript = tester.widget(_side);
    final composer = tester.widget(find.byKey(const Key('btw-composer-field')));
    await tester.pump(const Duration(milliseconds: 500));
    _expectOffset(tester, 412, 100);
    await drag.moveBy(const Offset(-40, 0));
    await tester.pump();
    _expectOffset(tester, 412, 60);
    expect(tester.widget(_side), same(transcript));
    expect(
      tester.widget(find.byKey(const Key('btw-composer-field'))),
      same(composer),
    );
    await drag.moveBy(const Offset(400, 0));
    await tester.pump();
    _expectOffset(tester, 412, 412);
    await tester.pump(const Duration(milliseconds: 500));
    await drag.moveBy(const Offset(-160, 0));
    await tester.pump();
    _expectOffset(tester, 412, 252);
    await tester.pump(const Duration(milliseconds: 500));
    await drag.up();
    await tester.pumpAndSettle();
    expect(_side, findsNothing);
    final reopen = await tester.startGesture(tester.getCenter(_reopen));
    await reopen.moveBy(const Offset(-140, 0));
    await tester.pump();
    await tester.pump();
    _expectOffset(tester, 412, 272);
    await tester.pump(const Duration(milliseconds: 500));
    _expectOffset(tester, 412, 272);
    await reopen.moveBy(const Offset(-160, 0));
    await tester.pump();
    _expectOffset(tester, 412, 112);
    await tester.pump(const Duration(milliseconds: 500));
    await reopen.up();
    await tester.pumpAndSettle();
    _expectOffset(tester, 412, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('touch catches a closing spring and can reopen without a jump', (
    tester,
  ) async {
    await _boot(tester);
    await _ask(tester);
    await tester.tap(_close);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 48));
    final position = tester.getRect(_side).left;
    final held = await tester.startGesture(tester.getCenter(_close));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    _expectOffset(tester, 412, position);
    await held.moveBy(const Offset(-100, 0));
    await tester.pump();
    _expectOffset(tester, 412, (position - 100).clamp(0, 412));
    await tester.pump(const Duration(milliseconds: 400));
    await held.up();
    await tester.pumpAndSettle();
    _expectOffset(tester, 412, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final width in [800.0, 1280.0]) {
    testWidgets('wide side pane slides and returns with gestures at $width', (
      tester,
    ) async {
      await _boot(tester, width: width);
      await _ask(tester);
      final back = tester.getRect(_close);
      expect(back.left, closeTo(tester.getRect(_side).left, .1));
      final paneWidth = tester.getRect(_side).width + 12;
      final gesture = await tester.startGesture(back.center);
      await gesture.moveBy(const Offset(80, 0));
      await tester.pump();
      await tester.pump();
      expect(tester.getRect(_side).left, closeTo(back.left + 80, .1));
      final held = tester.getRect(_side);
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.getRect(_side), held);
      await gesture.moveBy(Offset(paneWidth, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(_side, findsNothing);
      expect(tester.getRect(_reopen).right, width);
      final reopen = await tester.startGesture(tester.getCenter(_reopen));
      await reopen.moveBy(Offset(-paneWidth, 0));
      await tester.pump();
      await reopen.up();
      await tester.pumpAndSettle();
      expect(tester.getRect(_side).left, closeTo(back.left, .1));
      expect(
        find.byKey(const Key('composer-field')).hitTestable(),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('cancel settles; scrolling content does not move the pane', (
    tester,
  ) async {
    await _boot(tester);
    await _ask(tester);
    final drag = await tester.startGesture(tester.getCenter(_close));
    await drag.moveBy(const Offset(100, 0));
    await tester.pump();
    await drag.cancel();
    await tester.pumpAndSettle();
    _expectOffset(tester, 412, 0);
    await tester.drag(
      find.byKey(const Key('btw-transcript')),
      const Offset(-80, -300),
    );
    await tester.pumpAndSettle();
    _expectOffset(tester, 412, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'bare command opens a blank thread; reduced motion settles immediately',
    (tester) async {
      final state = await _boot(tester, reducedMotion: true);
      await _ask(tester, '');
      _expectOffset(tester, 412, 0);
      expect(state.active.messages, hasLength(1));
      await tester.tap(_close);
      await tester.pump();
      await tester.pump();
      expect(_side, findsNothing);
      await tester.tap(_reopen);
      await tester.pump();
      await tester.pump();
      _expectOffset(tester, 412, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
