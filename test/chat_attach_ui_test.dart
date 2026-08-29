import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/screens/chat_screen.dart';
import 'package:maichat/services/avatar_store.dart';
import 'package:maichat/services/chat_client.dart';
import 'package:maichat/state/app_state.dart';
import 'package:maichat/widgets/avatar_image.dart';
import 'package:maichat/widgets/message_bubble.dart';
import 'package:provider/provider.dart' hide Provider;
import 'package:shared_preferences/shared_preferences.dart';

/// Sending a picture, driven through the real composer: the operations strip, the
/// attachment tray, the preview of what is about to go, and the turn that lands.
class _FakeClient extends ChatClient {
  List<ChatMessage>? lastHistory;

  @override
  Stream<ChatDelta> streamChat({
    required Provider provider,
    required List<ChatMessage> history,
    GenParams params = const GenParams(),
  }) async* {
    lastHistory = List<ChatMessage>.from(history);
    yield const ChatDelta(text: 'I see it.');
  }

  @override
  Future<List<String>> listModels(Provider provider) async => const ['m'];
}

void main() {
  late Directory dir;
  late _FakeClient client;

  final png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAA'
      'DUlEQVR42mP8z8DAwAAABQABg1z0GwAAAABJRU5ErkJggg==');

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    dir = Directory.systemTemp.createTempSync('attach-ui');
    clearAvatarImageCache();
    client = _FakeClient();
  });
  tearDown(() {
    dir.deleteSync(recursive: true);
    avatarDirectory = null;
  });

  Future<AppState> boot() async {
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
    return state;
  }

  /// Files a picture in the gallery. Writing it is real file I/O, and a widget
  /// test's fake-async zone never pumps that — so it has to run in the real one
  /// or the future simply never completes.
  Future<void> seedGallery(WidgetTester tester, AppState state) =>
      tester.runAsync(() => state.addGalleryImages([png], title: 'Harbour'))
          .then((_) {});

  Widget host(AppState state) => ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: ChatScreen()),
      );

  /// Opens the operations strip and then the attachment tray.
  Future<void> openTray(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('composer-ops-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('composer-image-button')));
    await tester.pumpAndSettle();
  }

  testWidgets('the tray offers both sources and nothing else', (tester) async {
    final state = await boot();
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    // Closed until asked for: the tray must not sit over the conversation.
    expect(find.byKey(const Key('attach-from-gallery')), findsNothing);

    await openTray(tester);
    expect(find.byKey(const Key('attach-from-gallery')), findsOneWidget);
    expect(find.byKey(const Key('attach-from-device')), findsOneWidget);
    expect(find.text('From gallery'), findsOneWidget);
    expect(find.text('From device'), findsOneWidget);
  });

  testWidgets('a picture chosen from the gallery previews in the tray and then '
      'goes out with the message', (tester) async {
    final state = await boot();
    await seedGallery(tester, state);
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    await openTray(tester);
    await tester.tap(find.byKey(const Key('attach-from-gallery')));
    await tester.pumpAndSettle();

    // The picker's grid: take the first picture in it.
    await tester.tap(
      find
          .descendant(
            of: find.byType(GridView),
            matching: find.byType(InkWell),
          )
          .first,
    );
    await tester.pumpAndSettle();

    // The choices have given way to a preview of what is about to be sent, with
    // its own ✕ and a way to add another.
    expect(find.byKey(const Key('attach-from-gallery')), findsNothing);
    expect(find.byKey(const Key('attach-another')), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'what is this?');
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();

    // The turn carries both, and the request carried the picture.
    final turn = state.active.messages.first;
    expect(turn.content, 'what is this?');
    expect(turn.images, hasLength(1));
    final sent = client.lastHistory!.last;
    expect(sent.images.single.hasData, isTrue,
        reason: 'the bytes must have been resolved for the wire');

    // And the tray has put itself away.
    expect(find.byKey(const Key('attach-another')), findsNothing);
  });

  testWidgets('a picture with nothing typed is a message on its own',
      (tester) async {
    final state = await boot();
    await seedGallery(tester, state);
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    // Send is dead with an empty box and nothing attached.
    expect(
      tester.widget<IconButton>(
        find.ancestor(
          of: find.byIcon(Icons.arrow_upward),
          matching: find.byType(IconButton),
        ),
      ).onPressed,
      isNull,
    );

    await openTray(tester);
    await tester.tap(find.byKey(const Key('attach-from-gallery')));
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .descendant(of: find.byType(GridView), matching: find.byType(InkWell))
          .first,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();

    final turn = state.active.messages.first;
    expect(turn.content, isEmpty);
    expect(turn.images, hasLength(1));
    // A chat named after a picture rather than left as "New chat".
    expect(state.active.title, 'Picture');
  });

  testWidgets('the ✕ on a preview takes that picture back off the message',
      (tester) async {
    final state = await boot();
    await seedGallery(tester, state);
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    await openTray(tester);
    await tester.tap(find.byKey(const Key('attach-from-gallery')));
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .descendant(of: find.byType(GridView), matching: find.byType(InkWell))
          .first,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('attach-another')), findsOneWidget);

    // The remove button on the thumbnail, not the tray's own close.
    await tester.tap(find.byTooltip('Remove'));
    await tester.pumpAndSettle();

    // Back to the two choices, with nothing queued.
    expect(find.byKey(const Key('attach-from-gallery')), findsOneWidget);
    expect(
      tester.widget<IconButton>(
        find.ancestor(
          of: find.byIcon(Icons.arrow_upward),
          matching: find.byType(IconButton),
        ),
      ).onPressed,
      isNull,
    );
  });

  testWidgets('an attached picture is drawn in its turn, and is openable',
      (tester) async {
    final state = await boot();
    final image = await tester.runAsync(() => state.storeAttachment(png));
    state.active.messages.add(
      ChatMessage(role: 'user', content: 'look', images: [image!]),
    );
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    // Drawn inside the bubble: the picture is part of the message, and it is the
    // file that was written — not a blob carried on the turn.
    final inBubble = find.descendant(
      of: find.byType(MessageBubble),
      matching: find.byType(Image),
    );
    expect(inBubble, findsOneWidget);
    expect(tester.widget<Image>(inBubble).width, 232,
        reason: 'a lone picture is given room to be looked at');

    // And it is wired to open full size. (The tap itself is not driven here: a
    // widget test's fake-async zone never completes the decode, so the picture
    // lays out at zero height and there is nothing to hit — see the viewer's own
    // coverage in photo_viewer_gesture_test.dart.)
    expect(
      find.ancestor(of: inBubble, matching: find.byType(GestureDetector)),
      findsWidgets,
    );
    expect(state.active.messages.single.images.single.ref, image.ref);
  });
}
