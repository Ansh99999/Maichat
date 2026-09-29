import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/studio.dart';
import 'package:maichat/screens/studio/draft/draft_images_tab.dart';
import 'package:maichat/services/avatar_store.dart';
import 'package:maichat/services/studio/studio_controller.dart';
import 'package:maichat/services/studio/studio_images.dart';
import 'package:maichat/services/studio/studio_store.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart' hide Provider;
import 'package:shared_preferences/shared_preferences.dart';

/// The Images tab's "Add picture" sheet, down each of its three paths, over a
/// stand-in web (`MockClient` — in-process, so the widget-test binding's HTTP
/// override never comes into it).
final Uint8List png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DAwAAABQABg1z0GwAAAABJRU5ErkJggg==',
);

void main() {
  late Directory dir;
  late Map<String, http.Response Function(http.Request)> routes;
  final previous = StudioImages.shared;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    dir = Directory.systemTemp.createTempSync('studio_avatars_ui');
    routes = {};
    StudioImages.shared = StudioImages(
      client: () => MockClient((request) async {
        final route = routes['${request.url.host}${request.url.path}'];
        return route == null ? http.Response('not found', 404) : route(request);
      }),
      lookup: (host) async => [InternetAddress('93.184.216.34')],
    );
  });
  tearDown(() {
    StudioImages.shared = previous;
    dir.deleteSync(recursive: true);
    avatarDirectory = null;
  });

  Future<(AppState, StudioController)> boot(WidgetTester tester) async {
    final state = AppState(avatars: AvatarStore(dir));
    await tester.runAsync(state.init);
    final controller = StudioController(
      state: state,
      store: StudioStore(dir),
      session: StudioSession(
        id: 'ui',
        title: '',
        workspace: StudioWorkspace(
          character: Character(id: 'c1', name: 'Maren', avatar: 'local:old.png'),
        ),
      ),
    );
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: controller,
            builder: (_, _) => DraftImagesTab(controller: controller),
          ),
        ),
      ),
    ));
    await tester.pump();
    return (state, controller);
  }

  /// Lets real work (network stand-in, file writes) finish: a testWidgets
  /// body never pumps real I/O on its own.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump();
    }
  }

  /// Real work until the sheet's busy bar is gone (at most ~3 s of it), then
  /// the closing animation. A running progress bar never settles, so this is
  /// what stands in for pumpAndSettle while something is being saved.
  Future<void> settleUntilIdle(WidgetTester tester) async {
    for (var i = 0; i < 120; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump(const Duration(milliseconds: 16));
      if (find.byKey(const Key('add-picture-busy')).evaluate().isEmpty) break;
    }
    await tester.pumpAndSettle();
  }

  Future<void> openSheet(WidgetTester tester) async {
    // Below the picture grid, off the test window's 600 px at first.
    await tester.ensureVisible(find.byKey(const Key('draft-add-picture')));
    await tester.pumpAndSettle();
    // The key is on the full-width row; the button sits at its start.
    await tester.tap(find.text('Add picture'));
    await tester.pumpAndSettle();
  }

  testWidgets('the sheet offers the gallery, a link, and a search',
      (tester) async {
    await boot(tester);
    expect(find.text('Add picture'), findsOneWidget);
    await openSheet(tester);
    expect(find.text('From your gallery'), findsOneWidget);
    expect(find.text('From a link'), findsOneWidget);
    expect(find.text('Search the web'), findsOneWidget);

    // The gallery choice hands over to the gallery picker.
    await tester.tap(find.byKey(const Key('add-picture-gallery')));
    await tester.pumpAndSettle();
    expect(find.text('From a link'), findsNothing);
    expect(find.text('Choose from your gallery'), findsOneWidget);
  });

  testWidgets('a link is previewed with its credit, then set as the avatar',
      (tester) async {
    routes['www.pinterest.com/pin/7/'] = (_) => http.Response(
          '<head><meta property="og:image" content="https://i.pinimg.com/736x/a/b.jpg">'
          '<meta property="og:title" content="Keeper at dusk">'
          '<meta property="og:site_name" content="Pinterest"></head>',
          200,
          headers: {'content-type': 'text/html'},
        );
    routes['i.pinimg.com/originals/a/b.jpg'] = (_) =>
        http.Response.bytes(png, 200, headers: {'content-type': 'image/png'});
    final (state, controller) = await boot(tester);
    await openSheet(tester);
    await tester.tap(find.byKey(const Key('add-picture-link')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('add-picture-link-field')),
      'https://www.pinterest.com/pin/7/',
    );
    await tester.tap(find.byKey(const Key('add-picture-find')));
    await settle(tester);
    await tester.pumpAndSettle();

    expect(find.text('Use this picture?'), findsOneWidget);
    expect(find.byKey(const Key('add-picture-preview')), findsOneWidget);
    expect(find.text('Keeper at dusk'), findsOneWidget);
    expect(find.textContaining('Pinterest'), findsOneWidget);
    // Nothing is saved until it is chosen.
    expect(state.gallery, isEmpty);

    await tester.tap(find.byKey(const Key('add-picture-set-avatar')));
    await settleUntilIdle(tester);

    final c = controller.session.workspace.character;
    expect(c.avatar, startsWith('local:'));
    expect(c.avatar, isNot('local:old.png'));
    expect(c.avatars, ['local:old.png']);
    expect(controller.session.ops.single.tool, 'manual');
    final record = state.gallery.single;
    expect(record.image, c.avatar);
    expect(record.source, 'https://www.pinterest.com/pin/7/');
    expect(record.credit, 'Pinterest');
    expect(record.characterId, 'c1');
    // The sheet has closed.
    expect(find.text('Use this picture?'), findsNothing);
    // Let the session's own save land before the folder is deleted. (Not
    // `runAsync(controller.flush)`: that future belongs to the fake zone and
    // would never complete inside runAsync.)
    await settle(tester);
  });

  testWidgets('a page with no picture says what to do instead', (tester) async {
    routes['art.example/post'] = (_) =>
        http.Response('<p>words only</p>', 200, headers: {'content-type': 'text/html'});
    await boot(tester);
    await openSheet(tester);
    await tester.tap(find.byKey(const Key('add-picture-link')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('add-picture-link-field')),
      'https://art.example/post',
    );
    await tester.tap(find.byKey(const Key('add-picture-find')));
    await settle(tester);
    await tester.pumpAndSettle();
    final error = tester.widget<Text>(find.byKey(const Key('add-picture-error')));
    expect(error.data, contains('Open the picture itself'));
    expect(find.text('Use this picture?'), findsNothing);
  });

  testWidgets('a search result is previewed and added to the pictures',
      (tester) async {
    routes['api.openverse.org/v1/images/'] = (r) => http.Response(
          jsonEncode({
            'results': [
              {
                'url': 'https://cdn.example/keeper.png',
                // No file behind it: the grid draws its placeholder.
                'thumbnail': 'local:missing-thumb.png',
                'title': 'Keeper',
                'creator': 'Jane Doe',
                'license': 'by',
                'license_version': '4.0',
                'foreign_landing_url': 'https://flickr.example/p/1',
              },
            ],
          }),
          200,
        );
    routes['cdn.example/keeper.png'] = (_) =>
        http.Response.bytes(png, 200, headers: {'content-type': 'image/png'});
    final (state, controller) = await boot(tester);
    await openSheet(tester);
    await tester.tap(find.byKey(const Key('add-picture-search')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('add-picture-query')), 'keeper');
    await tester.tap(find.byKey(const Key('add-picture-run-search')));
    await settle(tester);
    await tester.pumpAndSettle();
    expect(find.text('by Jane Doe · CC BY 4.0'), findsOneWidget);

    await tester.tap(find.byKey(const Key('add-picture-result-0')));
    await settle(tester);
    await tester.pumpAndSettle();
    expect(find.text('Use this picture?'), findsOneWidget);

    await tester.tap(find.byKey(const Key('add-picture-add-pool')));
    await settleUntilIdle(tester);
    final c = controller.session.workspace.character;
    expect(c.avatar, 'local:old.png');
    expect(c.avatars.single, startsWith('local:'));
    expect(state.gallery.single.source, 'https://flickr.example/p/1');
    expect(state.gallery.single.credit, 'by Jane Doe · CC BY 4.0');
    // Let the session's own save land before the folder is deleted. (Not
    // `runAsync(controller.flush)`: that future belongs to the fake zone and
    // would never complete inside runAsync.)
    await settle(tester);
  });

  testWidgets('back goes back a page', (tester) async {
    await boot(tester);
    await openSheet(tester);
    await tester.tap(find.byKey(const Key('add-picture-search')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('add-picture-back')));
    await tester.pumpAndSettle();
    expect(find.text('From your gallery'), findsOneWidget);
  });
}
