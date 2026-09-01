import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/chat_interface.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/screens/chat_screen.dart';
import 'package:maichat/services/chat_client.dart';
import 'package:maichat/state/app_state.dart';
import 'package:maichat/widgets/message_bubble.dart';
import 'package:provider/provider.dart' hide Provider;
import 'package:shared_preferences/shared_preferences.dart';

/// Replies with a different text on each call, so a regeneration is
/// distinguishable from the reply it was generated beside.
class _SequenceClient extends ChatClient {
  _SequenceClient(this.replies);

  final List<String> replies;
  int calls = 0;
  List<ChatMessage>? lastHistory;

  @override
  Stream<ChatDelta> streamChat({
    required Provider provider,
    required List<ChatMessage> history,
    GenParams params = const GenParams(),
  }) async* {
    lastHistory = List<ChatMessage>.from(history);
    final reply = replies[calls.clamp(0, replies.length - 1)];
    calls++;
    yield ChatDelta(text: reply);
  }
}

/// Runs [onStream] from inside the stream (so the caller can stop mid-flight),
/// then fails the way a cancelled request does.
class _AbortClient extends ChatClient {
  _AbortClient(this.onStream);

  final void Function() onStream;

  @override
  Stream<ChatDelta> streamChat({
    required Provider provider,
    required List<ChatMessage> history,
    GenParams params = const GenParams(),
  }) async* {
    onStream();
    throw ChatApiException('cancelled');
  }
}

Provider _provider() => Provider(
      id: 'p',
      name: 'Test',
      kind: ProviderKind.openai,
      baseUrl: 'https://host.tld/v1',
      apiKey: '',
      model: 'm',
    );

Future<AppState> _state(ChatClient client) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final state = AppState(client: client);
  await state.init();
  await state.addProvider(_provider());
  return state;
}

void main() {
  group('ChatMessage swipes', () {
    test('a plainly built turn holds exactly one swipe', () {
      final m = ChatMessage(role: 'assistant', content: 'one');
      expect(m.swipeCount, 1);
      expect(m.hasSwipes, isFalse);
      expect(m.swipeIndex, 0);
      expect(m.content, 'one');
    });

    test('addSwipe appends the alternative and selects it', () {
      final m = ChatMessage(role: 'assistant', content: 'first')
          .addSwipe(const MessageVariant(content: 'second'));
      expect(m.swipeCount, 2);
      expect(m.swipeIndex, 1);
      expect(m.content, 'second');
      expect(m.hasSwipes, isTrue);
    });

    test('withSwipe selects an existing alternative; bad indices are no-ops',
        () {
      final m = ChatMessage(role: 'assistant', content: 'first')
          .addSwipe(const MessageVariant(content: 'second'));
      expect(m.withSwipe(0).content, 'first');
      // The other variant is still there, and still selectable.
      expect(m.withSwipe(0).withSwipe(1).content, 'second');
      expect(m.withSwipe(9).swipeIndex, 1);
      expect(m.withSwipe(-1).swipeIndex, 1);
    });

    test('copyWith edits only the live variant', () {
      final m = ChatMessage(role: 'assistant', content: 'first')
          .addSwipe(const MessageVariant(content: 'second'))
          .copyWith(content: 'edited');
      expect(m.content, 'edited');
      expect(m.swipes.first.content, 'first');
      expect(m.swipeCount, 2);
    });

    test('reasoning and thinking time are per swipe', () {
      final m = ChatMessage(
        role: 'assistant',
        content: 'plain',
      ).addSwipe(
          const MessageVariant(content: 'thought about', reasoning: 'hmm', thinkingMs: 1200));
      expect(m.hasReasoning, isTrue);
      expect(m.thinkingMs, 1200);
      final back = m.withSwipe(0);
      expect(back.hasReasoning, isFalse);
      expect(back.thinkingMs, isNull);
    });

    test('removeSwipe drops the live variant and steps back', () {
      final m = ChatMessage(role: 'assistant', content: 'first')
          .addSwipe(const MessageVariant(content: 'second'));
      final rolled = m.removeSwipe(m.swipeIndex);
      expect(rolled.swipeCount, 1);
      expect(rolled.content, 'first');
      // A turn always keeps at least one variant.
      expect(rolled.removeSwipe(0).swipeCount, 1);
    });

    test('json round-trips the swipes and keeps the live text readable flat',
        () {
      final m = ChatMessage(role: 'assistant', content: 'first')
          .addSwipe(const MessageVariant(content: 'second', reasoning: 'why'));
      final json = m.toJson();
      expect(json['content'], 'second');
      expect(json['swipeIndex'], 1);
      expect((json['swipes'] as List), hasLength(2));

      final back = ChatMessage.fromJson(json);
      expect(back.swipeCount, 2);
      expect(back.content, 'second');
      expect(back.reasoning, 'why');
      expect(back.withSwipe(0).content, 'first');
    });

    test('a single-swipe turn writes no swipe keys at all', () {
      final json = ChatMessage(role: 'user', content: 'hi').toJson();
      expect(json.containsKey('swipes'), isFalse);
      expect(json.containsKey('swipeIndex'), isFalse);
    });

    test('a stored turn from before swipes reads as one variant', () {
      final back = ChatMessage.fromJson(
          <String, dynamic>{'role': 'assistant', 'content': 'old'});
      expect(back.swipeCount, 1);
      expect(back.content, 'old');
    });

    test('the wire format carries the selected swipe', () {
      final m = ChatMessage(role: 'assistant', content: 'first')
          .addSwipe(const MessageVariant(content: 'second'));
      expect(m.toApi(), {'role': 'assistant', 'content': 'second'});
      expect(m.withSwipe(0).toApi(), {'role': 'assistant', 'content': 'first'});
    });
  });

  group('greeting swipes', () {
    Character card() => Character.empty()
      ..name = 'Ren'
      ..firstMes = 'Main greeting.'
      ..alternateGreetings = ['Alt one.', '  ', 'Alt two.'];

    test("a card's alternate greetings become the opening turn's swipes",
        () async {
      final state = await _state(_SequenceClient(['reply']));
      await state.addCharacter(card());
      state.startChatWithCharacter(state.characters.first);

      final opening = state.active.messages.single;
      expect(opening.role, 'assistant');
      // Blank alternates are dropped; card order is kept.
      expect(opening.swipes.map((s) => s.content).toList(),
          ['Main greeting.', 'Alt one.', 'Alt two.']);
      expect(opening.content, 'Main greeting.');
    });

    test('restarting a character chat re-seeds the greeting swipes', () async {
      final state = await _state(_SequenceClient(['reply']));
      await state.addCharacter(card());
      state.startChatWithCharacter(state.characters.first);
      await state.send('hello');
      await state.restartConversation();

      expect(state.active.messages.single.swipeCount, 3);
    });

    test('a chosen greeting is the one the model is sent', () async {
      final client = _SequenceClient(['reply']);
      final state = await _state(client);
      await state.addCharacter(card());
      state.startChatWithCharacter(state.characters.first);
      await state.setSwipe(state.active.id, 0, 2);
      expect(state.active.messages[0].content, 'Alt two.');

      await state.send('hi');
      final sent = client.lastHistory!.map((m) => m.content).join('\n');
      expect(sent, contains('Alt two.'));
      expect(sent, isNot(contains('Main greeting.')));
    });

    test('a card with no greetings opens an empty thread', () async {
      final state = await _state(_SequenceClient(['reply']));
      await state.addCharacter(Character.empty()..name = 'Blank');
      state.startChatWithCharacter(state.characters.first);
      expect(state.active.messages, isEmpty);
    });
  });

  group('regeneration keeps the old reply', () {
    test('the retry lands as a second swipe on the same turn', () async {
      final client = _SequenceClient(['first reply', 'second reply']);
      final state = await _state(client);
      await state.send('hi');
      expect(state.active.messages, hasLength(2));

      await state.regenerateMessage(state.active.id, 1);

      final turn = state.active.messages[1];
      expect(state.active.messages, hasLength(2), reason: 'still one turn');
      expect(turn.swipeCount, 2);
      expect(turn.swipeIndex, 1);
      expect(turn.content, 'second reply');
      expect(turn.withSwipe(0).content, 'first reply');
      // The reply being replaced is not part of its own prompt.
      final sent = client.lastHistory!;
      expect(sent.last.content, 'hi');
      expect(sent.every((m) => !m.content.contains('first reply')), isTrue);
    });

    test('swipes accumulate across repeated retries', () async {
      final client = _SequenceClient(['a', 'b', 'c']);
      final state = await _state(client);
      await state.send('hi');
      await state.regenerateMessage(state.active.id, 1);
      await state.regenerateMessage(state.active.id, 1);

      final turn = state.active.messages[1];
      expect(turn.swipes.map((s) => s.content).toList(), ['a', 'b', 'c']);
      expect(turn.content, 'c');
    });

    test('regenerating an earlier turn drops what followed it', () async {
      final client = _SequenceClient(['a', 'b', 'c']);
      final state = await _state(client);
      await state.send('one');
      await state.send('two');
      expect(state.active.messages, hasLength(4));

      await state.regenerateMessage(state.active.id, 1);

      expect(state.active.messages, hasLength(2));
      expect(state.active.messages[1].swipeCount, 2);
    });

    test('a user turn still cannot be regenerated', () async {
      final state = await _state(_SequenceClient(['a', 'b']));
      await state.send('hi');
      await state.regenerateMessage(state.active.id, 0);
      expect(state.active.messages, hasLength(2));
      expect(state.active.messages[0].swipeCount, 1);
    });

    test('a selected swipe is what the next request sends', () async {
      final client = _SequenceClient(['first reply', 'second reply']);
      final state = await _state(client);
      await state.send('hi');
      await state.regenerateMessage(state.active.id, 1);
      await state.setSwipe(state.active.id, 1, 0);
      expect(state.active.messages[1].content, 'first reply');

      await state.send('again');
      final sent = client.lastHistory!.map((m) => m.content).join('\n');
      expect(sent, contains('first reply'));
      expect(sent, isNot(contains('second reply')));
    });

    test('an aborted regeneration hands the turn back to the old reply',
        () async {
      late AppState state;
      state = await _state(_AbortClient(() => state.stop()));
      // Seed a reply without the network: the abort client fails every request.
      state.active.messages
        ..add(ChatMessage(role: 'user', content: 'hi'))
        ..add(ChatMessage(role: 'assistant', content: 'kept'));

      await state.regenerateMessage(state.active.id, 1);

      final turn = state.active.messages[1];
      expect(turn.swipeCount, 1);
      expect(turn.content, 'kept');
      expect(state.streaming, isFalse);
    });
  });

  group('the swipe control', () {
    Widget host(Widget child) => MaterialApp(
          home: Scaffold(body: SizedBox(width: 400, height: 600, child: child)),
        );

    IconButton buttonFor(WidgetTester tester, IconData icon) =>
        tester.widget<IconButton>(find.ancestor(
          of: find.byIcon(icon),
          matching: find.byType(IconButton),
        ));

    testWidgets('is absent when the turn has a single reply', (tester) async {
      await tester.pumpWidget(host(MessageBubble(
        message: ChatMessage(role: 'assistant', content: 'only one'),
        ui: const ChatInterface(),
        onSwipe: (_) {},
      )));
      expect(find.byIcon(Icons.chevron_left), findsNothing);
      expect(find.text('1 / 1'), findsNothing);
    });

    testWidgets('counts the alternatives and steps between them',
        (tester) async {
      var picked = -1;
      final message = ChatMessage(role: 'assistant', content: 'first')
          .addSwipe(const MessageVariant(content: 'second'))
          .withSwipe(0);
      await tester.pumpWidget(host(MessageBubble(
        message: message,
        ui: const ChatInterface(),
        onSwipe: (i) => picked = i,
      )));

      expect(find.text('1 / 2'), findsOneWidget);
      expect(find.text('first'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.chevron_right));
      expect(picked, 1);
    });

    testWidgets('the ends wrap round into a ring', (tester) async {
      var picked = -1;
      final three = ChatMessage(role: 'assistant', content: 'one')
          .addSwipe(const MessageVariant(content: 'two'))
          .addSwipe(const MessageVariant(content: 'three'));
      // Sitting on the last of three: forward comes back to the first.
      await tester.pumpWidget(host(MessageBubble(
        message: three,
        ui: const ChatInterface(),
        onSwipe: (i) => picked = i,
      )));
      expect(find.text('3 / 3'), findsOneWidget);
      expect(buttonFor(tester, Icons.chevron_right).onPressed, isNotNull);
      await tester.tap(find.byIcon(Icons.chevron_right));
      expect(picked, 0);

      // And back from the first goes to the last.
      await tester.pumpWidget(host(MessageBubble(
        message: three.withSwipe(0),
        ui: const ChatInterface(),
        onSwipe: (i) => picked = i,
      )));
      expect(find.text('1 / 3'), findsOneWidget);
      expect(buttonFor(tester, Icons.chevron_left).onPressed, isNotNull);
      await tester.tap(find.byIcon(Icons.chevron_left));
      expect(picked, 2);
    });

    testWidgets('is inert while a reply is streaming', (tester) async {
      await tester.pumpWidget(host(MessageBubble(
        message: ChatMessage(role: 'assistant', content: 'first')
            .addSwipe(const MessageVariant(content: 'second')),
        ui: const ChatInterface(),
        streaming: true,
        onSwipe: (_) {},
      )));
      expect(buttonFor(tester, Icons.chevron_left).onPressed, isNull);
      expect(buttonFor(tester, Icons.chevron_right).onPressed, isNull);
    });

    testWidgets('lays out in every text placement and bubble mode',
        (tester) async {
      for (final placement in TextPlacement.values) {
        for (final bubbles in [true, false]) {
          await tester.pumpWidget(host(ListView(
            children: [
              MessageBubble(
                message: ChatMessage(role: 'assistant', content: 'first')
                    .addSwipe(const MessageVariant(content: 'second')),
                ui: ChatInterface(textPlacement: placement, bubbles: bubbles),
                onSwipe: (_) {},
              ),
            ],
          )));
          expect(tester.takeException(), isNull);
          expect(find.text('2 / 2'), findsOneWidget);
        }
      }
    });
  });

  group('swiping the turn itself', () {
    Widget host(Widget child) => MaterialApp(
          home: Scaffold(body: SizedBox(width: 400, height: 600, child: child)),
        );

    ChatMessage three() => ChatMessage(role: 'assistant', content: 'one')
        .addSwipe(const MessageVariant(content: 'two'))
        .addSwipe(const MessageVariant(content: 'three'))
        .withSwipe(1);

    /// Drags across the turn's **words** — the place a reader's finger actually
    /// lands, and the place where the text's own selection gestures live to
    /// compete with. Anywhere else risks landing on the ‹ 1/2 › arrows, where a
    /// short drag is simply a tap.
    Future<int?> dragBy(WidgetTester tester, Offset by,
        {ChatMessage? message,
        String on = 'two',
        bool streaming = false,
        bool editing = false,
        ChatInterface ui = const ChatInterface()}) async {
      int? picked;
      await tester.pumpWidget(host(MessageBubble(
        message: message ?? three(),
        ui: ui,
        streaming: streaming,
        editing: editing,
        editController: editing ? TextEditingController(text: 'two') : null,
        onSwipe: (i) => picked = i,
      )));
      await tester.drag(find.text(on), by);
      await tester.pumpAndSettle();
      return picked;
    }

    testWidgets('a drag to the left takes the next alternative',
        (tester) async {
      expect(await dragBy(tester, const Offset(-120, 0)), 2);
    });

    testWidgets('a drag to the right takes the previous one', (tester) async {
      expect(await dragBy(tester, const Offset(120, 0)), 0);
    });

    testWidgets('it wraps at both ends, like the arrows', (tester) async {
      expect(
          await dragBy(tester, const Offset(-120, 0),
              message: three().withSwipe(2), on: 'three'),
          0,
          reason: 'forward off the end comes back to the first');
      expect(
          await dragBy(tester, const Offset(120, 0),
              message: three().withSwipe(0), on: 'one'),
          2,
          reason: 'back off the start goes to the last');
    });

    testWidgets('a small nudge changes nothing', (tester) async {
      expect(await dragBy(tester, const Offset(-12, 0)), isNull);
    });

    testWidgets('a vertical drag is left to the thread', (tester) async {
      expect(await dragBy(tester, const Offset(0, -160)), isNull);
    });

    testWidgets('a turn with one reply has nothing to swipe', (tester) async {
      expect(
          await dragBy(tester, const Offset(-120, 0),
              message: ChatMessage(role: 'assistant', content: 'only'),
              on: 'only'),
          isNull);
    });

    testWidgets('nothing swipes while a reply streams in', (tester) async {
      expect(await dragBy(tester, const Offset(-120, 0), streaming: true),
          isNull);
    });

    testWidgets('nothing swipes while the turn is being edited',
        (tester) async {
      expect(
          await dragBy(tester, const Offset(-120, 0), editing: true), isNull);
    });

    testWidgets('the turn follows the finger and settles back', (tester) async {
      await tester.pumpWidget(host(MessageBubble(
        message: three(),
        ui: const ChatInterface(),
        onSwipe: (_) {},
      )));
      final home = tester.getTopLeft(find.text('two'));

      final gesture = await tester.startGesture(tester.getCenter(find.text('two')));
      await gesture.moveBy(const Offset(-60, 0));
      await tester.pump();
      final held = tester.getTopLeft(find.text('two'));
      expect(held.dx, lessThan(home.dx), reason: 'the turn is pulled along');
      expect(home.dx - held.dx, lessThan(60),
          reason: 'with resistance, never as far as the finger');
      expect(held.dy, home.dy, reason: 'and never up or down');

      await gesture.up();
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('two')).dx, home.dx,
          reason: 'and eases home once let go');
    });

    testWidgets('a drag never scrolls the thread out from under itself',
        (tester) async {
      var picked = -1;
      final controller = ScrollController();
      await tester.pumpWidget(host(ListView(
        controller: controller,
        reverse: true,
        children: [
          for (var i = 0; i < 12; i++)
            MessageBubble(
              message: three(),
              ui: const ChatInterface(),
              onSwipe: (v) => picked = v,
            ),
        ],
      )));
      await tester.drag(find.text('two').first, const Offset(-120, 0));
      await tester.pumpAndSettle();
      expect(picked, 2);
      expect(controller.position.pixels, 0);
    });

    testWidgets('the thread still scrolls when dragged up the words',
        (tester) async {
      var picked = -1;
      final controller = ScrollController();
      await tester.pumpWidget(host(ListView(
        controller: controller,
        reverse: true,
        children: [
          for (var i = 0; i < 12; i++)
            MessageBubble(
              message: three(),
              ui: const ChatInterface(),
              onSwipe: (v) => picked = v,
            ),
        ],
      )));
      await tester.drag(find.text('two').first, const Offset(0, 220));
      await tester.pumpAndSettle();
      expect(controller.position.pixels, greaterThan(0),
          reason: 'the sheet over each turn takes sideways drags only');
      expect(picked, -1);
    });

    testWidgets('a long press on the words still belongs to the text',
        (tester) async {
      var sheetOpened = false;
      await tester.pumpWidget(host(MessageBubble(
        message: three(),
        ui: const ChatInterface(),
        onSwipe: (_) {},
        onLongPress: () => sheetOpened = true,
      )));
      await tester.longPress(find.text('two'));
      await tester.pumpAndSettle();
      // The selectable text's own long press still wins it — the sheet over the
      // turn claims sideways drags and nothing else.
      expect(sheetOpened, isFalse);
    });
  });

  group('swiping a turn in the real chat', () {
    testWidgets('a drag across the reply picks the next alternative',
        (tester) async {
      final state = await _state(_SequenceClient(['reply']));
      final alice = Character(id: 'alice', name: 'Alice');
      await state.addCharacter(alice);
      state.startChatWithCharacter(alice);
      // Seeded rather than sent: a reply's paint cadence never ticks inside a
      // widget test, so awaiting send() would hang.
      state.active.messages
        ..clear()
        ..add(ChatMessage(role: 'user', content: 'Which birds?'))
        ..add(ChatMessage(role: 'assistant', content: 'Gulls, mostly.')
            .addSwipe(const MessageVariant(content: 'Terns, mostly.'))
            .withSwipe(0));

      await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: ChatScreen()),
      ));
      await tester.pumpAndSettle();
      expect(find.text('1 / 2'), findsOneWidget);

      await tester.drag(find.text('Gulls, mostly.'), const Offset(-120, 0));
      await tester.pumpAndSettle();

      expect(state.active.messages[1].swipeIndex, 1);
      expect(find.text('Terns, mostly.'), findsOneWidget);
      expect(find.text('2 / 2'), findsOneWidget);

      // And round the ring, back to the first.
      await tester.drag(find.text('Terns, mostly.'), const Offset(-120, 0));
      await tester.pumpAndSettle();
      expect(state.active.messages[1].swipeIndex, 0);

      // The store is written a beat later, off the frame that showed the swap —
      // let that land rather than leaving a timer behind.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
    });
  });
}
