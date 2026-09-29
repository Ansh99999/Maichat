import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maichat/models/agent_message.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/gallery_image.dart';
import 'package:maichat/models/lorebook.dart';
import 'package:maichat/models/studio.dart';
import 'package:maichat/services/avatar_store.dart';
import 'package:maichat/services/studio/image_tools.dart';
import 'package:maichat/services/studio/studio_controller.dart';
import 'package:maichat/services/studio/studio_images.dart';
import 'package:maichat/services/studio/studio_store.dart';
import 'package:maichat/services/studio/studio_tools.dart';
import 'package:maichat/screens/studio/studio_agent_view.dart';
import 'package:maichat/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Pictures from the web and the gallery, end to end without the network: a
/// stand-in web (`MockClient`) serving small pages modelled on the real ones,
/// and a stand-in DNS that says which hosts are public.
///
/// Plain `test()`s on purpose: a `testWidgets` anywhere in this file would make
/// real HTTP answer 400 (see CLAUDE.md), and the filing tests below write real
/// files.

/// A real 1×1 PNG — the bytes a picture host would send.
final Uint8List png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DAwAAABQABg1z0GwAAAABJRU5ErkJggg==',
);

/// JPEG's magic, then filler — enough for the sniffer.
final Uint8List jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, ...List.filled(40, 7)]);

/// Hosts the stand-in DNS resolves, and to what.
const Map<String, String> dns = {
  'www.pinterest.com': '151.101.0.84',
  'i.pinimg.com': '151.101.0.84',
  'www.deviantart.com': '13.35.0.1',
  'images-wixmp.example': '13.35.0.2',
  'art.example': '93.184.216.34',
  'cdn.example': '93.184.216.35',
  'sneaky.example': '93.184.216.36',
  'intranet.example': '10.0.0.7',
  'api.openverse.org': '1.1.1.1',
  'commons.wikimedia.org': '1.1.1.2',
};

Future<List<InternetAddress>> lookup(String host) async {
  final ip = dns[host];
  if (ip == null) throw const SocketException('no such host');
  return [InternetAddress(ip)];
}

http.Response image(Uint8List bytes, [String type = 'image/png']) =>
    http.Response.bytes(bytes, 200, headers: {'content-type': type});

http.Response page(String html) => http.Response(html, 200,
    headers: {'content-type': 'text/html; charset=utf-8'});

/// A small Pinterest pin page, shaped like the real one's head.
const String pinterestPin = '''
<!DOCTYPE html><html><head>
<title>Lighthouse keeper | Pinterest</title>
<meta content="Lighthouse keeper at dusk" data-app="true" name="og:title" property="og:title"/>
<meta content="https://i.pinimg.com/736x/30/de/7c/30de7caee65927bd0cac2c010c49a787.jpg" data-app="true" name="og:image" property="og:image"/>
<meta content="1104" data-app="true" name="og:image:height" property="og:image:height"/>
<meta content="Pinterest" property="og:site_name"/>
</head><body><div id="root"></div></body></html>
''';

void main() {
  late List<String> asked;
  late Map<String, http.Response Function(http.Request)> routes;

  StudioImages images({int maxBytes = kMaxPictureBytes}) {
    asked = [];
    return StudioImages(
      client: () => MockClient((request) async {
        asked.add(request.url.toString());
        final key = '${request.url.host}${request.url.path}';
        final route = routes[key];
        if (route == null) return http.Response('not found', 404);
        return route(request);
      }),
      lookup: lookup,
      maxBytes: maxBytes,
    );
  }

  setUp(() => routes = {});

  group('search', () {
    test('Openverse results carry the picture, the page, and the credit',
        () async {
      routes['api.openverse.org/v1/images/'] = (r) {
        expect(r.url.queryParameters['q'], 'lighthouse keeper');
        expect(r.url.queryParameters['mature'], 'false');
        return http.Response(
          jsonEncode({
            'result_count': 1,
            'results': [
              {
                'id': 'a',
                'title': "Lighthouse Keeper's House",
                'foreign_landing_url': 'https://www.flickr.com/photos/x/1',
                'url': 'https://live.staticflickr.com/1_b.jpg',
                'creator': 'archer10 (Dennis)',
                'license': 'by-sa',
                'license_version': '2.0',
                'license_url': 'https://creativecommons.org/licenses/by-sa/2.0/',
                'width': 1024,
                'height': 680,
                'thumbnail': 'https://api.openverse.org/v1/images/a/thumb/',
              },
              {'id': 'no-url', 'title': 'skipped'},
            ],
          }),
          200,
        );
      };
      final found = await images().search('lighthouse keeper');
      expect(found, hasLength(1));
      final c = found.single;
      expect(c.url, 'https://live.staticflickr.com/1_b.jpg');
      expect(c.thumbnail, contains('/thumb/'));
      expect(c.page, 'https://www.flickr.com/photos/x/1');
      expect(c.license, 'CC BY-SA 2.0');
      expect(c.credit, 'by archer10 (Dennis) · CC BY-SA 2.0');
      expect(c.toJson()['size'], '1024x680');
    });

    test('Commons results are ordered, de-marked-up, and skip non-pictures',
        () async {
      routes['commons.wikimedia.org/w/api.php'] = (r) {
        expect(r.url.queryParameters['gsrnamespace'], '6');
        return http.Response(
          jsonEncode({
            'query': {
              'pages': [
                {
                  'index': 2,
                  'title': 'File:Second.jpg',
                  'imageinfo': [
                    {
                      'url': 'https://upload.wikimedia.org/second.jpg',
                      'thumburl': 'https://thumb.wikimedia.org/second.jpg',
                      'descriptionurl': 'https://commons.wikimedia.org/wiki/File:Second.jpg',
                      'mime': 'image/jpeg',
                      'width': 10,
                      'height': 20,
                      'extmetadata': {
                        'Artist': {
                          'value':
                              'Unknown author<span style="display: none;">Unknown author</span>',
                        },
                        'LicenseShortName': {'value': 'Public domain'},
                      },
                    },
                  ],
                },
                {
                  'index': 1,
                  'title': 'File:First keeper.png',
                  'imageinfo': [
                    {
                      'url': 'https://upload.wikimedia.org/first.png',
                      'mime': 'image/png',
                      'extmetadata': {
                        'Artist': {'value': '<a href="x">Jane Doe</a>'},
                        'LicenseShortName': {'value': 'CC BY 4.0'},
                      },
                    },
                  ],
                },
                {
                  'index': 3,
                  'title': 'File:Sound.ogg',
                  'imageinfo': [
                    {'url': 'https://upload.wikimedia.org/sound.ogg', 'mime': 'audio/ogg'},
                  ],
                },
              ],
            },
          }),
          200,
        );
      };
      final found = await images().search('keeper', source: ImageSource.commons);
      expect(found.map((c) => c.title), ['First keeper', 'Second']);
      expect(found.first.creator, 'Jane Doe');
      expect(found.first.thumbnail, 'https://upload.wikimedia.org/first.png');
      expect(found[1].creator, 'Unknown author');
      expect(found[1].license, 'Public domain');
    });

    test('an empty search and a busy service are said in words', () async {
      await expectLater(images().search('  '), throwsA(isA<ImageError>()));
      routes['api.openverse.org/v1/images/'] = (_) => http.Response('', 429);
      await expectLater(
        images().search('x'),
        throwsA(isA<ImageError>().having((e) => e.message, 'message', contains('busy'))),
      );
    });
  });

  group('a page\'s picture', () {
    Uri base = Uri.parse('https://art.example/post/1');

    test('og:image, preferring its secure twin', () {
      final p = pictureOfPage('''
<head>
<meta property="og:image" content="http://art.example/a.jpg">
<meta property="og:image:secure_url" content="https://art.example/a-secure.jpg">
<meta property="og:title" content="Keeper &amp; lamp">
<meta name="author" content="Jane Doe">
<meta property="og:site_name" content="ArtPlace">
</head>''', base)!;
      expect(p.urls.first, 'https://art.example/a-secure.jpg');
      expect(p.urls, contains('http://art.example/a.jpg'));
      expect(p.title, 'Keeper & lamp');
      expect(p.credit, 'by Jane Doe · ArtPlace');
    });

    test('twitter:image, then link rel=image_src, resolved relative', () {
      expect(
        pictureOfPage('<meta name="twitter:image" content="/t.png">', base)!.urls,
        ['https://art.example/t.png'],
      );
      expect(
        pictureOfPage('<link rel="image_src" href="//cdn.example/s.jpg">', base)!.urls,
        ['https://cdn.example/s.jpg'],
      );
    });

    test('with no tags, the largest plausible <img>, skipping icons', () {
      final p = pictureOfPage('''
<img src="/icon.png" width="16" height="16">
<img src="data:image/png;base64,AAAA" width="900" height="900">
<img src="/small.jpg" width="200" height="200">
<img src="/big.jpg" srcset="/big-800.jpg 800w, /big-1600.jpg 1600w">
<img src="/logo.svg" width="1000" height="1000">
''', base)!;
      expect(p.urls.single, 'https://art.example/big-1600.jpg');
      expect(p.credit, 'art.example');
    });

    test('nothing at all is null', () {
      expect(pictureOfPage('<p>just words</p>', base), isNull);
    });

    test("Pinterest's sized picture comes after its original", () {
      final p = pictureOfPage(pinterestPin, Uri.parse('https://www.pinterest.com/pin/1/'))!;
      expect(p.urls, [
        'https://i.pinimg.com/originals/30/de/7c/30de7caee65927bd0cac2c010c49a787.jpg',
        'https://i.pinimg.com/736x/30/de/7c/30de7caee65927bd0cac2c010c49a787.jpg',
      ]);
      expect(p.title, 'Lighthouse keeper at dusk');
      expect(p.credit, 'Pinterest');
      expect(pinterestOriginal('https://i.pinimg.com/originals/a/b.jpg'), isNull);
      expect(pinterestOriginal('https://example.com/736x/a.jpg'), isNull);
    });
  });

  group('fetching', () {
    test('a Pinterest pin gives its original picture, credited', () async {
      routes['www.pinterest.com/pin/1407443629011015/'] = (_) => page(pinterestPin);
      routes['i.pinimg.com/originals/30/de/7c/30de7caee65927bd0cac2c010c49a787.jpg'] =
          (r) {
        expect(r.headers['referer'], 'https://www.pinterest.com/pin/1407443629011015/');
        return image(jpeg, 'image/jpeg');
      };
      final picture = await images()
          .fetchPicture('https://www.pinterest.com/pin/1407443629011015/');
      expect(picture.mime, 'image/jpeg');
      expect(picture.url, contains('/originals/'));
      expect(picture.page, 'https://www.pinterest.com/pin/1407443629011015/');
      expect(picture.credit, 'Pinterest');
      expect(picture.source, picture.page);
    });

    test('when the original is refused, the sized one is used', () async {
      routes['www.pinterest.com/pin/1/'] = (_) => page(pinterestPin);
      routes['i.pinimg.com/originals/30/de/7c/30de7caee65927bd0cac2c010c49a787.jpg'] =
          (_) => http.Response('nope', 403);
      routes['i.pinimg.com/736x/30/de/7c/30de7caee65927bd0cac2c010c49a787.jpg'] =
          (_) => image(jpeg, 'image/jpeg');
      final picture = await images().fetchPicture('https://www.pinterest.com/pin/1/');
      expect(picture.url, contains('/736x/'));
    });

    test("a picture's own link is the picture", () async {
      routes['cdn.example/p.png'] = (_) => image(png);
      final picture = await images().fetchPicture('https://cdn.example/p.png');
      expect(picture.mime, 'image/png');
      expect(picture.bytes, png);
      expect(picture.page, '');
      expect(picture.source, 'https://cdn.example/p.png');
    });

    test('a download that is not really a picture is refused', () async {
      routes['cdn.example/fake.png'] =
          (_) => image(Uint8List.fromList(utf8.encode('<html>hi</html>')));
      await expectLater(
        images().fetchPicture('https://cdn.example/fake.png'),
        throwsA(isA<ImageError>()
            .having((e) => e.message, 'message', contains('not one I can use'))),
      );
      routes['cdn.example/notes.txt'] = (_) => http.Response('words', 200,
          headers: {'content-type': 'text/plain'});
      await expectLater(
        images().fetchPicture('https://cdn.example/notes.txt'),
        throwsA(isA<ImageError>()
            .having((e) => e.message, 'message', contains('text/plain'))),
      );
    });

    test('a picture over the size cap is refused', () async {
      routes['cdn.example/big.png'] =
          (_) => image(Uint8List.fromList([...png, ...List.filled(5000, 0)]));
      await expectLater(
        images(maxBytes: 2000).fetchPicture('https://cdn.example/big.png'),
        throwsA(isA<ImageError>().having((e) => e.message, 'message', contains('too big'))),
      );
    });

    test('a page with no picture says what to do instead', () async {
      routes['art.example/empty'] = (_) => page('<p>no pictures here</p>');
      await expectLater(
        images().fetchPicture('https://art.example/empty'),
        throwsA(isA<ImageError>()
            .having((e) => e.message, 'message', contains("picture itself"))),
      );
    });

    test('blocked sites are named, not a bare failure', () async {
      routes['www.deviantart.com/art/keeper-1'] = (_) => http.Response('', 403);
      await expectLater(
        images().fetchPicture('https://www.deviantart.com/art/keeper-1'),
        throwsA(isA<ImageError>().having(
            (e) => e.message, 'message', contains('save it to your gallery'))),
      );
    });

    group('never reaches the device or its network', () {
      Future<void> refused(String url) => expectLater(
            images().fetchPicture(url),
            throwsA(isA<ImageError>().having(
                (e) => e.message, 'message', contains('this device or its network'))),
          );

      test('literal addresses', () async {
        await refused('http://127.0.0.1/p.png');
        await refused('http://192.168.1.10/p.png');
        await refused('http://[::1]/p.png');
        await refused('http://localhost/p.png');
        expect(asked, isEmpty);
      });

      test('a host that resolves inside', () async {
        await refused('https://intranet.example/p.png');
        expect(asked, isEmpty);
      });

      test('a redirect that points inside, checked at every hop', () async {
        routes['sneaky.example/p.png'] = (_) => http.Response('', 302,
            headers: {'location': 'http://intranet.example/secret.png'});
        routes['intranet.example/secret.png'] = (_) => image(png);
        await refused('https://sneaky.example/p.png');
        expect(asked, ['https://sneaky.example/p.png']);
      });

      test('only web addresses', () async {
        await expectLater(
          images().fetchPicture('file:///etc/passwd'),
          throwsA(isA<ImageError>()),
        );
      });
    });
  });

  test('the sniffer knows PNG, JPEG, GIF and WebP by their bytes', () {
    expect(sniffPicture(png), 'image/png');
    expect(sniffPicture(jpeg), 'image/jpeg');
    expect(sniffPicture(Uint8List.fromList(utf8.encode('GIF89a...'))), 'image/gif');
    expect(
      sniffPicture(Uint8List.fromList([...utf8.encode('RIFF'), 1, 2, 3, 4, ...utf8.encode('WEBPVP8 ')])),
      'image/webp',
    );
    expect(sniffPicture(Uint8List.fromList(utf8.encode('<svg/>'))), isNull);
  });

  test('a gallery record keeps its source and credit, and reads old records',
      () {
    final g = GalleryImage(
      id: 'g',
      image: 'local:a.png',
      source: 'https://www.pinterest.com/pin/1/',
      credit: 'Pinterest',
    );
    final back = GalleryImage.fromJson(g.toJson());
    expect(back.source, 'https://www.pinterest.com/pin/1/');
    expect(back.credit, 'Pinterest');
    final old = GalleryImage.fromJson({'id': 'o', 'image': 'local:b.png'});
    expect(old.source, '');
    expect(old.credit, '');
    expect(GalleryImage(id: 'n', image: 'x').toJson().containsKey('source'), isFalse);
  });

  group('filing', () {
    late Directory dir;
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      dir = Directory.systemTemp.createTempSync('studio_images');
    });
    tearDown(() {
      dir.deleteSync(recursive: true);
      avatarDirectory = null;
    });

    test('a web picture becomes a file in the gallery, never base64', () async {
      final state = AppState(avatars: AvatarStore(dir));
      await state.init();
      final record = await filePictureFromWeb(
        state,
        WebPicture(
          bytes: png,
          mime: 'image/png',
          url: 'https://i.pinimg.com/originals/a.jpg',
          page: 'https://www.pinterest.com/pin/1/',
          title: 'Lighthouse keeper at dusk',
          credit: 'Pinterest',
        ),
        characterId: 'c1',
      );
      expect(record, isNotNull);
      expect(record!.image, startsWith('local:'));
      expect(avatarRefFile(record.image)!.readAsBytesSync(), png);
      expect(record.source, 'https://www.pinterest.com/pin/1/');
      expect(record.credit, 'Pinterest');
      expect(record.title, 'Lighthouse keeper at dusk');
      expect(record.characterId, 'c1');
      expect(state.gallery.single.id, record.id);
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString('gallery') ?? '';
      expect(stored, contains('"source"'));
      expect(stored, isNot(contains(base64Encode(png))));
    });
  });

  group('the tools', () {
    late _Pictures services;
    late StudioSession session;
    late StudioToolContext ctx;

    setUp(() {
      routes = {};
      services = _Pictures(images());
      session = StudioSession(
        id: 's',
        title: '',
        workspace: StudioWorkspace(
          character: Character(id: 'c1', name: 'Maren', avatar: 'local:old.png'),
        ),
      );
      ctx = StudioToolContext(session: session, services: services);
    });

    Future<StudioToolResult> call(String tool, Map<String, dynamic> args) =>
        kStudioTools[tool]!.call(ctx, args);
    Map<String, dynamic> json(StudioToolResult r) =>
        jsonDecode(r.text) as Map<String, dynamic>;

    test('are registered, and in the pictures group', () {
      for (final name in kImageToolNames) {
        expect(kStudioTools, contains(name));
      }
      expect(studioToolsFor('studio').map((t) => t.name), containsAll(kImageToolNames));
    });

    test('search_images numbers its candidates', () async {
      routes['api.openverse.org/v1/images/'] = (_) => http.Response(
            jsonEncode({
              'results': [
                {'url': 'https://cdn.example/1.jpg', 'title': 'One', 'creator': 'A'},
                {'url': 'https://cdn.example/2.jpg', 'title': 'Two'},
              ],
            }),
            200,
          );
      final r = await call('search_images', {'query': 'keeper'});
      expect(r.isError, isFalse);
      final candidates = (json(r)['candidates'] as List).cast<Map>();
      expect(candidates.map((c) => c['n']), [1, 2]);
      expect(candidates.first['creator'], 'A');
      // What the chip shows.
      expect(pictureRefsOf(r.text).map((p) => p.full),
          ['https://cdn.example/1.jpg', 'https://cdn.example/2.jpg']);
    });

    test('set_avatar_from_url makes it the avatar, keeps the old one, and '
        'can be rewound', () async {
      routes['www.pinterest.com/pin/9/'] = (_) => page(pinterestPin);
      routes['i.pinimg.com/originals/30/de/7c/30de7caee65927bd0cac2c010c49a787.jpg'] =
          (_) => image(jpeg, 'image/jpeg');
      final r = await call('set_avatar_from_url', {'url': 'https://www.pinterest.com/pin/9/'});
      expect(r.isError, isFalse, reason: r.text);
      final c = session.workspace.character;
      expect(c.avatar, 'local:filed-1.png');
      expect(c.avatars, ['local:old.png']);
      expect(services.filed.single.credit, 'Pinterest');
      expect(json(r)['credit'], 'Pinterest');
      expect(session.ops.last.tool, 'set_avatar_from_url');
      session.rewindTo(session.ops.length - 1);
      expect(session.workspace.character.avatar, 'local:old.png');
      expect(session.workspace.character.avatars, isEmpty);
    });

    test('as pool, it joins the extra pictures', () async {
      routes['cdn.example/p.png'] = (_) => image(png);
      await call('set_avatar_from_url', {'url': 'https://cdn.example/p.png', 'as': 'pool'});
      final c = session.workspace.character;
      expect(c.avatar, 'local:old.png');
      expect(c.avatars, ['local:filed-1.png']);
    });

    test('failures come back as sentences the model can act on', () async {
      routes['art.example/empty'] = (_) => page('<p>nothing</p>');
      final r = await call('set_avatar_from_url', {'url': 'https://art.example/empty'});
      expect(r.isError, isTrue);
      expect(r.text, contains('picture itself'));
      final bad = await call('set_avatar_from_url', {'url': 'https://cdn.example/x', 'as': 'banner'});
      expect(bad.isError, isTrue);
      expect((jsonDecode(bad.text) as Map)['error'], startsWith('"as" is'));
      expect(session.ops, isEmpty);
    });

    test('list_gallery and use_gallery_picture use the user\'s own pictures',
        () async {
      services.gallery = [
        GalleryImage(id: 'g1', image: 'local:sea.png', title: 'Sea at night', tags: ['moody']),
        GalleryImage(id: 'g2', image: 'local:cat.png', title: 'Cat'),
      ];
      final all = json(await call('list_gallery', {}));
      expect(all['count'], 2);
      final moody = json(await call('list_gallery', {'query': 'MOODY'}));
      expect((moody['pictures'] as List).single['id'], 'g1');
      final used = await call('use_gallery_picture', {'id': 'g1'});
      expect(used.isError, isFalse);
      expect(session.workspace.character.avatar, 'local:sea.png');
      expect(session.workspace.character.avatars, ['local:old.png']);
      final missing = await call('use_gallery_picture', {'id': 'nope'});
      expect(missing.isError, isTrue);
      expect(missing.text, contains('list_gallery'));
    });

    test('without picture services the tools say so', () async {
      final bare = StudioToolContext(session: session, services: _Bare());
      final r = await kStudioTools['list_gallery']!.call(bare, {});
      expect(r.isError, isTrue);
      expect(r.text, contains('Pictures cannot be fetched here'));
    });
  });

  test('a draft\'s avatar and pool pictures are kept by the sweep', () async {
    final dir = Directory.systemTemp.createTempSync('studio_images_store');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = StudioStore(dir);
    await store.save(StudioSession(
      id: 'k',
      title: '',
      workspace: StudioWorkspace(
        character: Character(
          id: 'c',
          name: 'M',
          avatar: 'local:web-avatar.png',
          avatars: ['local:web-pool.png'],
        ),
      ),
    ));
    expect(await store.pictureRefs(),
        containsAll(['local:web-avatar.png', 'local:web-pool.png']));
  });

  test('the chip line for each picture tool reads plainly', () {
    String line(String name, Map<String, dynamic> args) =>
        describeCall(ToolCall(id: 'x', name: name, arguments: args));
    expect(line('search_images', {'query': 'keeper'}), 'Looked for pictures: "keeper"');
    expect(line('set_avatar_from_url', {'url': 'u'}), 'Set a picture from the web');
    expect(line('set_avatar_from_url', {'url': 'u', 'as': 'pool'}),
        'Added a picture from the web');
    expect(line('use_gallery_picture', {'id': 'g'}), 'Set a gallery picture');
  });
}

/// Draft services with pictures: files "stored" in memory, a gallery list.
class _Pictures extends _Bare implements StudioPictureServices {
  _Pictures(this.images);

  @override
  final StudioImages images;

  final List<WebPicture> filed = <WebPicture>[];
  List<GalleryImage> gallery = <GalleryImage>[];

  @override
  Future<GalleryImage?> fileWebPicture(
    WebPicture picture, {
    required String characterId,
    String title = '',
  }) async {
    filed.add(picture);
    return GalleryImage(
      id: 'filed-${filed.length}',
      image: 'local:filed-${filed.length}.png',
      source: picture.source,
      credit: picture.credit,
      characterId: characterId,
    );
  }

  @override
  List<GalleryImage> get galleryPictures => gallery;
}

/// Draft services and nothing else.
class _Bare implements StudioServices {
  @override
  int countTokens(String text) => text.length ~/ 4;
  @override
  List<Character> get libraryCharacters => const [];
  @override
  List<Lorebook> get libraryLorebooks => const [];
  @override
  bool get canGenerateImages => false;
  @override
  Future<String> generatePicture({required String prompt, required String characterId}) =>
      throw UnimplementedError();
  @override
  Future<List<String>> playtest({
    required Character character,
    required List<Lorebook> lorebooks,
    required List<String> userTurns,
    int greetingIndex = 0,
  }) =>
      throw UnimplementedError();
  @override
  Future<StudioTaskOutcome> runTask({
    required String agentType,
    required String description,
    required String prompt,
    required String callId,
    String? taskId,
  }) =>
      throw UnimplementedError();
}
