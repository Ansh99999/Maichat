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
  }) {
    return MaterialApp(
      home: Scaffold(
        body: CustomScrollView(
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
                  height: item.startsWith('tall') ? 500 : 100,
                  child: Text(item),
                );
              },
            ),
          ],
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
