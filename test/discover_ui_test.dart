import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/discover.dart';
import 'package:maichat/models/lorebook.dart';
import 'package:maichat/screens/discover/discover_browser_sheet.dart';
import 'package:maichat/screens/discover/discover_screen.dart';
import 'package:maichat/services/discover/discover_source.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Drives the real Discover screens against a stand-in catalogue. The two source
/// suites already cover the wire; what these check is the seam a unit test
/// cannot see — that the section bar re-asks the right question, that the source
/// chips actually switch catalogue, and that pressing Download files the thing
/// in the user's own library.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Future<AppState> ready() async {
    final state = AppState();
    await state.init();
    return state;
  }

  Widget host(AppState state, Widget screen) =>
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(home: screen),
      );

  /// Lets the post-frame first load run and settle without waiting on the
  /// progress spinner, which never stops animating.
  Future<void> load(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('the feed lists characters and a tap opens the page',
      (tester) async {
    final state = await ready();
    final source = _FakeSource();
    await tester.pumpWidget(host(state, DiscoverScreen(sources: [source])));
    await load(tester);

    // The large title names the catalogue being browsed, now that the picker
    // lives in the drawer.
    expect(find.text('Fake'), findsWidgets);
    expect(find.text('Aria'), findsOneWidget);
    expect(find.text('Bram'), findsOneWidget);
    expect(find.text('by anon'), findsWidgets);
    expect(source.queries.single.kind, DiscoverKind.character);

    await tester.tap(find.text('Aria'));
    await load(tester);

    // The page reads like a local character's page, with the definition fetched.
    expect(find.text('DESCRIPTION'), findsOneWidget);
    expect(find.text('A ranger.'), findsOneWidget);
    expect(find.widgetWithText(FloatingActionButton, 'Download'), findsOneWidget);
  });

  testWidgets('Download files the character in the roster', (tester) async {
    final state = await ready();
    final source = _FakeSource();
    await tester.pumpWidget(host(state, DiscoverScreen(sources: [source])));
    await load(tester);
    await tester.tap(find.text('Aria'));
    await load(tester);

    expect(state.characters, isEmpty);
    await tester.tap(find.text('Download'));
    await load(tester);

    expect(state.characters, hasLength(1));
    expect(state.characters.single.name, 'Aria');
    expect(state.characters.single.description, 'A ranger.');
    // The button admits it is done rather than inviting a second copy.
    expect(find.text('Downloaded'), findsOneWidget);
    expect(find.text('Aria added to Characters'), findsWidgets);
  });

  testWidgets('the bottom bar re-asks for lorebooks, and one downloads',
      (tester) async {
    final state = await ready();
    final source = _FakeSource();
    await tester.pumpWidget(host(state, DiscoverScreen(sources: [source])));
    await load(tester);

    await tester.tap(find.text('Lorebooks'));
    await load(tester);

    expect(source.queries.last.kind, DiscoverKind.lorebook);
    expect(find.text('Kingdom'), findsOneWidget);
    // Books read as rows, with their entry count, not as art tiles.
    expect(find.textContaining('3 entries'), findsOneWidget);

    await tester.tap(find.text('Kingdom'));
    await load(tester);
    await tester.tap(find.text('Download'));
    await load(tester);

    expect(state.lorebooks, hasLength(1));
    expect(state.lorebooks.single.name, 'Kingdom');
    expect(state.lorebooks.single.entries, hasLength(1));
  });

  testWidgets('a section nothing publishes says so plainly', (tester) async {
    final state = await ready();
    await tester.pumpWidget(host(state, DiscoverScreen(sources: [_FakeSource()])));
    await load(tester);

    await tester.tap(find.text('Presets'));
    await load(tester);

    expect(find.text('No catalogue for presets'), findsOneWidget);
    expect(find.textContaining('generation presets'), findsOneWidget);
  });

  testWidgets('the drawer switches catalogue and reloads', (tester) async {
    final state = await ready();
    final first = _FakeSource();
    final second = _FakeSource(
      id: 'other',
      label: 'Other',
      characters: const ['Cass'],
    );
    await tester.pumpWidget(
      host(state, DiscoverScreen(sources: [first, second])),
    );
    await load(tester);

    expect(find.text('Aria'), findsOneWidget);

    // The catalogue picker is the navigation drawer now, not a row of chips.
    tester.state<ScaffoldState>(find.byType(Scaffold).first).openDrawer();
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'Home'), findsOneWidget);
    await tester.tap(find.widgetWithText(ListTile, 'Other'));
    await tester.pumpAndSettle();
    await load(tester);

    expect(find.text('Cass'), findsOneWidget);
    expect(find.text('Aria'), findsNothing);
    expect(second.queries, hasLength(1));
    expect(state.discoverPrefs.sourceId, 'other');
  });

  testWidgets('Discover opens on the first catalogue, whatever was last used',
      (tester) async {
    final state = await ready();
    // A stored choice from a previous visit.
    state.updateDiscoverPrefs(state.discoverPrefs.copyWith(sourceId: 'other'));
    final first = _FakeSource();
    final second = _FakeSource(
      id: 'other',
      label: 'Other',
      characters: const ['Cass'],
    );
    await tester.pumpWidget(
      host(state, DiscoverScreen(sources: [first, second])),
    );
    await load(tester);

    expect(find.text('Aria'), findsOneWidget);
    expect(find.text('Cass'), findsNothing);
  });

  testWidgets('a catalogue with no lorebooks says so instead of switching',
      (tester) async {
    final state = await ready();
    // Only the second publishes lorebooks; the first must not be swapped out
    // from under the user when the section changes.
    final first = _FakeSource(kinds: const {DiscoverKind.character});
    final second = _FakeSource(
      id: 'other',
      label: 'Other',
      kinds: const {DiscoverKind.character, DiscoverKind.lorebook},
    );
    await tester.pumpWidget(
      host(state, DiscoverScreen(sources: [first, second])),
    );
    await load(tester);

    await tester.tap(find.text('Lorebooks'));
    await load(tester);

    expect(find.text('Fake has no lorebooks'), findsOneWidget);
    expect(find.textContaining('Other'), findsWidgets);
  });

  testWidgets('a feed that fails offers a retry rather than a blank page',
      (tester) async {
    final state = await ready();
    final source = _FakeSource(failWith: 'Chub is unavailable right now.');
    await tester.pumpWidget(host(state, DiscoverScreen(sources: [source])));
    await load(tester);

    expect(find.text('Could not load the feed'), findsOneWidget);
    expect(find.text('Chub is unavailable right now.'), findsOneWidget);

    source.failWith = null;
    await tester.tap(find.text('Try again'));
    await load(tester);
    expect(find.text('Aria'), findsOneWidget);
  });

  testWidgets('the filter sheet applies once and remembers the adult switch',
      (tester) async {
    final state = await ready();
    final source = _FakeSource();
    await tester.pumpWidget(host(state, DiscoverScreen(sources: [source])));
    await load(tester);
    expect(source.queries.single.nsfw, isFalse);

    await tester.tap(find.byIcon(Icons.filter_list));
    await load(tester);
    await tester.tap(find.text('Show adult content'));
    await load(tester);
    // Nothing is asked of the catalogue until the sheet is dismissed.
    expect(source.queries, hasLength(1));

    await tester.tap(find.text('Show results'));
    await load(tester);

    expect(source.queries, hasLength(2));
    expect(source.queries.last.nsfw, isTrue);
    expect(state.discoverPrefs.nsfw, isTrue);
  });

  group('a site that wants to check the browser', () {
    final wasSupported = webViewSupported;
    final wasSolver = solveInBrowserView;

    /// Stands in for the WebView, which a test host does not have. Records what
    /// it was asked to open and answers with [reply].
    List<String> stubSolver(String? reply) {
      final opened = <String>[];
      solveInBrowserView = (context, {required url, required siteLabel}) async {
        opened.add(url);
        return reply;
      };
      return opened;
    }

    tearDown(() {
      webViewSupported = wasSupported;
      solveInBrowserView = wasSolver;
    });

    _FakeSource blocked() => _FakeSource(
          challenge: const DiscoverChallengeException(
            'JannyAI is checking the browser before it will hand over the card.',
            'https://example.invalid/characters/uuid-1',
          ),
        );

    testWidgets('passes the check without being asked to', (tester) async {
      webViewSupported = true;
      final opened = stubSolver('<html>the real page</html>');
      final state = await ready();
      final source = blocked();
      await tester.pumpWidget(host(state, DiscoverScreen(sources: [source])));
      await load(tester);
      await tester.tap(find.text('Aria'));
      await load(tester);

      // No button was pressed: opening the character was the request.
      expect(opened, ['https://example.invalid/characters/uuid-1']);
      expect(find.text('From the page: <html>the real page</html>'),
          findsOneWidget);
      expect(find.text('Pass the check'), findsNothing);
      expect(find.widgetWithText(FloatingActionButton, 'Download'),
          findsOneWidget);
    });

    testWidgets('backing out of the check leaves the offer standing',
        (tester) async {
      webViewSupported = true;
      final opened = stubSolver(null);
      final state = await ready();
      final source = blocked();
      await tester.pumpWidget(host(state, DiscoverScreen(sources: [source])));
      await load(tester);
      await tester.tap(find.text('Aria'));
      await load(tester);

      expect(opened, hasLength(1));
      // A check is not the same failure as a broken card, and does not read as
      // one — there is still a way through it.
      expect(find.text('The site wants to check the browser'), findsOneWidget);
      expect(find.text('Could not read the definition'), findsNothing);

      await tester.tap(find.text('Pass the check'));
      await load(tester);
      expect(opened, hasLength(2));
    });

    testWidgets('says only what is true when there is no browser view',
        (tester) async {
      webViewSupported = false;
      final opened = stubSolver('<html>never asked for</html>');
      final state = await ready();
      final source = blocked();
      await tester.pumpWidget(host(state, DiscoverScreen(sources: [source])));
      await load(tester);
      await tester.tap(find.text('Aria'));
      await load(tester);

      expect(opened, isEmpty);
      expect(find.text('Pass the check'), findsNothing);
      expect(find.text('Could not read the definition'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('an ordinary failure never opens a browser', (tester) async {
      webViewSupported = true;
      final opened = stubSolver('<html>never asked for</html>');
      final state = await ready();
      final source = _FakeSource(fetchError: 'That card was taken down.');
      await tester.pumpWidget(host(state, DiscoverScreen(sources: [source])));
      await load(tester);
      await tester.tap(find.text('Aria'));
      await load(tester);

      expect(opened, isEmpty);
      expect(find.text('Pass the check'), findsNothing);
      expect(find.text('That card was taken down.'), findsOneWidget);
    });

    testWidgets('a manual retry makes the source forget what was blocked',
        (tester) async {
      webViewSupported = false;
      stubSolver(null);
      final state = await ready();
      final source = _FakeSource(fetchError: 'Refused.');
      await tester.pumpWidget(host(state, DiscoverScreen(sources: [source])));
      await load(tester);
      await tester.tap(find.text('Aria'));
      await load(tester);

      expect(source.transportResets, 0);
      await tester.tap(find.text('Retry'));
      await load(tester);
      // Which route works depends on the network the phone is on, so a retry
      // asks afresh rather than repeating a remembered verdict.
      expect(source.transportResets, 1);
    });
  });
}

/// A catalogue that answers from memory, so the screens can be driven without a
/// network or a fixture server.
class _FakeSource extends DiscoverSource {
  _FakeSource({
    this.id = 'fake',
    this.label = 'Fake',
    this.characters = const ['Aria', 'Bram'],
    this.failWith,
    this.challenge,
    this.fetchError,
    this.kinds = const <DiscoverKind>{
      DiscoverKind.character,
      DiscoverKind.lorebook,
    },
  });

  @override
  final String id;
  @override
  final String label;

  final List<String> characters;

  /// When set, every search fails with this message.
  String? failWith;

  /// When set, every download raises this instead of returning a payload.
  final DiscoverChallengeException? challenge;

  /// When set, every download fails with this ordinary message.
  final String? fetchError;

  final List<DiscoverQuery> queries = <DiscoverQuery>[];

  /// How many times a retry asked this source to forget what it had learned.
  int transportResets = 0;

  @override
  void resetTransport() => transportResets++;

  @override
  String get blurb => 'A stand-in catalogue';

  @override
  String get homeUrl => 'https://example.invalid';

  @override
  final Set<DiscoverKind> kinds;

  @override
  List<DiscoverSort> sortsFor(DiscoverKind kind) =>
      const <DiscoverSort>[DiscoverSort('newest', 'Newest')];

  @override
  Future<List<String>> tags(DiscoverKind kind) async => const ['fantasy'];

  @override
  Future<DiscoverPage> search(DiscoverQuery query) async {
    queries.add(query);
    final failure = failWith;
    if (failure != null) throw DiscoverException(failure);
    if (query.kind == DiscoverKind.lorebook) {
      return DiscoverPage(items: [
        DiscoverItem(
          sourceId: id,
          kind: DiscoverKind.lorebook,
          id: 'anon/kingdom',
          name: 'Kingdom',
          creator: 'anon',
          tagline: 'Places and people',
          entryCount: 3,
        ),
      ]);
    }
    return DiscoverPage(items: [
      for (final name in characters)
        DiscoverItem(
          sourceId: id,
          kind: DiscoverKind.character,
          id: 'anon/${name.toLowerCase()}',
          name: name,
          creator: 'anon',
        ),
    ]);
  }

  @override
  Future<DiscoverPayload> fetch(DiscoverItem item) async {
    final blocked = challenge;
    if (blocked != null) throw blocked;
    final failure = fetchError;
    if (failure != null) throw DiscoverException(failure);
    if (item.kind == DiscoverKind.lorebook) {
      return DiscoverPayload(
        lorebook: Lorebook(
          id: 'book-1',
          name: item.name,
          entries: [LorebookEntry(uid: 0, content: 'A fact.')],
        ),
      );
    }
    return DiscoverPayload(
      character: Character(
        id: 'char-1',
        name: item.name,
        description: 'A ranger.',
        firstMes: 'Hello.',
      ),
    );
  }

  @override
  Future<DiscoverPayload> fetchFromHtml(DiscoverItem item, String html) async =>
      DiscoverPayload(
        character: Character(
          id: 'char-1',
          name: item.name,
          description: 'From the page: $html',
        ),
      );
}
