import '../models/gallery_image.dart';

/// One date band in a gallery: a heading and the pictures under it.
///
/// A section with an empty [label] is an unlabelled run — what a name-ordered or
/// character-ordered gallery produces, because a date heading over an A–Z list
/// would claim an order the list does not have.
class GallerySection {
  const GallerySection({
    required this.label,
    required this.bucket,
    required this.images,
  });

  /// The heading, e.g. `April 24, 2026`, `Apr 20–26, 2026`, `April 2026`. Empty
  /// for an unlabelled run.
  final String label;

  /// The start of the bucket this section covers — midnight of the day, the
  /// Monday of the week, or the first of the month. Epoch for an unlabelled run.
  final DateTime bucket;

  final List<GalleryImage> images;

  bool get hasLabel => label.isNotEmpty;
}

/// Groups [images] into date bands at the given [grouping].
///
/// The input order is preserved *within* and *between* bands: whatever sort the
/// screen applied decides which band comes first and where each picture sits
/// inside it. That keeps sorting and grouping independent — "oldest first" reads
/// top-down through the calendar without this function knowing which way round it
/// is going.
///
/// Pass [chronological] false (a name or character ordering) and the whole list
/// comes back as one unlabelled section.
List<GallerySection> groupImages(
  List<GalleryImage> images, {
  required DateGrouping grouping,
  bool chronological = true,
}) {
  if (images.isEmpty) return const <GallerySection>[];
  if (!chronological) {
    return [
      GallerySection(
        label: '',
        bucket: DateTime.fromMillisecondsSinceEpoch(0),
        images: List<GalleryImage>.unmodifiable(images),
      ),
    ];
  }

  final sections = <GallerySection>[];
  DateTime? currentBucket;
  var currentImages = <GalleryImage>[];

  void flush() {
    final bucket = currentBucket;
    if (bucket == null || currentImages.isEmpty) return;
    sections.add(GallerySection(
      label: sectionLabel(bucket, grouping),
      bucket: bucket,
      images: List<GalleryImage>.unmodifiable(currentImages),
    ));
  }

  for (final image in images) {
    final bucket = bucketStart(image.createdAt, grouping);
    if (currentBucket == null || bucket != currentBucket) {
      flush();
      currentBucket = bucket;
      currentImages = <GalleryImage>[image];
    } else {
      currentImages.add(image);
    }
  }
  flush();
  return sections;
}

/// The start of the bucket [when] falls in: midnight that day, the Monday of that
/// week, or the first of that month.
DateTime bucketStart(DateTime when, DateGrouping grouping) {
  switch (grouping) {
    case DateGrouping.day:
      return DateTime(when.year, when.month, when.day);
    case DateGrouping.week:
      // `weekday` is 1 (Monday) through 7 (Sunday), so this walks back to the
      // Monday. Constructing with a day-of-month that goes below 1 is fine —
      // DateTime normalises into the previous month, which is exactly what a week
      // straddling a month boundary needs.
      final day = DateTime(when.year, when.month, when.day);
      return DateTime(day.year, day.month, day.day - (day.weekday - 1));
    case DateGrouping.month:
      return DateTime(when.year, when.month);
  }
}

/// The heading for a bucket starting at [start].
///
/// A week reads `Apr 20–26, 2026`, shortening to `Apr 27 – May 3, 2026` when it
/// crosses a month and `Dec 28, 2025 – Jan 3, 2026` when it crosses a year, so
/// the label never claims a span it does not cover.
String sectionLabel(DateTime start, DateGrouping grouping) {
  switch (grouping) {
    case DateGrouping.day:
      return '${_months[start.month - 1]} ${start.day}, ${start.year}';
    case DateGrouping.month:
      return '${_months[start.month - 1]} ${start.year}';
    case DateGrouping.week:
      final end = DateTime(start.year, start.month, start.day + 6);
      final from = _shortMonths[start.month - 1];
      final to = _shortMonths[end.month - 1];
      if (start.year != end.year) {
        return '$from ${start.day}, ${start.year} – $to ${end.day}, ${end.year}';
      }
      if (start.month != end.month) {
        return '$from ${start.day} – $to ${end.day}, ${end.year}';
      }
      return '$from ${start.day}–${end.day}, ${end.year}';
  }
}

/// Applies [sort] to a copy of [images].
///
/// Kept beside the grouper rather than in the screen so the two agree about what
/// "chronological" means: this is the only place that decides the order the bands
/// come out in.
List<GalleryImage> sortImages(
  List<GalleryImage> images,
  GallerySort sort, {
  String Function(String? characterId)? nameOf,
}) {
  final out = List<GalleryImage>.from(images);
  switch (sort) {
    case GallerySort.newest:
      out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    case GallerySort.oldest:
      out.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    case GallerySort.titleAsc:
      out.sort((a, b) => _byTitle(a, b));
    case GallerySort.titleDesc:
      out.sort((a, b) => _byTitle(b, a));
    case GallerySort.lastViewed:
      // Never-opened pictures sink below the ones that have been, rather than
      // sorting as "infinitely long ago" among them.
      out.sort((a, b) {
        final av = a.lastViewed;
        final bv = b.lastViewed;
        if (av == null && bv == null) return b.createdAt.compareTo(a.createdAt);
        if (av == null) return 1;
        if (bv == null) return -1;
        final byViewed = bv.compareTo(av);
        return byViewed != 0 ? byViewed : b.createdAt.compareTo(a.createdAt);
      });
    case GallerySort.character:
      final name = nameOf ?? (id) => id ?? '';
      out.sort((a, b) {
        // Unattached pictures gather at the end; they belong to no album.
        if ((a.characterId == null) != (b.characterId == null)) {
          return a.characterId == null ? 1 : -1;
        }
        final byName = name(a.characterId)
            .toLowerCase()
            .compareTo(name(b.characterId).toLowerCase());
        return byName != 0 ? byName : b.createdAt.compareTo(a.createdAt);
      });
  }
  return out;
}

int _byTitle(GalleryImage a, GalleryImage b) {
  final byTitle = a.displayTitle.toLowerCase().compareTo(
        b.displayTitle.toLowerCase(),
      );
  return byTitle != 0 ? byTitle : b.createdAt.compareTo(a.createdAt);
}

const List<String> _months = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

const List<String> _shortMonths = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];
