import '../models/character.dart';
import '../models/message.dart';

/// A field of a character card the assistant can write.
///
/// Each carries the two things the model needs and the UI needs to say: what the
/// field is *for* (the [brief], which becomes part of the instruction) and what
/// it is called on screen ([label]).
enum WritableField {
  title(
    'Title',
    'a single short line that catches what this character is to the reader — a '
        'hook, not a summary. One sentence at most, no quotation marks.',
  ),
  description(
    'Description',
    "the character's description: who they are, how they look, how they speak, "
        'their history and their circumstances. Prose or an attribute list, '
        'whichever suits the card; this is the longest and most important field.',
  ),
  personality(
    'Personality',
    'a compact summary of temperament and manner — traits, habits, what they '
        'want, how they treat people. A few lines, not an essay: the description '
        'carries the detail.',
  ),
  scenario(
    'Scenario',
    'the situation the conversation opens in: where the two of them are, what is '
        'happening, and why they are together. Present tense, a short paragraph.',
  ),
  greeting(
    'Greeting',
    "the character's opening message, written as they would actually say it — in "
        'their voice, in the tense and style the card uses, addressed to '
        '{{user}}. Narration and dialogue are both fine.',
  ),
  exampleDialogue(
    'Example dialogue',
    "example exchanges that teach the model this character's voice. Use the "
        'SillyTavern convention: a `<START>` line before each example, then '
        '`{{char}}:` and `{{user}}:` turns.',
  ),
  systemPrompt(
    'System prompt',
    'instructions to the model about how to play this character and how to write '
        'the roleplay — not facts about the character, which belong in the '
        'description.',
  ),
  postHistory(
    'Post-history instructions',
    'the reminder placed after the conversation, closest to the reply: the rules '
        'that matter most and are most often forgotten. Short and imperative.',
  ),
  creatorNotes(
    'Creator notes',
    'notes for whoever downloads this card: what it is, how to play it, what to '
        'expect. Written to a human, never sent to the model. Plain prose unless '
        'the user asks for HTML.',
  ),
  tags(
    'Tags',
    'a short list of catalogue tags for this character — genre, setting, '
        'relationship, tone, the kind of word somebody would search for. Lower '
        'case, one or two words each.',
  );

  const WritableField(this.label, this.brief);

  final String label;

  /// What this field is for, in the second person, ready to be dropped into the
  /// instruction after "You are writing".
  final String brief;

  /// Whether the reply should be read as a list rather than as prose.
  bool get isList => this == WritableField.tags;
}

/// One turn of the writing conversation, as the sheet draws it.
class WriterTurn {
  const WriterTurn({required this.fromUser, required this.text});

  const WriterTurn.user(this.text) : fromUser = true;
  const WriterTurn.assistant(this.text) : fromUser = false;

  final bool fromUser;
  final String text;
}

/// What came back from one exchange: the text to put in the field (null when the
/// model only talked), and what it said to the user about it.
class WriterResult {
  const WriterResult({this.fieldText, this.note = ''});

  /// The new value for the field, or null when the reply carried none.
  final String? fieldText;

  /// The remark shown in the conversation — "here's a colder version, I kept the
  /// sister line" — which is the part the user reads.
  final String note;

  bool get wroteField => fieldText != null && fieldText!.trim().isNotEmpty;
}

/// Builds the request behind "let the AI write this for you", and reads the
/// answer back apart.
///
/// The shape is deliberate. The model is asked for the field between two markers
/// and then a sentence *about* it, because both halves are wanted for different
/// places: the marked-off text goes straight into the field (so it can be exact,
/// with its own line breaks and markup intact), and the sentence goes into the
/// conversation (so the user is told what changed without having to diff two
/// paragraphs). Everything outside the markers is the note; a reply with no
/// markers at all is treated as the field, because a model that ignored the
/// format has still usually written the thing that was asked for.
class CharacterWriter {
  const CharacterWriter._();

  /// The markers. Angle-bracketed like the rest of the prompt conventions this
  /// app uses, and long enough that a character description is very unlikely to
  /// contain one by accident.
  static const String openTag = '<maichat:field>';
  static const String closeTag = '</maichat:field>';

  /// The whole conversation to send: the standing instruction, then every turn
  /// that has happened in this sheet, then the user's new ask.
  ///
  /// The card so far is part of the *system* turn rather than repeated on every
  /// exchange, so a long back-and-forth does not re-send the character six times
  /// — and the model always sees the current state of the card, because the
  /// system turn is rebuilt from the live draft each time.
  static List<ChatMessage> messagesFor({
    required WritableField field,
    required Character draft,
    required String currentValue,
    required List<WriterTurn> history,
    required String ask,
    String userName = 'User',
  }) {
    return <ChatMessage>[
      ChatMessage(role: 'system', content: _system(field, draft, currentValue,
          userName: userName)),
      for (final turn in history)
        ChatMessage(
          role: turn.fromUser ? 'user' : 'assistant',
          content: turn.text,
        ),
      ChatMessage(role: 'user', content: ask.trim()),
    ];
  }

  static String _system(
    WritableField field,
    Character draft,
    String currentValue, {
    required String userName,
  }) {
    final buffer = StringBuffer()
      ..writeln('You are helping an author write a roleplay character card in '
          'MaiChat. You are not playing the character: you are writing the card.')
      ..writeln()
      ..writeln('You are writing the **${field.label}** field. That field is '
          '${field.brief}');

    final context = _cardContext(draft, field);
    if (context.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('The card so far:')
        ..writeln(context);
    }

    final current = currentValue.trim();
    if (current.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('What the field says at the moment — rewrite, extend or '
            'replace it as the author asks:')
        ..writeln('"""')
        ..writeln(current)
        ..writeln('"""');
    }

    buffer
      ..writeln()
      ..writeln('Answer in exactly this shape, every time:')
      ..writeln()
      ..writeln(openTag)
      ..writeln(field.isList
          ? 'the tags, comma-separated, and nothing else'
          : 'the complete new text for the field, and nothing else')
      ..writeln(closeTag)
      ..writeln('Then one or two sentences to the author about what you wrote '
          'and why, outside the markers.')
      ..writeln()
      ..writeln('Rules:')
      ..writeln('- Put the whole field between the markers, ready to paste. No '
          'headings, no "here is", no code fences, no commentary inside them.')
      ..writeln('- Write ${field.isList ? 'tags' : 'the field'} only for this '
          'one field. Never write any other field.')
      ..writeln('- Use {{char}} for the character and {{user}} for the human '
          'where a name is needed; the app substitutes them.')
      ..writeln('- If the author is only asking a question, leave the markers '
          'out entirely and just answer.');
    if (!field.isList) {
      buffer.writeln('- Match the language the rest of the card is written in.');
    }
    buffer
      ..writeln()
      ..writeln('The human in the conversation is called $userName.');
    return buffer.toString().trim();
  }

  /// The rest of the card, as context — everything except the field being
  /// written, which is shown separately as "what it says at the moment".
  ///
  /// Trimmed hard on purpose: this is a *briefing*, and a 6000-word description
  /// pasted into a system turn on every exchange is how a small helper becomes an
  /// expensive one.
  static String _cardContext(Character draft, WritableField field) {
    final buffer = StringBuffer();
    void section(String heading, String value, {int limit = 1200}) {
      final flat = value.trim();
      if (flat.isEmpty) return;
      final clipped =
          flat.length <= limit ? flat : '${flat.substring(0, limit)}…';
      buffer
        ..writeln('# $heading')
        ..writeln(clipped)
        ..writeln();
    }

    section('Name', draft.displayName, limit: 120);
    if (field != WritableField.title) {
      section('Title', draft.title, limit: 200);
    }
    if (field != WritableField.description) {
      section('Description', draft.description);
    }
    if (field != WritableField.personality) {
      section('Personality', draft.personality, limit: 800);
    }
    if (field != WritableField.scenario) {
      section('Scenario', draft.activeScenario, limit: 800);
    }
    if (field != WritableField.greeting) {
      section('Greeting', draft.firstMes, limit: 800);
    }
    if (field != WritableField.exampleDialogue) {
      section('Example dialogue', draft.mesExample, limit: 600);
    }
    if (field != WritableField.tags && draft.tags.isNotEmpty) {
      section('Tags', draft.tags.join(', '), limit: 300);
    }
    return buffer.toString().trim();
  }

  /// Splits a reply into the field text and the note.
  static WriterResult parse(String reply) {
    final text = reply.trim();
    if (text.isEmpty) return const WriterResult();
    final open = text.indexOf(openTag);
    if (open == -1) {
      // No markers: either the model was only talking, or it ignored the format.
      // A reply that reads like a sentence *about* writing is a note; anything
      // else is what was asked for. Guessing wrong costs a tap either way, and
      // handing the whole answer to the field is the more useful guess only when
      // there is no question mark and no first person in it.
      return _looksLikeTalk(text)
          ? WriterResult(note: text)
          : WriterResult(fieldText: text, note: '');
    }
    final bodyStart = open + openTag.length;
    final close = text.indexOf(closeTag, bodyStart);
    final body = close == -1
        ? text.substring(bodyStart)
        : text.substring(bodyStart, close);
    final note = <String>[
      text.substring(0, open).trim(),
      if (close != -1) text.substring(close + closeTag.length).trim(),
    ].where((s) => s.isNotEmpty).join('\n\n');
    return WriterResult(fieldText: _clean(body), note: note);
  }

  /// Strips the wrappers a model adds even when told not to: a code fence, or
  /// stray quotes around the whole thing.
  static String _clean(String body) {
    var text = body.trim();
    if (text.startsWith('```')) {
      final firstBreak = text.indexOf('\n');
      if (firstBreak != -1) text = text.substring(firstBreak + 1);
      if (text.endsWith('```')) {
        text = text.substring(0, text.length - 3);
      }
      text = text.trim();
    }
    if (text.length > 1 && text.startsWith('"') && text.endsWith('"') &&
        !text.substring(1, text.length - 1).contains('"')) {
      text = text.substring(1, text.length - 1).trim();
    }
    return text;
  }

  static bool _looksLikeTalk(String text) =>
      text.length < 400 &&
      (text.contains('?') ||
          text.toLowerCase().startsWith('i ') ||
          text.toLowerCase().startsWith("i'"));

  /// Reads a tag reply into a clean list: comma- or newline-separated, bullets
  /// and numbering stripped, blanks and duplicates dropped.
  static List<String> parseTags(String text) {
    final out = <String>[];
    for (final raw in text.split(RegExp(r'[,\n;]'))) {
      final tag = raw
          .replaceAll(RegExp(r'^\s*(?:[-*•]|\d+[.)])\s*'), '')
          .replaceAll(_leadingNoise, '')
          .replaceAll(_trailingNoise, '')
          .trim();
      if (tag.isEmpty || tag.length > 40) continue;
      if (out.any((t) => t.toLowerCase() == tag.toLowerCase())) continue;
      out.add(tag);
    }
    return out;
  }

  /// A leading hash or opening quote, as a model writes tags when it forgets it
  /// was asked for plain words.
  static final RegExp _leadingNoise = RegExp('''^[#"'\\s]+''');
  static final RegExp _trailingNoise = RegExp('''["'\\s.]+\$''');
}
