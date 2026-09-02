// Part of the screenshot generator (see developer notes/screenshots.md).
//
// A catalogue that answers from memory. Discover's own screen takes an injected
// list of sources, so photographing that feed needs no network and no site's
// permission to reproduce its art.
import 'package:maichat/models/character.dart';
import 'package:maichat/models/discover.dart';
import 'package:maichat/services/discover/discover_source.dart';

import 'png.dart';

class DemoCatalogue extends DiscoverSource {
  const DemoCatalogue();

  @override
  String get id => 'demo';
  @override
  String get label => 'Demo catalogue';
  @override
  String get blurb =>
      'A stand-in for the real sites: this feed is generated, so no '
      'catalogue\'s listings or art are reproduced in a screenshot.';
  @override
  String get homeUrl => 'https://example.invalid';
  @override
  Set<DiscoverKind> get kinds => const {
        DiscoverKind.character,
        DiscoverKind.lorebook,
      };

  @override
  List<DiscoverSort> sortsFor(DiscoverKind kind) => const [
        DiscoverSort('trending', 'Trending'),
        DiscoverSort('download_count', 'Most downloaded'),
        DiscoverSort('created_at', 'Newest'),
      ];

  @override
  bool get supportsTagExclusion => true;

  @override
  Future<List<String>> tags(DiscoverKind kind) async => const [
        'female',
        'male',
        'oc',
        'fantasy',
        'sci-fi',
        'slice of life',
        'mystery',
        'roleplay',
        'adventure',
      ];

  /// The listings. Written out rather than generated so the feed reads like a
  /// feed: uneven names, uneven tag counts, uneven popularity.
  static const List<({String name, String creator, String line, double hue,
      int downloads, int tokens, List<String> tags, bool lore})> _shelf = [
    (
      name: 'The Lighthouse at Carrow Point',
      creator: 'saltglass',
      line: 'A keeper who has not been relieved in eleven years.',
      hue: 262,
      downloads: 18420,
      tokens: 1840,
      tags: ['oc', 'mystery', 'slice of life'],
      lore: true,
    ),
    (
      name: 'Ash of the Third District',
      creator: 'rooftiles',
      line: 'Courier. Knows every roof. Will not say who pays.',
      hue: 188,
      downloads: 9120,
      tokens: 1210,
      tags: ['oc', 'adventure'],
      lore: false,
    ),
    (
      name: 'Juniper — harbour tea stall',
      creator: 'lowtide',
      line: 'Knows everyone. Repeats nothing.',
      hue: 34,
      downloads: 4460,
      tokens: 980,
      tags: ['slice of life', 'wholesome'],
      lore: false,
    ),
    (
      name: 'Orrin Blake, cartographer',
      creator: 'twelvefathom',
      line: 'Convinced the coast is drawn wrong on purpose.',
      hue: 134,
      downloads: 2310,
      tokens: 2260,
      tags: ['oc', 'mystery', 'fantasy'],
      lore: true,
    ),
    (
      name: 'Sable, 3am',
      creator: 'nulltransmit',
      line: 'A voice on the radio, and nobody at the transmitter.',
      hue: 322,
      downloads: 15870,
      tokens: 1590,
      tags: ['horror', 'sci-fi'],
      lore: false,
    ),
    (
      name: 'Wren and the wrong timetable',
      creator: 'ferryman',
      line: 'Keeps it in her head and resents being asked.',
      hue: 216,
      downloads: 780,
      tokens: 640,
      tags: ['slice of life'],
      lore: false,
    ),
  ];

  @override
  Future<DiscoverPage> search(DiscoverQuery query) async => DiscoverPage(
        items: [
          for (var i = 0; i < _shelf.length; i++)
            DiscoverItem(
              sourceId: id,
              kind: query.kind,
              id: 'demo/$i',
              name: _shelf[i].name,
              creator: _shelf[i].creator,
              tagline: _shelf[i].line,
              description: _shelf[i].line,
              tags: _shelf[i].tags,
              thumbnailUrl: demoArtBase64(
                size: 384,
                height: 512,
                hue: _shelf[i].hue,
              ),
              downloads: _shelf[i].downloads,
              tokens: _shelf[i].tokens,
              hasLore: _shelf[i].lore,
              createdAt: DateTime.now().subtract(Duration(days: 3 + i * 5)),
            ),
        ],
        hasMore: true,
      );

  @override
  Future<DiscoverPayload> fetch(DiscoverItem item) async =>
      DiscoverPayload(character: Character(id: item.id, name: item.name));
}
