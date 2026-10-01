import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:yaml/yaml.dart';

import '../../models/studio_skill.dart';

/// The `/` commands the Studio's composer understands: the built-in ones, one
/// per skill switched on, and the user's own — prompt templates saved as files
/// the way Claude Code keeps `.claude/commands/*.md`.
///
/// All of it is here and pure: what the names are, how a line is read, how a
/// template is filled in, and what a command comes to. What each action then
/// *does* (open a sheet, stop the agent, send a turn) is the screen's.
enum StudioCommandKind {
  builtIn('Built-in'),
  skill('Skill'),
  custom('Command');

  const StudioCommandKind(this.label);
  final String label;
}

/// One command the panel lists.
class StudioCommand {
  const StudioCommand({
    required this.name,
    required this.description,
    required this.kind,
    this.argumentHint = '',
    this.template = '',
  });

  /// Typed after the `/`.
  final String name;
  final String description;
  final StudioCommandKind kind;

  /// What goes after the name, shown greyed in the panel: `<message>`.
  final String argumentHint;

  /// A user command's text, with `$ARGUMENTS`, `$1`, `$2` … to fill in.
  final String template;
}

/// The built-in commands and what each is for.
const List<StudioCommand> kBuiltInCommands = [
  StudioCommand(
    name: 'help',
    description: 'What the commands do',
    kind: StudioCommandKind.builtIn,
  ),
  StudioCommand(
    name: 'skills',
    description: 'The skills the Studio can use',
    kind: StudioCommandKind.builtIn,
  ),
  StudioCommand(
    name: 'playtest',
    description: 'Have the Studio chat with the draft and report back',
    kind: StudioCommandKind.builtIn,
    argumentHint: '<what you say to the character>',
  ),
  StudioCommand(
    name: 'remember',
    description: 'Add a note to the Studio\'s memory of you',
    kind: StudioCommandKind.builtIn,
    argumentHint: '<preference>',
  ),
  StudioCommand(
    name: 'compact',
    description: 'Summarise the older conversation now, to free up room',
    kind: StudioCommandKind.builtIn,
  ),
  StudioCommand(
    name: 'context',
    description: 'See what the Studio is sending, and how much',
    kind: StudioCommandKind.builtIn,
  ),
  StudioCommand(
    name: 'agents',
    description: 'Show the sub-agents',
    kind: StudioCommandKind.builtIn,
  ),
  StudioCommand(
    name: 'new',
    description: 'Start a new session',
    kind: StudioCommandKind.builtIn,
  ),
  StudioCommand(
    name: 'stop',
    description: 'Stop the Studio and every sub-agent',
    kind: StudioCommandKind.builtIn,
  ),
  StudioCommand(
    name: 'btw',
    description: 'Ask a quick side question — not kept in the session',
    kind: StudioCommandKind.builtIn,
    argumentHint: '<question>',
  ),
];

/// Every command there is: the built-ins first, then the user's own, then
/// one per skill switched on. A name is taken by the first to claim it, so a
/// skill called `help` cannot hide the built-in.
List<StudioCommand> studioCommands({
  List<StudioSkill> skills = const <StudioSkill>[],
  List<StudioCommand> custom = const <StudioCommand>[],
}) {
  final taken = <String>{};
  final out = <StudioCommand>[];
  void add(StudioCommand c) {
    if (taken.add(c.name)) out.add(c);
  }

  kBuiltInCommands.forEach(add);
  custom.forEach(add);
  for (final s in skills) {
    if (!s.enabled) continue;
    add(StudioCommand(
      name: s.name,
      description: s.description,
      kind: StudioCommandKind.skill,
      argumentHint: '<what to apply it to>',
    ));
  }
  return out;
}

/// The commands whose names start with [prefix], best first: exact match,
/// then names starting with it, then names containing it.
List<StudioCommand> matchCommands(List<StudioCommand> all, String prefix) {
  final p = prefix.toLowerCase();
  if (p.isEmpty) return all;
  int rank(StudioCommand c) {
    if (c.name == p) return 0;
    if (c.name.startsWith(p)) return 1;
    return 2;
  }

  return [
    for (final c in all)
      if (c.name.contains(p)) c,
  ]..sort((a, b) => rank(a).compareTo(rank(b)));
}

/// A line read as a command: its name and what came after.
class SlashLine {
  const SlashLine(this.name, this.args);
  final String name;
  final String args;
}

final RegExp _slash = RegExp(r'^/([A-Za-z0-9][A-Za-z0-9_:\-]*)(?:[ \t\n]+([\s\S]*))?$');

/// [text] as a command, or null when it is not one: it must begin with `/`
/// and a name.
SlashLine? parseSlash(String text) {
  final m = _slash.firstMatch(text.trimRight());
  if (m == null) return null;
  return SlashLine(m.group(1)!.toLowerCase(), (m.group(2) ?? '').trim());
}

/// The command being typed, while the panel should show: [text] starts with
/// `/` and the caret has not yet left the name (no space typed). Null
/// otherwise — the panel never opens mid-sentence.
String? slashQuery(String text) {
  if (!text.startsWith('/')) return null;
  final m = RegExp(r'^/([A-Za-z0-9_:\-]*)$').firstMatch(text);
  return m?.group(1)?.toLowerCase();
}

/// A template with its arguments filled in: `$ARGUMENTS` is everything,
/// `$1`… `$9` the words (a quoted phrase counts as one). A template that
/// names none of them has the arguments added after it.
String expandTemplate(String template, String args) {
  final words = splitArgs(args);
  var used = false;
  var out = template.replaceAllMapped(RegExp(r'\$(ARGUMENTS|[1-9])'), (m) {
    used = true;
    final key = m.group(1)!;
    if (key == 'ARGUMENTS') return args;
    final i = int.parse(key) - 1;
    return i < words.length ? words[i] : '';
  });
  if (!used && args.isNotEmpty) out = '${out.trimRight()}\n\n$args';
  return out.trim();
}

/// [args] split into words, keeping "a quoted phrase" together.
List<String> splitArgs(String args) => [
      for (final m in RegExp(r'"([^"]*)"|(\S+)').allMatches(args))
        m.group(1) ?? m.group(2)!,
    ];

// --- the user's own commands, as files -------------------------------------------

/// The user's own commands: `studio/commands/<name>.md`, each a template with
/// optional frontmatter (`description`, `argument-hint`), like Claude Code's
/// `.claude/commands`.
class StudioCommandStore extends ChangeNotifier {
  StudioCommandStore(this.directory);

  /// `studio/commands`.
  final Directory directory;
  final List<StudioCommand> _commands = <StudioCommand>[];

  static final Map<String, Future<StudioCommandStore>> _open =
      <String, Future<StudioCommandStore>>{};

  /// The store the composer reads: the one opened last.
  static StudioCommandStore? active;

  static Future<StudioCommandStore> forDirectory(Directory studioFolder) async {
    final path = '${studioFolder.path}/commands';
    final store = await _open.putIfAbsent(path, () async {
      final store = StudioCommandStore(Directory(path));
      await store.reload();
      return store;
    });
    active = store;
    return store;
  }

  @visibleForTesting
  static void resetShared() {
    _open.clear();
    active = null;
  }

  List<StudioCommand> get commands => List.unmodifiable(_commands);

  Future<void> reload() async {
    _commands.clear();
    if (directory.existsSync()) {
      final files = directory
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.md'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final f in files) {
        final name = f.uri.pathSegments.last.replaceFirst(RegExp(r'\.md$'), '');
        if (commandNameProblem(name) != null) continue;
        try {
          _commands.add(parseCommandFile(name, await f.readAsString()));
        } catch (e) {
          debugPrint('MaiChat: skipped the command $name ($e)');
        }
      }
    }
    notifyListeners();
  }

  /// Writes [command] (a new one, or an edit of [previousName]).
  Future<void> save(StudioCommand command, {String? previousName}) async {
    final problem = commandNameProblem(command.name);
    if (problem != null) throw ArgumentError(problem);
    if (kBuiltInCommands.any((c) => c.name == command.name)) {
      throw ArgumentError('/${command.name} is a built-in command.');
    }
    if (command.name != previousName &&
        _commands.any((c) => c.name == command.name)) {
      throw ArgumentError('You already have a /${command.name}.');
    }
    directory.createSync(recursive: true);
    if (previousName != null && previousName != command.name) {
      final old = File('${directory.path}/$previousName.md');
      if (old.existsSync()) await old.delete();
    }
    await File('${directory.path}/${command.name}.md')
        .writeAsString(renderCommandFile(command));
    await reload();
  }

  Future<void> delete(String name) async {
    final f = File('${directory.path}/$name.md');
    if (f.existsSync()) await f.delete();
    await reload();
  }
}

/// Why [name] cannot name a command, or null.
String? commandNameProblem(String name) {
  if (name.isEmpty) return 'A command needs a name.';
  if (name.length > 40) return 'Keep the name to 40 characters.';
  if (!RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$').hasMatch(name)) {
    return 'Use lower-case letters, digits and single hyphens.';
  }
  return null;
}

/// A command file: optional frontmatter, then the template.
StudioCommand parseCommandFile(String name, String text) {
  final source = text.replaceAll('\r\n', '\n');
  var description = '';
  var hint = '';
  var body = source;
  final m = RegExp(r'^---[ \t]*\n([\s\S]*?)\n---[ \t]*(?:\n|$)').firstMatch(source);
  if (m != null) {
    body = source.substring(m.end);
    final yaml = loadYaml(m.group(1)!);
    if (yaml is Map) {
      description = '${yaml['description'] ?? ''}'.trim();
      hint = '${yaml['argument-hint'] ?? ''}'.trim();
    }
  }
  body = body.trim();
  if (description.isEmpty) {
    final first = body.split('\n').first.trim();
    description = first.length > 80 ? '${first.substring(0, 80)}…' : first;
  }
  return StudioCommand(
    name: name,
    description: description,
    kind: StudioCommandKind.custom,
    argumentHint: hint,
    template: body,
  );
}

/// A command written back out as its file.
String renderCommandFile(StudioCommand command) {
  String scalar(String v) => '"${v.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
  return [
    '---',
    'description: ${scalar(command.description)}',
    if (command.argumentHint.isNotEmpty)
      'argument-hint: ${scalar(command.argumentHint)}',
    '---',
    '',
    command.template.trim(),
    '',
  ].join('\n');
}
