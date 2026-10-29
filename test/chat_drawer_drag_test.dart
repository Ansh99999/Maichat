import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/btw_conversation.dart';
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
  Future<List<String>> listModels(Provider provider) async => const ['m'];
}

class _State extends AppState {
  _State() : super(client: _Client());
  int notifications = 0;

  @override
  void notifyListeners() {
    notifications++;
    super.notifyListeners();
  }

  @override
  Future<String> askAside(
    String question, {
    Conversation? conversation,
    BtwConversation? thread,
    List<ChatMessage> sideHistory = const [],
    ChatClient? client,
    BtwRun? run,
    void Function(String)? onProgress,
  }) async {
    onProgress?.call('A side answer');
    return 'A side answer';
  }
}

Future<AppState> _boot(ComposerStyle style) async {
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
  final alice = Character(id: 'a', name: 'Alice');
  await state.addCharacter(alice);
  state.startChatWithCharacter(alice);
  state.active.messages.add(
    ChatMessage(role: 'assistant', content: 'A short line'),
  );
  await state.updateChatInterface(
    state.chatInterface.copyWith(composerStyle: style),
  );
  return state;
}

Widget _host(AppState state) => ChangeNotifierProvider<AppState>.value(
  value: state,
  child: MaterialApp(
    theme: ThemeData(platform: TargetPlatform.android),
    home: const ChatScreen(),
  ),
);

Future<void> _surface(WidgetTester tester, double width) async {
  tester.view
    ..physicalSize = Size(width, 915)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Rect _main(WidgetTester tester) =>
    tester.getRect(find.byKey(const Key('chat-main-pane')));

Future<Rect> _drawer(WidgetTester tester) async =>
    tester.getRect(find.byKey(const Key('chat-drawer-pane')));

Offset _visibleDrawerPoint(WidgetTester tester) {
  final pane = tester.getRect(find.byKey(const Key('chat-drawer-pane')));
  final viewport =
      Offset.zero & tester.view.physicalSize / tester.view.devicePixelRatio;
  return pane.intersect(viewport).center;
}

void main() {
  // The core matrix: both layouts and both composers drive the same real
  // pointer stream. The first accepted move pays touch slop; every later move
  // must be one-for-one with the finger, including a hold and a reversal.
  for (final width in [412.0, 1280.0]) {
    for (final style in ComposerStyle.values) {
      testWidgets('drawer follows a held finger at $width with $style', (
        tester,
      ) async {
        await _surface(tester, width);
        final state = await _boot(style);
        await tester.pumpWidget(_host(state));
        await tester.pumpAndSettle();

        final closed = _main(tester);
        final gesture = await tester.startGesture(
          const Offset(2, 300),
          kind: PointerDeviceKind.touch,
        );
        await gesture.moveBy(const Offset(60, 0));
        await tester.pump();
        final drawerWidth = width < 720 ? width * .78 : width * .25;
        final first = await _drawer(tester);
        expect(first.right, lessThan(drawerWidth));
        expect(first.right, greaterThan(0));

        // Recognition has happened; this and every later delta are exact.
        await gesture.moveBy(const Offset(50, 0));
        await tester.pump();
        final second = await _drawer(tester);
        expect(second.right - first.right, closeTo(50, .1));
        expect(_main(tester).left, closeTo(second.right, .1));
        if (width < 720) {
          expect(_main(tester).width, closed.width);
          expect(
            find.byKey(const Key('composer-field')).hitTestable(),
            findsNothing,
            reason: 'a partially revealed phone drawer still blocks chat',
          );
        } else {
          expect(_main(tester).width, closeTo(width - second.right, .1));
          expect(
            find.byKey(const Key('composer-field')).hitTestable(),
            findsOneWidget,
            reason: 'the wide chat stays interactive while dragged',
          );
        }

        // Holding still is not an invitation for an implicit animation.
        final held = second;
        await tester.pump(const Duration(milliseconds: 400));
        expect(await _drawer(tester), held);
        expect(_main(tester).left, closeTo(held.right, .1));

        // Reversal is immediate, still without leaving the finger.
        await gesture.moveBy(const Offset(-50, 0));
        await tester.pump();
        expect((await _drawer(tester)).right, closeTo(first.right, .1));
        expect(_main(tester).left, closeTo(first.right, .1));

        // Both ends clamp while the pointer is down.
        await gesture.moveBy(Offset(drawerWidth * 2, 0));
        await tester.pump();
        expect((await _drawer(tester)).right, closeTo(drawerWidth, .1));
        await gesture.moveBy(Offset(-drawerWidth * 3, 0));
        await tester.pump();
        expect(_main(tester).left, closeTo(0, .1));
        expect(find.byKey(const Key('chat-drawer-pane')), findsNothing);

        // It can be brought back without a new pointer, then released.
        await gesture.moveBy(const Offset(50, 0));
        await tester.pump();
        expect((await _drawer(tester)).right, closeTo(50, .1));
        await gesture.up();
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('chat-drawer-pane')), findsNothing);
        expect(_main(tester), closed);

        await tester.pumpWidget(const SizedBox.shrink());
        state.dispose();
      });
    }
  }

  testWidgets('slow releases choose the nearest endpoint', (tester) async {
    await _surface(tester, 412);
    final state = await _boot(ComposerStyle.expressive);
    await tester.pumpWidget(_host(state));
    await tester.pumpAndSettle();
    final drawerWidth = 412 * .78;

    await tester.tap(find.byKey(chatMenuButtonKey));
    await tester.pumpAndSettle();
    final opened = await _drawer(tester);

    // Still mostly open: a slow release stays open.
    var gesture = await tester.startGesture(
      _visibleDrawerPoint(tester),
      kind: PointerDeviceKind.touch,
    );
    await gesture.moveBy(const Offset(-100, 0));
    await tester.pump();
    expect((await _drawer(tester)).right, lessThan(opened.right));
    await gesture.up();
    await tester.pumpAndSettle();
    expect((await _drawer(tester)).right, closeTo(drawerWidth, .1));

    // Mostly closed: a slow release finishes closing.
    gesture = await tester.startGesture(
      _visibleDrawerPoint(tester),
      kind: PointerDeviceKind.touch,
    );
    await gesture.moveBy(const Offset(-250, 0));
    await tester.pump();
    expect((await _drawer(tester)).right, lessThan(drawerWidth * .5));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('chat-drawer-pane')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets('a short decisive fling opens the drawer', (tester) async {
    await _surface(tester, 412);
    final state = await _boot(ComposerStyle.legacy);
    await tester.pumpWidget(_host(state));
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(
      const Offset(2, 300),
      kind: PointerDeviceKind.touch,
    );
    // Velocity estimation needs several timed samples. The whole fling still
    // travels less than halfway across the 321px drawer.
    for (final time in [20, 40, 60]) {
      await gesture.moveBy(
        const Offset(30, 0),
        timeStamp: Duration(milliseconds: time),
      );
    }
    await gesture.up(timeStamp: const Duration(milliseconds: 70));
    await tester.pumpAndSettle();
    expect(
      (await _drawer(tester)).right,
      closeTo(412 * .78, .1),
      reason: 'velocity should decide this short drag',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets('cancelling a mostly-closed drag settles closed', (tester) async {
    await _surface(tester, 1280);
    final state = await _boot(ComposerStyle.expressive);
    await tester.pumpWidget(_host(state));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(chatMenuButtonKey));
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(
      _visibleDrawerPoint(tester),
      kind: PointerDeviceKind.touch,
    );
    await gesture.moveBy(const Offset(-250, 0));
    await tester.pump();
    final almostClosed = await _drawer(tester);
    expect(almostClosed.right, lessThan(160));
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('chat-drawer-pane')), findsNothing);
    expect(_main(tester).left, closeTo(0, .1));

    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets('a finger can catch and reverse a closing animation', (
    tester,
  ) async {
    await _surface(tester, 412);
    final state = await _boot(ComposerStyle.legacy);
    await tester.pumpWidget(_host(state));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(chatMenuButtonKey));
    await tester.pumpAndSettle();
    await tester.tapAt(tester.getCenter(find.byKey(chatMenuButtonKey)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final mid = await _drawer(tester);
    expect(mid.right, allOf(greaterThan(0), lessThan(412 * .78)));

    final gesture = await tester.startGesture(
      _visibleDrawerPoint(tester),
      kind: PointerDeviceKind.touch,
    );
    await gesture.moveBy(const Offset(50, 0));
    await tester.pump();
    final caught = await _drawer(tester);
    expect(caught.right, greaterThan(mid.right));
    expect(caught.right - mid.right, lessThanOrEqualTo(50));
    // Continue beyond halfway, so a slow release naturally settles open.
    await gesture.moveBy(const Offset(120, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect((await _drawer(tester)).right, closeTo(412 * .78, .1));

    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets('a finger can catch and reverse an opening animation', (
    tester,
  ) async {
    await _surface(tester, 1280);
    final state = await _boot(ComposerStyle.legacy);
    await tester.pumpWidget(_host(state));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(chatMenuButtonKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final mid = await _drawer(tester);
    expect(mid.right, allOf(greaterThan(0), lessThan(320)));

    final gesture = await tester.startGesture(
      _visibleDrawerPoint(tester),
      kind: PointerDeviceKind.touch,
    );
    await gesture.moveBy(const Offset(-50, 0));
    await tester.pump();
    final caught = await _drawer(tester);
    expect(caught.right, lessThan(mid.right));
    expect(mid.right - caught.right, lessThanOrEqualTo(50));
    // Continue below halfway before releasing the caught opening animation.
    await gesture.moveBy(const Offset(-120, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('chat-drawer-pane')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets('an opening edge drag unfocuses the composer for good', (
    tester,
  ) async {
    await _surface(tester, 412);
    final state = await _boot(ComposerStyle.expressive);
    await tester.pumpWidget(_host(state));
    await tester.pumpAndSettle();

    final composer = find.byKey(const Key('composer-field'));
    EditableText editable() => tester.widget<EditableText>(
      find.descendant(of: composer, matching: find.byType(EditableText)),
    );
    await tester.tap(composer);
    await tester.pump();
    expect(editable().focusNode.hasFocus, isTrue);
    tester.testTextInput.hide();
    await tester.pump();
    expect(tester.testTextInput.isVisible, isFalse);

    final gesture = await tester.startGesture(
      const Offset(2, 300),
      kind: PointerDeviceKind.touch,
    );
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump();
    expect(editable().focusNode.hasFocus, isFalse);
    await gesture.moveBy(const Offset(180, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect((await _drawer(tester)).right, closeTo(412 * .78, .1));

    final close = await tester.startGesture(
      _visibleDrawerPoint(tester),
      kind: PointerDeviceKind.touch,
    );
    await close.moveBy(const Offset(-250, 0));
    await close.up();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('chat-drawer-pane')), findsNothing);
    expect(editable().focusNode.hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets('the edge gesture still works with a wide side thread open', (
    tester,
  ) async {
    await _surface(tester, 1280);
    final state = await _boot(ComposerStyle.expressive);
    await tester.pumpWidget(_host(state));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('composer-field')),
      '/btw Side question',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('chat-ask-aside')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('btw-thread')), findsOneWidget);

    final gesture = await tester.startGesture(
      const Offset(2, 300),
      kind: PointerDeviceKind.touch,
    );
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump();
    expect((await _drawer(tester)).right, greaterThan(0));
    await gesture.moveBy(const Offset(150, 0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect((await _drawer(tester)).right, closeTo(320, .1));
    expect(find.byKey(const Key('btw-resize-handle')), findsOneWidget);
    expect(_main(tester).width, greaterThanOrEqualTo(280));
    expect(
      find.byKey(const Key('composer-field')).hitTestable(),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });
}
