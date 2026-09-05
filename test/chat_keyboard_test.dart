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

/// What the soft keyboard costs the chat.
///
/// Tapping into the message box and leaving it again felt grainy, and the reason
/// was not the keyboard: the screen read the status-bar inset from
/// `MediaQuery.padding`, which *shrinks as the keyboard rises* (it is viewPadding
/// minus the keyboard's insets). So every frame of the keyboard's animation
/// rebuilt the whole chat — the thread, the composer, the drawer — where the
/// keyboard only ever needed to relayout it. Reading `viewPadding` instead, which
/// the keyboard does not move, leaves those subtrees untouched.
class _FakeClient extends ChatClient {
  @override
  Stream<ChatDelta> streamChat({
    required Provider provider,
    required List<ChatMessage> history,
    GenParams params = const GenParams(),
  }) async* {
    yield const ChatDelta(text: 'Gulls, mostly.');
  }

  @override
  Future<List<String>> listModels(Provider provider) async => const ['m'];
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Future<AppState> boot() async {
    final state = AppState(client: _FakeClient());
    await state.init();
    await state.addProvider(Provider(
      id: 'p',
      name: 'local',
      kind: ProviderKind.openai,
      baseUrl: 'https://host.tld/v1',
      model: 'm',
      apiKey: 'k',
    ));
    final alice = Character(id: 'alice', name: 'Alice');
    await state.addCharacter(alice);
    state.startChatWithCharacter(alice);
    state.active.messages
      ..clear()
      ..add(ChatMessage(role: 'user', content: 'Where are we?'))
      ..add(ChatMessage(role: 'assistant', content: 'Gulls, mostly.'));
    return state;
  }

  testWidgets('the keyboard rising relayouts the chat without rebuilding it',
      (tester) async {
    final state = await boot();
    // A device with a bottom inset of its own, so `padding` has something to lose
    // when the keyboard covers it — which is the whole trap being guarded.
    final dpr = tester.view.devicePixelRatio;
    tester.view.padding = FakeViewPadding(bottom: 32 * dpr, top: 24 * dpr);
    tester.view.viewPadding = FakeViewPadding(bottom: 32 * dpr, top: 24 * dpr);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const MaterialApp(home: ChatScreen()),
    ));
    await tester.pumpAndSettle();

    final composerField = find.byKey(const Key('composer-field'));
    final before = tester.widget<TextField>(composerField);
    final threadBefore = tester.widget<ListView>(find.byType(ListView));
    final composerTopBefore = tester.getTopLeft(composerField).dy;

    // The keyboard: an inset that eats the bottom padding as it rises.
    tester.view.viewInsets = FakeViewPadding(bottom: 300 * dpr);
    tester.view.padding = FakeViewPadding(top: 24 * dpr);
    await tester.pump();

    // Same widget objects: the composer and the thread were handed back
    // untouched, so nothing under them was rebuilt.
    expect(identical(tester.widget<TextField>(composerField), before), isTrue,
        reason: 'the composer was rebuilt on a keyboard frame');
    expect(identical(tester.widget<ListView>(find.byType(ListView)),
            threadBefore),
        isTrue,
        reason: 'the thread was rebuilt on a keyboard frame');
    // And it did what a keyboard is supposed to do.
    expect(tester.getTopLeft(composerField).dy,
        lessThan(composerTopBefore - 200),
        reason: 'the composer still rides up with the keyboard');
  });

  /// The other half of the same cost, and the bigger one.
  ///
  /// Not rebuilding the thread is not enough on its own: letting the Scaffold
  /// shrink the body still *lays the list out again* on every frame of the
  /// keyboard's animation, and a list that has been laid out again has to be
  /// painted again — a screenful of markdown, HTML and selectable text, fifteen
  /// times on the way up. So the keyboard no longer resizes this screen at all: the
  /// thread and the composer are slid, which the compositor does for free.
  testWidgets('the keyboard slides the chat rather than relaying it out',
      (tester) async {
    final state = await boot();
    final dpr = tester.view.devicePixelRatio;
    tester.view.padding = FakeViewPadding(bottom: 32 * dpr, top: 24 * dpr);
    tester.view.viewPadding = FakeViewPadding(bottom: 32 * dpr, top: 24 * dpr);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const MaterialApp(home: ChatScreen()),
    ));
    await tester.pumpAndSettle();

    final thread = find.byType(ListView);
    final composerField = find.byKey(const Key('composer-field'));
    final threadHeight = tester.getSize(thread).height;
    final threadTop = tester.getTopLeft(thread).dy;
    final offset = tester.widget<ListView>(thread).controller!.position.pixels;
    final composerBottom = tester.getBottomLeft(composerField).dy;

    tester.view.viewInsets = FakeViewPadding(bottom: 300 * dpr);
    tester.view.padding = FakeViewPadding(top: 24 * dpr);
    await tester.pump();

    // The viewport is the size it was, and the reader is exactly where they were.
    expect(tester.getSize(thread).height, threadHeight,
        reason: 'the thread was resized by the keyboard');
    expect(tester.widget<ListView>(thread).controller!.position.pixels, offset,
        reason: 'the keyboard moved the reader');

    // What moved is the whole column, by the keyboard's height less the
    // navigation bar it covers on the way up.
    final lift = composerBottom - tester.getBottomLeft(composerField).dy;
    expect(lift, moreOrLessEquals(300 - 32, epsilon: 0.5));
    expect(tester.getTopLeft(thread).dy, moreOrLessEquals(threadTop - lift,
        epsilon: 0.5));
    // Which leaves the composer sitting on the keyboard, not under it.
    expect(tester.getBottomLeft(composerField).dy,
        lessThanOrEqualTo(tester.view.physicalSize.height / dpr - 300 + 0.5));
  });
}
