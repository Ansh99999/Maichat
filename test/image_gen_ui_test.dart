import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/image_gen.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/screens/chat_screen.dart';
import 'package:maichat/services/avatar_store.dart';
import 'package:maichat/services/chat_client.dart';
import 'package:maichat/services/image_client.dart';
import 'package:maichat/state/app_state.dart';
import 'package:maichat/widgets/avatar_image.dart';
import 'package:provider/provider.dart' hide Provider;
import 'package:shared_preferences/shared_preferences.dart';

/// The image studio, driven through the chat it is opened from: the sheet, its
/// settings page, a generation, and the three things that can be done with the
/// picture that comes back.
class _FakeImageClient extends ImageClient {
  _FakeImageClient(this.bytes);

  final Uint8List bytes;
  ImageGenConfig? lastConfig;
  String? lastPrompt;
  List<ImageReference> lastReferences = const <ImageReference>[];
  String? failure;

  @override
  Future<ImageResult> generate({
    required ImageGenConfig config,
    required String prompt,
    List<ImageReference> references = const <ImageReference>[],
  }) async {
    lastConfig = config;
    lastPrompt = prompt;
    lastReferences = references;
    if (failure != null) throw ChatApiException(failure!);
    return ImageResult(images: <Uint8List>[bytes], text: 'here you go');
  }
}

void main() {
  late Directory dir;
  late _FakeImageClient images;

  final png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAA'
      'DUlEQVR42mP8z8DAwAAABQABg1z0GwAAAABJRU5ErkJggg==');

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    dir = Directory.systemTemp.createTempSync('studio');
    clearAvatarImageCache();
    images = _FakeImageClient(Uint8List.fromList(png));
  });
  tearDown(() {
    dir.deleteSync(recursive: true);
    avatarDirectory = null;
  });

  Future<AppState> boot({bool configured = true}) async {
    final state = AppState(imageClient: images, avatars: AvatarStore(dir));
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
    if (configured) {
      await state.updateImageGen(const ImageGenConfig(
        baseUrl: 'https://pictures.tld/v1',
        apiKey: 'k',
        model: 'gpt-image-1',
      ));
    }
    return state;
  }

  Widget host(AppState state) => ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: ChatScreen()),
      );

  /// Opens the operations strip, then the studio.
  Future<void> openStudio(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('composer-ops-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('composer-imagegen-button')));
    await tester.pumpAndSettle();
  }

  /// Waits for work that ends in real file I/O — filing a picture in the gallery
  /// writes a file, and a widget test's fake-async zone never pumps that. The
  /// chain is several real awaits long (write the file, save the records, sweep),
  /// so each turn needs a trip through the real event loop and back.
  Future<void> settleRealWork(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump();
    }
  }

  /// Types a prompt and generates. Note the deliberate absence of
  /// `pumpAndSettle` while a generation is in flight: the busy state is a
  /// progress spinner, which never settles by design.
  Future<void> generate(WidgetTester tester, String prompt) async {
    await tester.enterText(find.byType(TextField).last, prompt);
    await tester.pump();
    await tester.tap(find.byKey(const Key('imagegen-send-button')));
    await tester.pump();
    await settleRealWork(tester);
  }

  testWidgets('the studio opens over the chat and says what it is pointed at',
      (tester) async {
    final state = await boot();
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    await openStudio(tester);
    expect(find.text('Image studio'), findsOneWidget);
    expect(find.textContaining('gpt-image-1'), findsOneWidget);
    // Nothing made yet: an invitation rather than an empty frame.
    expect(find.textContaining('Describe a picture'), findsOneWidget);
  });

  testWidgets('an unconfigured studio still opens, and says what is missing',
      (tester) async {
    // "All chats and models can generate a picture" only holds if the studio is
    // always reachable; it is the endpoint that may be missing, not the feature.
    final state = await boot(configured: false);
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    await openStudio(tester);
    expect(find.text('No image model set'), findsOneWidget);

    await tester.enterText(find.byType(TextField).last, 'a lighthouse');
    await tester.pump();
    await tester.tap(find.byKey(const Key('imagegen-send-button')));
    await tester.pumpAndSettle();
    expect(find.textContaining('studio settings'), findsOneWidget);
  });

  testWidgets('the settings button opens a page inside the sheet, and Back '
      'returns to the studio', (tester) async {
    final state = await boot();
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();
    await openStudio(tester);

    await tester.tap(find.byKey(const Key('imagegen-settings-button')));
    await tester.pumpAndSettle();
    expect(find.text('Image settings'), findsOneWidget);
    // The studio is replaced, not covered — the sheet is still the same sheet.
    expect(find.text('Image studio'), findsNothing);

    // Editing a field writes through immediately: a settings page inside a sheet
    // that can be swiped away must not be holding unsaved work.
    await tester.enterText(
        find.widgetWithText(TextField, 'Model'), 'imagen-4');
    await tester.pump();
    expect(state.imageGen.model, 'imagen-4');

    await tester.tap(find.byKey(const Key('imagegen-settings-back')));
    await tester.pumpAndSettle();
    expect(find.text('Image studio'), findsOneWidget);
    expect(find.textContaining('imagen-4'), findsOneWidget);
  });

  testWidgets('a generated picture is shown, and filed in the gallery under the '
      'chat\'s character', (tester) async {
    final state = await boot();
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();
    await openStudio(tester);

    await generate(tester, 'a harbour at dusk');

    // Sent with the studio's own composed prompt, not the chat's provider.
    expect(images.lastPrompt, 'a harbour at dusk');
    expect(images.lastConfig?.model, 'gpt-image-1');

    // Filed automatically, owned by the character whose chat asked for it.
    expect(state.gallery, hasLength(1));
    expect(state.gallery.single.characterId, state.active.characterId);
    expect(state.gallery.single.title, 'a harbour at dusk');
    expect(state.gallery.single.tags, contains('generated'));

    // And it is what the sheet is showing, with the three things to do to it.
    expect(find.byKey(const Key('imagegen-download')), findsOneWidget);
    expect(find.byKey(const Key('imagegen-delete')), findsOneWidget);
    expect(find.byKey(const Key('imagegen-share')), findsOneWidget);
  });

  testWidgets('the standing instructions are wrapped around every prompt',
      (tester) async {
    final state = await boot();
    await state.updateImageGen(state.imageGen.copyWith(
      systemPrompt: 'watercolour',
      negativePrompt: 'text',
    ));
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();
    await openStudio(tester);

    await generate(tester, 'a kite');
    expect(images.lastPrompt, 'watercolour\n\na kite\n\nAvoid: text');
  });

  testWidgets('"Send to chat" puts the picture in the conversation and closes '
      'the studio', (tester) async {
    final state = await boot();
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();
    await openStudio(tester);
    await generate(tester, 'a fox');

    await tester.tap(find.byKey(const Key('imagegen-share')));
    await tester.pumpAndSettle();

    // A turn of its own carrying the picture — so it is on screen, and rides
    // along with the next request like any other attachment.
    final turn = state.active.messages.last;
    expect(turn.role, 'user');
    expect(turn.images.single.ref, state.gallery.single.image);
    expect(find.text('Image studio'), findsNothing);
  });

  testWidgets('delete removes the picture from the gallery too — the studio '
      'files everything it makes, so delete has to mean it', (tester) async {
    final state = await boot();
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();
    await openStudio(tester);
    await generate(tester, 'a fox');
    expect(state.gallery, hasLength(1));

    await tester.tap(find.byKey(const Key('imagegen-delete')));
    await tester.pump();
    await settleRealWork(tester);

    expect(state.gallery, isEmpty);
    expect(find.byKey(const Key('imagegen-share')), findsNothing);
    expect(find.textContaining('Describe a picture'), findsOneWidget);
  });

  testWidgets('a failure is reported in the studio rather than thrown away',
      (tester) async {
    final state = await boot();
    images.failure = 'Rejected (HTTP 401): check your API key.';
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();
    await openStudio(tester);
    await generate(tester, 'a fox');

    expect(find.textContaining('HTTP 401'), findsOneWidget);
    expect(state.gallery, isEmpty);
  });

  testWidgets('a message action opens the studio with that message as the '
      'prompt', (tester) async {
    final state = await boot();
    state.active.messages.add(ChatMessage(
      role: 'user',
      content: 'the harbour at dusk, gulls everywhere',
    ));
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    // Through the turn's own action menu, which is where message actions live.
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Generate image'));
    await tester.pumpAndSettle();

    expect(find.text('Image studio'), findsOneWidget);
    expect(
      find.widgetWithText(TextField, 'the harbour at dusk, gulls everywhere'),
      findsOneWidget,
    );
  });
}
