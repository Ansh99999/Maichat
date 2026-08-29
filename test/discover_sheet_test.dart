import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/discover.dart';
import 'package:maichat/models/lorebook.dart';
import 'package:maichat/screens/character_sheet_parts.dart';
import 'package:maichat/screens/discover/discover_item_screen.dart';
import 'package:maichat/services/discover/discover_source.dart';
import 'package:maichat/state/app_state.dart';
import 'package:maichat/widgets/avatar_image.dart';
import 'package:maichat/widgets/message_bubble.dart';
import 'package:maichat/widgets/natural_image.dart';
import 'package:maichat/widgets/rich_notes_view.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A catalogue entry's page is the character sheet, drawn from a listing. That
/// claim is layout-conditional in several independent ways — art present or not,
/// its aspect ratio, notes rich or plain, a character payload or a lorebook one,
/// and the definition arrived or still in flight — so it is tested as a matrix.
/// Testing one configuration is how "same as the characters section" ships as
/// "same in the one case I looked at".
///
/// Pictures are URLs whose ratio is pre-recorded, so what is measured is the
/// frame the page gives a picture and no test needs real image bytes.
String _pic(String tag) => 'https://example.com/$tag.png';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    clearAvatarImageCache();
    imageCache.clear();
    imageCache.clearLiveImages();
  });

  Widget host(AppState state, DiscoverItem item, _FakeSource source) =>
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          home: DiscoverItemScreen(item: item, source: source),
        ),
      );

  /// Opens the page and lets the on-open fetch land, without waiting on a
  /// progress spinner that never stops animating.
  Future<AppState> open(
    WidgetTester tester, {
    required DiscoverItem item,
    required _FakeSource source,
  }) async {
    final state = AppState();
    await state.init();
    await tester.pumpWidget(host(state, item, source));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    return state;
  }

  /// A tall window, so a page with a big header still lays its blocks out in one
  /// viewport and their order can be measured rather than scrolled for.
  void tallWindow(WidgetTester tester) {
    tester.view.physicalSize = const Size(420, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> scrollTo(WidgetTester tester, Finder target) async {
    await tester.scrollUntilVisible(
      target,
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
  }

  // --- the art takes its own shape, as it does on a local sheet -------------

  group('the header art', () {
    const ratios = <String, double>{
      'square': 1,
      'landscape': 16 / 9,
      'portrait': 3 / 4,
    };

    for (final entry in ratios.entries) {
      testWidgets('a ${entry.key} listing keeps its own proportions',
          (tester) async {
        final ref = _pic(entry.key);
        noteAvatarRatio(ref, entry.value);
        await open(
          tester,
          item: _item(name: 'Aria', imageUrl: ref),
          source: _FakeSource(),
        );

        final drawn = tester.getSize(find.byKey(naturalImageFrameKey));
        expect(
          drawn.width / drawn.height,
          closeTo(entry.value, 0.02),
          reason: 'the ${entry.key} listing art lost its proportions',
        );
      });
    }

    testWidgets('a very tall listing is capped but keeps its ratio',
        (tester) async {
      final ref = _pic('tall');
      noteAvatarRatio(ref, 9 / 32);
      await open(
        tester,
        item: _item(imageUrl: ref),
        source: _FakeSource(),
      );
      final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
      final drawn = tester.getSize(find.byKey(naturalImageFrameKey));
      expect(drawn.height, lessThan(screen.height));
      expect(drawn.width / drawn.height, closeTo(9 / 32, 0.02));
    });

    testWidgets("the name sits in the art's lower-right", (tester) async {
      final ref = _pic('named');
      noteAvatarRatio(ref, 1);
      await open(
        tester,
        item: _item(name: 'Sumire', imageUrl: ref, creator: 'anon'),
        source: _FakeSource(),
      );
      final picture = tester.getRect(find.byType(NaturalImage));
      final name = tester.getRect(find.text('Sumire'));
      expect(name.bottom, lessThanOrEqualTo(picture.bottom + 1));
      expect(name.center.dx, greaterThan(picture.center.dx));
      // The byline rides under it, on the art.
      expect(find.text('by anon'), findsOneWidget);
    });

    testWidgets('a listing with no art gets a tile, not an empty square',
        (tester) async {
      await open(
        tester,
        item: _item(name: 'Artless'),
        source: _FakeSource(),
      );
      expect(find.byType(NaturalImage), findsNothing);
      expect(find.text('Artless'), findsOneWidget);
    });

    testWidgets('the listing art wins over the fetched card avatar',
        (tester) async {
      final listed = _pic('listed');
      noteAvatarRatio(listed, 1);
      // The card that comes back names a different picture; the header must not
      // swap out from under the reader halfway through the fetch.
      await open(
        tester,
        item: _item(imageUrl: listed),
        source: _FakeSource(avatar: _pic('from-the-card')),
      );
      final image = tester.widget<NaturalImage>(find.byType(NaturalImage));
      expect(image.imageRef, listed);
    });

    testWidgets("a listing with no art falls back to the card's own picture",
        (tester) async {
      final carded = _pic('carded');
      noteAvatarRatio(carded, 1);
      await open(
        tester,
        item: _item(),
        source: _FakeSource(avatar: carded),
      );
      expect(
        tester.widget<NaturalImage>(find.byType(NaturalImage)).imageRef,
        carded,
      );
    });
  });

  // --- tags ------------------------------------------------------------------

  group('tags', () {
    testWidgets('many tags stay on one horizontally scrolling line',
        (tester) async {
      await open(
        tester,
        item: _item(tags: List<String>.generate(24, (i) => 'tag-$i')),
        source: _FakeSource(),
      );
      await scrollTo(tester, find.text('tag-0'));
      final first = tester.getRect(find.text('tag-0'));
      final later = tester.getRect(find.text('tag-5'));
      expect(later.top, closeTo(first.top, 1),
          reason: 'the tags wrapped instead of scrolling');
      expect(later.left, greaterThan(first.left));
    });

    testWidgets("the fetched card's tags replace the listing's thinner set",
        (tester) async {
      await open(
        tester,
        item: _item(tags: const ['listed']),
        source: _FakeSource(cardTags: const ['fuller', 'set']),
      );
      expect(find.text('fuller'), findsOneWidget);
      expect(find.text('set'), findsOneWidget);
      expect(find.text('listed'), findsNothing);
    });

    testWidgets('no tags anywhere means no band at all', (tester) async {
      await open(tester, item: _item(), source: _FakeSource());
      expect(find.byType(Chip), findsNothing);
    });
  });

  // --- the order the user asked for ------------------------------------------

  testWidgets(
      'tags, a rule, the catalogue block, a rule, then the creator notes',
      (tester) async {
    tallWindow(tester);
    final ref = _pic('ordered');
    noteAvatarRatio(ref, 16 / 9);
    await open(
      tester,
      item: _item(imageUrl: ref, tags: const ['fantasy'], downloads: 1200),
      source: _FakeSource(notes: 'Plainly written notes about her.'),
    );

    final tag = tester.getRect(find.text('fantasy'));
    final catalogue = tester.getRect(find.text('FROM THE CATALOGUE'));
    final notes = tester.getRect(find.text('CREATOR NOTES'));
    final rules = find.byType(SheetDivider);

    expect(tag.bottom, lessThan(catalogue.top));
    expect(catalogue.bottom, lessThan(notes.top));
    // A thin rule on either side of the catalogue block, and a third before the
    // definition folds under the notes.
    expect(rules, findsNWidgets(3));
    final first = tester.getRect(rules.at(0));
    final second = tester.getRect(rules.at(1));
    expect(first.top, greaterThan(tag.bottom));
    expect(first.top, lessThan(catalogue.top));
    expect(second.top, greaterThan(catalogue.bottom));
    expect(second.top, lessThan(notes.top));

    // And the numbers themselves are in that block.
    expect(find.text('Fake'), findsOneWidget);
    expect(find.text('1.2k'), findsOneWidget);
  });

  testWidgets('the catalogue block carries the listing tagline', (tester) async {
    await open(
      tester,
      item: _item(tagline: 'A ranger with a grudge.'),
      source: _FakeSource(),
    );
    await scrollTo(tester, find.text('FROM THE CATALOGUE'));
    expect(find.text('A ranger with a grudge.'), findsOneWidget);
  });

  // --- creator notes, images and CSS and all --------------------------------

  group('creator notes', () {
    const styled = '<div style="background:#101018;padding:12px">'
        '<h2 style="color:#ffb86c;font-size:1.4rem">ARIA</h2>'
        '<p>A quiet librarian who <b>loves</b> books.</p>'
        '<img src="https://example.com/banner.png" width="400">'
        '</div>';

    testWidgets("a card's CSS notes render, images and all", (tester) async {
      await open(tester, item: _item(), source: _FakeSource(notes: styled));
      await scrollTo(tester, find.byType(RichNotes));
      expect(find.byType(RichNotes), findsOneWidget);
      // A real HTML tree, not a text stand-in.
      expect(find.byType(Html), findsOneWidget);
      // Through the app's own capped/cached provider.
      expect(find.byType(Image), findsWidgets);
    });

    testWidgets('plain notes take the cheap path — no HTML engine',
        (tester) async {
      await open(
        tester,
        item: _item(),
        source: _FakeSource(notes: 'Just a sentence, written plainly.'),
      );
      await scrollTo(tester, find.textContaining('Just a sentence'));
      expect(find.byType(RichNotes), findsNothing);
      expect(find.byType(Html), findsNothing);
    });

    testWidgets("a card with no notes falls back to the listing's blurb, and "
        'says which it is', (tester) async {
      await open(
        tester,
        item: _item(description: 'What the site says about her.'),
        source: _FakeSource(),
      );
      await scrollTo(tester, find.text('ABOUT'));
      expect(find.text('CREATOR NOTES'), findsNothing);
      expect(find.text('What the site says about her.'), findsOneWidget);
    });
  });

  // --- the definition, behind the same folds --------------------------------

  group('the definition folds', () {
    testWidgets('a fold builds its body only once opened', (tester) async {
      await open(
        tester,
        item: _item(),
        source: _FakeSource(description: 'She keeps the night shift.'),
      );
      await scrollTo(tester, find.text('Description'));
      expect(find.text('She keeps the night shift.', skipOffstage: false),
          findsNothing,
          reason: 'a closed fold built its body anyway');
      await tester.tap(find.text('Description'));
      await tester.pumpAndSettle();
      expect(find.text('She keeps the night shift.'), findsOneWidget);
    });

    testWidgets('an empty field has no fold at all', (tester) async {
      await open(
        tester,
        item: _item(),
        source: _FakeSource(description: 'Something'),
      );
      await scrollTo(tester, find.text('Description'));
      expect(find.text('Personality'), findsNothing);
      expect(find.text('System prompt'), findsNothing);
    });

    testWidgets("a greeting is drawn by the chat's own bubble, HTML and all",
        (tester) async {
      await open(
        tester,
        item: _item(),
        source: _FakeSource(
          firstMes: '<div style="color:#ff8800">She waves.</div> '
              '<img src="https://example.com/wave.png">',
        ),
      );
      await scrollTo(tester, find.text('Greetings'));
      await tester.tap(find.text('Greetings'));
      await tester.pumpAndSettle();
      expect(find.byType(MessageBubble), findsOneWidget);
      expect(find.byType(Html), findsWidgets);
    });

    testWidgets('several greetings each get their own nested fold',
        (tester) async {
      await open(
        tester,
        item: _item(),
        source: _FakeSource(
          firstMes: 'First hello.',
          alternates: const ['Second hello.', 'Third hello.'],
        ),
      );
      await scrollTo(tester, find.text('Greetings'));
      expect(find.text('3 to choose from'), findsOneWidget);
      await tester.tap(find.text('Greetings'));
      await tester.pumpAndSettle();
      expect(find.text('First message'), findsOneWidget);
      expect(find.text('Alternate 2'), findsOneWidget);
      expect(find.byType(MessageBubble), findsNothing);
    });

    testWidgets('the scenario is readable but not editable — it is not yours '
        'yet', (tester) async {
      await open(
        tester,
        item: _item(),
        source: _FakeSource(scenario: 'A rainy night at the archive.'),
      );
      await scrollTo(tester, find.text('Scenario'));
      // The picker writes onto a stored character; there is no stored character.
      expect(find.byTooltip('Choose a scenario'), findsNothing);
      await tester.tap(find.text('Scenario'));
      await tester.pumpAndSettle();
      expect(find.text('A rainy night at the archive.'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Write your own'), findsNothing);
    });

    testWidgets('nothing fetched yet means no folds, and a note saying so',
        (tester) async {
      final state = AppState();
      await state.init();
      final source = _FakeSource(hold: true);
      await tester.pumpWidget(
        host(state, _item(description: 'Only the blurb.'), source),
      );
      await tester.pump();

      expect(find.text('Fetching the full definition…'), findsOneWidget);
      expect(find.text('Description'), findsNothing);
      // What the listing knew is still all there.
      expect(find.text('FROM THE CATALOGUE'), findsOneWidget);
      expect(find.text('Only the blurb.'), findsOneWidget);

      source.release();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('Fetching the full definition…'), findsNothing);
    });
  });

  // --- a lorebook listing ----------------------------------------------------

  group('a lorebook listing', () {
    testWidgets('its entries are folds, and the count is in the block',
        (tester) async {
      await open(
        tester,
        item: _item(
          name: 'Kingdom',
          kind: DiscoverKind.lorebook,
          entryCount: 2,
        ),
        source: _FakeSource(),
      );
      await scrollTo(tester, find.text('FROM THE CATALOGUE'));
      expect(find.text('2'), findsOneWidget);
      await scrollTo(tester, find.text('The capital'));
      expect(find.text('A fact.', skipOffstage: false), findsNothing);
      await tester.tap(find.text('The capital'));
      await tester.pumpAndSettle();
      expect(find.text('A fact.'), findsOneWidget);
      // An unnamed entry falls back to its keys.
      expect(find.text('rain, weather'), findsOneWidget);
    });

    testWidgets("the book's own blurb is the prose block", (tester) async {
      await open(
        tester,
        item: _item(name: 'Kingdom', kind: DiscoverKind.lorebook),
        source: _FakeSource(),
      );
      await scrollTo(tester, find.text('ABOUT'));
      expect(find.text('Places and people.'), findsOneWidget);
    });
  });
}

DiscoverItem _item({
  String name = 'Aria',
  DiscoverKind kind = DiscoverKind.character,
  String creator = '',
  String tagline = '',
  String description = '',
  List<String> tags = const <String>[],
  String? imageUrl,
  int? downloads,
  int? entryCount,
}) =>
    DiscoverItem(
      sourceId: 'fake',
      kind: kind,
      id: 'anon/${name.toLowerCase()}',
      name: name,
      creator: creator,
      tagline: tagline,
      description: description,
      tags: tags,
      imageUrl: imageUrl,
      pageUrl: 'https://example.invalid/$name',
      downloads: downloads,
      entryCount: entryCount,
    );

/// A catalogue that answers from memory, so the page can be driven without a
/// network. [hold] keeps the answer back until [release], which is how the
/// still-loading configuration is tested.
class _FakeSource extends DiscoverSource {
  _FakeSource({
    this.notes = '',
    this.description = '',
    this.scenario = '',
    this.firstMes = '',
    this.alternates = const <String>[],
    this.cardTags = const <String>[],
    this.avatar = '',
    this.hold = false,
  });

  final String notes;
  final String description;
  final String scenario;
  final String firstMes;
  final List<String> alternates;

  /// Tags on the card that comes back, as distinct from the listing's own.
  final List<String> cardTags;
  final String avatar;
  final bool hold;

  final _gate = Completer<void>();

  void release() => _gate.complete();

  @override
  String get id => 'fake';
  @override
  String get label => 'Fake';
  @override
  String get blurb => 'A stand-in catalogue';
  @override
  String get homeUrl => 'https://example.invalid';
  @override
  Set<DiscoverKind> get kinds =>
      const {DiscoverKind.character, DiscoverKind.lorebook};

  @override
  List<DiscoverSort> sortsFor(DiscoverKind kind) =>
      const <DiscoverSort>[DiscoverSort('newest', 'Newest')];

  @override
  Future<List<String>> tags(DiscoverKind kind) async => const ['fantasy'];

  @override
  Future<DiscoverPage> search(DiscoverQuery query) async =>
      const DiscoverPage.empty();

  @override
  Future<DiscoverPayload> fetch(DiscoverItem item) async {
    if (hold) await _gate.future;
    if (item.kind == DiscoverKind.lorebook) {
      return DiscoverPayload(
        lorebook: Lorebook(
          id: 'book-1',
          name: item.name,
          description: 'Places and people.',
          entries: [
            LorebookEntry(uid: 0, name: 'The capital', content: 'A fact.'),
            LorebookEntry(
              uid: 1,
              keys: const ['rain', 'weather'],
              content: 'It rains.',
            ),
          ],
        ),
      );
    }
    return DiscoverPayload(
      character: Character(
        id: 'char-1',
        name: item.name,
        avatar: avatar,
        creatorNotes: notes,
        description: description,
        scenario: scenario,
        firstMes: firstMes,
        alternateGreetings: alternates,
        tags: cardTags,
      ),
    );
  }

  @override
  Future<DiscoverPayload> fetchFromHtml(DiscoverItem item, String html) =>
      fetch(item);
}
