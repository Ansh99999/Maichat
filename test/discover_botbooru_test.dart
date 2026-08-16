import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/discover.dart';
import 'package:maichat/services/discover/botbooru_source.dart';
import 'package:maichat/services/discover/discover_source.dart';

String _cardJson(String name) => jsonEncode({
      'spec': 'chara_card_v2',
      'spec_version': '2.0',
      'data': {
        'name': name,
        'description': 'the definition',
        'first_mes': 'Hi.',
        'creator': 'someone',
      },
    });

/// Botbooru is a booru, so its listing talks about *posts* — an upload with tags
/// and its own display name — while the card underneath is a separate download.
/// These pin the two apart, and pin the paging arithmetic, which is offsets
/// rather than page numbers.
void main() {
  group('request building', () {
    final source = BotbooruSource(siteBase: 'https://booru.example');

    test('a feed turns a page number into an offset', () {
      final uri = source.searchUri(const DiscoverQuery(page: 3, pageSize: 24));
      expect(uri.path, '/posts/');
      expect(uri.queryParameters['limit'], '24');
      expect(uri.queryParameters['offset'], '48');
    });

    test('an unset sort is the site default, latest', () {
      expect(
        source.searchUri(const DiscoverQuery()).queryParameters['sort'],
        'latest',
      );
    });

    test('tags ride in the same search box as the words', () {
      // The site has no separate tag parameter; its own tag links pass the tag
      // name as `q`, and a leading `-` subtracts one.
      final q = source
          .searchUri(const DiscoverQuery(
            search: 'ranger',
            includeTags: ['anime', 'fantasy'],
            excludeTags: ['gore'],
          ))
          .queryParameters;
      expect(q['q'], 'ranger anime fantasy -gore');
    });

    test('a popularity order carries its window as its own parameter', () {
      final week = source
          .searchUri(const DiscoverQuery(sort: 'favorites:week'))
          .queryParameters;
      expect(week['sort'], 'favorites');
      expect(week['time_window'], 'week');

      final allTime =
          source.searchUri(const DiscoverQuery(sort: 'favorites')).queryParameters;
      expect(allTime['sort'], 'favorites');
      expect(allTime.containsKey('time_window'), isFalse);

      expect(BotbooruSource.splitSort('views:day'), ('views', 'day'));
      expect(BotbooruSource.splitSort('latest'), ('latest', null));
      expect(BotbooruSource.splitSort(''), ('latest', null));
    });

    test('the adult switch is a positive SFW filter, and only when asked', () {
      expect(
        source.searchUri(const DiscoverQuery()).queryParameters['sfw_only'],
        'true',
      );
      expect(
        source
            .searchUri(const DiscoverQuery(nsfw: true))
            .queryParameters
            .containsKey('sfw_only'),
        isFalse,
      );
    });
  });

  group('reading a post', () {
    final source = BotbooruSource(siteBase: 'https://booru.example');

    test('maps a post, preferring the booru label over the card name', () {
      final item = source.itemFrom(<String, dynamic>{
        'id': 73550,
        'filename': '98db1b25414341a6819c279559f2d937.png',
        'card_image_revision': 2,
        'character_name': 'Mental Health Bot. ',
        'meta_name': 'Therapy Bot',
        'tags': [
          {'id': 21, 'name': 'non-human', 'category': 'General'},
          {'id': 25, 'name': 'helpful', 'category': 'General'},
        ],
        'token_count': 704,
        'downloads': 42,
        'favorite_count': 3,
        'description_excerpt': '{{char}} is a chat bot',
        'creator_notes_excerpt': 'notes',
        'tagline': '',
        'created_at': '2026-08-15T03:57:32.984171',
      })!;

      expect(item.id, '73550');
      // An uploader can rename a card for the booru without touching the card.
      expect(item.name, 'Therapy Bot');
      expect(item.tags, ['non-human', 'helpful']);
      expect(item.tokens, 704);
      expect(item.downloads, 42);
      expect(item.favourites, 3);
      expect(item.description, '{{char}} is a chat bot');
      expect(item.createdAt?.year, 2026);
      expect(item.pageUrl, 'https://booru.example/character/73550');
      expect(
        item.thumbnailUrl,
        'https://booru.example/images/preview/320/'
        '98db1b25414341a6819c279559f2d937.png?v=2',
      );
      expect(item.imageUrl, contains('/preview/640/'));
    });

    test('with no booru label the card name is used', () {
      final item = source.itemFrom(<String, dynamic>{
        'id': 1,
        'character_name': 'Konata',
        'meta_name': '',
        'filename': 'a.png',
      })!;
      expect(item.name, 'Konata');
    });

    test('a post with no id is skipped', () {
      expect(source.itemFrom(<String, dynamic>{'character_name': 'x'}), isNull);
    });

    test('a post with no file has no thumbnail rather than a broken one', () {
      final item = source.itemFrom(<String, dynamic>{'id': 4, 'filename': ''})!;
      expect(item.thumbnailUrl, isNull);
    });

    test('the writer tag is the credit, not the uploader', () {
      // An upload's account is whoever posted it here, which is often not who
      // wrote the card; the booru credits the writer through a tag.
      final item = source.itemFrom(<String, dynamic>{
        'id': 9,
        'character_name': 'Konata',
        'filename': 'a.png',
        'tags': [
          {'name': 'anime'},
          {'name': 'writer:kagami', 'category': 'Auto'},
        ],
      })!;
      expect(item.creator, 'kagami');
      expect(BotbooruSource.writerFrom(const ['anime']), '');
    });
  });

  group('against a server', () {
    late HttpServer server;
    late String base;
    late BotbooruSource source;
    final requests = <String>[];
    late Map<String, Object> routes;

    setUp(() async {
      requests.clear();
      routes = <String, Object>{};
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://${server.address.host}:${server.port}';
      source = BotbooruSource(siteBase: base);
      server.listen((request) async {
        requests.add('${request.uri}');
        Object? body;
        for (final entry in routes.entries) {
          if ('${request.uri}'.contains(entry.key)) {
            body = entry.value;
            break;
          }
        }
        if (body == null) {
          request.response.statusCode = 404;
          await request.response.close();
          return;
        }
        if (body is List<int>) {
          request.response.headers.contentType = ContentType('image', 'png');
          request.response.add(body);
        } else {
          request.response.headers.contentType = ContentType.json;
          request.response.write(body);
        }
        await request.response.close();
      });
    });

    tearDown(() async {
      source.close();
      await server.close(force: true);
    });

    String feed({int total = 100}) => jsonEncode({
          'total': total,
          'posts': [
            {
              'id': 1,
              'filename': 'one.png',
              'character_name': 'One',
              'tags': [
                {'id': 1, 'name': 'anime'}
              ],
            },
            {
              'id': 2,
              'filename': 'two.png',
              'character_name': 'Two',
              'tags': const <Object>[],
            },
          ],
        });

    test('the total decides whether there is more, not the page size', () async {
      routes['/posts/'] = feed();
      final page = await source.search(const DiscoverQuery(pageSize: 2));
      expect(page.items.map((i) => i.name), ['One', 'Two']);
      expect(page.hasMore, isTrue);

      routes['/posts/'] = feed(total: 2);
      final last = await source.search(const DiscoverQuery(pageSize: 2));
      expect(last.hasMore, isFalse);
    });

    test('a download takes the JSON card, not the megabyte PNG', () async {
      routes['/posts/'] = feed();
      routes['/download/json/1'] = _cardJson('One');
      routes['/images/preview/'] = <int>[137, 80, 78, 71, 13, 10, 26, 10, 1, 2];
      final page = await source.search(const DiscoverQuery(pageSize: 2));
      final payload = await source.fetch(page.items.first);

      expect(payload.character?.name, 'One');
      expect(payload.character?.description, 'the definition');
      expect(requests.where((r) => r.contains('/download/png/')), isEmpty);
      // The JSON card has no picture, so the booru's thumbnail becomes one.
      expect(payload.character?.avatar, isNotEmpty);
      expect(requests.where((r) => r.contains('/images/preview/')).length, 1);
    });

    test('the post fills in tags the card left off', () async {
      routes['/posts/'] = feed();
      routes['/download/json/1'] = jsonEncode({
        'spec': 'chara_card_v2',
        'spec_version': '2.0',
        'data': {'name': 'One', 'description': 'x', 'tags': const <String>[]},
      });
      final page = await source.search(const DiscoverQuery(pageSize: 2));
      final character = (await source.fetch(page.items.first)).character!;
      expect(character.tags, ['anime']);
    });

    test('something that is not a card fails with a sentence', () async {
      routes['/posts/'] = feed();
      routes['/download/json/1'] = jsonEncode({'detail': 'Not found'});
      final page = await source.search(const DiscoverQuery(pageSize: 2));
      await expectLater(
        source.fetch(page.items.first),
        throwsA(isA<DiscoverException>()),
      );
    });

    test('a card that ships only a link to its picture gets real bytes',
        () async {
      // Botbooru's JSON cards carry `avatar` as an http link to the full-size
      // original. Keeping that would leave a saved character pointing at the
      // booru forever, so the thumbnail is downloaded over the top of it.
      routes['/posts/'] = feed();
      routes['/download/json/1'] = jsonEncode({
        'spec': 'chara_card_v2',
        'spec_version': '2.0',
        'data': {
          'name': 'One',
          'description': 'x',
          'avatar': 'http://booru.example/images/one.png',
        },
      });
      routes['/images/preview/'] = <int>[137, 80, 78, 71, 13, 10, 26, 10, 9, 9];
      final page = await source.search(const DiscoverQuery(pageSize: 2));
      final character = (await source.fetch(page.items.first)).character!;
      expect(character.avatarIsUrl, isFalse);
      expect(character.avatarBytes, isNotNull);
    });

    test('a missing thumbnail does not fail the download', () async {
      routes['/posts/'] = feed();
      routes['/download/json/1'] = _cardJson('One');
      // No /images/preview route: the server answers 404.
      final page = await source.search(const DiscoverQuery(pageSize: 2));
      final character = (await source.fetch(page.items.first)).character!;
      expect(character.name, 'One');
      // The link is kept rather than the picture being lost silently.
      expect(character.avatar, contains('/images/preview/'));
    });
  });
}
