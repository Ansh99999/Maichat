/// Which version of each part of a Studio draft is the latest, and who made it
/// — what lets an agent's edit be refused when somebody else changed the same
/// text after that agent last read it (Claude Code's "file modified since
/// read", for one field of a character).
///
/// The draft is split into *parts*, each named by a key: a character field
/// (`field:description`), an alternate greeting (`greeting:2`), one of the
/// character's own scenarios (`scenario:<id>`), a lorebook's settings
/// (`book:<id>`), one entry (`entry:<book>:<uid>`), a document (`doc:<id>`).
/// [partFingerprints] reduces a workspace to one string per part; comparing
/// the fingerprints before and after a change says which parts it touched, so
/// every writer — a tool, a hand edit, a rewind — is counted without having to
/// say what it changed.
library;

import 'dart:convert';

import 'studio.dart';

/// One part's latest version: a number that only goes up, and who wrote it.
class StudioRevision {
  const StudioRevision(this.rev, this.by);

  final int rev;

  /// A name fit for a sentence: `the user`, `the main agent`, `Subagent 3`.
  final String by;

  List<Object> toJson() => [rev, by];

  static StudioRevision? fromJson(Object? json) {
    if (json is! List || json.length < 2 || json[0] is! num) return null;
    return StudioRevision((json[0] as num).toInt(), json[1].toString());
  }
}

/// Who a [StudioSession.edit] tool string says made a change, as the sentence
/// in a refusal names them.
String editorOf(String tool) {
  if (tool == 'manual' || tool == 'rewind') return kUserEditor;
  final at = tool.indexOf(' · ');
  if (at > 0) return tool.substring(0, at);
  return kMainAgentEditor;
}

const String kUserEditor = 'the user';
const String kMainAgentEditor = 'the main agent';

/// What an agent is called in a revision: a tool context's `agent` is
/// `studio` for the main agent and the sub-agent's label otherwise.
String editorForAgent(String agent) =>
    agent == 'studio' ? kMainAgentEditor : agent;

/// The character fields as the tools name them, with where each lives in the
/// character's saved form. Kept beside the tools' own list in spirit: a field
/// the tools can write is a part here.
const Map<String, List<String>> _fieldParts = {
  'name': ['name'],
  'title': ['title', 'titleShown'],
  'description': ['description'],
  'personality': ['personality'],
  'scenario': ['scenario'],
  'first_message': ['firstMes'],
  'example_dialogue': ['mesExample'],
  'system_prompt': ['systemPrompt'],
  'post_history_instructions': ['postHistoryInstructions'],
  'creator_notes': ['creatorNotes'],
  'creator': ['creator'],
  'character_version': ['characterVersion'],
  'tags': ['tags'],
  'avatar': ['avatar', 'avatars'],
};

/// Every part of [ws], each reduced to a string that changes whenever the part
/// does.
Map<String, String> partFingerprints(StudioWorkspace ws) {
  final out = <String, String>{};
  final c = ws.character.toJson();
  for (final field in _fieldParts.entries) {
    out['field:${field.key}'] =
        jsonEncode([for (final k in field.value) c[k]]);
  }
  final alternates = ws.character.alternateGreetings;
  for (var i = 0; i < alternates.length; i++) {
    out['greeting:$i'] = alternates[i];
  }
  for (final s in ws.character.scenarios) {
    out['scenario:${s.id}'] = jsonEncode(s.toJson());
  }
  for (final b in ws.lorebooks) {
    final book = b.toJson()
      ..remove('entries')
      ..remove('updatedAt');
    out['book:${b.id}'] = jsonEncode(book);
    for (final e in b.entries) {
      out['entry:${b.id}:${e.uid}'] = jsonEncode(e.toJson());
    }
  }
  for (final d in ws.documents) {
    out['doc:${d.id}'] = jsonEncode([d.name, d.text]);
  }
  return out;
}

/// The parts that differ between two fingerprint maps: changed, added or gone.
Set<String> changedParts(Map<String, String> before, Map<String, String> after) {
  final out = <String>{};
  for (final e in after.entries) {
    if (before[e.key] != e.value) out.add(e.key);
  }
  for (final k in before.keys) {
    if (!after.containsKey(k)) out.add(k);
  }
  return out;
}

/// The keys of the parts named by [prefix] (`field:`, `greeting:`,
/// `entry:<book>:` …) that [ws] has now.
Iterable<String> partsWithPrefix(StudioWorkspace ws, String prefix) =>
    partFingerprints(ws).keys.where((k) => k.startsWith(prefix));

/// How a part is named in a sentence: "the description", "alternate greeting
/// 3", "lore entry "The marsh"".
String describePart(StudioWorkspace ws, String key) {
  final parts = key.split(':');
  switch (parts.first) {
    case 'field':
      return 'the ${parts[1].replaceAll('_', ' ')}';
    case 'greeting':
      final i = int.tryParse(parts[1]) ?? 0;
      return 'alternate greeting ${i + 1}';
    case 'scenario':
      final s = ws.character.scenarios.where((s) => s.id == parts[1]);
      return s.isEmpty ? 'that scenario' : 'scenario "${s.first.displayName}"';
    case 'book':
      final b = ws.lorebook(parts[1]);
      return b == null ? 'that lorebook' : 'lorebook "${b.displayName}"';
    case 'entry':
      final b = ws.lorebook(parts[1]);
      final uid = int.tryParse(parts.length > 2 ? parts[2] : '');
      final e = b?.entries.where((e) => e.uid == uid);
      return e == null || e.isEmpty
          ? 'that lore entry'
          : 'lore entry "${e.first.displayName}"';
    case 'doc':
      final d = ws.document(parts[1]);
      return d == null ? 'that document' : 'document "${d.name}"';
  }
  return key;
}
