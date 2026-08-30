import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/chat_interface.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/screens/chat_screen.dart';
import 'package:maichat/services/chat_client.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart' hide Provider;
import 'package:shared_preferences/shared_preferences.dart';

/// The three turn actions driven through the real composer: the strip they live
/// in, when each is offered, and what each one leaves behind.
class _FakeClient extends ChatClient {
  String reply = 'Gulls, mostly.';
  Completer<void>? hold;
  int calls = 0;

  @override
  Stream<ChatDelta> streamChat({
    required Provider provider,
    required List<ChatMessage> history,
    GenParams params = const GenParams(),
  }) async* {
    calls++;
    yield ChatDelta(text: reply);
    final gate = hold;
    if (gate != null) await gate.future;
  }

  @override
  Future<List<String>> listModels(Provider provider) async => const ['m'];
}

void main() {
  late _FakeClient client;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    client = _FakeClient();
  });

  Future<AppState> boot({bool withReply = true}) async {
    final state = AppState(client: client);
    await state.init();
    await state.addProvider(Provider(
      id: 'p',
      name: 'local',
      kind: ProviderKind.openai,
      baseUrl: 'https://host.tld/v1',
      model: 'm',
      apiKey: 'k',
    ));
    final alice = Character(id: 'alice', name: 'Alice', description: 'Curious.');
    await state.addCharacter(alice);
    state.startChatWithCharacter(alice);
    state.active.messages.clear();
    if (withReply) {
      state.active.messages
        ..add(ChatMessage(role: 'user', content: 'Where are we?'))
        ..add(ChatMessage(role: 'assistant', content: 'The harbour at dawn'));
    }
    return state;
  }

  Widget host(AppState state) => ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: ChatScreen()),
      );

  Future<void> openStrip(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('composer-ops-button')));
    await tester.pumpAndSettle();
  }

  bool enabled(WidgetTester tester, String key) =>
      tester.widget<IconButton>(find.byKey(Key(key))).onPressed != null;

  testWidgets('the strip stays under the ⋯ button it opens from',
      (tester) async {
    // The composer's Column centres a child that shrink-wraps, so the strip has
    // to claim the full width and settle its own contents to the right. Centred
    // symbols would drift away from the button that opened them.
    final state = await boot();
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();
    await openStrip(tester);

    final width = tester.getSize(find.byType(MaterialApp)).width;
    final studio =
        tester.getRect(find.byKey(const Key('composer-imagegen-button')));
    final continues = tester.getRect(find.byKey(const Key('turn-continue')));

    expect(studio.center.dx, greaterThan(width / 2),
        reason: 'the symbols sit on the right, not in the middle');
    expect(width - studio.right, lessThan(32),
        reason: 'the strip is flush with the right of the composer, under the '
            'buttons it grew from');
    // One row, all of it: the three new symbols sit beside the tools rather than
    // stacking a second line of chips over the conversation.
    expect(continues.center.dy, moreOrLessEquals(studio.center.dy, epsilon: 1),
        reason: 'asking for a turn is on the same line as the tools');
    expect(continues.right, lessThanOrEqualTo(studio.left),
        reason: 'and to their left, so the tools keep their places');
  });

  testWidgets('every symbol in the strip carries its name for a long press',
      (tester) async {
    // The names are how continue / respond again / generate for me are told
    // apart, and a tooltip is where Material puts a name that would not fit.
    final state = await boot();
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();
    await openStrip(tester);

    for (final name in ['Continue', 'Respond again', 'Generate for me']) {
      expect(find.byTooltip(name), findsOneWidget, reason: name);
    }

    // And a long press actually shows one, rather than it being decoration.
    await tester.longPress(find.byKey(const Key('turn-respond-again')));
    await tester.pumpAndSettle();
    expect(find.text('Respond again'), findsOneWidget);
  });

  testWidgets('a narrow phone with every symbol switched on still fits them',
      (tester) async {
    // Seven 48dp targets do not fit across a small screen, and a Row that
    // overflows clips whatever hangs off the end — silently, in a release build.
    // The strip slides instead, anchored right so the tools stay put.
    tester.view.physicalSize = const Size(320 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final state = await boot();
    await state.updateChatInterface(
        const ChatInterface(groupChatsEnabled: true));
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();
    await openStrip(tester);

    // Laid out without an overflow (which would fail this test on its own), all
    // on one line, with the group symbol flush right where it has always been.
    final group = tester.getRect(find.byKey(const Key('composer-group-button')));
    final continues = tester.getRect(find.byKey(const Key('turn-continue')));
    final studio =
        tester.getRect(find.byKey(const Key('composer-imagegen-button')));
    expect(group.height, greaterThanOrEqualTo(48),
        reason: 'full touch targets kept, rather than squeezed to fit');
    expect(continues.height, group.height);
    for (final rect in [continues, studio]) {
      expect(rect.center.dy, moreOrLessEquals(group.center.dy, epsilon: 1),
          reason: 'one row for the whole strip');
    }
    expect(320 - group.right, lessThan(32));
    expect(find.byType(SingleChildScrollView), findsWidgets,
        reason: 'seven full-size symbols are wider than a 320dp phone, so the '
            'strip slides rather than clipping the far end away');
  });

  testWidgets('the three actions live in the operations strip, and only there',
      (tester) async {
    final state = await boot();
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    // Nothing over the conversation until the strip is asked for.
    expect(find.byKey(const Key('turn-continue')), findsNothing);

    await openStrip(tester);
    expect(find.byKey(const Key('turn-continue')), findsOneWidget);
    expect(find.byKey(const Key('turn-respond-again')), findsOneWidget);
    expect(find.byKey(const Key('turn-write-for-me')), findsOneWidget);
  });

  testWidgets('an empty chat offers only the one that makes sense there',
      (tester) async {
    final state = await boot(withReply: false);
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();
    await openStrip(tester);

    expect(enabled(tester, 'turn-continue'), isFalse,
        reason: 'there is no reply to carry on from');
    expect(enabled(tester, 'turn-respond-again'), isFalse,
        reason: 'there is nothing to respond to');
    expect(enabled(tester, 'turn-write-for-me'), isTrue,
        reason: 'the model can still write the opening line');
  });

  testWidgets('with a reply on screen, continue and respond again are live',
      (tester) async {
    final state = await boot();
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();
    await openStrip(tester);

    expect(enabled(tester, 'turn-continue'), isTrue);
    expect(enabled(tester, 'turn-respond-again'), isTrue);
  });

  testWidgets('continue lengthens the reply that is already there',
      (tester) async {
    final state = await boot();
    client.reply = ', gulls everywhere.';
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();
    await openStrip(tester);

    await tester.tap(find.byKey(const Key('turn-continue')));
    await tester.pumpAndSettle();

    expect(state.active.messages, hasLength(2));
    expect(find.textContaining('The harbour at dawn, gulls everywhere.'),
        findsOneWidget);
    // The strip put itself away so the thread has the room.
    expect(find.byKey(const Key('turn-continue')), findsNothing);
  });

  testWidgets('respond again adds a reply and nothing of the user\'s',
      (tester) async {
    final state = await boot();
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();
    await openStrip(tester);

    await tester.tap(find.byKey(const Key('turn-respond-again')));
    await tester.pumpAndSettle();

    expect(state.active.messages, hasLength(3));
    expect(state.active.messages.last.content, 'Gulls, mostly.');
    expect(state.active.messages.where((m) => m.isUser), hasLength(1));
  });

  testWidgets('generate for me fills the composer instead of the chat',
      (tester) async {
    final state = await boot();
    client.reply = 'Same as ever, then.';
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();
    await openStrip(tester);

    await tester.tap(find.byKey(const Key('turn-write-for-me')));
    await tester.pumpAndSettle();

    // In the box, ready to edit or send — and the transcript is untouched.
    final field = tester.widget<TextField>(find.byType(TextField).first);
    expect(field.controller!.text, 'Same as ever, then.');
    expect(state.active.messages, hasLength(2));
    // Which means Send is live now, with nothing typed by hand.
    expect(
      tester
          .widget<IconButton>(find.ancestor(
            of: find.byIcon(Icons.arrow_upward),
            matching: find.byType(IconButton),
          ))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('none of them can be started while a reply is in flight',
      (tester) async {
    final state = await boot();
    client.hold = Completer<void>();
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();
    await openStrip(tester);

    await tester.tap(find.byKey(const Key('turn-respond-again')));
    // Long enough for the request to go out, short of the held stream ending.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(state.streaming, isTrue);
    await openStrip(tester);
    expect(enabled(tester, 'turn-continue'), isFalse);
    expect(enabled(tester, 'turn-respond-again'), isFalse);
    expect(enabled(tester, 'turn-write-for-me'), isFalse);
    expect(client.calls, 1);

    client.hold!.complete();
    await tester.pumpAndSettle();
  });
}
