import 'dart:convert';

import '../models/scenario.dart';

/// Reads and writes scenarios in the shapes that actually turn up, so an opening
/// can move between apps (and in from a character card) without being retyped:
///
///  * **MaiChat native** — this app's own object, or an array of them, which is
///    what a multi-select export writes.
///  * **Agnai scenario** — `{"kind": "scenario", "name", "text",
///    "overwriteCharacterScenario", "instructions", "entries", "states"}`. The
///    prompt is `text`; the triggered `entries`/`states` are kept verbatim (see
///    [Scenario.extensions]) because MaiChat has no trigger engine to run them.
///  * **A character card** — any card with a `scenario` field, flat or under
///    `data`, so an opening you liked on a card can be lifted into the library.
///  * **Plain text** — anything that is not JSON at all is taken as the prompt
///    itself, which is what pasting a scenario out of a chat log amounts to.
class ScenarioCodec {
  const ScenarioCodec._();

  /// The Agnai keys we understand; everything else on an imported scenario is
  /// preserved under [Scenario.extensions] rather than dropped.
  static const Set<String> _known = <String>{
    'kind',
    '_id',
    'userId',
    'name',
    'text',
    'overwriteCharacterScenario',
    'tags',
    'starred',
    'format',
    'id',
    'createdAt',
    'updatedAt',
  };

  /// Parses one or more scenarios out of [text].
  ///
  /// [fileName] names a scenario the format did not name — an Agnai export and a
  /// pasted block of prose both arrive nameless often enough that falling back
  /// to "Untitled scenario" for every one of them would be useless.
  ///
  /// Throws a [FormatException] with a sentence fit to show the user when there
  /// is nothing in [text] that could be a scenario.
  static List<Scenario> parse(String text, {String? fileName}) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('That file is empty.');
    }

    Object? json;
    try {
      json = jsonDecode(trimmed);
    } catch (_) {
      // Not JSON: the whole thing is the prompt. This is a feature, not a
      // fallback — a scenario is prose, and prose is how it is usually shared.
      return <Scenario>[_fromPlainText(trimmed, fileName: fileName)];
    }

    final scenarios = <Scenario>[];
    if (json is List) {
      for (final item in json) {
        if (item is Map<String, dynamic>) {
          final one = _one(item, fileName: fileName);
          if (one != null) scenarios.add(one);
        }
      }
    } else if (json is Map<String, dynamic>) {
      // A bundle written by this app wraps the list; anything else is one.
      final bundle = json['scenarios'];
      if (bundle is List) {
        for (final item in bundle) {
          if (item is Map<String, dynamic>) {
            final one = _one(item, fileName: fileName);
            if (one != null) scenarios.add(one);
          }
        }
      } else {
        final one = _one(json, fileName: fileName);
        if (one != null) scenarios.add(one);
      }
    } else if (json is String && json.trim().isNotEmpty) {
      // A JSON string literal — still just prose.
      return <Scenario>[_fromPlainText(json.trim(), fileName: fileName)];
    }

    if (scenarios.isEmpty) {
      throw const FormatException(
          'That file has no scenario in it — expected a "text" field, or a '
          'character card with a scenario.');
    }
    return scenarios;
  }
  /// Works out which shape [json] is and reads it, or returns null when it holds
  /// no scenario at all (an unrelated JSON file, a card with no scenario).
  static Scenario? _one(Map<String, dynamic> json, {String? fileName}) {
    // A character card: the scenario sits beside the rest of the definition,
    // either flat (V1) or under `data` (V2/V3).
    final card = json['data'] is Map<String, dynamic>
        ? json['data'] as Map<String, dynamic>
        : json;
    final looksLikeCard = card.containsKey('first_mes') ||
        card.containsKey('personality') ||
        card.containsKey('description') ||
        json.containsKey('spec');
    if (looksLikeCard && json['kind'] != 'scenario') {
      final text = _str(card['scenario']);
      if (text.isEmpty) return null;
      final owner = _str(card['name']);
      return Scenario(
        id: _freshId(),
        name: owner.isEmpty ? _fallbackName(fileName) : "$owner's scenario",
        text: text,
        tags: _tags(card['tags']),
        format: ScenarioFormat.characterCard,
      );
    }

    final text = _str(json['text']);
    if (text.isEmpty) return null;
    final agnai = json['kind'] == 'scenario' ||
        json.containsKey('overwriteCharacterScenario') ||
        json.containsKey('states');
    return Scenario(
      id: _freshId(),
      name: _str(json['name']).isEmpty
          ? _fallbackName(fileName)
          : _str(json['name']),
      text: text,
      tags: _tags(json['tags']),
      starred: json['starred'] == true,
      // Agnai defaults this to false; our own export always writes it.
      overwriteCharacterScenario:
          json['overwriteCharacterScenario'] as bool? ?? true,
      format: agnai ? ScenarioFormat.agnai : ScenarioFormat.manual,
      extensions: _leftovers(json),
    );
  }

  /// A pasted block of prose, taken as the prompt itself. Its first line becomes
  /// the title when it reads like one (short, and there is more after it), which
  /// is how a scenario shared as text is nearly always written.
  static Scenario _fromPlainText(String text, {String? fileName}) {
    final lines = text.split(RegExp(r'\r?\n'));
    final first = lines.first.trim();
    final rest = lines.skip(1).join('\n').trim();
    final titled = first.length <= 60 && rest.isNotEmpty;
    return Scenario(
      id: _freshId(),
      name: titled ? first : _fallbackName(fileName),
      text: titled ? rest : text,
      format: ScenarioFormat.plainText,
    );
  }

  static String _fallbackName(String? fileName) =>
      fileName?.trim().isNotEmpty == true
          ? fileName!.trim()
          : 'Imported scenario';

  /// Everything the source carried that has no field here — Agnai's
  /// `instructions`, `entries` and `states` among them.
  static Map<String, dynamic> _leftovers(Map<String, dynamic> json) {
    final extra = <String, dynamic>{};
    for (final entry in json.entries) {
      if (!_known.contains(entry.key)) extra[entry.key] = entry.value;
    }
    return extra;
  }

  /// How many triggered events [scenario] brought along that this app will not
  /// fire, so the import can say so instead of quietly ignoring them.
  static int eventCount(Scenario scenario) {
    final entries = scenario.extensions['entries'];
    return entries is List ? entries.length : 0;
  }
  // --- writing --------------------------------------------------------------

  /// This app's own shape: everything, including the tags and the replace/add
  /// choice. Agnai reads it too — it is a superset of an Agnai scenario.
  static String exportNative(Scenario scenario) =>
      _encode(_nativeJson(scenario));

  static Map<String, dynamic> _nativeJson(Scenario scenario) => {
        'kind': 'scenario',
        'name': scenario.name,
        'text': scenario.text,
        'overwriteCharacterScenario': scenario.overwriteCharacterScenario,
        if (scenario.tags.isNotEmpty) 'tags': scenario.tags,
        if (scenario.starred) 'starred': true,
        // Whatever came in from elsewhere goes back out, so a round trip through
        // this app is not lossy — Agnai's own events included.
        ...scenario.extensions,
      };

  /// Just what Agnai's importer reads, with the events it was given handed back.
  static String exportAgnai(Scenario scenario) => _encode({
        'kind': 'scenario',
        'name': scenario.name,
        'description': '',
        'text': scenario.text,
        'overwriteCharacterScenario': scenario.overwriteCharacterScenario,
        'instructions': _str(scenario.extensions['instructions']),
        'entries': scenario.extensions['entries'] ?? const <dynamic>[],
        'states': scenario.extensions['states'] ?? const <dynamic>[],
      });

  /// One file for a whole selection. Written as an array, which [parse] reads
  /// back as a bundle.
  static String exportManyNative(List<Scenario> scenarios) =>
      _encode(scenarios.map(_nativeJson).toList());

  static String _encode(Object json) =>
      const JsonEncoder.withIndent('  ').convert(json);

  // --- helpers --------------------------------------------------------------

  static int _seq = 0;

  /// A fresh id. Importing means "add a copy", so a bundle never silently
  /// overwrites what is already in the library, and two scenarios parsed in the
  /// same microsecond still get different ids.
  static String _freshId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${_seq++}';

  static String _str(Object? value) => value?.toString().trim() ?? '';

  static List<String> _tags(Object? value) {
    if (value is String) {
      return value
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
    }
    if (value is! List) return <String>[];
    return value
        .map((e) => e?.toString().trim() ?? '')
        .where((s) => s.isNotEmpty)
        .toList();
  }
}

/// The formats a scenario can be written out as, offered when exporting.
enum ScenarioExportFormat {
  native('MaiChat', 'Everything, including tags. Agnai reads this too.'),
  agnai('Agnai', 'A scenario with the fields Agnai supports.');

  const ScenarioExportFormat(this.label, this.blurb);
  final String label;
  final String blurb;

  String write(Scenario scenario) => switch (this) {
        ScenarioExportFormat.native => ScenarioCodec.exportNative(scenario),
        ScenarioExportFormat.agnai => ScenarioCodec.exportAgnai(scenario),
      };
}
