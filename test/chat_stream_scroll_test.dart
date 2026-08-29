import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/screens/chat_screen.dart';
import 'package:maichat/services/chat_client.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart' hide Provider;
import 'package:shared_preferences/shared_preferences.dart';

/// Reading back through a chat *while a reply is streaming*.
///
/// The thread is a reversed list: its newest turn is anchored to the bottom and
/// every older message is positioned relative to it, so a turn that grows by a
/// line moves the whole conversation above it by a line. At twenty tokens a
/// second that is a page that will not hold still — and the follow-the-bottom
/// snap used to fire on every repaint, which cancels a drag outright (`jumpTo`
/// goes through `goIdle`). Both are covered here, against the real chat screen.
class _ManualClient extends ChatClient {
  final StreamController<ChatDelta> deltas =
      StreamController<ChatDelta>.broadcast();

  @override
  Stream<ChatDelta> streamChat({
    required Provider provider,
    required List<ChatMessage> history,
    GenParams params = const GenParams(),
  }) =>
      deltas.stream;

  @override
  Future<List<String>> listModels(Provider provider) async => const ['m'];
}

void main() {
  late _ManualClient client;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    client = _ManualClient();
  });
  tearDown(() => client.deltas.close());

  Future<AppState> longChat({int turns = 80}) async {
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
    final character = Character.empty()..name = 'Aria';
    await state.addCharacter(character);
    state.startChatWithCharacter(character);
    for (var i = 0; i < turns; i++) {
      state.active.messages.add(ChatMessage(
        role: i.isEven ? 'user' : 'assistant',
        content: 'Message number $i in a long conversation.',
      ));
    }
    return state;
  }

  Widget host(AppState state) => ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: ChatScreen()),
      );

  ScrollPosition scroll(WidgetTester tester) =>
      tester.widget<ListView>(find.byType(ListView).first).controller!.position;

  /// Pushes one chunk of the reply and lets the screen repaint.
  ///
  /// The repaint cadence is measured on a real [Stopwatch] (it is about the
  /// device's frames, not about anything the test controls), so the wait has to
  /// be real time rather than pumped fake time.
  Future<void> streamIn(WidgetTester tester, String text) async {
    client.deltas.add(ChatDelta(text: text));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump();
  }

  /// Starts a send without waiting for it to finish — the reply is pushed by hand.
  Future<void> beginReply(WidgetTester tester, AppState state) async {
    unawaited(state.send('tell me a long story'));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('a reader scrolled back is not moved by the reply being written',
      (tester) async {
    final state = await longChat();
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    await beginReply(tester, state);
    // Well back into older turns: following stops, and the reply is out of sight.
    scroll(tester).jumpTo(1200);
    await tester.pump();
    final wasAt = scroll(tester).pixels;
    final extentWas = scroll(tester).maxScrollExtent;
    // A message that is on screen right now, and where it sits.
    final anchor = find.textContaining('Message number').first;
    final anchorWas = tester.getTopLeft(anchor);

    for (final chunk in [
      'Once upon a time there was a lighthouse keeper. ',
      'Every evening she climbed the stair with a lamp. ',
      'The gulls knew her by name, and she knew theirs. ',
      'One winter the light failed, and the village noticed. ',
    ]) {
      await streamIn(tester, chunk);
    }

    // Nothing moved: not the offset, not the thread's extent, and not the
    // message the reader was actually looking at.
    expect(scroll(tester).pixels, moreOrLessEquals(wasAt, epsilon: 0.5));
    expect(scroll(tester).maxScrollExtent,
        moreOrLessEquals(extentWas, epsilon: 0.5),
        reason: 'the turn being written must not change the thread\'s length '
            'while the reader is away from it');
    expect(tester.getTopLeft(anchor), anchorWas);

    // The button says a reply is coming rather than letting a held turn read as
    // a stalled one.
    expect(
      find.byTooltip('A reply is coming in — jump to it'),
      findsOneWidget,
    );
  });

  testWidgets('coming back to the bottom catches the reply up in full',
      (tester) async {
    final state = await longChat();
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    await beginReply(tester, state);
    scroll(tester).jumpTo(1200);
    await tester.pump();
    await streamIn(tester, 'The lighthouse keeper had a lamp. ');
    await streamIn(tester, 'It went out one winter. ');

    // Held still while away…
    expect(state.active.messages.last.content,
        'The lighthouse keeper had a lamp. It went out one winter. ');

    await tester.tap(find.byIcon(Icons.arrow_downward));
    await tester.pumpAndSettle();

    // …and the whole reply is on screen on return.
    expect(scroll(tester).pixels, moreOrLessEquals(0, epsilon: 1));
    expect(find.textContaining('It went out one winter'), findsOneWidget);
  });

  testWidgets('a reader at the bottom still follows the reply', (tester) async {
    final state = await longChat();
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    await beginReply(tester, state);
    await streamIn(tester, 'A short answer. ');
    await streamIn(tester, 'And a little more of it.');

    // A reversed list anchored at offset 0 keeps the newest text against the
    // bottom of the viewport on its own — no scrolling required.
    expect(scroll(tester).pixels, moreOrLessEquals(0, epsilon: 1));
    expect(find.textContaining('And a little more of it'), findsOneWidget);
  });

  testWidgets('a drag started near the bottom survives the reply arriving',
      (tester) async {
    // The regression: inside the stick threshold the screen snapped to the newest
    // message on every repaint, and `jumpTo` ends whatever activity the position
    // is running — so the first pixels of a scroll-back were eaten, over and
    // over, for as long as tokens kept coming.
    final state = await longChat();
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();
    await beginReply(tester, state);

    // Start just off the bottom, still inside the band where the thread follows
    // the reply — which is precisely where the snap used to fight the finger.
    scroll(tester).jumpTo(20);
    await tester.pump();

    final list = find.byType(ListView).first;
    final gesture = await tester.startGesture(tester.getCenter(list));
    // Small pulls: the first two are eaten by touch slop, as on a real screen.
    for (var i = 0; i < 4; i++) {
      await gesture.moveBy(const Offset(0, 10));
      await tester.pump();
    }
    final held = scroll(tester).pixels;
    expect(held, greaterThan(20), reason: 'the finger has moved the thread');
    expect(held, lessThan(48),
        reason: 'and it is still inside the follow-the-reply band');

    // Tokens land mid-drag.
    await streamIn(tester, 'chunk one ');
    await streamIn(tester, 'chunk two ');
    expect(scroll(tester).pixels, moreOrLessEquals(held, epsilon: 0.5),
        reason: 'a repaint must not snap the thread out from under the finger');

    // And the finger is still driving the list.
    await gesture.moveBy(const Offset(0, 15));
    await tester.pump();
    expect(scroll(tester).pixels, greaterThan(held),
        reason: 'the drag must still be delivered after a repaint');
    await gesture.up();
    await tester.pumpAndSettle();
  });
}
