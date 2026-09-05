import 'package:flutter/material.dart';

import '../../models/character.dart';
import '../../models/character_scenario.dart';
import '../../models/character_theme.dart';
import '../../services/character_writer.dart';

/// One scenario being edited: its own controllers, plus which greetings it is
/// attached to. Held apart from [CharacterScenario] because a [TextEditingController]
/// belongs to a screen, not to a model.
class ScenarioDraft {
  ScenarioDraft({
    required this.id,
    String name = '',
    String text = '',
    this.scenarioId,
    Set<int>? greetings,
  })  : name = TextEditingController(text: name),
        text = TextEditingController(text: text),
        greetings = greetings ?? <int>{};

  factory ScenarioDraft.from(CharacterScenario source) => ScenarioDraft(
        id: source.id,
        name: source.name,
        text: source.text,
        scenarioId: source.scenarioId,
        greetings: source.greetings.toSet(),
      );

  factory ScenarioDraft.blank() => ScenarioDraft(
        id: 'draft-${DateTime.now().microsecondsSinceEpoch}',
      );

  final String id;
  final TextEditingController name;
  final TextEditingController text;

  /// The library scenario this came from, kept for provenance.
  String? scenarioId;

  /// Greeting indexes; empty means every greeting.
  final Set<int> greetings;

  CharacterScenario build() => CharacterScenario(
        id: id,
        name: name.text.trim(),
        text: text.text.trim(),
        scenarioId: scenarioId,
        greetings: greetings.toList()..sort(),
      );

  void dispose() {
    name.dispose();
    text.dispose();
  }
}

/// The card being written, while it is being written.
///
/// Every tab reads and writes this one object, and it is a [ChangeNotifier] so a
/// change made on one tab (a greeting added, a lorebook attached, the theme
/// picked) is visible on the others and in the header without any of them knowing
/// about each other. The controllers live here rather than in the tabs for the
/// same reason a [PageView]'s children must not own their own state: a tab that
/// has been swiped away is disposed, and a disposed tab must not take the text
/// that was typed into it with it.
///
/// Nothing here touches the stored roster. [build] materialises a [Character] and
/// the screen decides where it goes — which is what lets the creator serve both
/// "edit this card" and "collect a draft for one chat".
class CreatorDraft extends ChangeNotifier {
  CreatorDraft({Character? source})
      : original = source,
        name = TextEditingController(text: source?.name ?? ''),
        title = TextEditingController(text: source?.title ?? ''),
        description = TextEditingController(text: source?.description ?? ''),
        personality = TextEditingController(text: source?.personality ?? ''),
        example = TextEditingController(text: source?.mesExample ?? ''),
        systemPrompt = TextEditingController(text: source?.systemPrompt ?? ''),
        postHistory = TextEditingController(
            text: source?.postHistoryInstructions ?? ''),
        notes = TextEditingController(text: source?.creatorNotes ?? ''),
        creator = TextEditingController(text: source?.creator ?? ''),
        version = TextEditingController(text: source?.characterVersion ?? ''),
        titleShown = source?.titleShown ?? false,
        theme = source?.theme ?? CharacterTheme.none,
        tags = (source?.tags ?? const <String>[]).toSet(),
        lorebookIds = (source?.lorebookIds ?? const <String>[]).toList() {
    pictures = _poolOf([
      source?.avatar ?? '',
      ...?source?.avatars,
    ]);
    greetings = <TextEditingController>[
      TextEditingController(text: source?.firstMes ?? ''),
      for (final alternate in source?.alternateGreetings ?? const <String>[])
        TextEditingController(text: alternate),
    ];
    scenarios = <ScenarioDraft>[
      for (final scenario in source?.scenarios ?? const <CharacterScenario>[])
        ScenarioDraft.from(scenario),
    ];
    // A card that has a scenario but no per-greeting ones starts with that
    // scenario as its first entry, applying to everything — so opening an old
    // card in the new editor shows what it actually says instead of an empty tab,
    // and saving does not quietly drop it.
    if (scenarios.isEmpty && (source?.activeScenario.trim().isNotEmpty ?? false)) {
      scenarios.add(ScenarioDraft(
        id: 'draft-card',
        text: source!.activeScenario.trim(),
      ));
    }
  }

  /// The card this draft started from, or null for a new one.
  final Character? original;

  final TextEditingController name;
  final TextEditingController title;
  final TextEditingController description;
  final TextEditingController personality;
  final TextEditingController example;
  final TextEditingController systemPrompt;
  final TextEditingController postHistory;
  final TextEditingController notes;
  final TextEditingController creator;
  final TextEditingController version;

  /// The first message, then the alternates — index 0 is `first_mes`.
  late List<TextEditingController> greetings;

  late List<ScenarioDraft> scenarios;

  bool titleShown;

  /// Every picture this card can wear, in the order they are swiped through:
  /// `local:<file>` refs, `http(s)` URLs, or freshly picked base64 on its way to
  /// a file (see `AvatarStore`). Never a data: URI.
  ///
  /// Index 0 is *not* special. Which one the card wears is [defaultPicture], so
  /// swiping the header does not reorder the run under the finger — the order a
  /// picture was added in is the order it stays in until the card is saved.
  late List<String> pictures;

  /// Which of [pictures] the card wears. Clamped by every mutator, so it is
  /// always a valid index or 0 for an empty run.
  int defaultPicture = 0;

  /// The picture the card wears — `Character.avatar` as this draft would build it.
  String get avatar =>
      defaultPicture >= 0 && defaultPicture < pictures.length
          ? pictures[defaultPicture]
          : '';

  /// Trims, drops empties and de-duplicates, keeping the first spelling — the
  /// same rule `AppState.avatarPoolFor` applies, so a card's run of pictures
  /// means the same thing in the creator as everywhere else.
  static List<String> _poolOf(Iterable<String> refs) {
    final out = <String>[];
    for (final ref in refs) {
      final trimmed = ref.trim();
      if (trimmed.isEmpty || out.contains(trimmed)) continue;
      out.add(trimmed);
    }
    return out;
  }

  CharacterTheme theme;

  final Set<String> tags;

  final List<String> lorebookIds;

  /// The writing conversations, one per field, kept for as long as the creator is
  /// open — which is what makes "jump back into that conversation" true: the ask
  /// and the answers are still there when the sheet is opened again.
  ///
  /// Keyed by a *slot* rather than by the field, because some fields exist more
  /// than once: greeting 3 and greeting 1 are both [WritableField.greeting] and
  /// must not share one conversation. See `writerSlot`.
  final Map<String, List<WriterTurn>> conversations =
      <String, List<WriterTurn>>{};

  /// The value a slot held before the assistant last rewrote it, so one tap can
  /// put it back.
  final Map<String, String> undo = <String, String>{};

  bool get isNew => original == null;

  /// Every greeting with something in it, in card order — the list a
  /// [CharacterScenario]'s greeting indexes point into. Matches
  /// [Character.greetings] for the card this draft will build.
  List<String> get filledGreetings => [
        for (final controller in greetings)
          if (controller.text.trim().isNotEmpty) controller.text.trim(),
      ];

  /// Says a change happened. Called by the tabs after anything that other parts
  /// of the screen have to see; ordinary typing does not go through here, because
  /// a controller notifies its own field.
  void touch() => notifyListeners();

  void setTitleShown(bool value) {
    titleShown = value;
    notifyListeners();
  }

  void setAvatar(String ref) {
    final trimmed = ref.trim();
    pictures = trimmed.isEmpty ? <String>[] : <String>[trimmed];
    defaultPicture = 0;
    notifyListeners();
  }

  /// Adds a picture to the run and wears it. A picture already in the run is not
  /// duplicated — picking it again just puts it on.
  void addPicture(String ref) {
    final trimmed = ref.trim();
    if (trimmed.isEmpty) return;
    final at = pictures.indexOf(trimmed);
    if (at != -1) {
      defaultPicture = at;
    } else {
      pictures.add(trimmed);
      defaultPicture = pictures.length - 1;
    }
    notifyListeners();
  }

  /// Takes picture [index] out of the run, keeping whichever one was being worn
  /// on — unless it was that one, in which case the neighbour before it is.
  void removePictureAt(int index) {
    if (index < 0 || index >= pictures.length) return;
    pictures.removeAt(index);
    if (pictures.isEmpty) {
      defaultPicture = 0;
    } else if (defaultPicture > index || defaultPicture >= pictures.length) {
      defaultPicture = (defaultPicture - 1).clamp(0, pictures.length - 1);
    }
    notifyListeners();
  }

  /// Which picture the card wears, by index.
  ///
  /// Deliberately silent: it does **not** notify. This is called as a swipe
  /// settles, the pager that called it is already showing the right picture, and
  /// rebuilding the whole creator — six tabs and every field on them — on each
  /// swipe is precisely the stutter a carousel must not have. Everything that
  /// reads the choice ([snapshot], [build], the discard check) reads it fresh.
  void setDefaultPicture(int index) {
    if (index < 0 || index >= pictures.length) return;
    defaultPicture = index;
  }

  void setTheme(CharacterTheme next) {
    theme = next;
    notifyListeners();
  }

  void addGreeting() {
    greetings.add(TextEditingController());
    notifyListeners();
  }

  /// Removes greeting [index] and renumbers every scenario that named a greeting
  /// after it, so "greeting 4" does not silently become a different greeting.
  void removeGreeting(int index) {
    if (index < 0 || index >= greetings.length) return;
    greetings.removeAt(index).dispose();
    for (final scenario in scenarios) {
      final shifted = <int>{};
      for (final greeting in scenario.greetings) {
        if (greeting == index) continue; // the one that went
        shifted.add(greeting > index ? greeting - 1 : greeting);
      }
      scenario.greetings
        ..clear()
        ..addAll(shifted);
    }
    notifyListeners();
  }

  void addScenario([ScenarioDraft? scenario]) {
    scenarios.add(scenario ?? ScenarioDraft.blank());
    notifyListeners();
  }

  void removeScenario(String id) {
    final index = scenarios.indexWhere((s) => s.id == id);
    if (index == -1) return;
    scenarios.removeAt(index).dispose();
    notifyListeners();
  }

  void attachLorebook(String id) {
    if (lorebookIds.contains(id)) return;
    lorebookIds.add(id);
    notifyListeners();
  }

  void detachLorebook(String id) {
    if (!lorebookIds.remove(id)) return;
    notifyListeners();
  }

  /// The controller behind [field], for the fields that have exactly one. Null
  /// for the fields that do not (a greeting is one of several; tags are a set).
  TextEditingController? controllerFor(WritableField field) => switch (field) {
        WritableField.title => title,
        WritableField.description => description,
        WritableField.personality => personality,
        WritableField.exampleDialogue => example,
        WritableField.systemPrompt => systemPrompt,
        WritableField.postHistory => postHistory,
        WritableField.creatorNotes => notes,
        WritableField.scenario => null,
        WritableField.greeting => null,
        WritableField.tags => null,
      };

  /// A snapshot of the card as it stands, for the assistant's briefing and for
  /// the previews. Cheap: it is the same [build] the Save button uses, against a
  /// throwaway id when the card is new.
  Character snapshot() => _write(
        Character(
          id: original?.id ?? 'draft',
          name: '',
          createdAt: original?.createdAt,
        ),
      );

  /// The card to save. With [into] given it is written onto that object (an
  /// in-place edit of the stored card, which is what `AppState.saveCharacter`
  /// expects); otherwise a fresh one is built.
  Character build({Character? into}) =>
      _write(into ?? original?.clone() ?? Character.empty());

  Character _write(Character card) {
    final filled = <String>[
      for (final controller in greetings)
        if (controller.text.trim().isNotEmpty) controller.text.trim(),
    ];
    // The scenarios worth keeping, with their greeting indexes clamped to the
    // greetings that actually exist — a scenario pinned to a greeting that has
    // since been deleted would otherwise never fire and never be visible.
    final keptScenarios = <CharacterScenario>[
      for (final draft in scenarios)
        if (draft.text.text.trim().isNotEmpty)
          (draft.build()
            ..greetings.removeWhere((i) => i >= filled.length)),
    ];
    card
      ..name = name.text.trim()
      ..title = title.text.trim()
      ..titleShown = titleShown && title.text.trim().isNotEmpty
      ..avatar = avatar
      // The rest of the run, in order, with the worn one taken out — the shape
      // `Character` keeps: one picture it wears, and a pool beside it.
      ..avatars = <String>[
        for (var i = 0; i < pictures.length; i++)
          if (i != defaultPicture) pictures[i],
      ]
      ..description = description.text.trim()
      ..personality = personality.text.trim()
      ..scenarios = keptScenarios
      ..lorebookIds = lorebookIds.toList()
      ..theme = theme
      ..firstMes = filled.isEmpty ? '' : filled.first
      ..alternateGreetings = filled.skip(1).toList()
      ..mesExample = example.text.trim()
      ..systemPrompt = systemPrompt.text.trim()
      ..postHistoryInstructions = postHistory.text.trim()
      ..creatorNotes = notes.text.trim()
      ..creator = creator.text.trim()
      ..characterVersion = version.text.trim()
      ..tags = tags.toList();

    // The single card scenario every other app reads. The first scenario that
    // covers every greeting is the one that belongs there — a card exported to
    // SillyTavern has one scenario slot, and it should hold the general one
    // rather than whichever happened to be written first.
    final general = keptScenarios.firstWhere(
      (s) => s.appliesToAll,
      orElse: () => keptScenarios.isEmpty
          ? CharacterScenario.empty()
          : keptScenarios.first,
    );
    // Which of the two slots it lands in depends on which was in force when the
    // card arrived. A card whose creator's scenario the user had already replaced
    // keeps both halves — the creator is not the place to quietly discard the
    // original, and `activeScenario` reads the same either way.
    if (original?.hasCustomScenario ?? false) {
      card.customScenario = general.text.trim();
    } else {
      card
        ..scenario = general.text.trim()
        ..customScenario = '';
    }
    return card;
  }

  @override
  void dispose() {
    for (final controller in <TextEditingController>[
      name, title, description, personality, example,
      systemPrompt, postHistory, notes, creator, version,
      ...greetings,
    ]) {
      controller.dispose();
    }
    for (final scenario in scenarios) {
      scenario.dispose();
    }
    super.dispose();
  }
}
