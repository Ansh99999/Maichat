import 'package:flutter/material.dart';

/// A picture on disk: the file's name, its size, and when it was last written.
/// The Storage screen lists these directly — see [StorageReport] and the images
/// grid — so it is a small record rather than anything that touches the store.
typedef ImageFileStat = ({String name, int bytes, DateTime modified});

/// The buckets the Storage screen groups the app's footprint into. The order
/// here is the fixed colour-slot order (see [storageColor]) and the order the
/// segmented bar and legend draw in — colour follows the *category*, never its
/// current size, so a big chat month never repaints images.
enum StorageCategory {
  images,
  chats,
  characters,
  lorebooks,
  presets,
  gallery,
  embeddings,
  cache,
  settings;

  /// The prefs keys that belong to this category. Empty for [images] (files on
  /// disk, not a prefs blob) and [settings] (the catch-all for everything else).
  /// [embeddings] owns its small config/records blobs; its bulk is the vector
  /// files on disk (added via [StorageReport.build]'s `vectorBytes`).
  List<String> get keys => switch (this) {
        StorageCategory.chats => const ['conversations'],
        StorageCategory.characters => const ['characters'],
        StorageCategory.lorebooks => const ['lorebooks'],
        StorageCategory.presets => const ['presets'],
        StorageCategory.gallery => const ['gallery'],
        StorageCategory.embeddings => const ['embeddings', 'documents'],
        StorageCategory.cache => const ['modelCache', 'discover'],
        _ => const <String>[],
      };

  String get label => switch (this) {
        StorageCategory.images => 'Images',
        StorageCategory.chats => 'Chats',
        StorageCategory.characters => 'Characters',
        StorageCategory.lorebooks => 'Lorebooks',
        StorageCategory.presets => 'Presets',
        StorageCategory.gallery => 'Gallery',
        StorageCategory.embeddings => 'Embeddings',
        StorageCategory.cache => 'Cache',
        StorageCategory.settings => 'Settings',
      };

  IconData get icon => switch (this) {
        StorageCategory.images => Icons.image_outlined,
        StorageCategory.chats => Icons.chat_bubble_outline,
        StorageCategory.characters => Icons.person_outline,
        StorageCategory.lorebooks => Icons.menu_book_outlined,
        StorageCategory.presets => Icons.tune_outlined,
        StorageCategory.gallery => Icons.photo_library_outlined,
        StorageCategory.embeddings => Icons.scatter_plot_outlined,
        StorageCategory.cache => Icons.cached_outlined,
        StorageCategory.settings => Icons.settings_outlined,
      };

  /// Whether tapping the row opens a manage screen. Settings is the read-only
  /// catch-all.
  bool get manageable => switch (this) {
        StorageCategory.settings => false,
        _ => true,
      };
}

/// The categorical colour for a bucket, from the data-viz reference palette
/// (validated for CVD safety in both modes; the light steps that fall below
/// 3:1 are always shown beside a text label, which the bar's legend guarantees).
/// Colour is a property of the category, not its rank — the enum order is the
/// fixed slot order the palette was validated in.
Color storageColor(StorageCategory category, Brightness brightness) {
  const light = <Color>[
    Color(0xFF2A78D6), // images  — blue
    Color(0xFF008300), // chats   — green
    Color(0xFFE87BA4), // characters — magenta
    Color(0xFFEDA100), // lorebooks — yellow
    Color(0xFF1BAF7A), // presets — aqua
    Color(0xFFEB6834), // gallery — orange
    Color(0xFF4A3AA7), // cache   — violet
    Color(0xFFE34948), // settings — red
  ];
  const dark = <Color>[
    Color(0xFF3987E5),
    Color(0xFF008300),
    Color(0xFFD55181),
    Color(0xFFC98500),
    Color(0xFF199E70),
    Color(0xFFD95926),
    Color(0xFF9085E9),
    Color(0xFFE66767),
  ];
  const muted = Color(0xFF898781); // embeddings placeholder
  final slot = switch (category) {
    StorageCategory.images => 0,
    StorageCategory.chats => 1,
    StorageCategory.characters => 2,
    StorageCategory.lorebooks => 3,
    StorageCategory.presets => 4,
    StorageCategory.gallery => 5,
    StorageCategory.cache => 6,
    StorageCategory.settings => 7,
    StorageCategory.embeddings => -1,
  };
  if (slot < 0) return muted;
  return (brightness == Brightness.dark ? dark : light)[slot];
}

/// One category's footprint: how many bytes and how many items it holds.
class StorageCategoryUsage {
  const StorageCategoryUsage(this.category, this.bytes, this.count);

  final StorageCategory category;
  final int bytes;
  final int count;
}

/// The whole storage picture behind the Storage settings screen: every category
/// with its size and item count, plus the total. Counts *both* the prefs blobs
/// (via [Storage.usage]) and the image files on disk — the images directory is
/// the bulk and is invisible to prefs accounting.
class StorageReport {
  const StorageReport(this.categories, this.totalBytes);

  /// Every category, in the fixed enum order.
  final List<StorageCategoryUsage> categories;
  final int totalBytes;

  StorageCategoryUsage operator [](StorageCategory category) =>
      categories.firstWhere((c) => c.category == category);

  /// The categories that actually hold something, in enum order — what the bar
  /// and legend draw. Embeddings (always empty) and any empty bucket fall away.
  List<StorageCategoryUsage> get nonEmpty =>
      categories.where((c) => c.bytes > 0).toList(growable: false);

  /// Buckets [prefsUsage] (key → bytes, e.g. from [Storage.usage]) and the
  /// on-disk [imageFiles] into categories. [itemCounts] carries the real item
  /// count for the list-backed categories (number of chats, characters, …),
  /// which the raw prefs blob cannot reveal; anything omitted counts as the
  /// number of prefs keys the category owns.
  factory StorageReport.build({
    required Map<String, int> prefsUsage,
    required List<ImageFileStat> imageFiles,
    Map<StorageCategory, int> itemCounts = const {},
    int vectorBytes = 0,
  }) {
    // Which category owns each known prefs key; the rest fall to `settings`.
    final owner = <String, StorageCategory>{};
    for (final category in StorageCategory.values) {
      for (final key in category.keys) {
        owner[key] = category;
      }
    }

    final bytes = {for (final c in StorageCategory.values) c: 0};
    final keyCount = {for (final c in StorageCategory.values) c: 0};
    prefsUsage.forEach((key, size) {
      final category = owner[key] ?? StorageCategory.settings;
      bytes[category] = bytes[category]! + size;
      keyCount[category] = keyCount[category]! + 1;
    });

    // Images live on disk, not in prefs.
    bytes[StorageCategory.images] =
        imageFiles.fold(0, (sum, f) => sum + f.bytes);

    // Embedding vectors live on disk too (files, never in prefs).
    bytes[StorageCategory.embeddings] =
        bytes[StorageCategory.embeddings]! + vectorBytes;

    final categories = <StorageCategoryUsage>[];
    for (final category in StorageCategory.values) {
      final count = switch (category) {
        StorageCategory.images => imageFiles.length,
        _ => itemCounts[category] ?? keyCount[category]!,
      };
      categories.add(StorageCategoryUsage(category, bytes[category]!, count));
    }
    final total = bytes.values.fold(0, (sum, v) => sum + v);
    return StorageReport(categories, total);
  }
}

/// A byte count in the shortest human unit — the one string the whole Storage
/// screen (bar total, category rows, per-item sizes) formats through.
String formatBytes(int bytes) {
  const kb = 1024;
  const mb = 1024 * 1024;
  const gb = 1024 * 1024 * 1024;
  if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(2)} GB';
  if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(2)} MB';
  if (bytes >= kb) return '${(bytes / kb).toStringAsFixed(1)} KB';
  return '$bytes B';
}
