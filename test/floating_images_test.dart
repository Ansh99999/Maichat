import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/floating_image.dart';
import 'package:maichat/models/gallery_image.dart';
import 'package:maichat/screens/chat_screen.dart';
import 'package:maichat/state/app_state.dart';
import 'package:maichat/widgets/floating_images_layer.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Drives the real [ChatScreen] with pictures floating over it: the drag, the
/// two-finger resize and turn, the ✕, and that where a picture ends up is what
/// gets persisted.
///
/// The pictures are seeded as records with `local:` references and no pictures
/// directory behind them, so nothing decodes — the frame, its gestures and the
/// stored geometry are what is under test, not the bitmaps.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Future<AppState> chatWithFloats({int count = 1}) async {
    final state = AppState();
    // The chat screen holds a startup gate until the store has been read.
    await state.init();
    final character = Character(id: 'aria', name: 'Aria', firstMes: 'Hello.');
    await state.addCharacter(character);
    state.startChatWithCharacter(character);
    for (var i = 0; i < count; i++) {
      await state.saveGalleryImage(GalleryImage(
        id: 'img$i',
        image: 'local:img$i.png',
        title: 'Picture $i',
        characterId: 'aria',
        createdAt: DateTime(2026, 4, 24, 12 - i),
      ));
      await state.floatImage(state.active.id, 'img$i');
    }
    return state;
  }

  Widget host(AppState state) => ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: ChatScreen()),
      );

  /// Pumps the chat. Explicit frames rather than `pumpAndSettle`: the frosted menu
  /// button and the composer strip animate, so settling never finishes.
  Future<void> pumpChat(WidgetTester tester, AppState state) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(host(state));
    await tester.pump();
    await tester.pump();
  }

  /// A **snapshot** of a float's geometry.
  ///
  /// `copyWith` matters: the stored [FloatingImage] is mutable and
  /// `moveFloatingImage` edits it in place, so holding the object itself as a
  /// "before" value would compare it against itself and every assertion would
  /// pass trivially — or, as it did here, fail claiming nothing moved.
  FloatingImage floatOf(AppState state, String imageId) => state
      .active.floatingImages
      .firstWhere((f) => f.imageId == imageId)
      .copyWith();

  testWidgets('a chat with nothing floating draws no layer', (tester) async {
    final state = await chatWithFloats(count: 0);
    await pumpChat(tester, state);
    expect(find.byType(FloatingImagesLayer), findsOneWidget,
        reason: 'the layer is always mounted');
    expect(find.byIcon(Icons.close), findsNothing,
        reason: 'but it draws nothing');
  });

  testWidgets('a floated picture appears over the thread with a dismiss control',
      (tester) async {
    final state = await chatWithFloats();
    await pumpChat(tester, state);

    expect(find.byIcon(Icons.close), findsOneWidget);
    // The greeting is still there underneath — a float covers the chat, it does
    // not replace it, and nothing was added to the transcript.
    expect(find.text('Hello.'), findsOneWidget);
    expect(state.active.messages, hasLength(1));
  });

  testWidgets('one finger drags it, and where it lands is remembered',
      (tester) async {
    final state = await chatWithFloats();
    await pumpChat(tester, state);
    final before = floatOf(state, 'img0');

    final grip = tester.getCenter(find.byIcon(Icons.close)) +
        const Offset(0, 40); // On the picture, clear of the ✕.
    final gesture = await tester.startGesture(grip);
    // Past the drag slop in several steps, the way a finger moves.
    for (var i = 0; i < 5; i++) {
      await gesture.moveBy(const Offset(12, 16));
      await tester.pump();
    }
    await gesture.up();
    await tester.pump();
    await tester.pump();

    final after = floatOf(state, 'img0');
    expect(after.x, greaterThan(before.x));
    expect(after.y, greaterThan(before.y));
    // Fractions of the chat area, not pixels, so the same float lands in the same
    // visual place on a different screen.
    expect(after.x, lessThanOrEqualTo(1));
    expect(after.y, lessThanOrEqualTo(1));
  });

  testWidgets('two fingers resize and turn it', (tester) async {
    final state = await chatWithFloats();
    await pumpChat(tester, state);
    final before = floatOf(state, 'img0');
    expect(before.rotation, 0);

    final centre =
        tester.getCenter(find.byIcon(Icons.close)) + const Offset(-40, 60);
    final left = await tester.startGesture(centre - const Offset(40, 0));
    final right = await tester.startGesture(centre + const Offset(40, 0));
    // Apart and around: bigger and turned in one motion, which is the point of
    // driving all three from one recogniser.
    for (var i = 0; i < 6; i++) {
      await left.moveBy(const Offset(-6, -3));
      await right.moveBy(const Offset(6, 3));
      await tester.pump();
    }
    await left.up();
    await right.up();
    await tester.pump();
    await tester.pump();

    final after = floatOf(state, 'img0');
    expect(after.width, greaterThan(before.width));
    expect(after.rotation, isNot(0));
  });

  testWidgets('resizing stops at the bounds rather than vanishing',
      (tester) async {
    final state = await chatWithFloats();
    await pumpChat(tester, state);

    final centre =
        tester.getCenter(find.byIcon(Icons.close)) + const Offset(-40, 60);
    final left = await tester.startGesture(centre - const Offset(120, 0));
    final right = await tester.startGesture(centre + const Offset(120, 0));
    // Squeezed hard: a float must stay big enough to grab and dismiss.
    for (var i = 0; i < 10; i++) {
      await left.moveBy(const Offset(11, 0));
      await right.moveBy(const Offset(-11, 0));
      await tester.pump();
    }
    await left.up();
    await right.up();
    await tester.pump();
    await tester.pump();

    expect(floatOf(state, 'img0').width,
        greaterThanOrEqualTo(kFloatingImageMinWidth));
  });

  testWidgets('the ✕ takes it back off the chat', (tester) async {
    final state = await chatWithFloats();
    await pumpChat(tester, state);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    await tester.pump();

    expect(state.active.floatingImages, isEmpty);
    expect(find.byIcon(Icons.close), findsNothing);
    // The picture itself is untouched — dismissing is not deleting.
    expect(state.galleryImageById('img0'), isNotNull);
  });

  testWidgets('several floats coexist, and touching one raises it',
      (tester) async {
    final state = await chatWithFloats(count: 3);
    await pumpChat(tester, state);
    expect(state.active.floatingImages, hasLength(3));
    expect(find.byIcon(Icons.close), findsNWidgets(3));
    // Fanned out rather than exactly stacked, so all three can be reached.
    final xs = state.active.floatingImages.map((f) => f.x).toSet();
    expect(xs, hasLength(3));

    // The first-floated is at the back; dragging it should bring it to the front.
    expect(state.active.floatingImages.first.imageId, 'img0');
    final grip = tester.getTopLeft(find.byType(FloatingImagesLayer)) +
        Offset(
          state.active.floatingImages.first.x * 400 + 40,
          state.active.floatingImages.first.y * 700 + 60,
        );
    final gesture = await tester.startGesture(grip);
    await gesture.moveBy(const Offset(6, 6));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    await tester.pump();

    expect(state.active.floatingImages.last.imageId, 'img0');
  });

  testWidgets('deleting the picture takes its float with it', (tester) async {
    final state = await chatWithFloats();
    await pumpChat(tester, state);
    expect(find.byIcon(Icons.close), findsOneWidget);

    await state.deleteGalleryImage('img0');
    await tester.pump();
    await tester.pump();

    expect(state.active.floatingImages, isEmpty);
    expect(find.byIcon(Icons.close), findsNothing);
  });

  testWidgets('floats survive leaving and re-entering the chat', (tester) async {
    final state = await chatWithFloats();
    await pumpChat(tester, state);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    await pumpChat(tester, state);
    expect(find.byIcon(Icons.close), findsOneWidget);
    expect(state.active.floatingImages.single.imageId, 'img0');
  });
}
