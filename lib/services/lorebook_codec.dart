import 'dart:convert';

import '../models/lorebook.dart';

/// Reads and writes lorebooks in the formats the two ecosystems this app talks
/// to actually use, so a book can move between them without being retyped:
///
///  * **SillyTavern world info** — `{"entries": {"0": {…}}}`, an object keyed by
///    entry id. This is what "Export world info" produces, and it is also the
///    one shape Agnai's importer recognises from SillyTavern, so it is the most
///    portable thing we can write.
///  * **A character card's `character_book`** — the same entries as a JSON
///    *array* with the V2 spec's snake_case names, everything SillyTavern-only
///    tucked into each entry's `extensions`.
///  * **Agnai memory book** — `{"kind": "memory", "entries": [{"entry": …}]}`,
///    where the injected text is called `entry` and the keys `keywords`.
///  * **MaiChat native** — the SillyTavern shape plus the book's own name,
///    description and the extras only this app has (picture, colour, tags).
///
/// Anything a format carries that has no field here is kept in `extensions` and
/// written back out, so a round trip through MaiChat is not lossy.
class LorebookCodec {
  const LorebookCodec._();

  /// Where this app's own extras live inside an entry's or a book's
  /// `extensions`, namespaced so neither ecosystem trips over them.
  static const String extensionKey = 'maichat';

  /// Parses one or more books out of [text]. A JSON array is read as a bundle
  /// (what multi-select export writes), anything else as a single book.
  ///
  /// [fileName] is used for the book's name when the format does not carry one —
  /// which is the norm for SillyTavern world files, where the file *is* the name.
  static List<Lorebook> parse(String text, {String? fileName}) {
    final json = jsonDecode(text.trim());
    final books = <Lorebook>[];
    if (json is List) {
      for (final item in json) {
        if (item is Map<String, dynamic>) {
          books.add(_book(item, fileName: fileName));
        }
      }
      if (books.isEmpty) {
        throw const FormatException('That file has no lorebooks in it.');
      }
    } else if (json is Map<String, dynamic>) {
      books.add(_book(json, fileName: fileName));
    } else {
      throw const FormatException('That is not a lorebook.');
    }
    // A world file carries no name of its own — the file is the name.
    for (final book in books) {
      if (book.name.trim().isEmpty) {
        book.name = fileName?.trim().isNotEmpty == true
            ? fileName!.trim()
            : 'Imported lorebook';
      }
    }
    return books;
  }

  /// Works out which of the four shapes [json] is and reads it.
  static Lorebook _book(Map<String, dynamic> json, {String? fileName}) {
    // A character card carries its book under `character_book`, either at the
    // top level (V1-style) or inside `data` (V2/V3).
    final card = json['data'] is Map<String, dynamic>
        ? json['data'] as Map<String, dynamic>
        : json;
    final embedded = card['character_book'] ?? card['characterBook'];
    if (embedded is Map<String, dynamic>) {
      final book = _book(embedded, fileName: fileName);
      if (book.name.trim().isEmpty) {
        final owner = (card['name'] as String?)?.trim();
        book.name = owner == null || owner.isEmpty
            ? (fileName ?? 'Imported lorebook')
            : "$owner's lorebook";
      }
      book.format = LorebookFormat.characterCard;
      return book;
    }

    final entries = json['entries'];
    if (entries is Map) return _fromWorldInfo(json, fileName: fileName);
    if (entries is List) {
      if (json['kind'] == 'memory' || _looksAgnai(entries)) {
        return _fromAgnai(json, fileName: fileName);
      }
      if (_looksNative(entries)) return _fromNative(json, fileName: fileName);
      return _fromCharacterBook(json, fileName: fileName);
    }
    throw const FormatException(
        'That file has no lorebook entries — expected an "entries" object or list.');
  }

  /// Agnai calls the injected text `entry`; nothing else does.
  static bool _looksAgnai(List<dynamic> entries) => entries
      .whereType<Map<String, dynamic>>()
      .any((e) => e.containsKey('entry'));

  /// Only this app's own storage shape keys an entry by `uid` in a list.
  static bool _looksNative(List<dynamic> entries) => entries
      .whereType<Map<String, dynamic>>()
      .any((e) => e.containsKey('uid'));

  static int _seq = 0;

  /// A fresh book id. Importing means "add a copy", so a bundle of books never
  /// silently overwrites what is already in the library, and two books parsed in
  /// the same microsecond still get different ids.
  static String _freshId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${_seq++}';

  /// This app's own shape, straight back through the model.
  static Lorebook _fromNative(Map<String, dynamic> json, {String? fileName}) {
    final book = Lorebook.fromJson({...json, 'id': _freshId()});
    if (book.name.trim().isEmpty) {
      book.name = fileName?.trim().isNotEmpty == true
          ? fileName!.trim()
          : 'Imported lorebook';
    }
    return book;
  }

  /// SillyTavern world info: `entries` is an object keyed by entry id. Ordered
  /// by `displayIndex` when the author dragged the rows around, else by id.
  static Lorebook _fromWorldInfo(Map<String, dynamic> json, {String? fileName}) {
    final raw = (json['entries'] as Map).values
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    raw.sort((a, b) {
      final ai = _num(a['displayIndex']) ?? _num(a['uid']) ?? 0;
      final bi = _num(b['displayIndex']) ?? _num(b['uid']) ?? 0;
      return ai.compareTo(bi);
    });

    final entries = <LorebookEntry>[];
    for (var i = 0; i < raw.length; i++) {
      entries.add(_worldEntry(raw[i], i));
    }

    final extras = _extras(json['extensions']);
    final book = Lorebook(
      id: _freshId(),
      name: (json['name'] as String?)?.trim().isNotEmpty == true
          ? (json['name'] as String).trim()
          : (fileName?.trim().isNotEmpty == true
              ? fileName!.trim()
              : 'Imported lorebook'),
      description: json['description'] as String? ?? '',
      thumbnail: extras['thumbnail'] as String? ?? '',
      color: _num(extras['color'])?.toInt(),
      tags: _list(extras['tags']),
      starred: extras['starred'] as bool? ?? false,
      scanDepth: _num(json['scan_depth'] ?? json['scanDepth'])?.toInt(),
      tokenBudget: _num(json['token_budget'] ?? json['tokenBudget'])?.toInt(),
      recursive:
          (json['recursive_scanning'] ?? json['recursiveScanning']) == true,
      format: LorebookFormat.sillyTavern,
      entries: entries,
      extensions: _withoutExtras(json['extensions']),
    );
    return book;
  }

  /// One SillyTavern world-info entry. `comment` is the name, `order` is the
  /// insertion order, and `disable` is the switch read the other way round.
  static LorebookEntry _worldEntry(Map<String, dynamic> e, int index) {
    final order = _num(e['order'])?.toInt() ?? kLoreDefaultWeight;
    final extras = _extras(e['extensions']);
    // World info has one ordering knob, so it stands for both of ours unless the
    // book came from here originally (our export keeps the separate discard
    // priority in `extensions`) or from a card, which does have both.
    final priority = _num(extras['priority'])?.toInt() ??
        _num(e['priority'])?.toInt() ??
        order;
    return LorebookEntry(
      uid: _num(e['uid'])?.toInt() ?? index,
      name: e['comment'] as String? ?? '',
      content: e['content'] as String? ?? '',
      keys: _list(e['key'] ?? e['keys']),
      secondaryKeys: _list(e['keysecondary'] ?? e['secondary_keys']),
      // SillyTavern stores the switch inverted, and an entry with no `disable`
      // key at all is on.
      enabled: e['disable'] == true ? false : (e['enabled'] as bool? ?? true),
      constant: e['constant'] as bool? ?? false,
      selective: e['selective'] as bool? ?? true,
      selectiveLogic: SelectiveLogic.fromWire(e['selectiveLogic']),
      priority: priority,
      weight: order,
      position: LorebookPosition.fromWire(e['position']),
      depth: _num(e['depth'])?.toInt() ?? 4,
      role: LoreRole.fromWire(e['role']),
      probability: _num(e['probability'])?.toInt() ?? 100,
      useProbability: e['useProbability'] as bool? ?? true,
      caseSensitive: e['caseSensitive'] as bool?,
      matchWholeWords: (e['matchWholeWords'] ?? e['matchWholeWorlds']) as bool?,
      scanDepth: _num(e['scanDepth'])?.toInt(),
      excludeRecursion: e['excludeRecursion'] as bool? ?? false,
      preventRecursion: e['preventRecursion'] as bool? ?? false,
      delayUntilRecursion: _num(e['delayUntilRecursion'])?.toInt() ?? 0,
      group: e['group'] as String? ?? '',
      groupOverride: e['groupOverride'] as bool? ?? false,
      groupWeight: _num(e['groupWeight'])?.toInt() ?? kLoreDefaultWeight,
      useGroupScoring: e['useGroupScoring'] as bool?,
      sticky: _num(e['sticky'])?.toInt(),
      cooldown: _num(e['cooldown'])?.toInt(),
      delay: _num(e['delay'])?.toInt(),
      automationId: e['automationId'] as String? ?? '',
      extensions: _withoutExtras(e['extensions']),
    );
  }

  /// An Agnai memory book: entries are a list, the text is called `entry`, and
  /// the keys `keywords`. Agnai has a separate discard `priority` and ordering
  /// `weight`, which is where this app's pair of fields comes from.
  static Lorebook _fromAgnai(Map<String, dynamic> json, {String? fileName}) {
    final raw = (json['entries'] as List)
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final entries = <LorebookEntry>[];
    for (var i = 0; i < raw.length; i++) {
      final e = raw[i];
      entries.add(LorebookEntry(
        uid: _num(e['id'])?.toInt() ?? i,
        name: e['name'] as String? ?? '',
        content: e['entry'] as String? ?? e['content'] as String? ?? '',
        keys: _list(e['keywords']),
        secondaryKeys: _list(e['secondaryKeys']),
        enabled: e['enabled'] as bool? ?? true,
        constant: e['constant'] as bool? ?? false,
        selective: e['selective'] as bool? ?? true,
        selectiveLogic: SelectiveLogic.fromWire(e['selectiveLogic']),
        priority: _num(e['priority'])?.toInt() ?? kLoreDefaultWeight,
        weight: _num(e['weight'])?.toInt() ?? kLoreDefaultWeight,
        position: LorebookPosition.fromWire(e['position']),
        probability: _num(e['probability'])?.toInt() ?? 100,
        useProbability: e['useProbability'] as bool? ?? true,
        excludeRecursion: e['excludeRecursion'] as bool? ?? false,
      ));
    }
    return Lorebook(
      id: _freshId(),
      name: (json['name'] as String?)?.trim().isNotEmpty == true
          ? (json['name'] as String).trim()
          : (fileName?.trim().isNotEmpty == true
              ? fileName!.trim()
              : 'Imported lorebook'),
      description: json['description'] as String? ?? '',
      scanDepth: _num(json['scanDepth'])?.toInt(),
      tokenBudget: _num(json['tokenBudget'])?.toInt(),
      recursive: json['recursiveScanning'] == true,
      format: LorebookFormat.agnai,
      entries: entries,
      extensions: _withoutExtras(json['extensions']),
    );
  }

  /// A character card's `character_book`: the V2 spec's snake_case field names,
  /// with everything SillyTavern-specific inside each entry's `extensions`.
  static Lorebook _fromCharacterBook(Map<String, dynamic> json,
      {String? fileName}) {
    final raw = (json['entries'] as List)
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final entries = <LorebookEntry>[];
    for (var i = 0; i < raw.length; i++) {
      final e = raw[i];
      final x = e['extensions'] is Map
          ? Map<String, dynamic>.from(e['extensions'] as Map)
          : <String, dynamic>{};
      final order = _num(e['insertion_order'])?.toInt() ?? kLoreDefaultWeight;
      entries.add(LorebookEntry(
        uid: _num(e['id'])?.toInt() ?? i,
        name: e['comment'] as String? ?? e['name'] as String? ?? '',
        content: e['content'] as String? ?? '',
        keys: _list(e['keys']),
        secondaryKeys: _list(e['secondary_keys']),
        enabled: e['enabled'] as bool? ?? true,
        constant: e['constant'] as bool? ?? false,
        selective: e['selective'] as bool? ?? true,
        selectiveLogic: SelectiveLogic.fromWire(x['selectiveLogic']),
        priority: _num(e['priority'])?.toInt() ?? order,
        weight: order,
        // The spec's own `position` is a string; SillyTavern's numeric one in
        // `extensions` is more precise, so it wins when both are there.
        position: LorebookPosition.fromWire(x['position'] ?? e['position']),
        depth: _num(x['depth'])?.toInt() ?? 4,
        role: LoreRole.fromWire(x['role']),
        probability: _num(x['probability'])?.toInt() ?? 100,
        useProbability: x['useProbability'] as bool? ?? true,
        caseSensitive: (e['case_sensitive'] ?? x['case_sensitive']) as bool?,
        matchWholeWords: x['match_whole_words'] as bool?,
        scanDepth: _num(x['scan_depth'])?.toInt(),
        excludeRecursion: x['exclude_recursion'] as bool? ?? false,
        preventRecursion: x['prevent_recursion'] as bool? ?? false,
        delayUntilRecursion: _num(x['delay_until_recursion'])?.toInt() ?? 0,
        group: x['group'] as String? ?? '',
        groupOverride: x['group_override'] as bool? ?? false,
        groupWeight: _num(x['group_weight'])?.toInt() ?? kLoreDefaultWeight,
        useGroupScoring: x['use_group_scoring'] as bool?,
        sticky: _num(x['sticky'])?.toInt(),
        cooldown: _num(x['cooldown'])?.toInt(),
        delay: _num(x['delay'])?.toInt(),
        automationId: x['automation_id'] as String? ?? '',
        extensions: x,
      ));
    }
    return Lorebook(
      id: _freshId(),
      name: (json['name'] as String?)?.trim() ?? '',
      description: json['description'] as String? ?? '',
      scanDepth: _num(json['scan_depth'])?.toInt(),
      tokenBudget: _num(json['token_budget'])?.toInt(),
      recursive: json['recursive_scanning'] == true,
      format: LorebookFormat.characterCard,
      entries: entries,
      extensions: _withoutExtras(json['extensions']),
    );
  }

  /// This app's extras, pulled out of an `extensions` bag.
  static Map<String, dynamic> _extras(Object? extensions) {
    if (extensions is! Map) return <String, dynamic>{};
    final mine = extensions[extensionKey];
    return mine is Map ? Map<String, dynamic>.from(mine) : <String, dynamic>{};
  }

  /// An `extensions` bag with this app's own namespace removed, so re-exporting
  /// does not nest our extras inside themselves.
  static Map<String, dynamic> _withoutExtras(Object? extensions) {
    if (extensions is! Map) return <String, dynamic>{};
    final out = Map<String, dynamic>.from(extensions)..remove(extensionKey);
    return out;
  }

  static num? _num(Object? value) {
    if (value == null) return null;
    if (value is bool) return value ? 1 : 0;
    if (value is num) return value;
    return num.tryParse(value.toString().trim());
  }

  static List<String> _list(Object? value) {
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

  /// One entry in SillyTavern's world-info shape. This app's two extra fields
  /// (the separate discard priority, and per-book styling) ride in `extensions`
  /// under [extensionKey], which SillyTavern preserves and ignores.
  static Map<String, dynamic> _toWorldEntry(LorebookEntry e, int displayIndex) {
    final extras = <String, dynamic>{
      if (e.priority != e.weight) 'priority': e.priority,
    };
    return {
      'uid': e.uid,
      'key': e.keys,
      'keysecondary': e.secondaryKeys,
      'comment': e.name,
      'content': e.content,
      'constant': e.constant,
      'vectorized': false,
      'selective': e.selective,
      'selectiveLogic': e.selectiveLogic.wire,
      'addMemo': e.name.trim().isNotEmpty,
      'order': e.weight,
      'position': e.position.wire,
      'disable': !e.enabled,
      'excludeRecursion': e.excludeRecursion,
      'preventRecursion': e.preventRecursion,
      'delayUntilRecursion': e.delayUntilRecursion,
      'probability': e.probability,
      'useProbability': e.useProbability,
      'depth': e.depth,
      'group': e.group,
      'groupOverride': e.groupOverride,
      'groupWeight': e.groupWeight,
      'scanDepth': e.scanDepth,
      'caseSensitive': e.caseSensitive,
      'matchWholeWords': e.matchWholeWords,
      'useGroupScoring': e.useGroupScoring,
      'automationId': e.automationId,
      'role': e.role.wire,
      'sticky': e.sticky,
      'cooldown': e.cooldown,
      'delay': e.delay,
      'displayIndex': displayIndex,
      if (e.extensions.isNotEmpty || extras.isNotEmpty)
        'extensions': {
          ...e.extensions,
          if (extras.isNotEmpty) extensionKey: extras,
        },
    };
  }

  /// The entries object, keyed by entry id the way SillyTavern keys it.
  static Map<String, dynamic> _entriesObject(Lorebook book) => {
        for (var i = 0; i < book.entries.length; i++)
          '${book.entries[i].uid}': _toWorldEntry(book.entries[i], i),
      };

  /// SillyTavern world info, and deliberately nothing else at the top level:
  /// Agnai only recognises a SillyTavern export when `entries` is the sole key,
  /// so this one file imports cleanly into both. The book's name travels as the
  /// file name, which is how SillyTavern names a world too.
  static String exportSillyTavern(Lorebook book) =>
      _encode({'entries': _entriesObject(book)});

  /// The same entries plus everything only this app has (its name, description,
  /// picture, colour and tags). SillyTavern reads this happily — it ignores the
  /// extra keys — so it is the better choice unless Agnai is the destination.
  static String exportNative(Lorebook book) => _encode(_nativeJson(book));

  static Map<String, dynamic> _nativeJson(Lorebook book) {
    final extras = <String, dynamic>{
      if (book.thumbnail.isNotEmpty) 'thumbnail': book.thumbnail,
      if (book.color != null) 'color': book.color,
      if (book.tags.isNotEmpty) 'tags': book.tags,
      if (book.starred) 'starred': true,
    };
    return {
      'name': book.name,
      if (book.description.isNotEmpty) 'description': book.description,
      if (book.scanDepth != null) 'scan_depth': book.scanDepth,
      if (book.tokenBudget != null) 'token_budget': book.tokenBudget,
      if (book.recursive) 'recursive_scanning': true,
      if (book.extensions.isNotEmpty || extras.isNotEmpty)
        'extensions': {
          ...book.extensions,
          if (extras.isNotEmpty) extensionKey: extras,
        },
      'entries': _entriesObject(book),
    };
  }

  /// An Agnai memory book. Agnai validates the six fields it supports on every
  /// entry, so they are always written even at their defaults.
  static String exportAgnai(Lorebook book) => _encode({
        'kind': 'memory',
        'name': book.name,
        'description': book.description,
        if (book.scanDepth != null) 'scanDepth': book.scanDepth,
        if (book.tokenBudget != null) 'tokenBudget': book.tokenBudget,
        if (book.recursive) 'recursiveScanning': true,
        'entries': [
          for (final e in book.entries)
            {
              'name': e.name,
              'entry': e.content,
              'keywords': e.keys,
              'priority': e.priority,
              'weight': e.weight,
              'enabled': e.enabled,
              'id': e.uid,
              if (e.secondaryKeys.isNotEmpty) 'secondaryKeys': e.secondaryKeys,
              if (e.constant) 'constant': true,
              if (e.position == LorebookPosition.beforeChar)
                'position': 'before_char'
              else if (e.position == LorebookPosition.afterChar)
                'position': 'after_char',
              if (e.probability != 100) 'probability': e.probability,
              if (!e.useProbability) 'useProbability': false,
              if (!e.selective) 'selective': false,
              if (e.selectiveLogic != SelectiveLogic.andAny)
                'selectiveLogic': e.selectiveLogic.wire,
              if (e.excludeRecursion) 'excludeRecursion': true,
            },
        ],
      });

  /// Several books in one file, for exporting a multi-selection.
  static String exportManyNative(List<Lorebook> books) =>
      _encode(books.map(_nativeJson).toList());

  static String _encode(Object json) =>
      const JsonEncoder.withIndent('  ').convert(json);
}

/// The formats a book can be written out as, offered when exporting.
enum LoreExportFormat {
  native('MaiChat', 'Everything, including the picture and colour. '
      'SillyTavern reads this too.'),
  sillyTavern('SillyTavern / Agnai', 'World info entries only — the safest '
      'choice for importing elsewhere.'),
  agnai('Agnai', 'A memory book, with the fields Agnai supports.');

  const LoreExportFormat(this.label, this.blurb);
  final String label;
  final String blurb;

  /// The file contents for [book] in this format.
  String write(Lorebook book) => switch (this) {
        LoreExportFormat.native => LorebookCodec.exportNative(book),
        LoreExportFormat.sillyTavern => LorebookCodec.exportSillyTavern(book),
        LoreExportFormat.agnai => LorebookCodec.exportAgnai(book),
      };
}
