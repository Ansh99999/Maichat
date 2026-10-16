import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/home_layout.dart';

/// Every page's tiles inside the grid and clear of each other.
void expectValid(HomeLayout layout) {
  for (final page in layout.pages) {
    for (final t in page.tiles) {
      expect(t.x, greaterThanOrEqualTo(0), reason: '${t.id} x');
      expect(t.y, greaterThanOrEqualTo(0), reason: '${t.id} y');
      expect(t.w, greaterThanOrEqualTo(1));
      expect(t.h, greaterThanOrEqualTo(1));
      expect(t.right, lessThanOrEqualTo(layout.columns), reason: '${t.id} right');
      expect(t.bottom, lessThanOrEqualTo(layout.rows), reason: '${t.id} bottom');
      for (final o in page.tiles) {
        if (o.id != t.id) {
          expect(t.overlaps(o), isFalse, reason: '${t.id} overlaps ${o.id}');
        }
      }
    }
  }
}

List<HomeTile> allTiles(HomeLayout l) => [for (final p in l.pages) ...p.tiles];

HomeTile tile(String id, int x, int y, [int w = 1, int h = 1]) => HomeTile(
      id: id,
      kind: HomeWidgetKind.quickOpen,
      x: x,
      y: y,
      w: w,
      h: h,
    );

HomeLayout grid(int c, int r, List<List<HomeTile>> pages) => HomeLayout(
      columns: c,
      rows: r,
      pages: [
        for (var i = 0; i < pages.length; i++)
          HomePage(id: 'p$i', tiles: pages[i]),
      ],
    );

/// A [c] × [r] page filled with 1×1 tiles.
List<HomeTile> full(int c, int r, [String prefix = 't']) => [
      for (var y = 0; y < r; y++)
        for (var x = 0; x < c; x++) tile('$prefix$x-$y', x, y),
    ];

void main() {
  group('defaults', () {
    test('a valid 4×6 home with New chat and the Studio up front', () {
      final l = HomeLayout.defaults();
      expect(l.columns, 4);
      expect(l.rows, 6);
      expect(l.pages, hasLength(2));
      expectValid(l);
      // The Studio is on the first page, one tap away.
      expect(
        l.pages.first.tiles.any((t) => t.kind == HomeWidgetKind.studio),
        isTrue,
      );
      final targets = [
        for (final t in allTiles(l))
          if (t.kind == HomeWidgetKind.quickOpen) t.str('target'),
      ];
      expect(targets, contains('newChat'));
    });
  });

  group('fits', () {
    final l = grid(4, 6, [
      [tile('a', 0, 0, 2, 2)],
    ]);
    test('rejects what leaves the grid', () {
      expect(l.fits(0, tile('n', -1, 0)), isFalse);
      expect(l.fits(0, tile('n', 0, -1)), isFalse);
      expect(l.fits(0, tile('n', 3, 0, 2)), isFalse);
      expect(l.fits(0, tile('n', 0, 5, 1, 2)), isFalse);
      expect(l.fits(0, tile('n', 3, 5)), isTrue);
    });
    test('rejects an overlap, but a tile never collides with itself', () {
      expect(l.fits(0, tile('n', 1, 1)), isFalse);
      expect(l.fits(0, tile('a', 1, 1, 2, 2)), isTrue);
      expect(l.fits(0, tile('n', 2, 0)), isTrue);
    });
    test('rejects a page that does not exist', () {
      expect(l.fits(3, tile('n', 3, 3)), isFalse);
    });
  });

  group('firstFree', () {
    test('is row-major', () {
      final l = grid(4, 6, [
        [tile('a', 0, 0, 2, 1)],
      ]);
      expect(l.firstFree(0, 1, 1), (x: 2, y: 0));
      expect(l.firstFree(0, 3, 1), (x: 0, y: 1));
    });
    test('is null when full or when the span is bigger than the grid', () {
      expect(grid(4, 6, [full(4, 6)]).firstFree(0, 1, 1), isNull);
      expect(grid(4, 6, [[]]).firstFree(0, 5, 1), isNull);
      expect(grid(4, 6, [[]]).firstFree(0, 1, 7), isNull);
    });
  });

  group('add', () {
    test('goes where it was dropped when there is room', () {
      final r = grid(4, 6, [[]]).add(HomeWidgetKind.quickOpen, at: (x: 3, y: 4))!;
      expect((r.tile.x, r.tile.y), (3, 4));
      expect(r.page, 0);
      expectValid(r.layout);
    });
    test('falls back to the first free place', () {
      final r = grid(4, 6, [
        [tile('a', 0, 0)],
      ]).add(HomeWidgetKind.quickOpen, at: (x: 0, y: 0))!;
      expect((r.tile.x, r.tile.y), (1, 0));
      expectValid(r.layout);
    });
    test('moves to another page, then to a new one', () {
      final two = grid(4, 6, [full(4, 6), []]).add(HomeWidgetKind.quickOpen)!;
      expect(two.page, 1);
      final grown = grid(4, 6, [full(4, 6)]).add(HomeWidgetKind.quickOpen)!;
      expect(grown.page, 1);
      expect(grown.layout.pages, hasLength(2));
      expectValid(grown.layout);
    });
    test('gives up only when every page is full and no page can be added', () {
      final l = grid(4, 6, [
        for (var i = 0; i < kHomeMaxPages; i++) full(4, 6, 'p$i-'),
      ]);
      expect(l.add(HomeWidgetKind.quickOpen), isNull);
    });
    test('scales the default span with the grid', () {
      expect(HomeWidgetKind.recentChat.defaultSpan(8, 6).w, 8);
      expect(HomeWidgetKind.recentChat.defaultSpan(4, 6), (w: 4, h: 2));
      final r = grid(8, 9, [[]]).add(HomeWidgetKind.recentChat)!;
      expect(r.tile.w, 8);
      expect(r.tile.h, 3);
    });
  });

  group('put and update', () {
    final l = grid(4, 6, [
      [tile('a', 0, 0), tile('b', 1, 0)],
    ]);
    test('refuses an occupied place', () {
      expect(l.update(l.tileById('a')!.copyWith(x: 1)), isNull);
    });
    test('moves into a free place and keeps one copy', () {
      final moved = l.update(l.tileById('a')!.copyWith(x: 3, y: 5))!;
      expect(allTiles(moved).where((t) => t.id == 'a'), hasLength(1));
      expect(moved.tileById('a')!.x, 3);
      expectValid(moved);
    });
    test('update of an unknown tile is null', () {
      expect(l.update(tile('zz', 3, 3)), isNull);
    });
  });

  group('pages', () {
    test('remove drops one tile', () {
      final l = grid(4, 6, [
        [tile('a', 0, 0), tile('b', 1, 0)],
      ]).remove('a');
      expect(l.tileById('a'), isNull);
      expect(l.tileById('b'), isNotNull);
    });
    test('moveToPage needs room there', () {
      final l = grid(4, 6, [
        [tile('a', 0, 0)],
        [],
      ]);
      final moved = l.moveToPage('a', 1)!;
      expect(moved.pageOf('a'), 1);
      final crowded = grid(4, 6, [
        [tile('a', 0, 0)],
        full(4, 6, 'f'),
      ]);
      expect(crowded.moveToPage('a', 1), isNull);
    });
    test('addPage is capped, the last page cannot be removed', () {
      var l = HomeLayout.defaults();
      for (var i = 0; i < 10; i++) {
        l = l.addPage();
      }
      expect(l.pages, hasLength(kHomeMaxPages));
      var one = HomeLayout.defaults();
      one = one.removePage(0);
      expect(one.pages, hasLength(1));
      expect(l.removePage(1).pages, hasLength(kHomeMaxPages - 1));
    });
  });

  group('withGrid', () {
    test('growing keeps every tile, in bounds, apart', () {
      final l = HomeLayout.defaults();
      final big = l.withGrid(8, 9);
      expect(big.columns, 8);
      expect(big.rows, 9);
      expect(allTiles(big).map((t) => t.id).toSet(),
          allTiles(l).map((t) => t.id).toSet());
      expectValid(big);
    });
    test('shrinking a full page spills onto new pages without losing a tile', () {
      final l = grid(4, 6, [full(4, 6)]);
      final small = l.withGrid(3, 4);
      expect(allTiles(small), hasLength(24));
      expect(small.pages.length, greaterThan(1));
      expectValid(small);
    });
    test('shrinking the defaults keeps them valid', () {
      final small = HomeLayout.defaults().withGrid(3, 4);
      expectValid(small);
      expect(allTiles(small), hasLength(allTiles(HomeLayout.defaults()).length));
    });
    test('clamps the grid and returns the same layout for the same size', () {
      final l = HomeLayout.defaults();
      expect(identical(l.withGrid(4, 6), l), isTrue);
      final huge = l.withGrid(99, 99);
      expect(huge.columns, kHomeMaxColumns);
      expect(huge.rows, kHomeMaxRows);
      final tiny = l.withGrid(1, 1);
      expect(tiny.columns, kHomeMinColumns);
      expect(tiny.rows, kHomeMinRows);
      expectValid(tiny);
    });
    test('keeps the look', () {
      final l = HomeLayout.defaults().withStyle(
        iconShape: HomeIconShape.flower,
        showLabels: false,
        wallpaper: 'local:w.png',
      );
      final g = l.withGrid(5, 7);
      expect(g.iconShape, HomeIconShape.flower);
      expect(g.showLabels, isFalse);
      expect(g.wallpaper, 'local:w.png');
    });
  });

  group('JSON', () {
    test('round-trips', () {
      final l = HomeLayout(
        columns: 5,
        rows: 7,
        iconShape: HomeIconShape.circle,
        showLabels: false,
        wallpaper: 'local:wall.jpg',
        wallpaperDim: 0.3,
        pages: [
          HomePage(id: 'a', tiles: [
            const HomeTile(
              id: 't1',
              kind: HomeWidgetKind.gallery,
              x: 1,
              y: 2,
              w: 2,
              h: 2,
              config: {'count': '4', 'shuffle': true, 'n': 3, 'r': 0.5},
            ),
          ]),
          const HomePage(id: 'b'),
        ],
      );
      final back = HomeLayout.fromJson(jsonDecode(jsonEncode(l.toJson())));
      expect(back, l);
      expect(back.tileById('t1')!.config['shuffle'], true);
    });
    test('garbage gives the defaults', () {
      for (final junk in <Object?>[
        null,
        'x',
        <String, Object?>{},
        {'pages': 'no'},
        {'pages': []},
        {'pages': [1, 2]},
      ]) {
        expect(HomeLayout.fromJson(junk), HomeLayout.defaults(),
            reason: '$junk');
      }
    });
    test('repairs what it can', () {
      final l = HomeLayout.fromJson({
        'columns': 4,
        'rows': 6,
        'pages': [
          {
            'id': 'p',
            'tiles': [
              {'id': 'a', 'kind': 'quickOpen', 'x': 0, 'y': 0},
              {'id': 'b', 'kind': 'quickOpen', 'x': 0, 'y': 0},
              {'id': 'a', 'kind': 'quickOpen', 'x': 2, 'y': 2},
              {'id': 'c', 'kind': 'fromTheFuture', 'x': 3, 'y': 3},
              {'id': 'd', 'kind': 'gallery', 'x': 9, 'y': 9, 'w': 2, 'h': 2},
              {
                'id': 'e',
                'kind': 'cost',
                'x': 0,
                'y': 5,
                'config': {
                  'ok': 'yes',
                  'list': [1],
                  'map': {'a': 1},
                },
              },
            ],
          },
        ],
      });
      expectValid(l);
      final tiles = allTiles(l);
      expect(tiles, hasLength(5));
      expect(tiles.map((t) => t.id).toSet(), hasLength(5));
      expect(tiles.any((t) => t.id == 'c'), isFalse);
      final e = l.tileById('e')!;
      expect(e.config.keys, ['ok']);
    });
  });

  group('style and readers', () {
    test('withStyle clears the wallpaper with an empty string; dim clamps', () {
      final l = HomeLayout.defaults().withStyle(wallpaper: 'local:a');
      expect(l.withStyle(wallpaper: '').wallpaper, isNull);
      expect(l.withStyle(wallpaperDim: 5).wallpaperDim, 0.9);
      expect(l.withStyle(wallpaperDim: -1).wallpaperDim, 0.0);
    });
    test('byName falls back', () {
      expect(QuickTarget.byName('nonsense'), QuickTarget.chats);
      expect(HomeIconShape.byName(null), HomeIconShape.squircle);
      expect(HomeWidgetKind.byName('nope'), isNull);
    });
    test('typed readers never throw on the wrong type', () {
      const t = HomeTile(
        id: 'x',
        kind: HomeWidgetKind.cost,
        x: 0,
        y: 0,
        config: {'s': 1, 'i': 'two', 'n': true, 'b': 'yes', 'e': ''},
      );
      expect(t.str('s'), isNull);
      expect(t.str('e'), isNull);
      expect(t.integer('i', 7), 7);
      expect(t.copyWith(config: {'c': '4'}).integer('c', 1), 4);
      expect(t.copyWith(config: {'c': '0.5'}).number('c', 1), 0.5);
      expect(t.number('n', 1.5), 1.5);
      expect(t.flag('b', true), isTrue);
      expect(t.withConfig('s', null).config.containsKey('s'), isFalse);
      expect(t.withConfig('z', 'v').str('z'), 'v');
    });
  });

  group('moveTo and folders', () {
    test('moveTo carries a tile across pages', () {
      final l = grid(4, 6, [
        [tile('a', 0, 0)],
        [],
      ]);
      final moved = l.moveTo('a', 1, 3, 5)!;
      expect(moved.pageOf('a'), 1);
      expect((moved.tileById('a')!.x, moved.tileById('a')!.y), (3, 5));
      expectValid(moved);
      expect(l.moveTo('a', 5, 0, 0), isNull);
    });

    test('two shortcuts merge into a folder where the target was', () {
      final l = grid(4, 6, [
        [
          tile('a', 0, 0).withConfig('target', 'chats'),
          tile('b', 2, 0).withConfig('target', 'gallery'),
        ],
      ]);
      final merged = l.mergeIntoFolder('b', 'a')!;
      final f = merged.tileById('a')!;
      expect(f.kind, HomeWidgetKind.appFolder);
      expect((f.x, f.y), (0, 0));
      expect(HomeLayout.folderTargets(f), ['chats', 'gallery']);
      expect(merged.tileById('b'), isNull);
      // A third joins the folder, once.
      final more = merged
          .put(0, tile('c', 3, 3).withConfig('target', 'studio'))!
          .mergeIntoFolder('c', 'a')!;
      expect(HomeLayout.folderTargets(more.tileById('a')!),
          ['chats', 'gallery', 'studio']);
    });

    test('only shortcuts merge, and never into themselves', () {
      final l = grid(4, 6, [
        [
          tile('a', 0, 0),
          const HomeTile(id: 'w', kind: HomeWidgetKind.clock, x: 1, y: 1, w: 2, h: 2),
        ],
      ]);
      expect(l.mergeIntoFolder('a', 'a'), isNull);
      expect(l.mergeIntoFolder('a', 'w'), isNull);
      expect(l.mergeIntoFolder('w', 'a'), isNull);
    });
  });
}
