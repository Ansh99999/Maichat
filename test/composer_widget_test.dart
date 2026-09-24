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

/// The expressive composer and its legacy twin, across the grid of looks the
/// settings expose: which composer, what background, outline on or off, a
/// picture frosted or not, a persona shown or not. The widget keys a swath of
/// other UI tests key off must survive every combination, and none of the
/// background variants may throw when built.
class _FakeClient extends ChatClient {
  @override
  Stream<ChatDelta> streamChat({
    required Provider provider,
    required List<ChatMessage> history,
    GenParams params = const GenParams(),
  }) async* {
    yield const ChatDelta(text: 'ok');
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
      ..add(ChatMessage(role: 'user', content: 'Hi'))
      ..add(ChatMessage(role: 'assistant', content: 'ok'));
    return state;
  }

  Future<void> pump(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const MaterialApp(home: ChatScreen()),
    ));
    await tester.pumpAndSettle();
  }

  const field = Key('composer-field');
  const ops = Key('composer-ops-button');

  bool sendEnabled(WidgetTester tester) {
    final button = tester.widget<IconButton>(
      find.ancestor(
        of: find.byTooltip('Send'),
        matching: find.byType(IconButton),
      ),
    );
    return button.onPressed != null;
  }

  testWidgets('the expressive composer is the default and shows the persona',
      (tester) async {
    final state = await boot();
    expect(state.chatInterface.composerStyle, ComposerStyle.expressive);
    await pump(tester, state);

    expect(find.byKey(field), findsOneWidget);
    expect(find.byKey(ops), findsOneWidget);
    expect(find.byTooltip('Send'), findsOneWidget);
    // No impersonation, so the persona reads as the default "You".
    expect(find.text('You'), findsOneWidget);
    // The hint that marks the roomy expressive box.
    expect(find.text('Type your reply..'), findsOneWidget);
  });

  testWidgets('the persona name follows an impersonation', (tester) async {
    final state = await boot();
    final bob = Character(id: 'bob', name: 'Bob');
    await state.addCharacter(bob);
    await state.setImpersonation(bob);
    await pump(tester, state);
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('You'), findsNothing);
  });

  testWidgets('the legacy composer keeps its keys and its flat row',
      (tester) async {
    final state = await boot();
    await state.updateChatInterface(
        state.chatInterface.copyWith(composerStyle: ComposerStyle.legacy));
    await pump(tester, state);

    expect(find.byKey(field), findsOneWidget);
    expect(find.byKey(ops), findsOneWidget);
    expect(find.byTooltip('Send'), findsOneWidget);
    // The legacy box's hint, not the expressive one.
    expect(find.text('Type your reply..'), findsNothing);
    expect(find.text('Message'), findsOneWidget);
  });

  for (final style in ComposerStyle.values) {
    testWidgets('the ⋯ button opens the ops panel (${style.name})',
        (tester) async {
      final state = await boot();
      await state.updateChatInterface(
          state.chatInterface.copyWith(composerStyle: style));
      await pump(tester, state);

      // The picture button lives in the ops panel, which is closed at first.
      expect(find.byKey(const Key('composer-image-button')), findsNothing);
      await tester.tap(find.byKey(ops));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('composer-image-button')), findsOneWidget);
      expect(find.byKey(const Key('composer-imagegen-button')), findsOneWidget);
    });
  }

  testWidgets('the expressive ops panel opens the attachment tray in a riser',
      (tester) async {
    final state = await boot();
    await pump(tester, state);

    // Open the ops strip, then the picture tray it holds. Both the tray and the
    // composer must survive — the expressive panels rise out of the box as their
    // own rounded risers rather than sitting in the legacy slab.
    await tester.tap(find.byKey(ops));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('composer-image-button')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('attach-tray')), findsOneWidget);
    expect(find.byKey(field), findsOneWidget);
    expect(find.byTooltip('Send'), findsOneWidget);
  });

  testWidgets('focusing the expressive composer does not throw', (tester) async {
    final state = await boot();
    await pump(tester, state);

    // Tapping into the box lights its outline glow (a focus-driven rebuild); it
    // must repaint cleanly, with every key still in place.
    await tester.tap(find.byKey(field));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(field), findsOneWidget);
    expect(find.byKey(ops), findsOneWidget);
    expect(find.byTooltip('Send'), findsOneWidget);
  });

  testWidgets('the expressive composer floats over the thread, not in a slot',
      (tester) async {
    final state = await boot();
    await pump(tester, state);

    // The thread fills the whole body and the box is laid over its bottom edge,
    // so the conversation is visible behind and around the composer rather than
    // stopping at a send bar. The list therefore extends *past* the box's top.
    final listBottom = tester.getRect(find.byType(ListView)).bottom;
    final boxTop = tester.getRect(find.byKey(field)).top;
    expect(listBottom, greaterThan(boxTop),
        reason: 'the thread runs behind the floating composer');
  });

  testWidgets('the legacy composer takes a slot below the thread',
      (tester) async {
    final state = await boot();
    await state.updateChatInterface(
        state.chatInterface.copyWith(composerStyle: ComposerStyle.legacy));
    await pump(tester, state);

    // The counterpart: the flat send bar is furniture below the thread, so the
    // list ends at (does not run under) the composer.
    final listBottom = tester.getRect(find.byType(ListView)).bottom;
    final boxTop = tester.getRect(find.byKey(field)).top;
    expect(listBottom, lessThanOrEqualTo(boxTop + 1),
        reason: 'the legacy thread stops at the send bar');
  });

  testWidgets('opening a panel over the expressive composer never moves the '
      'thread', (tester) async {
    final state = await boot();
    await pump(tester, state);

    // A turn to watch. Opening the operations strip rises a riser out of the box
    // and must overlay the conversation, not shove it up the way a Column slot
    // would — the whole point of floating the composer.
    final before = tester.getRect(find.text('Hi')).top;
    await tester.tap(find.byKey(ops));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('composer-image-button')), findsOneWidget);
    final after = tester.getRect(find.text('Hi')).top;
    expect((after - before).abs(), lessThan(1.0),
        reason: 'the thread stays put while the panel overlays it');
  });

  testWidgets('send is dead with an empty box and lives once text is typed',
      (tester) async {
    final state = await boot();
    await pump(tester, state);
    expect(sendEnabled(tester), isFalse);

    await tester.enterText(find.byKey(field), 'hello');
    await tester.pump();
    expect(sendEnabled(tester), isTrue);
  });

  group('background and outline variants build without throwing', () {
    for (final bg in ComposerBackground.values) {
      for (final outline in const [true, false]) {
        for (final blur in const [true, false]) {
          testWidgets('${bg.name} · outline=$outline · blur=$blur',
              (tester) async {
            final state = await boot();
            await state.updateChatInterface(state.chatInterface.copyWith(
              composerBackground: bg,
              composerOutline: outline,
              composerBackgroundBlur: blur,
              composerBackgroundColor:
                  bg == ComposerBackground.color ? 0xFF335577 : null,
              composerBackgroundImage:
                  bg == ComposerBackground.image ? 'local:missing.png' : null,
              composerBackgroundOpacity: 0.7,
            ));
            await pump(tester, state);

            expect(tester.takeException(), isNull);
            expect(find.byKey(field), findsOneWidget);
            expect(find.byTooltip('Send'), findsOneWidget);
          });
        }
      }
    }
  });
}
