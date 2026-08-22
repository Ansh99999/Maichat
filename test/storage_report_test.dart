import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/services/storage_report.dart';

void main() {
  ImageFileStat img(String name, int bytes) =>
      (name: name, bytes: bytes, modified: DateTime(2026, 1, 1));

  test('build buckets known prefs keys and folds image files into images', () {
    final report = StorageReport.build(
      prefsUsage: {
        'conversations': 200,
        'characters': 5000,
        'lorebooks': 300,
        'presets': 100,
        'gallery': 40,
        'modelCache': 10,
        'discover': 20,
      },
      imageFiles: [img('a.png', 1000), img('b.jpg', 2500)],
      itemCounts: {
        StorageCategory.chats: 3,
        StorageCategory.characters: 12,
      },
    );

    expect(report[StorageCategory.images].bytes, 3500);
    expect(report[StorageCategory.images].count, 2);
    expect(report[StorageCategory.chats].bytes, 200);
    expect(report[StorageCategory.chats].count, 3); // itemCount wins
    expect(report[StorageCategory.characters].count, 12);
    expect(report[StorageCategory.cache].bytes, 30); // modelCache + discover
    // Total counts prefs blobs AND the image files.
    expect(report.totalBytes, 200 + 5000 + 300 + 100 + 40 + 30 + 3500);
  });

  test('unknown prefs keys fall into settings, not images', () {
    final report = StorageReport.build(
      prefsUsage: {
        'providers': 80,
        'appearance': 20,
        'chatInterface': 15,
        'tokenizer': 5,
        'activeConversation': 4,
      },
      imageFiles: const [],
    );
    expect(report[StorageCategory.settings].bytes, 124);
    expect(report[StorageCategory.settings].count, 5);
    expect(report[StorageCategory.images].bytes, 0);
  });

  test('image bytes come from the files, never a prefs key', () {
    // Even if some stray "images" prefs key existed, images total is the disk.
    final report = StorageReport.build(
      prefsUsage: const {},
      imageFiles: [img('x.png', 42)],
    );
    expect(report[StorageCategory.images].bytes, 42);
  });

  test('nonEmpty drops empty buckets and the embeddings placeholder', () {
    final report = StorageReport.build(
      prefsUsage: {'conversations': 10},
      imageFiles: [img('a.png', 5)],
    );
    final present = report.nonEmpty.map((c) => c.category).toList();
    expect(present, contains(StorageCategory.images));
    expect(present, contains(StorageCategory.chats));
    expect(present, isNot(contains(StorageCategory.embeddings)));
    expect(present, isNot(contains(StorageCategory.presets)));
  });

  test('embeddings counts on-disk vector bytes and is manageable', () {
    final empty =
        StorageReport.build(prefsUsage: const {}, imageFiles: const []);
    expect(empty[StorageCategory.embeddings].bytes, 0);
    // Vector files live on disk (like images), passed in via vectorBytes.
    final withVectors = StorageReport.build(
      prefsUsage: const {},
      imageFiles: const [],
      vectorBytes: 2048,
    );
    expect(withVectors[StorageCategory.embeddings].bytes, 2048);
    expect(StorageCategory.embeddings.manageable, isTrue);
    expect(StorageCategory.settings.manageable, isFalse);
    expect(StorageCategory.chats.manageable, isTrue);
  });

  test('formatBytes picks the shortest sensible unit', () {
    expect(formatBytes(512), '512 B');
    expect(formatBytes(1536), '1.5 KB');
    expect(formatBytes(3 * 1024 * 1024), '3.00 MB');
    expect(formatBytes(2 * 1024 * 1024 * 1024), '2.00 GB');
  });
}
