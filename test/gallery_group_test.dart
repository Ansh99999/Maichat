import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/gallery_image.dart';
import 'package:maichat/services/gallery_group.dart';

/// The date grouper is pure, so it gets exercised directly: every label shape,
/// every boundary a week can straddle, and the promise that a non-chronological
/// sort produces one unlabelled run rather than date headings it cannot honour.
void main() {
  GalleryImage at(DateTime when, {String title = '', String? characterId}) =>
      GalleryImage(
        id: '${when.microsecondsSinceEpoch}-$title',
        image: 'local:${when.microsecondsSinceEpoch}.png',
        title: title,
        characterId: characterId,
        createdAt: when,
      );

  group('bucketStart', () {
    test('a day starts at midnight', () {
      expect(
        bucketStart(DateTime(2026, 4, 24, 17, 42, 9), DateGrouping.day),
        DateTime(2026, 4, 24),
      );
    });

    test('a week starts on the Monday', () {
      // 2026-04-24 is a Friday; its week begins Monday the 20th.
      expect(
        bucketStart(DateTime(2026, 4, 24), DateGrouping.week),
        DateTime(2026, 4, 20),
      );
      // A Monday is already its own bucket start.
      expect(
        bucketStart(DateTime(2026, 4, 20), DateGrouping.week),
        DateTime(2026, 4, 20),
      );
      // A Sunday belongs to the week that began six days earlier.
      expect(
        bucketStart(DateTime(2026, 4, 26), DateGrouping.week),
        DateTime(2026, 4, 20),
      );
    });

    test('a week reaching back into the previous month still resolves', () {
      // 2026-05-01 is a Friday, so its Monday is 2026-04-27.
      expect(
        bucketStart(DateTime(2026, 5, 1), DateGrouping.week),
        DateTime(2026, 4, 27),
      );
    });

    test('a month starts on the first', () {
      expect(
        bucketStart(DateTime(2026, 4, 24, 23, 59), DateGrouping.month),
        DateTime(2026, 4),
      );
    });
  });

  group('sectionLabel', () {
    test('a day names the month in full', () {
      expect(sectionLabel(DateTime(2026, 4, 24), DateGrouping.day),
          'April 24, 2026');
    });

    test('a month names itself and the year', () {
      expect(
          sectionLabel(DateTime(2026, 4), DateGrouping.month), 'April 2026');
    });

    test('a week inside one month is a day range', () {
      expect(sectionLabel(DateTime(2026, 4, 20), DateGrouping.week),
          'Apr 20–26, 2026');
    });

    test('a week crossing a month names both months', () {
      expect(sectionLabel(DateTime(2026, 4, 27), DateGrouping.week),
          'Apr 27 – May 3, 2026');
    });

    test('a week crossing a year names both years', () {
      // 2025-12-29 is a Monday, so the week ends 2026-01-04.
      expect(sectionLabel(DateTime(2025, 12, 29), DateGrouping.week),
          'Dec 29, 2025 – Jan 4, 2026');
    });
  });

  group('groupImages', () {
    test('an empty gallery has no sections', () {
      expect(groupImages(const <GalleryImage>[], grouping: DateGrouping.day),
          isEmpty);
    });

    test('pictures from one day form one section', () {
      final images = [
        at(DateTime(2026, 4, 24, 18)),
        at(DateTime(2026, 4, 24, 9)),
      ];
      final sections = groupImages(images, grouping: DateGrouping.day);
      expect(sections, hasLength(1));
      expect(sections.single.label, 'April 24, 2026');
      expect(sections.single.images, hasLength(2));
    });

    test('pictures from different days form a section each, in input order', () {
      final images = [
        at(DateTime(2026, 4, 24), title: 'friday'),
        at(DateTime(2026, 4, 23), title: 'thursday'),
        at(DateTime(2026, 4, 23, 8), title: 'thursday-early'),
      ];
      final sections = groupImages(images, grouping: DateGrouping.day);
      expect(sections.map((s) => s.label),
          ['April 24, 2026', 'April 23, 2026']);
      expect(sections.last.images.map((i) => i.title),
          ['thursday', 'thursday-early']);
    });

    test('the same pictures collapse into one week and then one month', () {
      final images = [
        at(DateTime(2026, 4, 24)),
        at(DateTime(2026, 4, 23)),
        at(DateTime(2026, 4, 21)),
      ];
      expect(groupImages(images, grouping: DateGrouping.day), hasLength(3));

      final weekly = groupImages(images, grouping: DateGrouping.week);
      expect(weekly, hasLength(1));
      expect(weekly.single.label, 'Apr 20–26, 2026');
      expect(weekly.single.images, hasLength(3));

      final monthly = groupImages(images, grouping: DateGrouping.month);
      expect(monthly, hasLength(1));
      expect(monthly.single.label, 'April 2026');
    });

    test('a week bucket keeps pictures from two months together', () {
      final images = [
        at(DateTime(2026, 5, 1)),
        at(DateTime(2026, 4, 28)),
      ];
      final sections = groupImages(images, grouping: DateGrouping.week);
      expect(sections, hasLength(1));
      expect(sections.single.label, 'Apr 27 – May 3, 2026');
    });

    test('a non-chronological order is one unlabelled run', () {
      final images = [
        at(DateTime(2026, 4, 24), title: 'apple'),
        at(DateTime(2025, 1, 2), title: 'banana'),
      ];
      final sections = groupImages(
        images,
        grouping: DateGrouping.day,
        chronological: false,
      );
      expect(sections, hasLength(1));
      expect(sections.single.hasLabel, isFalse);
      expect(sections.single.images.map((i) => i.title), ['apple', 'banana']);
    });

    test('a returning day starts a new section rather than rejoining', () {
      // Sections follow the *order given*, so an unsorted list is not silently
      // re-bucketed into a tidy calendar it does not have.
      final images = [
        at(DateTime(2026, 4, 24), title: 'a'),
        at(DateTime(2026, 4, 23), title: 'b'),
        at(DateTime(2026, 4, 24), title: 'c'),
      ];
      final sections = groupImages(images, grouping: DateGrouping.day);
      expect(sections, hasLength(3));
      expect(sections.map((s) => s.images.single.title), ['a', 'b', 'c']);
    });
  });

  group('sortImages', () {
    test('newest and oldest are mirror images', () {
      final images = [
        at(DateTime(2026, 4, 23), title: 'older'),
        at(DateTime(2026, 4, 24), title: 'newer'),
      ];
      expect(sortImages(images, GallerySort.newest).map((i) => i.title),
          ['newer', 'older']);
      expect(sortImages(images, GallerySort.oldest).map((i) => i.title),
          ['older', 'newer']);
    });

    test('name order is case-insensitive and untitled sorts as "Untitled"', () {
      final images = [
        at(DateTime(2026, 4, 24), title: 'zebra'),
        at(DateTime(2026, 4, 24), title: 'Apple'),
        at(DateTime(2026, 4, 24)),
      ];
      expect(sortImages(images, GallerySort.titleAsc).map((i) => i.displayTitle),
          ['Apple', 'Untitled', 'zebra']);
      expect(
          sortImages(images, GallerySort.titleDesc).map((i) => i.displayTitle),
          ['zebra', 'Untitled', 'Apple']);
    });

    test('never-opened pictures sink below opened ones', () {
      final opened = at(DateTime(2026, 4, 20), title: 'opened')
        ..lastViewed = DateTime(2026, 4, 25);
      final newerButUnopened = at(DateTime(2026, 4, 24), title: 'unopened');
      expect(
        sortImages([newerButUnopened, opened], GallerySort.lastViewed)
            .map((i) => i.title),
        ['opened', 'unopened'],
      );
    });

    test('character order uses names and puts unattached pictures last', () {
      final images = [
        at(DateTime(2026, 4, 24), title: 'loose'),
        at(DateTime(2026, 4, 24), title: 'zoe-pic', characterId: 'zoe'),
        at(DateTime(2026, 4, 24), title: 'amy-pic', characterId: 'amy'),
      ];
      final names = {'amy': 'Amy', 'zoe': 'Zoe'};
      final sorted = sortImages(
        images,
        GallerySort.character,
        nameOf: (id) => names[id] ?? '',
      );
      expect(sorted.map((i) => i.title), ['amy-pic', 'zoe-pic', 'loose']);
    });

    test('sorting does not disturb the caller\'s list', () {
      final images = [
        at(DateTime(2026, 4, 23), title: 'first'),
        at(DateTime(2026, 4, 24), title: 'second'),
      ];
      sortImages(images, GallerySort.newest);
      expect(images.map((i) => i.title), ['first', 'second']);
    });
  });
}
