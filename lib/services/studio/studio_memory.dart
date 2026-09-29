import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Most notes the Studio keeps, and the longest one. Memory rides in every
/// agent's instructions, so it is kept to what fits in a glance.
const int kStudioMemoryMaxNotes = 40;
const int kStudioMemoryMaxNoteChars = 240;

/// The Studio's memory across sessions: short notes about the user's taste —
/// "prefers third-person present", "keeps lore entries under 150 tokens" — that
/// every agent is told before it starts, the way Claude Code reads CLAUDE.md.
///
/// A file (`memory.md`, one `- note` per line) in the Studio's folder, beside
/// the session files: readable and editable by hand, and never in preferences.
/// It is not `.json`, so the session list does not mistake it for a session.
class StudioMemory extends ChangeNotifier {
  StudioMemory(this.file, [List<String>? notes])
      : _notes = List<String>.of(notes ?? const <String>[]);

  final File file;
  final List<String> _notes;
  Future<void> _saving = Future<void>.value();

  List<String> get notes => List.unmodifiable(_notes);
  bool get isEmpty => _notes.isEmpty;

  static final Map<String, Future<StudioMemory>> _open =
      <String, Future<StudioMemory>>{};

  /// The memory kept in [directory], read once and then shared — the tools
  /// that write to it and the settings page that shows it hold the same one.
  static Future<StudioMemory> forDirectory(Directory directory) =>
      _open.putIfAbsent(directory.path, () async {
        final file = File('${directory.path}/memory.md');
        var notes = const <String>[];
        try {
          if (file.existsSync()) notes = parse(await file.readAsString());
        } catch (error) {
          debugPrint('MaiChat: could not read the Studio memory ($error)');
        }
        return StudioMemory(file, notes);
      });

  /// Forgets the shared instances; for tests.
  @visibleForTesting
  static void resetShared() => _open.clear();

  /// The notes in a `memory.md`: every `- ` or `* ` line, and any other
  /// non-empty line that is not a heading, so a file edited by hand still
  /// reads.
  static List<String> parse(String text) {
    final out = <String>[];
    for (final raw in text.split('\n')) {
      var line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      if (line.startsWith('- ') || line.startsWith('* ')) {
        line = line.substring(2).trim();
      }
      if (line.isNotEmpty) out.add(line);
    }
    return out;
  }

  static String _normal(String note) =>
      note.toLowerCase().replaceAll(RegExp(r'[\s.!]+'), ' ').trim();

  static String _clean(String note) =>
      note.replaceAll(RegExp(r'\s+'), ' ').trim();

  /// Adds [note]. Returns why it was not added (empty, too long, already
  /// known, memory full), or null when it was.
  String? add(String note) {
    final text = _clean(note);
    if (text.isEmpty) return 'The note is empty.';
    if (text.length > kStudioMemoryMaxNoteChars) {
      return 'Keep a note under $kStudioMemoryMaxNoteChars characters; this '
          'one is ${text.length}. Say it shorter.';
    }
    final key = _normal(text);
    if (_notes.any((n) => _normal(n) == key)) {
      return 'That is already remembered.';
    }
    if (_notes.length >= kStudioMemoryMaxNotes) {
      return 'Memory is full ($kStudioMemoryMaxNotes notes). Forget one that '
          'no longer holds first.';
    }
    _notes.add(text);
    _changed();
    return null;
  }

  /// Removes the note [noteOrIndex] names — its number (from 1, as the
  /// instructions list them) or its text, or a unique part of it. Returns the
  /// note removed, or null when none matched.
  String? remove(String noteOrIndex) {
    final value = noteOrIndex.trim();
    final index = int.tryParse(value);
    if (index != null && index >= 1 && index <= _notes.length) {
      final removed = _notes.removeAt(index - 1);
      _changed();
      return removed;
    }
    final key = _normal(value);
    if (key.isEmpty) return null;
    var at = _notes.indexWhere((n) => _normal(n) == key);
    if (at == -1) {
      final partial = [
        for (var i = 0; i < _notes.length; i++)
          if (_normal(_notes[i]).contains(key)) i,
      ];
      if (partial.length == 1) at = partial.single;
    }
    if (at == -1) return null;
    final removed = _notes.removeAt(at);
    _changed();
    return removed;
  }

  /// Rewrites note [index] (from 0); an empty [note] removes it.
  void replace(int index, String note) {
    if (index < 0 || index >= _notes.length) return;
    final text = _clean(note);
    if (text.isEmpty) {
      _notes.removeAt(index);
    } else {
      _notes[index] = text.length > kStudioMemoryMaxNoteChars
          ? text.substring(0, kStudioMemoryMaxNoteChars)
          : text;
    }
    _changed();
  }

  void clear() {
    if (_notes.isEmpty) return;
    _notes.clear();
    _changed();
  }

  void _changed() {
    notifyListeners();
    _save();
  }

  /// The file as it is written: a heading, then one `- note` per line.
  String render() => [
        '# What the Character Studio remembers about you',
        '',
        for (final n in _notes) '- $n',
        '',
      ].join('\n');

  /// Writes through a temporary file and a rename, one write at a time.
  void _save() {
    final text = render();
    _saving = _saving.then((_) async {
      try {
        final dir = file.parent;
        if (!dir.existsSync()) dir.createSync(recursive: true);
        final temp = File('${file.path}.tmp');
        await temp.writeAsString(text, flush: true);
        await temp.rename(file.path);
      } catch (error) {
        debugPrint('MaiChat: could not save the Studio memory ($error)');
      }
    });
  }

  /// Waits for every write asked for so far.
  Future<void> flush() => _saving;
}
