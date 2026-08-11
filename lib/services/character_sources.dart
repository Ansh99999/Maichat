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
/// pasted JSON, a direct URL and JannyAI/JanitorAI links; [characterSources] is
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
  /// [SourceInputKind.none]). Returns null when the user cancelled (e.g. closed
  /// the file picker) so the caller can quietly do nothing. Throws
  /// [CharacterParseException] on user-facing failures.
  Future<SourcePayload?> fetch(String input);
}

/// The ordered list of import sources shown in the picker. Add a plugin here to
/// surface it in the UI.
const List<CharacterSource> characterSources = <CharacterSource>[
  FileSource(),
  PasteSource(),
  UrlSource(),
  JannyAiSource(),
];

/// A browser-ish User-Agent, since some hosts (JanitorAI/JannyAI CDNs) reject
/// requests without one.
const Map<String, String> _browserHeaders = {
  'User-Agent':
      'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) '
          'Chrome/124.0 Mobile Safari/537.36',
  'Accept': '*/*',
};

/// Import from a local `.json` or `.png` character card on the device.
class FileSource extends CharacterSource {
  const FileSource();
  @override
  String get id => 'file';
  @override
  String get label => 'From file';
  @override
  String get description => 'Pick a .json or .png card from this device';
  @override
  IconData get icon => Icons.folder_open_outlined;
  @override
  SourceInputKind get inputKind => SourceInputKind.none;

  @override
  Future<SourcePayload?> fetch(String input) async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json', 'png', 'charx', 'card'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null; // cancelled
    final file = result.files.first;
    final bytes = file.bytes;
    if (bytes == null || bytes.isEmpty) {
      throw CharacterParseException('Could not read that file.');
    }
    return SourcePayload(bytes, filename: file.name);
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
  Future<SourcePayload?> fetch(String input) async {
    final text = input.trim();
    if (text.isEmpty) {
      throw CharacterParseException('Paste a character card first.');
    }
    return SourcePayload(Uint8List.fromList(utf8.encode(text)));
  }
}

/// Import from any direct URL that serves a card (a raw `.json`, a `.png` card,
/// a gist, etc.).
class UrlSource extends CharacterSource {
  const UrlSource();
  @override
  String get id => 'url';
  @override
  String get label => 'From URL';
  @override
  String get description => 'Fetch a card from a direct link';
  @override
  IconData get icon => Icons.link_outlined;
  @override
  SourceInputKind get inputKind => SourceInputKind.url;
  @override
  String get inputHint => 'https://example.com/character.png';

  @override
  Future<SourcePayload?> fetch(String input) => fetchUrl(input);

  /// Shared GET used by URL-based sources.
  static Future<SourcePayload> fetchUrl(String input) async {
    final raw = input.trim();
    if (raw.isEmpty) {
      throw CharacterParseException('Enter a link first.');
    }
    final uri = Uri.tryParse(raw.startsWith('http') ? raw : 'https://$raw');
    if (uri == null || !uri.hasAuthority) {
      throw CharacterParseException('That is not a valid link.');
    }
    http.Response response;
    try {
      response = await http
          .get(uri, headers: _browserHeaders)
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      throw CharacterParseException('Could not reach that link.');
    }
    if (response.statusCode != 200) {
      throw CharacterParseException(
        'The link returned HTTP ${response.statusCode}.',
      );
    }
    final contentType =
        (response.headers['content-type'] ?? '').toLowerCase();
    if (contentType.contains('text/html')) {
      throw CharacterParseException(
        'That link returned a web page, not a card. Use the direct '
        'download link to the .png or .json card.',
      );
    }
    final name = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : null;
    return SourcePayload(response.bodyBytes, filename: name);
  }
}

/// Import from JannyAI / JanitorAI. JanitorAI has no public card API, so this
/// takes the *direct download link* a JannyAI download produces (a `.png` or
/// `.json` card) and fetches it — falling back to a clear hint when handed a
/// plain site page instead.
class JannyAiSource extends CharacterSource {
  const JannyAiSource();
  @override
  String get id => 'jannyai';
  @override
  String get label => 'JannyAI / JanitorAI';
  @override
  String get description => 'Paste a JannyAI card download link';
  @override
  IconData get icon => Icons.extension_outlined;
  @override
  SourceInputKind get inputKind => SourceInputKind.url;
  @override
  String get inputHint => 'https://jannyai.com/.../card.png';

  @override
  Future<SourcePayload?> fetch(String input) async {
    try {
      return await UrlSource.fetchUrl(input);
    } on CharacterParseException catch (e) {
      // Sharpen the "got a web page" case for the JanitorAI character-page URL
      // people most often paste by mistake.
      if (e.message.contains('web page')) {
        throw CharacterParseException(
          'That looks like a JanitorAI page, not a card. Open it in JannyAI '
          '(jannyai.com), download the character, and paste that direct '
          '.png/.json link here.',
        );
      }
      rethrow;
    }
  }
}

