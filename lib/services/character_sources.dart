import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'character_codec.dart';

/// How a source collects its input before it can fetch.
enum SourceInputKind {
  /// Runs immediately (e.g. opens a file picker).
  none,

  /// Needs a blob of pasted text.
  text,

  /// Needs a URL.
  url,
}

/// Raw bytes a source produced, ready for [CharacterCodec.parseBytes].
class SourcePayload {
  const SourcePayload(this.bytes, {this.filename});
  final Uint8List bytes;
  final String? filename;
}

/// A pluggable place to import a character from. Built-ins cover a local file,
/// pasted JSON, a direct URL and JannyAI links; [characterSources] is
/// a plain list, so more plugins can simply be added to it.
abstract class CharacterSource {
  const CharacterSource();

  String get id;
  String get label;
  String get description;
  IconData get icon;
  SourceInputKind get inputKind;

  /// Placeholder for the text/url field, when [inputKind] is not [SourceInputKind.none].
  String get inputHint => '';

  /// Fetches raw card bytes for [input] (the pasted text / URL; empty for
  /// [SourceInputKind.none]). Returns one payload per file — the file source
  /// can return several (bulk import); the others return zero or one. An empty
  /// list means the user cancelled. Throws [CharacterParseException] on
  /// user-facing failures.
  Future<List<SourcePayload>> fetch(String input);
}

/// The ordered list of import sources shown in the picker. Add a plugin here to
/// surface it in the UI.
const List<CharacterSource> characterSources = <CharacterSource>[
  FileSource(),
  PasteSource(),
  UrlSource(),
  JannyAiSource(),
];

/// Browser-ish headers, since some hosts/CDNs reject plain clients. This does
/// not defeat Cloudflare-style bot walls (a JannyAI card page), only helps
/// with picky direct asset links.
const Map<String, String> _browserHeaders = {
  'User-Agent':
      'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) '
          'Chrome/124.0 Mobile Safari/537.36',
  'Accept':
      'text/html,application/xhtml+xml,application/json,image/avif,image/webp,*/*;q=0.8',
  'Accept-Language': 'en-US,en;q=0.9',
};

/// Import from local `.json`/`.png` character cards on the device — one or
/// several at once (bulk import).
class FileSource extends CharacterSource {
  const FileSource();
  @override
  String get id => 'file';
  @override
  String get label => 'From file';
  @override
  String get description => 'Pick .json / .png / .charx cards';
  @override
  IconData get icon => Icons.folder_open_outlined;
  @override
  SourceInputKind get inputKind => SourceInputKind.none;

  @override
  Future<List<SourcePayload>> fetch(String input) async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      // Cards travel as JSON, PNG, a CharX zip, or a CharX embedded in an
      // image (JPEG/WEBP) — accept them all.
      allowedExtensions: const [
        'json',
        'png',
        'charx',
        'card',
        'jpg',
        'jpeg',
        'webp',
      ],
      withData: true,
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) return const []; // cancelled
    final payloads = <SourcePayload>[];
    for (final file in result.files) {
      final bytes = file.bytes;
      if (bytes != null && bytes.isNotEmpty) {
        payloads.add(SourcePayload(bytes, filename: file.name));
      }
    }
    if (payloads.isEmpty) {
      throw CharacterParseException('Could not read the selected file(s).');
    }
    return payloads;
  }
}

/// Import from JSON pasted straight into a text box — works everywhere, no
/// permissions, and handy for copying a card out of another app.
class PasteSource extends CharacterSource {
  const PasteSource();
  @override
  String get id => 'paste';
  @override
  String get label => 'Paste JSON';
  @override
  String get description => 'Paste a SillyTavern or Agnai card as text';
  @override
  IconData get icon => Icons.content_paste_outlined;
  @override
  SourceInputKind get inputKind => SourceInputKind.text;
  @override
  String get inputHint => 'Paste character JSON here';

  @override
  Future<List<SourcePayload>> fetch(String input) async {
    final text = input.trim();
    if (text.isEmpty) {
      throw CharacterParseException('Paste a character card first.');
    }
    return [SourcePayload(Uint8List.fromList(utf8.encode(text)))];
  }
}

/// Import from a URL. A direct card link (a raw `.json` or `.png` card) works
/// as-is, and a few known hosts are special-cased to their real download APIs —
/// the same way SillyTavern imports (it resolves an API/CDN link rather than
/// scraping the HTML page).
class UrlSource extends CharacterSource {
  const UrlSource();
  @override
  String get id => 'url';
  @override
  String get label => 'From URL';
  @override
  String get description => 'A direct link, or a JannyAI/RisuAI page';
  @override
  IconData get icon => Icons.link_outlined;
  @override
  SourceInputKind get inputKind => SourceInputKind.url;
  @override
  String get inputHint => 'https://example.com/character.png';

  @override
  Future<List<SourcePayload>> fetch(String input) async =>
      [await fetchUrl(input)];

  /// Resolves [input] to card bytes, routing known hosts to their download API.
  static Future<SourcePayload> fetchUrl(String input) async {
    final raw = input.trim();
    if (raw.isEmpty) {
      throw CharacterParseException('Enter a link first.');
    }
    final uri = Uri.tryParse(raw.startsWith('http') ? raw : 'https://$raw');
    if (uri == null || !uri.hasAuthority) {
      throw CharacterParseException('That is not a valid link.');
    }
    final host = uri.host.toLowerCase();
    // JannyAI's card API is what resolves both hosts — a janitorai.com link is
    // still accepted here, it just is not something the app advertises.
    if (host.contains('jannyai.com') || host.contains('janitorai')) {
      return _fetchJanny(uri);
    }
    if (host.contains('realm.risuai.net')) {
      return _fetchRisu(uri);
    }
    return _getDirect(uri);
  }

  /// A plain GET for direct asset links; rejects HTML pages.
  static Future<SourcePayload> _getDirect(Uri uri) async {
    final response = await _get(uri);
    final contentType = (response.headers['content-type'] ?? '').toLowerCase();
    if (contentType.contains('text/html')) {
      throw CharacterParseException(
        'That link returned a web page, not a card. Use the direct '
        'download link to the .png or .json card.',
      );
    }
    final name = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : null;
    return SourcePayload(response.bodyBytes, filename: name);
  }

  /// GET with browser-ish headers + a same-origin referer and clear failures.
  static Future<http.Response> _get(Uri uri) async {
    http.Response response;
    try {
      response = await http.get(uri, headers: {
        ..._browserHeaders,
        'Referer': '${uri.scheme}://${uri.host}/',
      }).timeout(const Duration(seconds: 30));
    } catch (_) {
      throw CharacterParseException('Could not reach that link.');
    }
    if (response.statusCode != 200) {
      if (response.statusCode == 401 ||
          response.statusCode == 403 ||
          response.statusCode == 503) {
        throw CharacterParseException(
          'The link returned HTTP ${response.statusCode} — it is blocking '
          'non-browser downloads. Download the card file (.png/.json) in your '
          'browser and import it with "From file", or paste its JSON.',
        );
      }
      throw CharacterParseException(
        'The link returned HTTP ${response.statusCode}.',
      );
    }
    return response;
  }

  /// The character-id candidates in a JannyAI URL: the full
  /// `<uuid>_<slug>` segment after `/characters/`, and the bare UUID. JannyAI's
  /// API has been seen to accept either, so both are tried in turn.
  static List<String> jannyCharacterIds(Uri uri) {
    final segs = uri.pathSegments;
    final ci = segs.indexOf('characters');
    final full = (ci >= 0 && ci + 1 < segs.length)
        ? segs[ci + 1]
        : (segs.isNotEmpty ? segs.last : '');
    final uuid = RegExp(
      r'[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}',
    ).firstMatch(uri.toString())?.group(0);
    return <String>{
      if (full.isNotEmpty) full,
      ?uuid,
    }.toList();
  }

  /// SillyTavern-style JannyAI import: ask `api.jannyai.com` for a
  /// download URL for the character, then fetch that card. Falls back to clear
  /// guidance when the API declines or the CDN link is Cloudflare-blocked.
  static Future<SourcePayload> _fetchJanny(Uri uri) =>
      fetchJannyCard(jannyCharacterIds(uri));

  /// Resolves the first of [candidates] that JannyAI's download API recognises.
  /// Discover calls this with the single UUID a feed result carries; the URL
  /// source calls it with both spellings found in a link. [apiBase] exists so
  /// the tests can point it at a loopback server.
  static Future<SourcePayload> fetchJannyCard(
    List<String> candidates, {
    String apiBase = 'https://api.jannyai.com',
  }) async {
    if (candidates.isEmpty) throw CharacterParseException(JannyAiSource.guidance);

    for (final id in candidates) {
      http.Response api;
      try {
        api = await http
            .post(
              Uri.parse('$apiBase/api/v1/download'),
              headers: {'Content-Type': 'application/json', ..._browserHeaders},
              body: jsonEncode({'characterId': id}),
            )
            .timeout(const Duration(seconds: 30));
      } catch (_) {
        continue; // try the next candidate / fall through to guidance
      }
      if (api.statusCode != 200) continue;
      Object? data;
      try {
        data = jsonDecode(api.body);
      } catch (_) {
        continue;
      }
      if (data is Map &&
          data['status'] == 'ok' &&
          data['downloadUrl'] is String) {
        final dl = Uri.tryParse(data['downloadUrl'] as String);
        if (dl == null) continue;
        http.Response img;
        try {
          img = await http
              .get(dl, headers: _browserHeaders)
              .timeout(const Duration(seconds: 30));
        } catch (_) {
          throw CharacterParseException(
            'JannyAI returned a download link but it could not be reached.',
          );
        }
        if (img.statusCode == 200) {
          return SourcePayload(img.bodyBytes, filename: '$id.png');
        }
        throw CharacterParseException(
          'JannyAI returned a download link but it was blocked (HTTP '
          '${img.statusCode}) by Cloudflare. Download the card in your browser '
          'and import it with "From file".',
        );
      }
    }
    throw CharacterParseException(JannyAiSource.guidance);
  }

  /// RisuAI realm: `/character/<uuid>` → the documented card download.
  ///
  /// One format is not enough, which is why this used to fail on perfectly good
  /// links. A card built with assets — RisuAI's own CharX — refuses `png-v3`
  /// with 403 "This card is not allowed to be downloaded in this format", and
  /// three of six cards sampled off Realm's own front page were that kind. So
  /// the documented formats are tried cheapest first, and when every one is
  /// refused it is Realm's own wording that gets shown, since "the link returned
  /// HTTP 403" explains nothing.
  static const List<String> risuFormats = <String>[
    'json-v3',
    'png-v3',
    'charx-v3',
  ];

  static Future<SourcePayload> _fetchRisu(Uri uri) async {
    final last = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : '';
    final uuid = RegExp(r'[a-f0-9-]{16,}').firstMatch(last)?.group(0);
    if (uuid == null) {
      throw CharacterParseException(
        'Could not find a RisuAI character id in that link.',
      );
    }
    return fetchRisuCard(uuid);
  }

  /// Walks [risuFormats] for [uuid]. [apiBase] exists so tests can point this at
  /// a loopback server.
  static Future<SourcePayload> fetchRisuCard(
    String uuid, {
    String apiBase = 'https://realm.risuai.net',
  }) async {
    String? refusal;
    var reached = false;
    for (final format in risuFormats) {
      final target = Uri.parse(
        '$apiBase/api/v1/download/$format/$uuid?non_commercial=true',
      );
      http.Response response;
      try {
        response = await http.get(target, headers: {
          ..._browserHeaders,
          'Referer': '$apiBase/character/$uuid',
        }).timeout(const Duration(seconds: 60));
      } catch (_) {
        continue;
      }
      reached = true;
      // Realm reports a refused format in the body, sometimes under a 200, so
      // the body is what decides.
      final complaint = _risuRefusal(response.bodyBytes);
      if (complaint != null) {
        refusal ??= complaint;
        continue;
      }
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) continue;
      final extension = format.startsWith('charx')
          ? 'charx'
          : (format.startsWith('png') ? 'png' : 'json');
      return SourcePayload(response.bodyBytes, filename: '$uuid.$extension');
    }
    if (!reached) {
      throw CharacterParseException('Could not reach realm.risuai.net.');
    }
    throw CharacterParseException(
      refusal ??
          'RisuAI would not hand over that card in any format the app can '
              'read.',
    );
  }

  /// Realm's complaint about a download, or null when the bytes are a card.
  ///
  /// Only a JSON body can be an error — and a `json-v3` card is JSON too, so it
  /// takes reading the keys, not the shape.
  static String? _risuRefusal(Uint8List bytes) {
    if (bytes.isEmpty || bytes.first != 0x7b) return null; // not '{'
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final message = decoded['message'] ?? decoded['error'];
    if (message is! String || message.trim().isEmpty) return null;
    return 'RisuAI declined that download: ${message.trim()}';
  }
}

/// Import from JannyAI. Like SillyTavern, this resolves the
/// character through `api.jannyai.com` (not by scraping the Cloudflare-guarded
/// page), so a normal character-page link works. If the API declines or the
/// card CDN is bot-blocked, it explains how to import the downloaded file.
///
/// Discover's JannyAI source is the better route now — it reads the definition
/// off the character page and can open a browser view to pass a bot check. This
/// stays for pasting a link to a specific character.
class JannyAiSource extends CharacterSource {
  const JannyAiSource();
  @override
  String get id => 'jannyai';
  @override
  String get label => 'JannyAI';
  @override
  String get description => 'Paste a JannyAI character link';
  @override
  IconData get icon => Icons.extension_outlined;
  @override
  SourceInputKind get inputKind => SourceInputKind.url;
  @override
  String get inputHint => 'https://jannyai.com/characters/…';

  static const String guidance =
      'Could not fetch that character from JannyAI — its card API declined, or '
      'Cloudflare is guarding the download. Try browsing for it in Discover, '
      'which can open the page in a browser view to get past the check. '
      'Otherwise save the card as a PNG or JSON in your browser and import it '
      'with "From file" or "Paste JSON".';

  @override
  Future<List<SourcePayload>> fetch(String input) async =>
      [await UrlSource.fetchUrl(input)];
}

