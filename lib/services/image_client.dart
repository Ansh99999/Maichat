import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/image_gen.dart';
import 'chat_client.dart';

/// One reference picture handed to a generation request.
class ImageReference {
  const ImageReference({required this.bytes, this.mime = 'image/png'});

  final Uint8List bytes;
  final String mime;
}

/// What came back from a generation: the pictures, and any text the model said
/// alongside them (Gemini's image models routinely narrate, and a refusal
/// arrives as text with no picture at all — worth showing rather than reporting
/// "nothing came back").
class ImageResult {
  const ImageResult({
    this.images = const <Uint8List>[],
    this.text = '',
    this.links = const <String>[],
  });

  final List<Uint8List> images;
  final String text;

  /// Links the host gave instead of bytes, before they are downloaded.
  final List<String> links;

  bool get isEmpty => images.isEmpty;
}

/// Talks to an image endpoint. Two dialects, chosen by [ImageGenKind]:
///
///  * **OpenAI images** — `POST /images/generations` with JSON, or
///    `POST /images/edits` as multipart when there are reference pictures (which
///    is the only way that API accepts one). Both `b64_json` and `url` responses
///    are read, because the hosted models disagree about which they return and a
///    proxy in between may rewrite it either way.
///  * **Gemini** — `POST /models/<model>:generateContent` asking for an image
///    modality, which takes references inline in the same `parts` array as the
///    prompt. An Imagen-style `predictions[]` response is read too, so pointing
///    this at `:predict` also works.
///
/// Failures are [ChatApiException], the same type (and the same wording) the chat
/// client raises, so every error path in the app reads alike.
class ImageClient {
  /// Generates pictures for [prompt] under [config].
  ///
  /// [prompt] is used verbatim — the caller composes it (see
  /// [ImageGenConfig.composePrompt]) so the studio can show exactly what is sent.
  Future<ImageResult> generate({
    required ImageGenConfig config,
    required String prompt,
    List<ImageReference> references = const <ImageReference>[],
  }) async {
    if (prompt.trim().isEmpty) {
      throw ChatApiException('Type what the picture should show.');
    }
    if (config.model.trim().isEmpty) {
      throw ChatApiException('Choose an image model in the studio settings.');
    }
    switch (config.kind) {
      case ImageGenKind.openai:
        return references.isEmpty
            ? _openAiGenerate(config, prompt)
            : _openAiEdit(config, prompt, references);
      case ImageGenKind.gemini:
        return _gemini(config, prompt, references);
    }
  }

  Map<String, String> _headers(ImageGenConfig config, {bool json = true}) {
    final key = config.apiKey.trim();
    return {
      if (json) 'Content-Type': 'application/json',
      if (key.isNotEmpty)
        ...switch (config.kind) {
          ImageGenKind.gemini => {'x-goog-api-key': key},
          ImageGenKind.openai => {'Authorization': 'Bearer $key'},
        },
    };
  }

  /// The endpoint a request goes to — exposed so the studio's settings page can
  /// show the user the exact URL it will call.
  static Uri uriFor(ImageGenConfig config, {bool edit = false}) {
    switch (config.kind) {
      case ImageGenKind.openai:
        return ChatClient.endpoint(
          config.resolvedBaseUrl,
          edit ? '/images/edits' : '/images/generations',
          preferHttp: _isLocal(config.resolvedBaseUrl),
        );
      case ImageGenKind.gemini:
        return ChatClient.endpoint(
          config.resolvedBaseUrl,
          '/models/${Uri.encodeComponent(config.model.trim())}:generateContent',
          preferHttp: _isLocal(config.resolvedBaseUrl),
        );
    }
  }

  /// A scheme-less loopback/LAN address plainly means http; upgrading it only
  /// produces a TLS error against a server that speaks none. Mirrors the same
  /// judgement `ProviderKind.prefersHttp` encodes for chat.
  static bool _isLocal(String base) {
    final lower = base.toLowerCase();
    return lower.startsWith('http://') ||
        lower.startsWith('localhost') ||
        lower.startsWith('127.') ||
        lower.startsWith('192.168.') ||
        lower.startsWith('10.');
  }

  Future<ImageResult> _openAiGenerate(
      ImageGenConfig config, String prompt) async {
    final body = <String, dynamic>{
      'model': config.model.trim(),
      'prompt': prompt,
      if (config.count > 1) 'n': config.count,
      if (config.size != 'auto' && config.size.isNotEmpty) 'size': config.size,
      if (config.quality.isNotEmpty) 'quality': config.quality,
    };
    final http.Response response;
    try {
      response = await http
          .post(
            uriFor(config),
            headers: _headers(config),
            body: jsonEncode(body),
          )
          .timeout(const Duration(minutes: 3));
    } catch (e) {
      throw ChatApiException(ChatClient.describeTransport(e));
    }
    return _withFetchedLinks(_readOpenAi(response));
  }

  /// The reference-picture path. `/images/edits` is multipart only — there is no
  /// JSON form of it — so this is the one request in the app that is not JSON.
  Future<ImageResult> _openAiEdit(
    ImageGenConfig config,
    String prompt,
    List<ImageReference> references,
  ) async {
    final request = http.MultipartRequest('POST', uriFor(config, edit: true))
      ..headers.addAll(_headers(config, json: false))
      ..fields['model'] = config.model.trim()
      ..fields['prompt'] = prompt;
    if (config.count > 1) request.fields['n'] = '${config.count}';
    if (config.size != 'auto' && config.size.isNotEmpty) {
      request.fields['size'] = config.size;
    }
    if (config.quality.isNotEmpty) request.fields['quality'] = config.quality;
    for (var i = 0; i < references.length; i++) {
      final reference = references[i];
      request.files.add(http.MultipartFile.fromBytes(
        // `image[]` is what accepts more than one; a single-image host reads it
        // as `image` all the same.
        'image[]',
        reference.bytes,
        filename: 'reference-$i.${reference.mime.split('/').last}',
      ));
    }
    final http.Response response;
    try {
      final streamed = await request.send().timeout(const Duration(minutes: 3));
      response = await http.Response.fromStream(streamed);
    } catch (e) {
      throw ChatApiException(ChatClient.describeTransport(e));
    }
    return _withFetchedLinks(_readOpenAi(response));
  }

  ImageResult _readOpenAi(http.Response response) {
    if (response.statusCode != 200) {
      throw ChatApiException(
          ChatClient.describeFailure(response.statusCode, response.body));
    }
    final decoded = _decode(response.body);
    final data = decoded['data'];
    if (data is! List || data.isEmpty) {
      throw ChatApiException('The host returned no pictures.');
    }
    final images = <Uint8List>[];
    final urls = <String>[];
    for (final entry in data) {
      if (entry is! Map) continue;
      final b64 = entry['b64_json'];
      if (b64 is String && b64.isNotEmpty) {
        final bytes = _base64(b64);
        if (bytes != null) images.add(bytes);
        continue;
      }
      final url = entry['url'];
      if (url is String && url.isNotEmpty) urls.add(url);
    }
    if (images.isEmpty && urls.isEmpty) {
      throw ChatApiException('The host returned no pictures.');
    }
    return ImageResult(images: images, links: urls);
  }

  /// Turns a link-only reply into bytes. The hosted models disagree about
  /// whether they return base64 or a link, and a link that expires in an hour is
  /// not a picture — the studio files what it generates in the gallery, so the
  /// bytes have to be fetched either way.
  Future<ImageResult> _withFetchedLinks(ImageResult result) async {
    if (result.links.isEmpty) return result;
    final fetched = <Uint8List>[];
    for (final url in result.links) {
      final uri = Uri.tryParse(url);
      if (uri == null) continue;
      try {
        final response =
            await http.get(uri).timeout(const Duration(seconds: 90));
        if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
          fetched.add(response.bodyBytes);
        }
      } catch (_) {
        // A link that will not download is skipped; if none of them do, the
        // throw below says so rather than reporting a silent success.
      }
    }
    final images = <Uint8List>[...result.images, ...fetched];
    if (images.isEmpty) {
      throw ChatApiException(
        'The host answered with links to the pictures, but none of them could '
        'be downloaded.',
      );
    }
    return ImageResult(images: images, text: result.text);
  }

  Future<ImageResult> _gemini(
    ImageGenConfig config,
    String prompt,
    List<ImageReference> references,
  ) async {
    final body = <String, dynamic>{
      'contents': [
        {
          'role': 'user',
          'parts': [
            {'text': prompt},
            for (final reference in references)
              {
                'inlineData': {
                  'mimeType': reference.mime,
                  'data': base64Encode(reference.bytes),
                },
              },
          ],
        },
      ],
      'generationConfig': <String, dynamic>{
        // Both modalities: the image models narrate, and asking for IMAGE alone
        // is rejected by some of them.
        'responseModalities': ['TEXT', 'IMAGE'],
        if (config.count > 1) 'candidateCount': config.count,
      },
      if (config.systemPrompt.trim().isNotEmpty)
        'systemInstruction': {
          'parts': [
            {'text': config.systemPrompt.trim()}
          ],
        },
    };
    final http.Response response;
    try {
      response = await http
          .post(
            uriFor(config),
            headers: _headers(config),
            body: jsonEncode(body),
          )
          .timeout(const Duration(minutes: 3));
    } catch (e) {
      throw ChatApiException(ChatClient.describeTransport(e));
    }
    if (response.statusCode != 200) {
      throw ChatApiException(
          ChatClient.describeFailure(response.statusCode, response.body));
    }
    final decoded = _decode(response.body);
    final images = <Uint8List>[];
    final text = StringBuffer();

    void readParts(Object? content) {
      if (content is! Map) return;
      final parts = content['parts'];
      if (parts is! List) return;
      for (final part in parts) {
        if (part is! Map) continue;
        final inline = part['inlineData'] ?? part['inline_data'];
        if (inline is Map) {
          final data = inline['data'];
          if (data is String) {
            final bytes = _base64(data);
            if (bytes != null) images.add(bytes);
          }
          continue;
        }
        if (part['text'] is String) text.writeln((part['text'] as String).trim());
      }
    }

    final candidates = decoded['candidates'];
    if (candidates is List) {
      for (final candidate in candidates) {
        if (candidate is Map) readParts(candidate['content']);
      }
    }
    // Imagen's `:predict` shape, so pointing the studio at it also works.
    final predictions = decoded['predictions'];
    if (predictions is List) {
      for (final prediction in predictions) {
        if (prediction is! Map) continue;
        final data = prediction['bytesBase64Encoded'];
        if (data is String) {
          final bytes = _base64(data);
          if (bytes != null) images.add(bytes);
        }
      }
    }
    if (images.isEmpty) {
      final said = text.toString().trim();
      throw ChatApiException(said.isEmpty
          ? 'The model returned no picture.'
          : 'The model returned no picture:\n$said');
    }
    return ImageResult(images: images, text: text.toString().trim());
  }

  static Map<String, dynamic> _decode(String body) {
    try {
      final json = jsonDecode(body);
      if (json is Map<String, dynamic>) return json;
    } catch (_) {
      // Fall through to the shared wording.
    }
    throw ChatApiException('The host sent a malformed response.');
  }

  static Uint8List? _base64(String value) {
    try {
      // Some hosts hand back a full data URL rather than bare base64.
      final comma = value.indexOf(',');
      final payload = value.startsWith('data:') && comma > 0
          ? value.substring(comma + 1)
          : value;
      final bytes = base64Decode(payload.trim());
      return bytes.isEmpty ? null : bytes;
    } catch (_) {
      return null;
    }
  }
}
