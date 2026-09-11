import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/widgets/adaptive_mosaic.dart';

void main() {
  Widget host({
    required List<String> items,
    required Map<String, double> ratios,
    int? columns,
    double? maxCrossAxisExtent,
    Map<String, ValueChanged<double>>? callbacks,
    ValueChanged<String>? built,
    Map<String, double> heights = const <String, double>{},
    ScrollController? controller,
    TextDirection textDirection = TextDirection.ltr,
  }) {
    return MaterialApp(
      home: Directionality(
        textDirection: textDirection,
        child: Scaffold(
          body: CustomScrollView(
            controller: controller,
            slivers: [
              AdaptiveMosaicSliver<String>(
                items: items,
                itemKey: (item) => item,
                imageKey: (item) => item,
                ratioOf: (item) => ratios[item],
                columns: columns,
                maxCrossAxisExtent: maxCrossAxisExtent,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                itemBuilder: (context, item, width, onRatioResolved) {
                  callbacks?[item] = onRatioResolved;
                  built?.call(item);
                  return SizedBox(
                    key: ValueKey('tile-$item'),
                    width: width,
                    height:
                        heights[item] ?? (item.startsWith('tall') ? 500 : 100),
                    child: Text(item),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  testWidgets('wide art spans a two-column phone', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      host(
        items: const ['wide', 'square', 'portrait'],
        ratios: const {'wide': 16 / 9, 'square': 1, 'portrait': 3 / 4},
        maxCrossAxisExtent: 200,
      ),
    );

    final wide = tester.getRect(find.byKey(const ValueKey('tile-wide')));
    final square = tester.getRect(find.byKey(const ValueKey('tile-square')));
    final portrait = tester.getRect(
      find.byKey(const ValueKey('tile-portrait')),
    );
    expect(wide.width, 400);
    expect(square.width, 195);
    expect(portrait.width, 195);
    expect(square.top, greaterThan(wide.bottom));
    expect(portrait.top, square.top);
    expect(portrait.left, 205);
  });

  testWidgets('later cards fill the shortest masonry lane', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      host(
        items: const ['short', 'tall-card', 'next'],
        ratios: const {'short': 1, 'tall-card': 1, 'next': 1},
        heights: const {'short': 100, 'tall-card': 300, 'next': 80},
        columns: 2,
      ),
    );

    final short = tester.getRect(find.byKey(const ValueKey('tile-short')));
    final tall = tester.getRect(find.byKey(const ValueKey('tile-tall-card')));
    final next = tester.getRect(find.byKey(const ValueKey('tile-next')));
    expect(next.top, short.bottom + 10);
    expect(next.top, lessThan(tall.bottom));
    expect(next.left, short.left);
  });

  testWidgets('a tall first card does not starve an empty lane', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      host(
        items: const ['tower', 'next', 'after'],
        ratios: const {'tower': 1, 'next': 1, 'after': 1},
        heights: const {'tower': 1200, 'next': 80, 'after': 80},
        columns: 2,
      ),
    );

    final tower = tester.getRect(find.byKey(const ValueKey('tile-tower')));
    final next = tester.getRect(find.byKey(const ValueKey('tile-next')));
    final after = tester.getRect(find.byKey(const ValueKey('tile-after')));
    expect(next.top, tower.top);
    expect(next.left, greaterThan(tower.left));
    expect(after.top, next.bottom + 10);
  });

  testWidgets('a high source item cannot hide a later low card', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      host(
        items: const ['a', 'b', 'c', 'wide-high', 'low'],
        ratios: const {'a': 1, 'b': 1, 'c': 1, 'wide-high': 2, 'low': 1},
        heights: const {'a': 1200, 'b': 1200, 'c': 1200},
        columns: 4,
      ),
    );
    expect(find.byKey(const ValueKey('tile-low')), findsOneWidget);

    tester.view.physicalSize = const Size(400, 300);
    await tester.pump();
    await tester.pump();

    final first = tester.getRect(find.byKey(const ValueKey('tile-a')));
    final low = tester.getRect(find.byKey(const ValueKey('tile-low')));
    expect(low.top, first.top);
    expect(low.left, greaterThan(first.left));
  });

  testWidgets('adjacent pairs use the lowest frontier and leading ties', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      host(
        items: const ['one', 'two', 'three', 'four', 'wide'],
        ratios: const {'one': 1, 'two': 1, 'three': 1, 'four': 1, 'wide': 2},
        heights: const {'one': 300, 'two': 100, 'three': 100, 'four': 300},
        columns: 4,
      ),
    );

    final two = tester.getRect(find.byKey(const ValueKey('tile-two')));
    final wide = tester.getRect(find.byKey(const ValueKey('tile-wide')));
    expect(wide.left, two.left);
    expect(wide.top, two.bottom + 10);
  });

  testWidgets('leading-lane placement mirrors in RTL', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      host(
        items: const ['first', 'second'],
        ratios: const {'first': 1, 'second': 1},
        columns: 2,
        textDirection: TextDirection.rtl,
      ),
    );

    final first = tester.getRect(find.byKey(const ValueKey('tile-first')));
    final second = tester.getRect(find.byKey(const ValueKey('tile-second')));
    expect(first.left, greaterThan(second.left));
  });

  testWidgets('a two-slot image shares wider rows in source order', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      host(
        items: const ['wide', 'one', 'two'],
        ratios: const {'wide': 4 / 3, 'one': 1, 'two': 3 / 4},
        columns: 4,
      ),
    );

    final wide = tester.getRect(find.byKey(const ValueKey('tile-wide')));
    final one = tester.getRect(find.byKey(const ValueKey('tile-one')));
    final two = tester.getRect(find.byKey(const ValueKey('tile-two')));
    expect(wide.width, 195);
    expect(one.width, 92.5);
    expect(two.width, 92.5);
    expect(one.top, wide.top);
    expect(two.top, wide.top);
    expect(wide.left, lessThan(one.left));
    expect(one.left, lessThan(two.left));
  });

  testWidgets('one and six-slot modes use the requested density', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(610, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      host(items: const ['wide'], ratios: const {'wide': 16 / 9}, columns: 1),
    );
    expect(tester.getSize(find.byKey(const ValueKey('tile-wide'))).width, 610);

    await tester.pumpWidget(
      host(
        items: const ['wide', 'one'],
        ratios: const {'wide': 16 / 9, 'one': 1},
        columns: 6,
      ),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('tile-wide'))).width,
      196.66666666666666,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('tile-one'))).width,
      93.33333333333333,
    );
  });

  testWidgets('a resolved unknown ratio regroups after the frame', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final callbacks = <String, ValueChanged<double>>{};
    await tester.pumpWidget(
      host(
        items: const ['one', 'unknown'],
        ratios: const {'one': 1},
        columns: 2,
        callbacks: callbacks,
      ),
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('tile-unknown'))).dy,
      tester.getTopLeft(find.byKey(const ValueKey('tile-one'))).dy,
    );

    callbacks['unknown']!(16 / 9);
    await tester.pump();
    await tester.pump();
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('tile-unknown'))).dy,
      greaterThan(
        tester.getBottomLeft(find.byKey(const ValueKey('tile-one'))).dy,
      ),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('tile-unknown'))).width,
      400,
    );
  });

  testWidgets('a changed image cannot inherit its item’s resolved span', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final callbacks = <String, ValueChanged<double>>{};
    var imageKey = 'first-image';

    Widget changingHost() => MaterialApp(
      home: Scaffold(
        body: CustomScrollView(
          slivers: [
            AdaptiveMosaicSliver<String>(
              items: const ['same-item'],
              itemKey: (item) => item,
              imageKey: (item) => imageKey,
              ratioOf: (_) => null,
              columns: 2,
              itemBuilder: (context, item, width, onRatioResolved) {
                callbacks[item] = onRatioResolved;
                return SizedBox(
                  key: ValueKey('tile-$item'),
                  width: width,
                  height: 100,
                );
              },
            ),
          ],
        ),
      ),
    );

    await tester.pumpWidget(changingHost());
    callbacks['same-item']!(16 / 9);
    await tester.pump();
    await tester.pump();
    expect(
      tester.getSize(find.byKey(const ValueKey('tile-same-item'))).width,
      400,
    );

    imageKey = 'replacement-image';
    await tester.pumpWidget(changingHost());
    expect(
      tester.getSize(find.byKey(const ValueKey('tile-same-item'))).width,
      200,
    );
  });

  testWidgets('reordering invalidates cached item geometry', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var items = const ['short', 'tall-card', 'next'];
    Widget currentHost() => host(
      items: items,
      ratios: const {'short': 1, 'tall-card': 1, 'next': 1},
      heights: const {'short': 100, 'tall-card': 300, 'next': 80},
      columns: 2,
    );

    await tester.pumpWidget(currentHost());
    items = const ['tall-card', 'short', 'next'];
    await tester.pumpWidget(currentHost());

    final tall = tester.getRect(find.byKey(const ValueKey('tile-tall-card')));
    final short = tester.getRect(find.byKey(const ValueKey('tile-short')));
    final next = tester.getRect(find.byKey(const ValueKey('tile-next')));
    expect(tall.left, lessThan(short.left));
    expect(next.left, short.left);
    expect(next.top, short.bottom + 10);
  });

  testWidgets('backscroll reuses cached children instead of rebuilding all', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final builds = <String, int>{};
    await tester.pumpWidget(
      host(
        items: [for (var i = 0; i < 100; i++) 'item-$i'],
        ratios: const {},
        columns: 2,
        controller: controller,
        built: (item) => builds[item] = (builds[item] ?? 0) + 1,
      ),
    );
    final initial = Map<String, int>.of(builds);

    controller.jumpTo(900);
    await tester.pump();
    controller.jumpTo(0);
    await tester.pump();

    expect(builds.length, lessThan(100));
    for (final entry in initial.entries) {
      expect(builds[entry.key], lessThanOrEqualTo(entry.value + 1));
    }
  });

  testWidgets('shrinking a lazy collection drops its old scroll estimate', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    var items = [for (var i = 0; i < 10000; i++) 'tall-$i'];
    Widget currentHost() => host(
      items: items,
      ratios: const {},
      columns: 1,
      controller: controller,
    );

    await tester.pumpWidget(currentHost());
    final largeExtent = controller.position.maxScrollExtent;
    expect(largeExtent, greaterThan(1000000));

    items = items.take(20).toList();
    await tester.pumpWidget(currentHost());
    await tester.pump();

    expect(controller.position.maxScrollExtent, lessThan(largeExtent / 10));
  });

  testWidgets('only visible rows build their children', (tester) async {
    tester.view.physicalSize = const Size(400, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final built = <String>[];
    await tester.pumpWidget(
      host(
        items: [for (var i = 0; i < 100; i++) 'tall-$i'],
        ratios: const {},
        columns: 1,
        built: built.add,
      ),
    );
    expect(built.length, lessThan(100));
    expect(built, contains('tall-0'));
  });
}
