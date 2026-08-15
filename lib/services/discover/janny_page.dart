import 'dart:convert';

/// Reading a JannyAI character page.
///
/// JannyAI has no JSON detail API. The definition is server-rendered into the
/// page as the props of an Astro island — a `<astro-island props="...">`
/// attribute holding HTML-escaped JSON, where every value is wrapped in Astro's
/// own `[type, data]` envelope. The maintained SillyTavern Character Library
/// extension reads it the same way; this is a port of that, with one addition:
/// rather than depending on the order of attributes in the tag, the last resort
/// sweeps every island on the page and takes whichever one carries a
/// `character` key. Attribute order is not part of any contract.
///
/// Everything here is pure string work, so it can be tested against a captured
/// page without a network — which matters, because JannyAI's front door is
/// Cloudflare-guarded and cannot be reached from every machine.

/// What a page yielded: the character object as JannyAI models it, plus the
/// picture the page was showing.
class JannyPage {
  const JannyPage({required this.character, this.imageUrl, this.creator});

  /// JannyAI's own field names — `personality` is the definition body,
  /// `description` is the public blurb. Crossed relative to the card spec.
  final Map<String, dynamic> character;

  final String? imageUrl;

  /// Scraped from the rendered "Creator: @name" line, which the props do not
  /// always carry.
  final String? creator;

  /// Whether this page actually carried a definition, as opposed to a shell with
  /// a name in it.
  bool get hasDefinition =>
      _nonEmpty(character['personality']) ||
      _nonEmpty(character['firstMessage']);

  static bool _nonEmpty(Object? value) =>
      value is String && value.trim().isNotEmpty;
}

/// Raised when a page could be fetched but not understood.
class JannyPageException implements Exception {
  const JannyPageException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Cloudflare's interstitial and error pages, by the markers they all carry.
/// Only the head of the body is examined — the markers are always in it, and a
/// challenge page is small.
bool looksLikeChallenge(String body) {
  final head = body.length <= 4000 ? body : body.substring(0, 4000);
  return RegExp(
    r'Just a moment|cf-challenge|challenge-platform|__cf_chl|'
    r'Attention Required! \| Cloudflare|cf-error-details|cf_captcha',
    caseSensitive: false,
  ).hasMatch(head);
}

/// Whether a body is plausibly a rendered character page rather than a stub, a
/// redirect or a block page.
bool looksLikeCharacterPage(String body) =>
    body.length > 1000 &&
    (body.contains('astro-island') || body.contains('CharacterButtons'));

/// Undoes the HTML escaping of an attribute value. `&amp;` is resolved last, so
/// text that legitimately contained `&amp;lt;` does not decode twice.
String unescapeAttribute(String value) => value
    .replaceAll('&quot;', '"')
    .replaceAll('&#34;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&#39;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&#x2F;', '/')
    .replaceAll('&amp;', '&');

/// Unwraps Astro's `[type, data]` props envelope.
///
/// Type 0 is a plain value — and when that value is a map, each of *its* values
/// is wrapped in turn, so it recurses. Type 1 is an array of wrapped items.
/// Astro has further types for dates, bigints and typed arrays; none appear in
/// this payload, so anything else is handed back as its raw data.
Object? decodeAstroValue(Object? value) {
  if (value is! List || value.length < 2) return value;
  final type = value[0];
  final data = value[1];
  if (type == 0) {
    if (data is Map) {
      return <String, dynamic>{
        for (final entry in data.entries)
          '${entry.key}': decodeAstroValue(entry.value),
      };
    }
    return data;
  }
  if (type == 1 && data is List) {
    return data.map(decodeAstroValue).toList();
  }
  return data;
}

/// Every `props="…"` attribute on the page, decoded, in document order.
Iterable<Map<String, dynamic>> _islandProps(String html) sync* {
  for (final match
      in RegExp(r'props="([^"]*)"', caseSensitive: false).allMatches(html)) {
    final raw = match.group(1);
    if (raw == null || raw.isEmpty) continue;
    Object? decoded;
    try {
      decoded = jsonDecode(unescapeAttribute(raw));
    } catch (_) {
      continue; // Not every props attribute on the page is the one we want.
    }
    if (decoded is Map<String, dynamic>) yield decoded;
  }
}

/// Pulls the character out of [html], or throws [JannyPageException] saying
/// which way it failed — a challenge page and a restructured page need
/// different responses from the caller.
JannyPage parseJannyPage(String html) {
  if (looksLikeChallenge(html)) {
    throw const JannyPageException(
      'JannyAI answered with a Cloudflare check instead of the page.',
    );
  }
  if (!looksLikeCharacterPage(html)) {
    throw JannyPageException(
      'That did not look like a JannyAI character page '
      '(${html.length} bytes, no Astro island in it).',
    );
  }

  // The two shapes the extension relies on, tried first because they are known
  // to match the live page today.
  final targeted = RegExp(
    r'astro-island[^>]*component-export="CharacterButtons"[^>]*props="([^"]*)"',
  ).firstMatch(html) ??
      RegExp(r'astro-island[^>]*props="([^"]*character[^"]*)"').firstMatch(html);

  final candidates = <Map<String, dynamic>>[];
  if (targeted != null) {
    try {
      final decoded = jsonDecode(unescapeAttribute(targeted.group(1)!));
      if (decoded is Map<String, dynamic>) candidates.add(decoded);
    } catch (_) {
      // Fall through to the sweep.
    }
  }
  // Then every island on the page, so a reordered attribute or a renamed
  // component does not take the feature down.
  candidates.addAll(_islandProps(html));

  for (final props in candidates) {
    final character = decodeAstroValue(props['character']);
    if (character is! Map<String, dynamic> || character.isEmpty) continue;
    final image = decodeAstroValue(props['imageUrl']);
    return JannyPage(
      character: character,
      imageUrl: image is String && image.trim().isNotEmpty ? image.trim() : null,
      creator: scrapeCreator(html),
    );
  }

  // Opening tags only: `<astro-island …></astro-island>` would otherwise count
  // twice and the number in the message would be nonsense.
  final islands = RegExp(r'<astro-island').allMatches(html).length;
  throw JannyPageException(
    'JannyAI\'s page no longer carries the character where the app looks for '
    'it ($islands islands, none with a definition).',
  );
}

/// The creator name from the rendered "Creator: @name" line. The props often
/// omit it even when the page shows it.
///
/// Any run of tags is allowed between the label and the link — the label may be
/// the tail of one element and the link the start of another, and which it is
/// depends on markup nobody promised to keep stable.
String? scrapeCreator(String html) {
  final match = RegExp(
    r'Creator:\s*(?:<[^>]*>\s*)*<a[^>]*>\s*@?([^<]+)<\/a>',
    caseSensitive: false,
  ).firstMatch(html);
  final name = match?.group(1)?.trim();
  return name == null || name.isEmpty ? null : name;
}
