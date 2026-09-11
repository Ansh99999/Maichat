import 'dart:collection';

/// Compact intrinsic image metadata shared by every natural-size picture.
///
/// Only exact `local:` references and HTTP(S) URLs are durable. Legacy base64
/// pictures can still benefit for this process, but their bytes (or a key made
/// from those bytes) must never enter preferences.
class ImageRatioCache {
  ImageRatioCache({this.maxEntries = 256});

  final int maxEntries;
  final LinkedHashMap<String, double> _durable =
      LinkedHashMap<String, double>();
  final LinkedHashMap<String, double> _ephemeral =
      LinkedHashMap<String, double>();

  Object? _listenerToken;
  void Function()? _onDurableChanged;

  double? ratioOf(String imageRef) {
    final ref = imageRef.trim();
    if (ref.isEmpty) return null;
    final durable = durableImageRatioKey(ref);
    final cache = durable == null ? _ephemeral : _durable;
    final key = durable ?? _signature(ref);
    final ratio = cache.remove(key);
    if (ratio == null) return null;
    cache[key] = ratio;
    return ratio;
  }

  void note(String imageRef, double ratio) {
    final ref = imageRef.trim();
    if (ref.isEmpty || !ratio.isFinite || ratio <= 0) return;
    final durable = durableImageRatioKey(ref);
    final cache = durable == null ? _ephemeral : _durable;
    final key = durable ?? _signature(ref);
    final previous = cache.remove(key);
    cache[key] = ratio;
    _trim(cache);
    if (durable != null && previous != ratio) _onDurableChanged?.call();
  }

  /// Replaces durable state during startup without treating hydration as a write.
  void replaceDurable(Map<String, double> ratios) {
    _durable.clear();
    for (final entry in ratios.entries) {
      final key = durableImageRatioKey(entry.key);
      final ratio = entry.value;
      if (key == null || !ratio.isFinite || ratio <= 0) continue;
      _durable.remove(key);
      _durable[key] = ratio;
      _trim(_durable);
    }
  }

  Map<String, double> durableSnapshot() => Map<String, double>.of(_durable);

  /// Clears process state. Cache clearing and tests persist/remove storage
  /// explicitly, so this deliberately does not invoke the persistence listener.
  void clear() {
    _durable.clear();
    _ephemeral.clear();
  }

  /// Test/process reset: clears data and releases a stale app-state owner.
  void reset() {
    clear();
    _listenerToken = null;
    _onDurableChanged = null;
  }

  /// Installs the one app-state persistence owner and returns its identity token.
  Object bindDurableChanged(void Function() listener) {
    final token = Object();
    _listenerToken = token;
    _onDurableChanged = listener;
    return token;
  }

  void unbindDurableChanged(Object? token) {
    if (!identical(token, _listenerToken)) return;
    _listenerToken = null;
    _onDurableChanged = null;
  }

  void _trim(LinkedHashMap<String, double> cache) {
    while (cache.length > maxEntries) {
      cache.remove(cache.keys.first);
    }
  }
}

/// Returns the exact safe persistence key, or null for ephemeral image data.
String? durableImageRatioKey(String imageRef) {
  final ref = imageRef.trim();
  if (ref.startsWith('local:')) {
    final name = ref.substring('local:'.length).trim();
    if (name.isEmpty || name.contains('/') || name.contains('\\')) return null;
    return 'local:$name';
  }
  final uri = Uri.tryParse(ref);
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    return null;
  }
  return ref;
}

String _signature(String value) {
  final head = value.length <= 24 ? value : value.substring(0, 24);
  final tail = value.length <= 24 ? '' : value.substring(value.length - 24);
  return '${value.length}:${value.hashCode}:$head:$tail';
}

final ImageRatioCache imageRatioCache = ImageRatioCache();
