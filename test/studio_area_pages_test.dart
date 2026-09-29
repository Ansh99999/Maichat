import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/screens/studio/shell/area_pages.dart';

/// Counts its own builds, so a test can say "nothing was built during the
/// slide" rather than guessing at smoothness.
class _Page extends StatelessWidget {
  const _Page(this.label, this.builds);

  final String label;
  final Map<String, int> builds;

  @override
  Widget build(BuildContext context) {
    builds[label] = (builds[label] ?? 0) + 1;
    return ColoredBox(
      color: Colors.white,
      child: Center(child: Text(label, textDirection: TextDirection.ltr)),
    );
  }
}

/// A page that listens to [notifier] through [ActiveListenableBuilder].
class _Listening extends StatelessWidget {
  const _Listening(this.notifier, this.builds);

  final ChangeNotifier notifier;
  final Map<String, int> builds;

  @override
  Widget build(BuildContext context) => ActiveListenableBuilder(
        listenable: notifier,
        builder: (context) {
          builds['listening'] = (builds['listening'] ?? 0) + 1;
          return const SizedBox.expand();
        },
      );
}

class _Tick extends ChangeNotifier {
  void tick() => notifyListeners();
}

void main() {
  late Map<String, int> builds;
  late List<Widget> pages;

  setUp(() {
    builds = <String, int>{};
    // The same instances on every pump, as the shell hands them in.
    pages = [
      _Page('interface', builds),
      _Page('draft', builds),
      _Page('changes', builds),
    ];
  });

  // Anchored top-left, so the root's tight constraints do not stretch the
  // 400-wide page to the whole test window.
  Widget host(int index) => Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 400,
            height: 600,
            child: StudioAreaPages(index: index, pages: pages),
          ),
        ),
      );

  Finder onstage(String label) => find.text(label);
  Finder anywhere(String label) => find.text(label, skipOffstage: false);

  testWidgets('every page is built once, before the first slide', (tester) async {
    await tester.pumpWidget(host(0));
    expect(builds, {'interface': 1});
    // The first idle frame builds the rest, out of sight.
    await tester.pump();
    expect(builds, {'interface': 1, 'draft': 1, 'changes': 1});
    expect(onstage('draft'), findsNothing);
    expect(anywhere('draft'), findsOneWidget);

    // Sliding to them builds nothing: no frame of the slide pays for a page.
    await tester.pumpWidget(host(1));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpWidget(host(2));
    await tester.pumpAndSettle();
    await tester.pumpWidget(host(0));
    await tester.pumpAndSettle();
    expect(builds, {'interface': 1, 'draft': 1, 'changes': 1});
  });

  testWidgets('a slide moves only the two pages involved, straight across',
      (tester) async {
    await tester.pumpWidget(host(0));
    await tester.pump();
    await tester.pumpWidget(host(2));
    await tester.pump(const Duration(milliseconds: 120));

    // Mid-slide: the conversation leaving to the left, the changes coming in
    // from the right — and the draft between them never on screen.
    expect(onstage('interface'), findsOneWidget);
    expect(onstage('changes'), findsOneWidget);
    expect(onstage('draft'), findsNothing);
    final leaving = tester.getCenter(onstage('interface')).dx;
    final coming = tester.getCenter(onstage('changes')).dx;
    expect(leaving, lessThan(200));
    expect(coming, greaterThan(200));
    expect(coming - leaving, closeTo(400, 1));

    await tester.pumpAndSettle();
    expect(onstage('interface'), findsNothing);
    expect(tester.getCenter(onstage('changes')).dx, 200);
  });

  testWidgets('going back slides the other way', (tester) async {
    await tester.pumpWidget(host(2));
    await tester.pump();
    await tester.pumpWidget(host(1));
    await tester.pump(const Duration(milliseconds: 120));
    // To an earlier page: it comes in from the left.
    expect(tester.getCenter(onstage('draft')).dx, lessThan(200));
    expect(tester.getCenter(onstage('changes')).dx, greaterThan(200));
    await tester.pumpAndSettle();
  });

  testWidgets('the leaving page takes no taps', (tester) async {
    var taps = 0;
    pages = [
      GestureDetector(
        onTap: () => taps++,
        child: const ColoredBox(color: Colors.white, child: SizedBox.expand()),
      ),
      _Page('draft', builds),
      _Page('changes', builds),
    ];
    await tester.pumpWidget(host(0));
    await tester.pump();
    await tester.pumpWidget(host(1));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(const Offset(20, 300));
    expect(taps, 0);
    await tester.pumpAndSettle();
  });

  testWidgets('a page out of sight does not rebuild for every change',
      (tester) async {
    final tick = _Tick();
    addTearDown(tick.dispose);
    pages = [
      _Page('interface', builds),
      _Listening(tick, builds),
      _Page('changes', builds),
    ];
    await tester.pumpWidget(host(0));
    await tester.pump();
    expect(builds['listening'], 1);

    // Streaming on the conversation: the draft, out of sight, stays put.
    for (var i = 0; i < 20; i++) {
      tick.tick();
      await tester.pump();
    }
    expect(builds['listening'], 1);

    // Shown again, it catches up in one rebuild…
    await tester.pumpWidget(host(1));
    await tester.pump();
    expect(builds['listening'], 2);
    await tester.pumpAndSettle();
    // …and follows changes while it is on screen.
    tick.tick();
    await tester.pump();
    expect(builds['listening'], 3);
  });
}
