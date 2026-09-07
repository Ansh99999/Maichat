import 'dart:io';

/// The limits applied to Flutter's decoded-bitmap cache.
class ImageCacheBudget {
  const ImageCacheBudget({
    required this.maximumSize,
    required this.maximumSizeBytes,
  });

  final int maximumSize;
  final int maximumSizeBytes;
}

const int _minimumBytes = 100 * 1024 * 1024;
const int _maximumBytes = 256 * 1024 * 1024;

/// Keeps enough decoded pictures for image-heavy screens without allowing the
/// cache to grow without bound. Flutter's 100 MiB default remains the floor on
/// low-memory devices; larger devices lend at most 256 MiB to the cache.
ImageCacheBudget imageCacheBudget({int? physicalMemoryBytes}) {
  final total = physicalMemoryBytes ?? _physicalMemoryBytes() ?? 0;
  final bytes = (total * 0.20)
      .round()
      .clamp(_minimumBytes, _maximumBytes)
      .toInt();
  return ImageCacheBudget(maximumSize: 2000, maximumSizeBytes: bytes);
}

int? _physicalMemoryBytes() {
  try {
    final file = File('/proc/meminfo');
    if (!file.existsSync()) return null;
    for (final line in file.readAsLinesSync()) {
      if (!line.startsWith('MemTotal:')) continue;
      final fields = line.trim().split(RegExp(r'\s+'));
      if (fields.length < 2) return null;
      final kibibytes = int.tryParse(fields[1]);
      return kibibytes == null ? null : kibibytes * 1024;
    }
  } catch (_) {
    // A platform without procfs keeps Flutter's existing 100 MiB floor.
  }
  return null;
}
