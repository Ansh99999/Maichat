import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/gallery_image.dart';
import 'package:maichat/screens/gallery/gallery_upload_sheet.dart';
import 'package:maichat/services/avatar_store.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Naming pictures on their way into the gallery.
///
/// The old sheet asked for **one** title and stuck a number on the end of it, so
/// twelve photos became "Trip 1" … "Trip 12" — which is not a name for anything and
/// is unsearchable the moment you have two trips. This is the replacement: a row
/// per picture, a box per row, and the tags and owner they genuinely share.
final _png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAA'
    'DUlEQVR42mP8z8DAwAAABQABg1z0GwAAAABJRU5ErkJggg==');

void main() {
  late Directory dir;
  late Directory picks;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    dir = Directory.systemTemp.createTempSync('upload-store');
    picks = Directory.systemTemp.createTempSync('upload-picks');
  });
  tearDown(() {
    dir.deleteSync(recursive: true);
    picks.deleteSync(recursive: true);
    avatarDirectory = null;
  });

  Future<AppState> boot() async {
    final state = AppState(avatars: AvatarStore(dir));
    await state.init();
    return state;
  }

  /// A picture sitting where the device picker would have left it.
  GalleryUpload picked(String name, int seed) {
    final file = File('${picks.path}/$name')
      ..writeAsBytesSync(<int>[..._png, ...List<int>.filled(4, seed)]);
    return GalleryUpload(title: '', path: file.path, name: name);
  }

  /// Opens the naming sheet over a bare screen and files what it collects — the
  /// screen's own path with only the device picker taken out.
  Future<int?> open(
    WidgetTester tester,
    AppState state,
    List<GalleryUpload> uploads, {
    List<Character> characters = const <Character>[],
  }) async {
    int? filed;
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  filed = await nameAndFilePictures(
                    context,
                    picked: uploads,
                    characters: characters,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return filed;
  }

  /// Lets the real file writes behind Add actually happen.
  ///
  /// A `testWidgets` body runs in a fake-async zone that never pumps `dart:io`
  /// futures, so the store has to be handed real time — and one `runAsync` only
  /// gets one `await` in the chain past its I/O, so a picture takes several passes
  /// and three pictures take several times that. Waits for [expected] records
  /// rather than a fixed number of turns, then lets the sheet close.
  Future<void> awaitFiled(
    WidgetTester tester,
    AppState state,
    int expected,
  ) async {
    for (var i = 0; i < 400 && state.gallery.length < expected; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 4)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  /// The same, for the cases where nothing is supposed to be written: there is no
  /// count to wait for, so it is a fixed handful of turns.
  Future<void> settleRealWork(WidgetTester tester) async {
    for (var i = 0; i < 24; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 4)));
      await tester.pump();
    }
  }

  testWidgets('one box per picture, and each keeps its own name',
      (tester) async {
    final state = await boot();
    await open(tester, state, [
      picked('DSC_0001.jpg', 1),
      picked('DSC_0002.jpg', 2),
      picked('DSC_0003.jpg', 3),
    ]);

    // The header counts them, and there is a title box for every one — not one
    // box and a numbering rule.
    expect(find.text('Name 3 pictures'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Title'), findsNWidgets(3));
    // The file name is offered as the hint, so a photo can be told from the next
    // one before it has a name of its own.
    for (final name in const ['DSC_0001.jpg', 'DSC_0002.jpg', 'DSC_0003.jpg']) {
      expect(find.text(name), findsOneWidget, reason: name);
    }

    final boxes = find.widgetWithText(TextField, 'Title');
    await tester.enterText(boxes.at(0), 'Beach outfit');
    await tester.enterText(boxes.at(1), 'Rain, later');
    // The third is left blank on purpose: a name is optional.
    await tester.pump();

    await tester.tap(find.byKey(const Key('gallery-upload-add')));
    await tester.pump();
    await awaitFiled(tester, state, 3);

    expect(state.gallery.map((i) => i.title),
        containsAll(<String>['Beach outfit', 'Rain, later']));
    expect(state.gallery, hasLength(3));
    // Three separate files, and none of the bytes in the preferences store.
    expect(state.gallery.map((i) => i.image).toSet(), hasLength(3));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('gallery'), isNot(contains(base64Encode(_png))));
  });

  testWidgets('tags and the owner are shared, because they always are',
      (tester) async {
    final state = await boot();
    await state.addCharacter(Character(id: 'sumire', name: 'Sumire'));
    await open(
      tester,
      state,
      [picked('a.png', 1), picked('b.png', 2)],
      characters: state.characters,
    );

    await tester.enterText(
      find.widgetWithText(TextField, 'Tags'),
      'beach, summer',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('gallery-upload-add')));
    await tester.pump();
    await awaitFiled(tester, state, 2);

    expect(state.gallery, hasLength(2));
    for (final image in state.gallery) {
      expect(image.tags, ['beach', 'summer']);
    }
  });

  testWidgets('a single picture is named, not numbered', (tester) async {
    final state = await boot();
    await open(tester, state, [picked('only.png', 1)]);

    expect(find.text('Add a picture'), findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextField, 'Title'), 'Beach outfit');
    await tester.pump();
    await tester.tap(find.byKey(const Key('gallery-upload-add')));
    await tester.pump();
    await awaitFiled(tester, state, 1);

    // No trailing "1" — that only ever made sense to the code that wrote it.
    expect(state.gallery.single.title, 'Beach outfit');
  });

  testWidgets('with the keyboard up, Add is still reachable', (tester) async {
    // The bug that made "import several pictures" impossible: the sheet was
    // capped against the whole display rather than the room left above the
    // keyboard, so with a few rows in it Cancel and Add were pushed off the
    // bottom. One picture fitted; three did not.
    final state = await boot();
    final dpr = tester.view.devicePixelRatio;
    await open(tester, state, [
      picked('a.png', 1),
      picked('b.png', 2),
      picked('c.png', 3),
      picked('d.png', 4),
    ]);

    tester.view.viewInsets = FakeViewPadding(bottom: 300 * dpr);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();

    final add = find.byKey(const Key('gallery-upload-add'));
    final screen = tester.view.physicalSize.height / dpr;
    expect(tester.getBottomLeft(add).dy, lessThanOrEqualTo(screen - 300),
        reason: 'Add is behind the keyboard');
    // And it really can be pressed from there.
    await tester.tap(add);
    await tester.pump();
    await awaitFiled(tester, state, 4);
    expect(state.gallery, hasLength(4));
  });

  testWidgets('backing out writes nothing', (tester) async {
    final state = await boot();
    await open(tester, state, [picked('a.png', 1)]);

    await tester.enterText(find.widgetWithText(TextField, 'Title'), 'Ignored');
    await tester.pump();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
    await tester.pumpAndSettle();
    await settleRealWork(tester);

    expect(state.gallery, isEmpty);
    expect(dir.listSync(), isEmpty);
  });
}
