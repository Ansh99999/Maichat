import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import '../../models/gallery_image.dart';
import '../../state/app_state.dart';
import 'studio_web.dart' show isPrivateAddress, plainText;

/// Where [StudioImages.search] looks. Both are free and need no key, and both
/// say who made each picture and under what licence.
enum ImageSource {
  /// Openverse: openly licensed pictures gathered from Flickr, Wikimedia,
  /// museums and more.
  openverse('Openverse'),

  /// Wikimedia Commons: the media library behind Wikipedia.
  commons('Wikimedia Commons');

  const ImageSource(this.label);
  final String label;

  static ImageSource byName(String? name) {
    final n = (name ?? '').trim().toLowerCase();
    for (final s in ImageSource.values) {
      if (s.name == n) return s;
    }
    if (n == 'wikimedia' || n == 'wikipedia') return ImageSource.commons;
    return ImageSource.openverse;
  }
}

/// One picture a search turned up.
class ImageCandidate {
  const ImageCandidate({
    required this.thumbnail,
    required this.url,
    this.page = '',
    this.title = '',
    this.creator = '',
    this.license = '',
    this.licenseUrl = '',
    this.width,
    this.height,
    required this.source,
  });

  /// A small version, for a grid or a chip.
  final String thumbnail;

  /// The picture itself.
  final String url;

  /// The page it is shown on — where the credit points.
  final String page;
  final String title;
  final String creator;

  /// "CC BY-SA 2.0", "Public domain" …
  final String license;
  final String licenseUrl;
  final int? width;
  final int? height;
  final ImageSource source;

  /// "by archer10 · CC BY-SA 2.0" — the line shown under a result.
  String get credit => [
        if (creator.isNotEmpty) 'by $creator',
        if (license.isNotEmpty) license,
      ].join(' · ');

  Map<String, dynamic> toJson() => {
        'title': title,
        'url': url,
        'thumbnail': thumbnail,
        if (page.isNotEmpty) 'page': page,
        if (creator.isNotEmpty) 'creator': creator,
        if (license.isNotEmpty) 'license': license,
        if (width != null && height != null) 'size': '${width}x$height',
        'source': source.label,
      };
}

/// A picture fetched from the web, not yet stored: its bytes, what it is, and
/// who to credit.
class WebPicture {
  const WebPicture({
    required this.bytes,
    required this.mime,
    required this.url,
    this.page = '',
    this.title = '',
    this.credit = '',
  });

  final Uint8List bytes;
  final String mime;

  /// Where the picture itself came from.
  final String url;

  /// The page it was found on, when a page was given rather than the picture.
  final String page;
  final String title;

  /// Who made it or where it is from — "Pinterest", "by Jane Doe" — for the
  /// gallery record.
  final String credit;

  /// The address to credit: the page when there was one.
  String get source => page.isNotEmpty ? page : url;
}

/// What a page says its picture is, before the picture is fetched.
class PagePicture {
  const PagePicture({
    required this.urls,
    this.title = '',
    this.credit = '',
  });

  /// The picture's addresses, best first — a larger variant ahead of the one
  /// the page names, when the host has one (Pinterest's `/originals/`).
  final List<String> urls;
  final String title;
  final String credit;
}

/// A picture could not be found, fetched or used, in words for a person (or
/// for the model to act on).
class ImageError implements Exception {
  ImageError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The most a picture may weigh. A portrait is well under this; anything
/// bigger is not a portrait.
const int kMaxPictureBytes = 15 * 1024 * 1024;

/// The most of a page read while looking for its picture: the tags that name
/// it sit in the page's head.
const int kMaxPageBytes = 2 * 1024 * 1024;

/// The Studio's way of finding pictures on the web and bringing them home.
///
/// Searching uses Openverse and Wikimedia Commons, which are free, need no
/// key and say who made each picture. Any other site — Pinterest, DeviantArt,
/// ArtStation, a blog — is reached through a link: [fetchPicture] takes either
/// a picture's own address or the page it is on, and finds the picture the
/// page presents (the way a chat app finds a link's preview).
///
/// Everything is downloaded, never hot-linked: the picture becomes a file in
/// the app's pictures folder like every other one. Every address — and every
/// redirect on the way — must be public http(s): nothing on the device or its
/// network can be reached through a link.
class StudioImages {
  StudioImages({
    http.Client Function()? client,
    String Function(String host)? baseFor,
    Future<List<InternetAddress>> Function(String host)? lookup,
    this.allowPrivate = false,
    this.timeout = const Duration(seconds: 25),
    this.maxBytes = kMaxPictureBytes,
  })  : _client = client ?? http.Client.new,
        _baseFor = baseFor ?? ((host) => 'https://$host'),
        _lookup = lookup ?? InternetAddress.lookup;

  /// The one the app uses. Tests put a stand-in here.
  static StudioImages shared = StudioImages();

  final http.Client Function() _client;
  final String Function(String host) _baseFor;
  final Future<List<InternetAddress>> Function(String host) _lookup;

  /// Lets links reach loopback and private addresses. Tests only.
  final bool allowPrivate;
  final Duration timeout;
  final int maxBytes;

  /// A phone browser's, so sites serve the page a person would see (several
  /// answer a bare client with a stripped page, or nothing).
  static const String userAgent =
      'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/128.0 Mobile Safari/537.36';

  // --- search ------------------------------------------------------------------

  /// Pictures for [query] from [source], at most [limit], safe for work.
  Future<List<ImageCandidate>> search(
    String query, {
    ImageSource source = ImageSource.openverse,
    int limit = 8,
  }) async {
    final q = query.trim();
    if (q.isEmpty) throw ImageError('The search is empty.');
    final count = limit.clamp(1, 20);
    return switch (source) {
      ImageSource.openverse => _openverse(q, count),
      ImageSource.commons => _commons(q, count),
    };
  }

  Future<List<ImageCandidate>> _openverse(String q, int count) async {
    final json = await _getJson(Uri.parse(
      '${_baseFor('api.openverse.org')}/v1/images/',
    ).replace(queryParameters: {
      'q': q,
      'page_size': '$count',
      'mature': 'false',
    }));
    final results = json['results'];
    if (results is! List) return const <ImageCandidate>[];
    final out = <ImageCandidate>[];
    for (final r in results) {
      if (r is! Map) continue;
      final url = (r['url'] as String? ?? '').trim();
      if (url.isEmpty) continue;
      final license = (r['license'] as String? ?? '').trim();
      final version = (r['license_version'] as String? ?? '').trim();
      out.add(ImageCandidate(
        thumbnail: (r['thumbnail'] as String? ?? url).trim(),
        url: url,
        page: (r['foreign_landing_url'] as String? ?? '').trim(),
        title: (r['title'] as String? ?? '').trim(),
        creator: (r['creator'] as String? ?? '').trim(),
        license: _licenseName(license, version),
        licenseUrl: (r['license_url'] as String? ?? '').trim(),
        width: (r['width'] as num?)?.toInt(),
        height: (r['height'] as num?)?.toInt(),
        source: ImageSource.openverse,
      ));
    }
    return out;
  }

  /// "by-sa" + "2.0" → "CC BY-SA 2.0"; "cc0" → "CC0"; "pdm" → "Public domain".
  static String _licenseName(String license, String version) {
    final l = license.toLowerCase();
    if (l.isEmpty) return '';
    if (l == 'pdm') return 'Public domain';
    if (l == 'cc0') return 'CC0';
    return 'CC ${l.toUpperCase()}${version.isEmpty ? '' : ' $version'}';
  }

  Future<List<ImageCandidate>> _commons(String q, int count) async {
    final json = await _getJson(Uri.parse(
      '${_baseFor('commons.wikimedia.org')}/w/api.php',
    ).replace(queryParameters: {
      'action': 'query',
      'format': 'json',
      'formatversion': '2',
      'generator': 'search',
      // The File: namespace — pictures, not articles about them.
      'gsrnamespace': '6',
      'gsrsearch': 'filetype:bitmap $q',
      'gsrlimit': '$count',
      'prop': 'imageinfo',
      'iiprop': 'url|size|mime|extmetadata',
      'iiurlwidth': '320',
      'iiextmetadatafilter': 'Artist|LicenseShortName|LicenseUrl|ObjectName',
    }));
    final query = json['query'];
    final pages = query is Map ? query['pages'] : null;
    if (pages is! List) return const <ImageCandidate>[];
    final ordered = [
      for (final p in pages)
        if (p is Map) p,
    ]..sort((a, b) =>
        ((a['index'] as num?) ?? 0).compareTo((b['index'] as num?) ?? 0));
    final out = <ImageCandidate>[];
    for (final p in ordered) {
      final infos = p['imageinfo'];
      if (infos is! List || infos.isEmpty || infos.first is! Map) continue;
      final info = infos.first as Map;
      final mime = (info['mime'] as String? ?? '').toLowerCase();
      if (mime.isNotEmpty && !_pictureMimes.contains(mime)) continue;
      final url = (info['url'] as String? ?? '').trim();
      if (url.isEmpty) continue;
      final meta = info['extmetadata'];
      String metaValue(String key) {
        if (meta is! Map) return '';
        final entry = meta[key];
        final value = entry is Map ? entry['value'] : null;
        return value is String ? plainText(_withoutHidden(value)) : '';
      }

      final rawTitle = (p['title'] as String? ?? '').trim();
      final title = metaValue('ObjectName').isNotEmpty
          ? metaValue('ObjectName')
          : rawTitle
              .replaceFirst(RegExp(r'^File:'), '')
              .replaceFirst(RegExp(r'\.[A-Za-z0-9]+$'), '');
      out.add(ImageCandidate(
        thumbnail: (info['thumburl'] as String? ?? url).trim(),
        url: url,
        page: (info['descriptionurl'] as String? ?? '').trim(),
        title: title,
        creator: _firstName(metaValue('Artist')),
        license: metaValue('LicenseShortName'),
        licenseUrl: metaValue('LicenseUrl'),
        width: (info['width'] as num?)?.toInt(),
        height: (info['height'] as num?)?.toInt(),
        source: ImageSource.commons,
      ));
    }
    return out;
  }

  /// Commons markup carries hidden copies for machines
  /// (`<span style="display: none;">…</span>`); a person reads it once.
  static String _withoutHidden(String html) => html.replaceAll(
        RegExp(
          r'<(\w+)[^>]*style="[^"]*display:\s*none[^"]*"[^>]*>.*?</\1>',
          caseSensitive: false,
          dotAll: true,
        ),
        '',
      );

  /// A long artist line (a biography, a list of uploaders) cut to a credit.
  static String _firstName(String artist) {
    final a = artist.trim();
    return a.length > 80 ? '${a.substring(0, 80)}…' : a;
  }

  static const Set<String> _pictureMimes = {
    'image/jpeg',
    'image/png',
    'image/webp',
    'image/gif',
  };

  Future<Map<String, dynamic>> _getJson(Uri uri) async {
    final client = _client();
    try {
      final response = await client.get(uri, headers: {
        'User-Agent': 'MaiChat-CharacterStudio/1.0 '
            '(+https://github.com/Ansh99999/Maichat)',
        'Accept': 'application/json',
      }).timeout(timeout);
      if (response.statusCode == 429) {
        throw ImageError('The picture search is busy right now. Try again in '
            'a minute.');
      }
      if (response.statusCode != 200) {
        throw ImageError(
            'The picture search answered HTTP ${response.statusCode}.');
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw ImageError('The picture search sent something unexpected.');
      }
      return decoded;
    } on ImageError {
      rethrow;
    } on TimeoutException {
      throw ImageError('The picture search did not answer in time.');
    } on FormatException {
      throw ImageError('The picture search sent something unexpected.');
    } catch (_) {
      throw ImageError('Could not reach the picture search. The device may be '
          'offline.');
    } finally {
      client.close();
    }
  }

  // --- links ---------------------------------------------------------------------

  /// The picture at [url] — its own address, or any page that shows one.
  ///
  /// A page is read only as far as its picture: `og:image` (and its secure
  /// twin), then `twitter:image`, then `<link rel="image_src">`, then the
  /// largest plausible `<img>`. The page's title and its author or site name
  /// are kept for the credit.
  Future<WebPicture> fetchPicture(String url) async {
    final start = _parse(url);
    final first = await _get(start, accept: 'image/*,text/html;q=0.9,*/*;q=0.5');
    try {
      if (_isImageResponse(first.response)) {
        final bytes = await _readCapped(first.response.stream, maxBytes);
        return _picture(bytes, first.response, first.uri);
      }
      final type = (first.response.headers['content-type'] ?? '').toLowerCase();
      if (!type.contains('html') && type.isNotEmpty) {
        await first.response.stream.drain<void>();
        throw ImageError('That address is a ${type.split(';').first} file, not '
            'a picture or a page with one.');
      }
      final body = utf8.decode(
        await _readCapped(first.response.stream, kMaxPageBytes, cut: true),
        allowMalformed: true,
      );
      final found = pictureOfPage(body, first.uri);
      if (found == null || found.urls.isEmpty) {
        throw ImageError('That page has no picture I can find. Open the '
            'picture itself and use its own link.');
      }
      ImageError? last;
      for (final candidate in found.urls) {
        try {
          final picture = await _download(
            _parse(candidate),
            referer: first.uri.toString(),
          );
          return WebPicture(
            bytes: picture.bytes,
            mime: picture.mime,
            url: picture.url,
            page: first.uri.toString(),
            title: found.title,
            credit: found.credit,
          );
        } on ImageError catch (e) {
          last = e;
        }
      }
      throw last ?? ImageError('The page\'s picture could not be fetched.');
    } finally {
      first.client.close();
    }
  }

  /// Downloads the picture at [uri] itself, sending [referer] — some image
  /// hosts refuse a picture asked for without the page it is shown on (Pixiv's
  /// `i.pximg.net` does; Pinterest's `i.pinimg.com`, Wikimedia and Flickr do
  /// not).
  Future<WebPicture> _download(Uri uri, {String? referer}) async {
    final got = await _get(uri, accept: 'image/*', referer: referer);
    try {
      if (!_isImageResponse(got.response)) {
        await got.response.stream.drain<void>();
        throw ImageError('That address did not give a picture.');
      }
      final bytes = await _readCapped(got.response.stream, maxBytes);
      return _picture(bytes, got.response, got.uri);
    } finally {
      got.client.close();
    }
  }

  WebPicture _picture(List<int> bytes, http.StreamedResponse response, Uri uri) {
    final data = Uint8List.fromList(bytes);
    final mime = sniffPicture(data);
    if (mime == null) {
      throw ImageError('That file says it is a picture but is not one I can '
          'use (PNG, JPEG, WebP or GIF).');
    }
    return WebPicture(bytes: data, mime: mime, url: uri.toString());
  }

  static bool _isImageResponse(http.StreamedResponse response) {
    final type = (response.headers['content-type'] ?? '').toLowerCase();
    // Some image hosts label pictures as a plain download; the bytes decide.
    return type.startsWith('image/') ||
        type.startsWith('application/octet-stream') ||
        type.startsWith('binary/');
  }

  Uri _parse(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null ||
        !(uri.isScheme('http') || uri.isScheme('https')) ||
        uri.host.isEmpty) {
      throw ImageError('That is not a web address. Use a link that starts '
          'with http:// or https://.');
    }
    return uri;
  }

  /// A GET that follows up to five redirects itself, checking every address
  /// on the way. The caller closes the client when it has read the body.
  Future<({http.Client client, http.StreamedResponse response, Uri uri})> _get(
    Uri start, {
    required String accept,
    String? referer,
  }) async {
    var uri = start;
    final client = _client();
    try {
      for (var hop = 0; hop <= 5; hop++) {
        await _guard(uri);
        final request = http.Request('GET', uri)
          ..followRedirects = false
          ..headers.addAll({
            'User-Agent': userAgent,
            'Accept': accept,
            'Referer': ?referer,
          });
        final response = await client.send(request).timeout(timeout);
        final location = response.headers['location'];
        if (response.statusCode >= 300 &&
            response.statusCode < 400 &&
            location != null) {
          await response.stream.drain<void>();
          uri = uri.resolve(location);
          if (!(uri.isScheme('http') || uri.isScheme('https'))) {
            throw ImageError('The link redirected somewhere that is not a web '
                'address.');
          }
          continue;
        }
        if (response.statusCode != 200) {
          await response.stream.drain<void>();
          throw ImageError(switch (response.statusCode) {
            403 || 429 => 'The site would not hand the picture over (HTTP '
                '${response.statusCode}). Some sites block apps; try the '
                'picture\'s own link, or save it to your gallery and pick it '
                'from there.',
            404 || 410 => 'Nothing is at that address any more (HTTP '
                '${response.statusCode}).',
            _ => 'The site answered HTTP ${response.statusCode}.',
          });
        }
        return (client: client, response: response, uri: uri);
      }
      throw ImageError('The link redirected too many times.');
    } catch (e) {
      client.close();
      if (e is ImageError) rethrow;
      if (e is TimeoutException) {
        throw ImageError('The site did not answer in time.');
      }
      throw ImageError('Could not reach that address. The device may be '
          'offline, or the link may be wrong.');
    }
  }

  Future<void> _guard(Uri uri) async {
    if (allowPrivate) return;
    final host = uri.host.toLowerCase();
    if (host == 'localhost' ||
        host.endsWith('.local') ||
        host.endsWith('.localhost') ||
        host.endsWith('.internal')) {
      throw ImageError('Addresses on this device or its network cannot be '
          'used.');
    }
    final literal = InternetAddress.tryParse(host);
    List<InternetAddress> addresses;
    if (literal != null) {
      addresses = [literal];
    } else {
      try {
        addresses = await _lookup(host).timeout(timeout);
      } catch (_) {
        throw ImageError('No such site: "$host". Check the link.');
      }
    }
    if (addresses.isEmpty || addresses.any(isPrivateAddress)) {
      throw ImageError('Addresses on this device or its network cannot be '
          'used.');
    }
  }

  /// Reads at most [cap] bytes. A picture over the cap is refused; a page is
  /// simply cut ([cut]) — its picture is named near the top.
  static Future<List<int>> _readCapped(
    Stream<List<int>> stream,
    int cap, {
    bool cut = false,
  }) async {
    final out = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      if (out.length + chunk.length > cap) {
        if (cut) {
          out.add(chunk.sublist(0, cap - out.length));
          break;
        }
        throw ImageError('That picture is over '
            '${cap ~/ (1024 * 1024)} MB — too big for a portrait.');
      }
      out.add(chunk);
    }
    return out.takeBytes();
  }
}

/// What [bytes] are, read from their first bytes rather than from what the
/// server claimed: `image/png`, `image/jpeg`, `image/gif`, `image/webp` — or
/// null for anything else.
String? sniffPicture(Uint8List bytes) {
  bool starts(List<int> magic, [int at = 0]) {
    if (bytes.length < at + magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (bytes[at + i] != magic[i]) return false;
    }
    return true;
  }

  if (starts(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
    return 'image/png';
  }
  if (starts(const [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  if (starts(const [0x47, 0x49, 0x46, 0x38])) return 'image/gif';
  if (starts(const [0x52, 0x49, 0x46, 0x46]) &&
      starts(const [0x57, 0x45, 0x42, 0x50], 8)) {
    return 'image/webp';
  }
  return null;
}

/// The picture [html] presents, resolved against [base], or null when it
/// names none.
PagePicture? pictureOfPage(String html, Uri base) {
  final doc = html_parser.parse(html);

  String meta(List<String> names) {
    for (final name in names) {
      for (final el in doc.querySelectorAll('meta')) {
        final key = (el.attributes['property'] ?? el.attributes['name'] ?? '')
            .toLowerCase();
        if (key == name) {
          final content = (el.attributes['content'] ?? '').trim();
          if (content.isNotEmpty) return content;
        }
      }
    }
    return '';
  }

  String? resolve(String raw) {
    final v = raw.trim();
    if (v.isEmpty || v.startsWith('data:')) return null;
    final uri = Uri.tryParse(v.startsWith('//') ? '${base.scheme}:$v' : v);
    if (uri == null) return null;
    final full = base.resolveUri(uri);
    if (!(full.isScheme('http') || full.isScheme('https'))) return null;
    if (full.path.toLowerCase().endsWith('.svg')) return null;
    return full.toString();
  }

  final named = <String>[
    for (final raw in [
      meta(['og:image:secure_url']),
      meta(['og:image', 'og:image:url']),
      meta(['twitter:image', 'twitter:image:src']),
      doc.querySelector('link[rel="image_src"]')?.attributes['href'] ?? '',
    ])
      ?resolve(raw),
  ];
  if (named.isEmpty) {
    final img = _largestImage(doc.querySelectorAll('img'));
    if (img != null) {
      final src = resolve(img);
      if (src != null) named.add(src);
    }
  }
  if (named.isEmpty) return null;

  final urls = <String>[];
  for (final url in named) {
    for (final variant in [?pinterestOriginal(url), url]) {
      if (!urls.contains(variant)) urls.add(variant);
    }
  }

  final title = [
    meta(['og:title', 'twitter:title']),
    doc.querySelector('title')?.text.trim() ?? '',
  ].firstWhere((t) => t.isNotEmpty, orElse: () => '');
  final author = meta([
    'author',
    'article:author',
    'twitter:creator',
    'pinterestapp:pinner',
  ]);
  final site = meta(['og:site_name', 'application-name']);
  final credit = [
    if (author.isNotEmpty && !author.startsWith('http')) 'by $author',
    if (site.isNotEmpty) site else base.host.replaceFirst(RegExp(r'^www\.'), ''),
  ].join(' · ');
  return PagePicture(
    urls: urls,
    title: _clip(plainText(title), 120),
    credit: _clip(credit, 120),
  );
}

/// The `src` of the largest `<img>` that plausibly is the page's picture —
/// the biggest declared area (or the widest `srcset` entry), skipping icons,
/// tracking pixels and data: URLs.
String? _largestImage(List<dom.Element> images) {
  String? best;
  var bestArea = -1;
  for (final img in images) {
    final w = int.tryParse(img.attributes['width'] ?? '') ?? 0;
    final h = int.tryParse(img.attributes['height'] ?? '') ?? 0;
    if ((w > 0 && w < 64) || (h > 0 && h < 64)) continue;
    var src = (img.attributes['src'] ?? img.attributes['data-src'] ?? '').trim();
    var area = w * h;
    final srcset = img.attributes['srcset'] ?? '';
    for (final part in srcset.split(',')) {
      final bits = part.trim().split(RegExp(r'\s+'));
      if (bits.length < 2 || !bits[1].endsWith('w')) continue;
      final width = int.tryParse(bits[1].substring(0, bits[1].length - 1)) ?? 0;
      if (width * width > area) {
        area = width * width;
        src = bits[0];
      }
    }
    if (src.isEmpty || src.startsWith('data:')) continue;
    if (area > bestArea) {
      bestArea = area;
      best = src;
    }
  }
  return best;
}

/// Pinterest's full-size version of one of its sized pictures:
/// `i.pinimg.com/736x/…` → `i.pinimg.com/originals/…`. Null for anything else.
String? pinterestOriginal(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.host.endsWith('pinimg.com')) return null;
  final segments = uri.pathSegments;
  if (segments.length < 2 || segments.first == 'originals') return null;
  if (!RegExp(r'^\d+x(\d+)?$').hasMatch(segments.first)) return null;
  return uri.replace(pathSegments: ['originals', ...segments.skip(1)]).toString();
}

String _clip(String text, int max) =>
    text.length <= max ? text : '${text.substring(0, max - 1)}…';

/// Files [picture] in the app's gallery under [characterId] — a file in the
/// pictures folder, with where it came from and who made it on the record —
/// and returns the record. Null when the pictures folder is not available.
Future<GalleryImage?> filePictureFromWeb(
  AppState state,
  WebPicture picture, {
  String? characterId,
  String title = '',
  String credit = '',
}) async {
  final name = title.trim().isNotEmpty
      ? title.trim()
      : picture.title.trim().isNotEmpty
          ? picture.title.trim()
          : 'Picture from ${Uri.tryParse(picture.source)?.host ?? 'the web'}';
  final added = await state.addGalleryImages(
    [picture.bytes],
    characterId: characterId,
    title: _clip(name, 80),
    tags: const <String>['from the web'],
  );
  if (added.isEmpty) return null;
  final record = added.first.copyWith(
    source: picture.source,
    credit: credit.trim().isNotEmpty ? credit.trim() : picture.credit,
  );
  await state.saveGalleryImage(record);
  return record;
}
