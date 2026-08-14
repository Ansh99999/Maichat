import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/painting.dart';

/// Image providers for character avatars, deduplicated and size-capped.
///
/// Avatars are stored on the character as base64 (an imported card keeps its own
/// picture), so a naive `MemoryImage(base64Decode(...))` has two problems: the
/// decode runs again for every widget that shows the avatar, and — because
/// `MemoryImage` compares its byte list by identity — each fresh `Uint8List`
/// becomes a *different* key in Flutter's [ImageCache]. One character shown on
/// twelve turns then means twelve base64 decodes, twelve image decodes and
/// twelve full-size bitmaps resident at once. On a 1600x1600 card that is ~10 MB
/// each, which is what made scrolling past a character's picture stutter.
///
/// [avatarImage] fixes both: the same avatar at the same display size always
/// returns the *identical* provider (so the image cache holds one entry), and
/// the bitmap is decoded at the size it is drawn at rather than at source
/// resolution.

/// Providers by `signature@pixel-bucket`, most recently used last.
final LinkedHashMap<String, ImageProvider> _cache =
    LinkedHashMap<String, ImageProvider>();

/// Source bytes each cached entry pins, same keys as [_cache].
final Map<String, int> _bytes = <String, int>{};

/// Kept deliberately small: a handful of distinct avatars at a couple of sizes
/// covers a chat, the character list and the editor.
const int _maxEntries = 32;

/// A cached provider pins the picture's *source* bytes, so the count of entries
/// is not the only thing worth bounding — a store written before avatars were
/// capped can hold one of ten megabytes.
const int _maxCachedBytes = 24 * 1024 * 1024;

/// Decoded-bitmap size to ask for, in device pixels — the longest side.
/// Bucketing keeps one avatar from occupying a new cache entry for every
/// slightly different display size. The top bucket only comes into play when
/// the user has cranked the avatar size right up in Chat Interface settings.
const List<int> _buckets = [64, 128, 256, 512, 1024, 2048];

int _bucketFor(double? displaySize, double devicePixelRatio) {
  if (displaySize == null || displaySize <= 0) return _buckets.last;
  final wanted = displaySize * (devicePixelRatio <= 0 ? 1 : devicePixelRatio);
  for (final bucket in _buckets) {
    if (wanted <= bucket) return bucket;
  }
  return _buckets.last;
}

/// A short, collision-safe stand-in for a possibly multi-megabyte base64
/// string, so the cache key stays cheap to hash and compare.
String _signature(String avatar) {
  final head = avatar.length <= 24 ? avatar : avatar.substring(0, 24);
  final tail = avatar.length <= 24 ? '' : avatar.substring(avatar.length - 24);
  return '${avatar.length}:${avatar.hashCode}:$head:$tail';
}

/// Whether [avatar] is a URL rather than base64 bytes.
bool avatarIsUrl(String avatar) {
  final trimmed = avatar.trim();
  return trimmed.startsWith('http://') || trimmed.startsWith('https://');
}

/// The provider for [avatar] (a URL or base64 image), decoded at no more than
/// what [displaySize] logical pixels need. Returns null when there is no usable
/// picture, so callers fall back to a monogram.
///
/// Passing the same [avatar] and a [displaySize] in the same bucket returns the
/// same object every time — that is the whole point, so keep it that way.
ImageProvider? avatarImage(
  String avatar, {
  double? displaySize,
  double devicePixelRatio = 1,
}) {
  final trimmed = avatar.trim();
  if (trimmed.isEmpty) return null;
  final bucket = _bucketFor(displaySize, devicePixelRatio);
  final key = '${_signature(trimmed)}@$bucket';

  final cached = _cache.remove(key);
  if (cached != null) {
    _cache[key] = cached; // Re-insert so it counts as most recently used.
    return cached;
  }

  final ImageProvider? base;
  final int sourceBytes;
  if (avatarIsUrl(trimmed)) {
    base = NetworkImage(trimmed);
    sourceBytes = 0; // The bytes live in Flutter's own image cache, not here.
  } else {
    final bytes = _decode(trimmed);
    base = bytes == null ? null : MemoryImage(bytes);
    sourceBytes = bytes?.length ?? 0;
  }
  if (base == null) return null;

  // Cap the resident bitmap at the size it is actually drawn at. "fit" with
  // both sides set means the longest side lands on the bucket and the aspect
  // ratio is kept, so free-fit avatars still report their real proportions.
  final provider = ResizeImage(
    base,
    width: bucket,
    height: bucket,
    policy: ResizeImagePolicy.fit,
    allowUpscaling: false,
  );
  _cache[key] = provider;
  _bytes[key] = sourceBytes;
  var held = _bytes.values.fold<int>(0, (sum, b) => sum + b);
  while (_cache.length > 1 &&
      (_cache.length > _maxEntries || held > _maxCachedBytes)) {
    final oldest = _cache.keys.first;
    _cache.remove(oldest);
    held -= _bytes.remove(oldest) ?? 0;
  }
  return provider;
}

Uint8List? _decode(String base64Avatar) {
  try {
    final bytes = base64Decode(base64Avatar);
    return bytes.isEmpty ? null : bytes;
  } catch (_) {
    // Not base64 (a stale path, a data: URI, junk): show the monogram.
    return null;
  }
}

/// Drops every cached provider. For tests and for the "free up memory" path.
void clearAvatarImageCache() {
  _cache.clear();
  _bytes.clear();
}
