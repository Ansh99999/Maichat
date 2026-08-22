import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:syncfusion_flutter_pdf/pdf.dart';

import '../models/embedding.dart';

/// Plain text pulled from some source, ready to be chunked and embedded, plus a
/// suggested [name] and provenance for the [EmbeddingDocument] record.
class DocumentText {
  const DocumentText({
    required this.name,
    required this.text,
    required this.source,
    this.origin = '',
  });

  final String name;
  final String text;
  final DocSource source;
  final String origin;

  bool get isEmpty => text.trim().isEmpty;
}

/// Raised when a document source cannot produce usable text.
class DocumentSourceException implements Exception {
  DocumentSourceException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Lets the user pick a `.txt` / `.md` / `.pdf` file and returns its text. Null
/// when the picker is dismissed. Throws [DocumentSourceException] on a file that
/// yields no text (e.g. a scanned PDF).
Future<DocumentText?> pickDocumentFile() async {
  final result = await FilePicker.pickFiles(
    withData: true,
    type: FileType.custom,
    allowedExtensions: const ['txt', 'md', 'markdown', 'text', 'log', 'pdf'],
  );
  final files = result?.files ?? const <PlatformFile>[];
  if (files.isEmpty) return null;
  final file = files.first;
  final bytes = file.bytes;
  if (bytes == null || bytes.isEmpty) {
    throw DocumentSourceException('That file was empty.');
  }
  final isPdf = (file.extension ?? '').toLowerCase() == 'pdf' || _looksLikePdf(bytes);
  final text = isPdf ? extractPdfText(bytes) : _decodeText(bytes);
  if (text.trim().isEmpty) {
    throw DocumentSourceException(isPdf
        ? 'No text found — a scanned/image PDF needs OCR, which is not supported.'
        : 'That file had no readable text.');
  }
  return DocumentText(
    name: _stripExtension(file.name),
    text: text,
    source: DocSource.file,
    origin: file.name,
  );
}

/// Fetches a web page and extracts its text. Wikipedia is pulled cleanly through
/// its API; any other site is fetched and stripped of HTML.
Future<DocumentText> fetchDocumentUrl(String input) async {
  final trimmed = input.trim();
  if (trimmed.isEmpty) throw DocumentSourceException('Enter a link.');
  var uri = Uri.tryParse(trimmed);
  if (uri == null || !uri.hasScheme) {
    uri = Uri.tryParse('https://$trimmed');
  }
  if (uri == null || (!uri.isScheme('http') && !uri.isScheme('https'))) {
    throw DocumentSourceException('That is not a valid web link.');
  }

  if (isWikipedia(uri)) {
    return _fetchWikipedia(uri);
  }

  final http.Response response;
  try {
    response = await http.get(uri, headers: const {
      'User-Agent': 'MaiChat/1.0 (embeddings document import)',
    }).timeout(const Duration(seconds: 30));
  } catch (e) {
    throw DocumentSourceException('Could not reach that link.');
  }
  if (response.statusCode != 200) {
    throw DocumentSourceException(
        'The site returned ${response.statusCode} for that link.');
  }
  final text = stripHtml(response.body);
  if (text.trim().isEmpty) {
    throw DocumentSourceException('No readable text found at that link.');
  }
  return DocumentText(
    name: _titleFromUri(uri),
    text: text,
    source: DocSource.url,
    origin: uri.toString(),
  );
}

/// Wraps a pasted blob as a document.
DocumentText pastedDocument(String name, String text) => DocumentText(
      name: name.trim().isEmpty ? 'Pasted text' : name.trim(),
      text: text,
      source: DocSource.paste,
      origin: '',
    );

/// Extracts text from PDF [bytes] using Syncfusion's pure-Dart extractor. Empty
/// for an image-only (scanned) PDF.
String extractPdfText(Uint8List bytes) {
  PdfDocument? document;
  try {
    document = PdfDocument(inputBytes: bytes);
    return PdfTextExtractor(document).extractText();
  } catch (_) {
    return '';
  } finally {
    document?.dispose();
  }
}

/// Whether [uri] points at a Wikipedia article (`*.wikipedia.org/wiki/<title>`).
bool isWikipedia(Uri uri) =>
    uri.host.endsWith('wikipedia.org') &&
    uri.pathSegments.length >= 2 &&
    uri.pathSegments.first == 'wiki';

/// Builds the plain-text extract API URL for a Wikipedia article link. Uses the
/// action API's `extracts` (explaintext) — the reliable way to get the whole
/// article as clean text, no HTML.
Uri buildWikipediaApiUrl(Uri articleUri) {
  final lang = articleUri.host.split('.').first;
  final title = Uri.decodeComponent(articleUri.pathSegments[1]);
  return Uri.https('$lang.wikipedia.org', '/w/api.php', {
    'action': 'query',
    'prop': 'extracts',
    'explaintext': '1',
    'redirects': '1',
    'format': 'json',
    'titles': title,
  });
}

Future<DocumentText> _fetchWikipedia(Uri articleUri) async {
  final api = buildWikipediaApiUrl(articleUri);
  final http.Response response;
  try {
    response = await http.get(api, headers: const {
      'User-Agent': 'MaiChat/1.0 (embeddings document import)',
    }).timeout(const Duration(seconds: 30));
  } catch (e) {
    throw DocumentSourceException('Could not reach Wikipedia.');
  }
  if (response.statusCode != 200) {
    throw DocumentSourceException(
        'Wikipedia returned ${response.statusCode}.');
  }
  final extract = parseWikipediaExtract(response.body);
  if (extract.text.trim().isEmpty) {
    throw DocumentSourceException('That Wikipedia article had no text.');
  }
  return DocumentText(
    name: extract.title.isEmpty ? _titleFromUri(articleUri) : extract.title,
    text: extract.text,
    source: DocSource.url,
    origin: articleUri.toString(),
  );
}

/// The (title, extract) from a Wikipedia `query&prop=extracts` JSON response.
({String title, String text}) parseWikipediaExtract(String body) {
  try {
    final json = jsonDecode(body);
    final query = json is Map ? json['query'] : null;
    final pages = query is Map ? query['pages'] : null;
    if (pages is Map) {
      for (final page in pages.values) {
        if (page is Map) {
          final extract = page['extract']?.toString() ?? '';
          if (extract.trim().isNotEmpty) {
            return (title: page['title']?.toString() ?? '', text: extract);
          }
        }
      }
    }
  } catch (_) {
    // Fall through to empty.
  }
  return (title: '', text: '');
}

/// Strips HTML to readable text: drops script/style, turns tags into spaces,
/// decodes the handful of common entities, and collapses whitespace. Good enough
/// for feeding an embedder — it is not a full HTML renderer.
String stripHtml(String html) {
  var text = html
      .replaceAll(RegExp(r'<script[^>]*>[\s\S]*?</script>', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'<style[^>]*>[\s\S]*?</style>', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'<head[^>]*>[\s\S]*?</head>', caseSensitive: false), ' ');
  // Keep paragraph/line structure by mapping block-enders to newlines first.
  text = text.replaceAll(
      RegExp(r'</(p|div|br|li|h[1-6]|tr)\s*>', caseSensitive: false), '\n');
  text = text.replaceAll(RegExp(r'<[^>]+>'), ' ');
  text = _decodeEntities(text);
  // Collapse runs of spaces/tabs, then trim blank lines.
  text = text.replaceAll(RegExp(r'[ \t]+'), ' ');
  text = text.replaceAll(RegExp(r'\n\s*\n\s*\n+'), '\n\n');
  return text.trim();
}

String _decodeEntities(String s) => s
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&apos;', "'");

/// Decodes text bytes as UTF-8, falling back to Latin-1 if the bytes are not
/// valid UTF-8 (so a Windows-encoded .txt still imports rather than throwing).
String _decodeText(Uint8List bytes) {
  try {
    return utf8.decode(bytes);
  } catch (_) {
    return latin1.decode(bytes);
  }
}

bool _looksLikePdf(Uint8List bytes) =>
    bytes.length >= 5 &&
    bytes[0] == 0x25 && // %
    bytes[1] == 0x50 && // P
    bytes[2] == 0x44 && // D
    bytes[3] == 0x46 && // F
    bytes[4] == 0x2D; // -

String _stripExtension(String name) {
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

String _titleFromUri(Uri uri) {
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.isEmpty) return uri.host;
  return Uri.decodeComponent(segments.last).replaceAll('_', ' ');
}
