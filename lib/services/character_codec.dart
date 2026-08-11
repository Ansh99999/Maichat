import 'dart:convert';
import 'dart:typed_data';

import '../models/character.dart';

/// Raised when bytes/text cannot be understood as a character card. The message
/// is written to be shown straight to the user.
class CharacterParseException implements Exception {
  CharacterParseException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Reads and writes character cards across the formats the app accepts:
/// SillyTavern cards (v1 flat JSON, v2 `chara_card_v2`, v3 `chara_card_v3`,
/// including the JSON embedded in a PNG's text chunks) and Agnai's character
/// export. Export always emits a SillyTavern v2 card, the de-facto interchange
/// shape both ecosystems (and JannyAI downloads) understand.
class CharacterCodec {
  const CharacterCodec._();

  static const List<int> _pngSignature = [137, 80, 78, 71, 13, 10, 26, 10];

  /// A PNG card's own image doubles as the avatar. Skip embedding it past this
  /// size so a huge card doesn't bloat the (SharedPreferences-backed) store.
  static const int _maxEmbeddedAvatarBytes = 4 * 1024 * 1024;

  /// Parses raw bytes, auto-detecting a PNG card versus a JSON card. [filename]
  /// only sharpens error messages.
  static Character parseBytes(Uint8List bytes, {String? filename}) {
    if (bytes.isEmpty) {
      throw CharacterParseException('That file is empty.');
    }
    if (_looksLikePng(bytes)) {
      final embedded = _extractPngCard(bytes);
      if (embedded == null) {
        throw CharacterParseException(
          'That PNG has no embedded character card. Export it from '
          'SillyTavern/JannyAI as a character card, or import the JSON instead.',
        );
      }
      final character = parseJson(embedded);
      // The card image *is* the portrait — keep it as the avatar unless the
      // card already named a URL of its own.
      if (character.avatar.trim().isEmpty &&
          bytes.lengthInBytes <= _maxEmbeddedAvatarBytes) {
        character.avatar = base64Encode(bytes);
      }
      return character;
    }
    // Not a PNG — assume text (JSON).
    final String text;
    try {
      text = utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      throw CharacterParseException('That file is not a character card.');
    }
    return parseJson(text);
  }

  /// Parses raw bytes into one or more cards: a PNG holds a single card, while
  /// JSON may be a single card object or an array of them (a bulk export).
  static List<Character> parseCards(Uint8List bytes, {String? filename}) {
    if (bytes.isEmpty) {
      throw CharacterParseException('That file is empty.');
    }
    if (_looksLikePng(bytes)) {
      return [parseBytes(bytes, filename: filename)];
    }
    final String text;
    try {
      text = utf8.decode(bytes, allowMalformed: true).trim();
    } catch (_) {
      throw CharacterParseException('That file is not a character card.');
    }
    if (text.isEmpty) {
      throw CharacterParseException('There is nothing to import.');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      throw CharacterParseException(
        "That doesn't look like a character card (not valid JSON).",
      );
    }
    if (decoded is List) {
      final cards = <Character>[];
      for (final entry in decoded) {
        if (entry is Map<String, dynamic>) {
          try {
            cards.add(_parseMap(entry));
          } catch (_) {
            // Skip an unreadable entry rather than failing the whole batch.
          }
        }
      }
      if (cards.isEmpty) {
        throw CharacterParseException('That file has no character cards in it.');
      }
      return cards;
    }
    if (decoded is Map<String, dynamic>) return [_parseMap(decoded)];
    throw CharacterParseException(
      'A character card should be a JSON object or array.',
    );
  }

  /// Parses a JSON card string in any accepted shape.
  static Character parseJson(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw CharacterParseException('There is nothing to import.');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } catch (_) {
      throw CharacterParseException(
        "That doesn't look like a character card (not valid JSON).",
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw CharacterParseException(
        'A character card should be a JSON object.',
      );
    }
    return _parseMap(decoded);
  }

  /// Dispatches a decoded card map to the right format parser.
  static Character _parseMap(Map<String, dynamic> map) {
    // SillyTavern v2/v3: the real card lives under `data`, tagged by `spec`.
    final spec = _str(map, 'spec').toLowerCase();
    final data = map['data'];
    if (data is Map<String, dynamic> && (spec.contains('chara_card') ||
        data.containsKey('first_mes') ||
        data.containsKey('name'))) {
      final format =
          spec.contains('v3') ? CharacterFormat.tavernV3 : CharacterFormat.tavernV2;
      return _fromTavern(data, format);
    }

    // Agnai export: a persona object and/or a greeting/sampleChat.
    if (map.containsKey('persona') ||
        map.containsKey('sampleChat') ||
        map.containsKey('greeting')) {
      return _fromAgnai(map);
    }

    // SillyTavern v1: flat fields at the top level.
    if (map.containsKey('first_mes') ||
        map.containsKey('mes_example') ||
        (map.containsKey('name') && map.containsKey('description'))) {
      return _fromTavern(map, CharacterFormat.tavernV1);
    }

    throw CharacterParseException(
      "That JSON isn't a character card the app recognises "
      '(SillyTavern or Agnai).',
    );
  }

  /// Serialises [c] as a pretty-printed SillyTavern v2 card. The core fields are
  /// mirrored at the top level so v1-only readers still work.
  static String exportTavernV2(Character c) =>
      const JsonEncoder.withIndent('  ').convert(_v2Card(c));

  /// Serialises several characters as a JSON array of v2 cards (a bulk export
  /// that [parseCards] reads back).
  static String exportTavernV2Many(List<Character> cs) =>
      const JsonEncoder.withIndent('  ').convert(cs.map(_v2Card).toList());

  static Map<String, dynamic> _v2Card(Character c) {
    final data = <String, dynamic>{
      'name': c.name,
      'description': c.description,
      'personality': c.personality,
      'scenario': c.scenario,
      'first_mes': c.firstMes,
      'mes_example': c.mesExample,
      'creator_notes': c.creatorNotes,
      'system_prompt': c.systemPrompt,
      'post_history_instructions': c.postHistoryInstructions,
      'alternate_greetings': c.alternateGreetings,
      'tags': c.tags,
      'creator': c.creator,
      'character_version': c.characterVersion,
      'extensions': <String, dynamic>{},
    };
    return <String, dynamic>{
      'spec': 'chara_card_v2',
      'spec_version': '2.0',
      'data': data,
      'name': c.name,
      'description': c.description,
      'personality': c.personality,
      'scenario': c.scenario,
      'first_mes': c.firstMes,
      'mes_example': c.mesExample,
    };
  }

  // --- Tavern (v1/v2/v3) ---------------------------------------------------

  static Character _fromTavern(Map<String, dynamic> m, CharacterFormat format) {
    final avatar = _str(m, 'avatar');
    return Character(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: _firstNonEmpty([_str(m, 'name'), _str(m, 'char_name')]),
      avatar: (avatar.startsWith('http') ? avatar : ''),
      description: _firstNonEmpty([_str(m, 'description'), _str(m, 'char_persona')]),
      personality: _str(m, 'personality'),
      scenario: _str(m, 'scenario'),
      firstMes:
          _firstNonEmpty([_str(m, 'first_mes'), _str(m, 'char_greeting')]),
      alternateGreetings: _strList(m['alternate_greetings']),
      mesExample:
          _firstNonEmpty([_str(m, 'mes_example'), _str(m, 'example_dialogue')]),
      systemPrompt: _str(m, 'system_prompt'),
      postHistoryInstructions: _str(m, 'post_history_instructions'),
      creatorNotes: _str(m, 'creator_notes'),
      tags: _strList(m['tags']),
      creator: _firstNonEmpty([_str(m, 'creator'), _str(m, 'created_by')]),
      characterVersion: _str(m, 'character_version'),
      format: format,
    );
  }

  // --- Agnai ---------------------------------------------------------------

  static Character _fromAgnai(Map<String, dynamic> m) {
    return Character(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: _str(m, 'name'),
      avatar: (() {
        final a = _str(m, 'avatar');
        return a.startsWith('http') ? a : '';
      })(),
      description: _flattenAgnaiPersona(m['persona']),
      personality: _str(m, 'personality'),
      scenario: _str(m, 'scenario'),
      firstMes: _str(m, 'greeting'),
      alternateGreetings: _strList(m['alternateGreetings']),
      mesExample: _str(m, 'sampleChat'),
      systemPrompt: _str(m, 'systemPrompt'),
      postHistoryInstructions: _str(m, 'postHistoryInstructions'),
      // Agnai's top-level `description` is the author's blurb, not the persona.
      creatorNotes: _str(m, 'description'),
      tags: _strList(m['tags']),
      creator: _str(m, 'creator'),
      characterVersion: _str(m, 'characterVersion'),
      format: CharacterFormat.agnai,
    );
  }

  /// Flattens Agnai's `persona` (a `{kind, attributes}` object, or a plain
  /// string) into readable prose for the description.
  static String _flattenAgnaiPersona(Object? persona) {
    if (persona is String) return persona.trim();
    if (persona is Map) {
      final attrs = persona['attributes'];
      final kind = persona['kind'];
      if (attrs is Map) {
        if (kind == 'text') {
          final t = attrs['text'];
          if (t is List) return t.map((e) => e.toString()).join('\n').trim();
          return (t?.toString() ?? '').trim();
        }
        // wpp / boostyle / sbf: render each attribute as "key: values".
        final buf = StringBuffer();
        attrs.forEach((key, value) {
          final vals = value is List
              ? value.map((e) => e.toString()).join(', ')
              : value.toString();
          buf.writeln('$key: $vals');
        });
        return buf.toString().trim();
      }
    }
    return '';
  }

  // --- PNG text chunks -----------------------------------------------------

  static bool _looksLikePng(Uint8List bytes) {
    if (bytes.length < 8) return false;
    for (var i = 0; i < 8; i++) {
      if (bytes[i] != _pngSignature[i]) return false;
    }
    return true;
  }

  /// Returns the decoded card JSON embedded in a PNG's `ccv3`/`chara` text
  /// chunk, or null when there is none. SillyTavern base64-encodes the JSON
  /// there; a few tools store it raw.
  static String? _extractPngCard(Uint8List bytes) {
    final chunks = _readPngTextChunks(bytes);
    final raw = chunks['ccv3'] ?? chunks['chara'];
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.startsWith('{')) return trimmed;
    try {
      return utf8.decode(base64.decode(_normaliseBase64(trimmed)));
    } catch (_) {
      return trimmed.startsWith('{') ? trimmed : null;
    }
  }

  /// Walks the PNG chunk stream and collects `tEXt`/uncompressed-`iTXt`
  /// keyword→value pairs. Deliberately tolerant: a malformed tail just ends the
  /// scan instead of throwing.
  static Map<String, String> _readPngTextChunks(Uint8List bytes) {
    final out = <String, String>{};
    final view = ByteData.sublistView(bytes);
    var off = 8;
    while (off + 8 <= bytes.length) {
      final len = view.getUint32(off);
      off += 4;
      final type = latin1.decode(bytes.sublist(off, off + 4));
      off += 4;
      if (off + len > bytes.length) break;
      final chunk = bytes.sublist(off, off + len);
      off += len + 4; // skip data + CRC
      if (type == 'tEXt') {
        final z = chunk.indexOf(0);
        if (z > 0) {
          out[latin1.decode(chunk.sublist(0, z))] =
              latin1.decode(chunk.sublist(z + 1));
        }
      } else if (type == 'iTXt') {
        final parsed = _parseITxt(chunk);
        if (parsed != null) out[parsed.$1] = parsed.$2;
      } else if (type == 'IEND') {
        break;
      }
    }
    return out;
  }

  /// Parses an uncompressed `iTXt` chunk into (keyword, text). Compressed
  /// chunks (rare for cards) are skipped.
  static (String, String)? _parseITxt(Uint8List chunk) {
    final z = chunk.indexOf(0);
    if (z <= 0 || z + 2 >= chunk.length) return null;
    final keyword = latin1.decode(chunk.sublist(0, z));
    final compressionFlag = chunk[z + 1];
    if (compressionFlag != 0) return null; // zlib-compressed: skip
    var p = z + 3; // past compression flag + method
    final langEnd = chunk.indexOf(0, p);
    if (langEnd < 0) return null;
    p = langEnd + 1;
    final transEnd = chunk.indexOf(0, p);
    if (transEnd < 0) return null;
    p = transEnd + 1;
    return (keyword, utf8.decode(chunk.sublist(p), allowMalformed: true));
  }

  // --- helpers -------------------------------------------------------------

  static String _str(Map<String, dynamic> m, String key) {
    final v = m[key];
    if (v == null) return '';
    return v.toString().trim();
  }

  static String _firstNonEmpty(List<String> candidates) {
    for (final c in candidates) {
      if (c.trim().isNotEmpty) return c.trim();
    }
    return '';
  }

  static List<String> _strList(Object? value) {
    if (value is List) {
      return value
          .map((e) => e?.toString().trim() ?? '')
          .where((e) => e.isNotEmpty)
          .toList();
    }
    if (value is String && value.trim().isNotEmpty) {
      return value
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    return <String>[];
  }

  /// Restores base64 padding that some exporters strip, so `base64.decode`
  /// accepts it.
  static String _normaliseBase64(String input) {
    final cleaned = input.replaceAll(RegExp(r'\s'), '');
    final remainder = cleaned.length % 4;
    if (remainder == 0) return cleaned;
    return cleaned + ('=' * (4 - remainder));
  }
}
