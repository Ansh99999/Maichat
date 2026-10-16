// Subscription assertions intentionally inspect notifier listeners.
// ignore_for_file: invalid_use_of_protected_member

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/gallery_image.dart';
import 'package:maichat/models/home_layout.dart';
import 'package:maichat/models/studio.dart';
import 'package:maichat/screens/home/clock_ticker.dart';
import 'package:maichat/screens/home/home_spec.dart';
import 'package:maichat/screens/home/widgets/gallery_widget.dart';
import 'package:maichat/screens/home/widgets/search_widget.dart';
import 'package:maichat/screens/home/widgets/studio_widget.dart';
import 'package:maichat/services/studio/studio_controller.dart';
import 'package:maichat/services/studio/studio_store.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart';

class _State extends AppState {
  final pictures = <GalleryImage>[];
  Character? persona;
  StudioStore? store;

  @override
  List<GalleryImage> get gallery => pictures;
  @override
  Character? get defaultPersona => persona;
  @override
  StudioStore? get studioStore => store;

  void changed() => notifyListeners();
}

class _Store extends StudioStore {
  _Store(super.directory, this.sessions);
  final List<StudioSession> sessions;

  @override
  Future<List<StudioSession>> list() async => sessions;
  @override
  Future<void> save(StudioSession session) async {}
}

Widget _visible(ValueNotifier<bool> enabled, Widget child) =>
    ValueListenableBuilder<bool>(
      valueListenable: enabled,
      child: child,
      builder: (_, value, child) => TickerMode(enabled: value, child: child!),
    );

Widget _tile(
  HomeWidgetSpec spec,
  _State state, {
  int w = 2,
  int h = 2,
  Map<String, Object?> config = const {},
}) {
  final tile = HomeTile(
    id: 'activity',
    kind: spec.kind,
    x: 0,
    y: 0,
    w: w,
    h: h,
    config: config,
  );
  final size = Size(w * 100.0, h * 100.0);
  final ctx = HomeTileContext(
    tile: tile,
    size: size,
    layout: HomeLayout(
      columns: 4,
      rows: 6,
      pages: [
        HomePage(id: 'page', tiles: [tile]),
      ],
    ),
    editing: false,
  );
  return ChangeNotifierProvider<AppState>.value(
    value: state,
    child: SizedBox.fromSize(
      size: size,
      child: Builder(builder: (context) => spec.build(context, ctx)),
    ),
  );
}

Widget _app(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

void main() {
  testWidgets('minute listener ignores seconds and refreshes after hiding', (
    tester,
  ) async {
    final previous = ClockTicker.clock;
    ClockTicker.clock = tester.binding.clock.now;
    addTearDown(() => ClockTicker.clock = previous);
    final enabled = ValueNotifier(true);
    addTearDown(enabled.dispose);
    var minutes = 0;
    var seconds = 0;
    DateTime? shown;
    await tester.pumpWidget(
      _app(
        Column(
          children: [
            _visible(
              enabled,
              ClockListener(
                builder: (_, now) {
                  minutes++;
                  shown = now;
                  return const SizedBox();
                },
              ),
            ),
            ClockListener(
              seconds: true,
              builder: (_, _) {
                seconds++;
                return const SizedBox();
              },
            ),
          ],
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(minutes, 1);
    expect(seconds, 2);
    await tester.pump(const Duration(seconds: 59));
    expect(minutes, 2);
    enabled.value = false;
    await tester.pump();
    final hiddenBuilds = minutes;
    await tester.pump(const Duration(seconds: 65));
    expect(minutes, hiddenBuilds);
    enabled.value = true;
    await tester.pump();
    expect(minutes, hiddenBuilds + 1);
    expect(shown, tester.binding.clock.now());
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('clock seconds demand changes and hidden clocks cancel ticks', (
    tester,
  ) async {
    final previous = ClockTicker.clock;
    ClockTicker.clock = tester.binding.clock.now;
    addTearDown(() => ClockTicker.clock = previous);
    final enabled = ValueNotifier(true);
    final seconds = ValueNotifier(false);
    addTearDown(enabled.dispose);
    addTearDown(seconds.dispose);
    var builds = 0;
    await tester.pumpWidget(
      _app(
        _visible(
          enabled,
          ValueListenableBuilder<bool>(
            valueListenable: seconds,
            builder: (_, value, _) => ClockListener(
              seconds: value,
              builder: (_, _) {
                builds++;
                return const SizedBox();
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(builds, 1);
    seconds.value = true;
    await tester.pump();
    final beforeTick = builds;
    await tester.pump(const Duration(seconds: 1));
    expect(builds, beforeTick + 1);
    enabled.value = false;
    await tester.pump();
    expect(ClockTicker.instance.hasListeners, isFalse);
    seconds.value = false;
    await tester.pump();
    enabled.value = true;
    await tester.pump();
    final resumed = builds;
    await tester.pump(const Duration(seconds: 1));
    expect(builds, resumed);
    await tester.pumpWidget(const SizedBox());
    expect(ClockTicker.instance.hasListeners, isFalse);
  });

  testWidgets('gallery cancels hidden shuffle timer and resumes after 30s', (
    tester,
  ) async {
    final state = _State();
    addTearDown(state.dispose);
    state.pictures.addAll([
      GalleryImage(id: 'a', image: ''),
      GalleryImage(id: 'b', image: ''),
    ]);
    final enabled = ValueNotifier(false);
    addTearDown(enabled.dispose);
    final timers = <Timer>[];
    // Observe actual timers rather than relying on TickerMode to stop animation.
    Future<void> observe(Future<void> Function() action) => runZoned(
      action,
      zoneSpecification: ZoneSpecification(
        createPeriodicTimer: (self, parent, zone, duration, callback) {
          final timer = parent.createPeriodicTimer(zone, duration, callback);
          if (duration == const Duration(seconds: 30)) timers.add(timer);
          return timer;
        },
      ),
    );
    await observe(
      () => tester.pumpWidget(
        _app(
          _visible(
            enabled,
            _tile(const GallerySpec(), state, config: const {'shuffle': true}),
          ),
        ),
      ),
    );
    expect(timers, isEmpty);
    enabled.value = true;
    await observe(tester.pump);
    expect(timers, hasLength(1));
    final controller = tester
        .widget<PageView>(find.byType(PageView))
        .controller!;
    final initial = controller.page!;
    await tester.pump(const Duration(seconds: 30));
    await tester.pump(const Duration(milliseconds: 700));
    expect(controller.page, initial + 1);
    enabled.value = false;
    await tester.pump();
    expect(timers.single.isActive, isFalse);
    final hiddenPage = controller.page;
    await tester.pump(const Duration(minutes: 2));
    expect(controller.page, hiddenPage);
    enabled.value = true;
    await observe(tester.pump);
    expect(timers, hasLength(2));
    await tester.pump(const Duration(seconds: 29));
    expect(controller.page, hiddenPage);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 700));
    expect(controller.page, hiddenPage! + 1);
    await tester.pumpWidget(const SizedBox());
    expect(timers.last.isActive, isFalse);
  });

  testWidgets(
    'search notices persona mutations and ignores unrelated changes',
    (tester) async {
      final state = _State()..persona = Character(id: 'p', name: 'Alice');
      addTearDown(state.dispose);
      await tester.pumpWidget(
        _app(_tile(const SearchSpec(), state, w: 4, h: 1)),
      );
      expect(find.text('A'), findsOneWidget);
      final original = tester.widget(find.byType(Semantics).last);
      state.changed();
      await tester.pump();
      expect(tester.widget(find.byType(Semantics).last), same(original));
      state.persona!.name = 'Bea';
      state.changed();
      await tester.pump();
      expect(find.text('B'), findsOneWidget);
      state.persona = null;
      state.changed();
      await tester.pump();
      expect(find.text('B'), findsNothing);
    },
  );

  for (final span in [(2, 2), (4, 4)]) {
    testWidgets(
      'Studio $span filters transcripts and catches up when visible',
      (tester) async {
        final dir = Directory('/tmp/maichat-home-activity-${span.$1}');
        final session = newStudioSession()..title = 'Keeper';
        final state = _State()..store = _Store(dir, [session]);
        addTearDown(state.dispose);
        final controller = (await tester.runAsync(
          () async => StudioHub.instance.open(
            state: state,
            store: state.store!,
            session: session,
          ),
        ))!;
        addTearDown(
          () => tester.runAsync(() => StudioHub.instance.close(session.id)),
        );
        final enabled = ValueNotifier(true);
        addTearDown(enabled.dispose);
        await tester.pumpWidget(
          _app(
            _visible(
              enabled,
              _tile(const StudioSpec(), state, w: span.$1, h: span.$2),
            ),
          ),
        );
        await tester.pump();
        expect(controller.hasListeners, isTrue);
        final title = tester.widget<Text>(find.text('Keeper'));
        for (var i = 0; i < 10; i++) {
          controller.liveFor(kMainAgent).text += 'token';
          controller.dismissNotice();
          await tester.pump(const Duration(milliseconds: 80));
        }
        expect(tester.widget<Text>(find.text('Keeper')), same(title));
        session.title = 'Visible edit';
        session.todos.add(
          const StudioTodo(
            content: 'Draft greeting',
            status: StudioTodoStatus.inProgress,
          ),
        );
        session.ops.add(
          StudioOp(
            id: 'op',
            tool: 'manual',
            summary: 'Added greeting',
            before: '',
          ),
        );
        controller.dismissNotice();
        await tester.pump();
        expect(find.text('Visible edit'), findsOneWidget);
        expect(
          find.text(span.$1 == 2 ? 'Draft greeting' : 'Added greeting'),
          findsOneWidget,
        );
        enabled.value = false;
        await tester.pump();
        expect(controller.hasListeners, isFalse);
        session.title = 'Hidden edit';
        session.ops.single.reverted = true;
        controller.dismissNotice();
        await tester.pump();
        expect(find.text('Hidden edit'), findsNothing);
        enabled.value = true;
        await tester.pump();
        expect(controller.hasListeners, isTrue);
        expect(find.text('Hidden edit'), findsOneWidget);
        if (span.$1 == 4) {
          expect(
            tester.widget<Text>(find.text('Added greeting')).style!.decoration,
            TextDecoration.lineThrough,
          );
        }
        await tester.pumpWidget(const SizedBox());
        expect(controller.hasListeners, isFalse);
      },
    );
  }
}
