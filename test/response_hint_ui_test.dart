import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/chat_interface.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/screens/chat_screen.dart';
import 'package:maichat/screens/settings/chat_behaviour_page.dart';
import 'package:maichat/services/avatar_store.dart';
import 'package:maichat/services/chat_client.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart' hide Provider;
import 'package:shared_preferences/shared_preferences.dart';

/// The response hint, driven through the real composer: the symbol in the
/// operations strip, the box it opens above that strip, what the ✕ does (and
/// pointedly does not do), and the switch in Chat Interface settings that offers
/// the whole thing.
class _FakeClient extends ChatClient {
  List<ChatMessage>? lastHistory;

  @override
  Stream<ChatDelta> streamChat({
    required Provider provider,
    required List<ChatMessage> history,
    GenParams params = const GenParams(),
  }) async* {
    lastHistory = List<ChatMessage>.from(history);
    yield const ChatDelta(text: 'Very well.');
  }

  @override
  Future<List<String>> listModels(Provider provider) async => const ['m'];
}

void main() {
  late Directory dir;
  late _FakeClient client;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    dir = Directory.systemTemp.createTempSync('hint-ui');
    client = _FakeClient();
  });
  tearDown(() {
    dir.deleteSync(recursive: true);
    avatarDirectory = null;
  });

  Future<AppState> boot({bool hints = true}) async {
    final state = AppState(client: client, avatars: AvatarStore(dir));
    await state.init();
    await state.addProvider(Provider(
      id: 'p',
      name: 'local',
      kind: ProviderKind.openai,
      baseUrl: 'https://host.tld/v1',
      model: 'm',
      apiKey: 'k',
    ));
    if (hints) {
      await state.updateChatInterface(
          state.chatInterface.copyWith(responseHintEnabled: true));
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

  Future<void> openBox(WidgetTester tester) async {
    await openStrip(tester);
    await tester.tap(find.byKey(const Key('composer-hint-button')));
    await tester.pumpAndSettle();
  }

  testWidgets('with the feature off, the strip offers no hint at all',
      (tester) async {
    final state = await boot(hints: false);
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    await openStrip(tester);
    expect(find.byKey(const Key('composer-hint-button')), findsNothing);
    expect(find.byKey(const Key('hint-box')), findsNothing);
  });

  testWidgets('the box opens above the operations strip, and not before it is '
      'asked for', (tester) async {
    final state = await boot();
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    // Nothing over the conversation until it is opened.
    expect(find.byKey(const Key('hint-box')), findsNothing);

    await openBox(tester);
    expect(find.byKey(const Key('hint-box')), findsOneWidget);
    expect(find.byKey(const Key('hint-field')), findsOneWidget);

    // Above the row of symbols it was opened from — the whole box, not just its
    // top edge.
    final boxBottom = tester.getBottomLeft(find.byKey(const Key('hint-box'))).dy;
    final stripTop = tester
        .getTopLeft(find.byKey(const Key('composer-image-button')))
        .dy;
    expect(boxBottom, lessThanOrEqualTo(stripTop));
  });

  testWidgets('the box is an outlined prompt over the chat, nothing more',
      (tester) async {
    // Asked for twice: a plain prompt box. No heading, no symbol inside it, no
    // tinted card of its own — the outline is the box, and behind it is the same
    // background the rest of the chat has.
    final state = await boot();
    await state.updateChatInterface(
        state.chatInterface.copyWith(responseHintDepth: 2));
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();
    await openBox(tester);

    final box = find.byKey(const Key('hint-box'));
    expect(tester.widget<Container>(box).decoration, isNull,
        reason: 'no fill and no frame of its own');
    expect(
        find.descendant(
            of: box, matching: find.byIcon(Icons.tips_and_updates_outlined)),
        findsNothing,
        reason: 'the symbol belongs in the strip, not in the box');
    expect(find.descendant(of: box, matching: find.text('Response hint')),
        findsNothing);

    final field = tester.widget<TextField>(find.byKey(const Key('hint-field')));
    expect(field.decoration?.border, isA<OutlineInputBorder>());
    // Where it lands, in as few words as it takes.
    expect(field.decoration?.helperText, '2 messages back');
    expect(find.text('2 messages back'), findsOneWidget);
    // And the one control it has is still there.
    expect(find.byKey(const Key('hint-close')), findsOneWidget);
  });

  testWidgets('the ✕ closes the box and keeps the hint', (tester) async {
    final state = await boot();
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    await openBox(tester);
    await tester.enterText(
        find.byKey(const Key('hint-field')), 'she is lying');
    await tester.pumpAndSettle();
    expect(state.responseHint(state.active.id), 'she is lying');

    await tester.tap(find.byKey(const Key('hint-close')));
    await tester.pumpAndSettle();

    // Closed, but nothing was cancelled: the hint is still in force and the
    // symbol is lit to say so.
    expect(find.byKey(const Key('hint-box')), findsNothing);
    expect(state.responseHint(state.active.id), 'she is lying');
    expect(find.byIcon(Icons.tips_and_updates), findsOneWidget);

    // Re-opening brings the text back rather than a blank box.
    await tester.tap(find.byKey(const Key('composer-hint-button')));
    await tester.pumpAndSettle();
    expect(find.text('she is lying'), findsOneWidget);
  });

  testWidgets('erasing the hint by hand unlights the symbol', (tester) async {
    final state = await boot();
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    await openBox(tester);
    await tester.enterText(find.byKey(const Key('hint-field')), 'be brief');
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.tips_and_updates), findsOneWidget);

    await tester.enterText(find.byKey(const Key('hint-field')), '');
    await tester.pumpAndSettle();
    expect(state.responseHint(state.active.id), isEmpty);
    expect(find.byIcon(Icons.tips_and_updates), findsNothing);
    expect(find.byIcon(Icons.tips_and_updates_outlined),
        findsWidgets, reason: 'the outlined symbol is still there to tap');
  });

  testWidgets('the hint goes out with the message and survives the send',
      (tester) async {
    final state = await boot();
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    await openBox(tester);
    await tester.enterText(
        find.byKey(const Key('hint-field')), 'HINT_TOKEN be brief');
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, 'hello');
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();

    final sent = client.lastHistory!.map((m) => m.content).join('\n');
    expect(sent, contains('HINT_TOKEN be brief'));
    // The turn itself is the message, not the hint.
    expect(state.active.messages.first.content, 'hello');
    expect(state.active.messages.first.content, isNot(contains('HINT_TOKEN')));
    // And the hint is still there, ready for the next reply.
    expect(state.responseHint(state.active.id), 'HINT_TOKEN be brief');
    expect(find.text('HINT_TOKEN be brief'), findsOneWidget);
  });

  testWidgets('switching chats swaps the hint over', (tester) async {
    final state = await boot();
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    await openBox(tester);
    await tester.enterText(find.byKey(const Key('hint-field')), 'first chat');
    await tester.pumpAndSettle();
    final first = state.active.id;

    // A message, so "new chat" makes a genuinely new one rather than reusing this
    // still-empty thread.
    await tester.enterText(find.byType(TextField).last, 'hello');
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();

    state.newConversation();
    await tester.pumpAndSettle();

    // A fresh chat starts with no steering of its own.
    expect(find.text('first chat'), findsNothing);
    expect(state.responseHint(state.active.id), isEmpty);

    await tester.enterText(find.byKey(const Key('hint-field')), 'second chat');
    await tester.pumpAndSettle();
    expect(state.responseHint(first), 'first chat');
    expect(state.responseHint(state.active.id), 'second chat');

    // Back again, and the first chat's hint is where it was left.
    state.selectConversation(first);
    await tester.pumpAndSettle();
    expect(find.text('first chat'), findsOneWidget);
  });

  // A response hint is an injection depth — a fact about the prompt rather than
  // about the screen — so the switch and the depth live in Chat behaviour, not
  // in Chat Interface, where they were also app-wide-only oddities.
  group('Chat behaviour settings', () {
    Widget settings(AppState state) => ChangeNotifierProvider<AppState>.value(
          value: state,
          child: const MaterialApp(home: ChatBehaviourPage()),
        );

    Future<void> reveal(WidgetTester tester, Finder target) async {
      await tester.scrollUntilVisible(target, 140,
          scrollable: find.byType(Scrollable).first);
      await tester.ensureVisible(target);
      await tester.pumpAndSettle();
    }

    testWidgets('the switch offers the feature and reveals the depth',
        (tester) async {
      final state = await boot(hints: false);
      await tester.pumpWidget(settings(state));
      await tester.pumpAndSettle();

      await reveal(tester, find.text('Enable response hints'));
      // Off, so there is nothing to configure yet.
      expect(find.text('Injection depth'), findsNothing);

      await tester.tap(find.text('Enable response hints'));
      await tester.pumpAndSettle();
      expect(state.chatInterface.responseHintEnabled, isTrue);

      await reveal(tester, find.text('Injection depth'));
      expect(find.text('Injection depth'), findsOneWidget);
      // The default reads as what it does rather than as a bare number.
      expect(find.text('Just before the reply'), findsOneWidget);
    });

    testWidgets('the depth slider records whole messages', (tester) async {
      final state = await boot();
      await tester.pumpWidget(settings(state));
      await tester.pumpAndSettle();

      await reveal(tester, find.text('Injection depth'));
      final slider = find.byType(Slider).last;
      await tester.drag(slider, const Offset(60, 0));
      await tester.pumpAndSettle();

      expect(state.chatInterface.responseHintDepth, greaterThan(0));
      expect(state.chatInterface.responseHintDepth,
          lessThanOrEqualTo(kMaxResponseHintDepth));
      expect(find.textContaining('back'), findsWidgets);
    });
  });
}
