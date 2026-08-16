/// Decoder for the payload SvelteKit serves at `<route>/__data.json` — the same
/// data a page gets when it loads, which is how a SvelteKit site navigates
/// without a full reload.
///
/// The encoding (devalue) is a flat list where **every integer is a pointer into
/// that list**, not a number. `{"cards": 1}` means "cards is whatever lives at
/// index 1". Values are shared by reference, so the same string appears once no
/// matter how many cards use it — which is why a 60-card page fits in 67 KB, and
/// why reading it naively yields a structure full of small integers.
///
/// Negative indexes are constants rather than positions: -1 undefined, -2 a hole
/// in an array, -3 NaN, -4/-5 infinities, -6 negative zero. A list whose first
/// element is a *string* is a tagged value (`["Date", 12]`), not an array.
class SvelteKitData {
  const SvelteKitData._();

  /// Hydrates the `nodes` of a `__data.json` document and returns the data of
  /// the last node that carries any — for a page route that is the page's own
  /// data, with the layout's data in the nodes before it.
  ///
  /// Returns null when the document is not a data response at all.
  static Object? decodeDocument(Object? json) {
    if (json is! Map) return null;
    final nodes = json['nodes'];
    if (nodes is! List) return null;
    Object? last;
    for (final node in nodes) {
      if (node is! Map) continue;
      if (node['type'] != 'data') continue;
      final decoded = decodeNode(node['data']);
      if (decoded != null) last = decoded;
    }
    return last;
  }

  /// Hydrates one node's flat list. Index 0 is the root.
  static Object? decodeNode(Object? data) {
    if (data is! List || data.isEmpty) return null;
    return _hydrate(0, data, <int, Object?>{}, 0);
  }

  static Object? _hydrate(
    Object? value,
    List<Object?> flat,
    Map<int, Object?> seen,
    int depth,
  ) {
    // A structure this deep is a cycle or a payload we have no business reading.
    if (depth > 64) return null;
    if (value is! int) return _plain(value, flat, seen, depth);
    return switch (value) {
      -1 || -2 => null,
      -3 => double.nan,
      -4 => double.infinity,
      -5 => double.negativeInfinity,
      -6 => -0.0,
      _ => _atIndex(value, flat, seen, depth),
    };
  }

  static Object? _atIndex(
    int index,
    List<Object?> flat,
    Map<int, Object?> seen,
    int depth,
  ) {
    if (index < 0 || index >= flat.length) return null;
    if (seen.containsKey(index)) return seen[index];
    // Guard against a self-referential pointer before recursing into it.
    seen[index] = null;
    final hydrated = _plain(flat[index], flat, seen, depth + 1);
    seen[index] = hydrated;
    return hydrated;
  }

  static Object? _plain(
    Object? raw,
    List<Object?> flat,
    Map<int, Object?> seen,
    int depth,
  ) {
    if (raw is Map) {
      final out = <String, dynamic>{};
      for (final entry in raw.entries) {
        out['${entry.key}'] = _hydrate(entry.value, flat, seen, depth + 1);
      }
      return out;
    }
    if (raw is List) {
      if (raw.isNotEmpty && raw.first is String) {
        // A tagged value. Dates are the only one worth reviving here; anything
        // else (Map, Set, BigInt, RegExp) is handed back as its payload so a
        // caller sees data rather than a marker.
        final tag = raw.first as String;
        final payload =
            raw.length > 1 ? _hydrate(raw[1], flat, seen, depth + 1) : null;
        if (tag == 'Date' && payload is String) {
          return DateTime.tryParse(payload) ?? payload;
        }
        return payload;
      }
      return raw
          .map((e) => _hydrate(e, flat, seen, depth + 1))
          .toList(growable: false);
    }
    return raw;
  }
}
