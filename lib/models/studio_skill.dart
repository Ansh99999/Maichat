/// A skill in the open Agent Skills format (https://agentskills.io): a folder
/// holding a `SKILL.md` — YAML frontmatter naming and describing it, then
/// Markdown instructions — and, optionally, `references/`, `assets/` and
/// `scripts/`.
///
/// Parsing is lenient the way the format's own client guide asks: a skill with
/// a cosmetic problem (a name that breaks the character rules, a name that
/// does not match its folder, an over-long description) still loads, with a
/// warning to show the user; only a missing description or YAML that cannot be
/// read at all stops it, since the description is how an agent knows when to
/// use it.
library;

import 'package:yaml/yaml.dart';

/// The spec's limits.
const int kSkillNameMax = 64;
const int kSkillDescriptionMax = 1024;
const int kSkillCompatibilityMax = 500;

/// What a name must look like: lower-case letters, digits and single hyphens,
/// never at either end.
final RegExp kSkillNamePattern = RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$');

/// One skill, read from its `SKILL.md`.
class StudioSkill {
  const StudioSkill({
    required this.name,
    required this.description,
    required this.body,
    this.license = '',
    this.compatibility = '',
    this.metadata = const <String, String>{},
    this.allowedTools = const <String>[],
    this.files = const <String>[],
    this.warnings = const <String>[],
    this.enabled = true,
  });

  /// How it is called — the `/name` command and `use_skill`'s argument.
  final String name;

  /// What it does and when to use it: all an agent sees until it loads it.
  final String description;

  /// The instructions, frontmatter stripped.
  final String body;
  final String license;
  final String compatibility;
  final Map<String, String> metadata;

  /// The spec's experimental `allowed-tools`, kept for display. The Studio's
  /// own tools decide what a skill can do, so it grants nothing here.
  final List<String> allowedTools;

  /// Every other file in the folder, as paths relative to it (`references/
  /// voice.md`), sorted.
  final List<String> files;

  /// What is off about it, in words for the user.
  final List<String> warnings;
  final bool enabled;

  /// Whether it carries scripts — which can be read here but never run.
  bool get hasScripts => files.any((f) => f.startsWith('scripts/'));

  /// Whether it is one of the skills MaiChat ships.
  bool get isStarter => metadata['origin'] == kStarterSkillOrigin;

  StudioSkill copyWith({bool? enabled, List<String>? files}) => StudioSkill(
        name: name,
        description: description,
        body: body,
        license: license,
        compatibility: compatibility,
        metadata: metadata,
        allowedTools: allowedTools,
        files: files ?? this.files,
        warnings: warnings,
        enabled: enabled ?? this.enabled,
      );
}

/// What the skills MaiChat ships carry in their `metadata.origin`.
const String kStarterSkillOrigin = 'maichat-starter';

/// A `SKILL.md` that could not be read as a skill, and why.
class SkillParseException implements Exception {
  SkillParseException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Reads a `SKILL.md`. [folder], when known, is the name of the folder it
/// sits in, which the spec says the name must match.
///
/// Throws [SkillParseException] for what stops a skill loading: no
/// frontmatter, frontmatter that is not YAML even after the usual repair, or
/// no description. Everything else is a warning on the result.
StudioSkill parseSkill(String text, {String? folder}) {
  final source = text.replaceAll('\r\n', '\n').replaceFirst('﻿', '');
  final match = RegExp(r'^---[ \t]*\n([\s\S]*?)\n---[ \t]*(?:\n|$)')
      .firstMatch(source.trimLeft());
  if (match == null) {
    throw SkillParseException(
      'A SKILL.md starts with frontmatter between two "---" lines, naming and '
      'describing the skill. This file has none.',
    );
  }
  final frontmatter = match.group(1)!;
  final body = source.trimLeft().substring(match.end).trim();
  final map = _readFrontmatter(frontmatter);
  final warnings = <String>[];

  String text0(String key) {
    final value = map[key];
    if (value == null) return '';
    if (value is String) return value.trim();
    return value.toString().trim();
  }

  final description = text0('description');
  if (description.isEmpty) {
    throw SkillParseException(
      'The skill has no description. The description is how an agent knows '
      'when to use it, so it is required.',
    );
  }
  if (description.length > kSkillDescriptionMax) {
    warnings.add('The description is ${description.length} characters; the '
        'format allows $kSkillDescriptionMax.');
  }

  var name = text0('name');
  if (name.isEmpty) {
    if (folder == null || folder.trim().isEmpty) {
      throw SkillParseException('The skill has no name.');
    }
    name = folder.trim();
    warnings.add('No name in the frontmatter; using the folder\'s, "$name".');
  }
  if (name.length > kSkillNameMax) {
    warnings.add('The name is ${name.length} characters; the format allows '
        '$kSkillNameMax.');
  }
  if (!kSkillNamePattern.hasMatch(name)) {
    warnings.add('The name should be lower-case letters, digits and single '
        'hyphens, not starting or ending with one.');
  }
  if (folder != null && folder.isNotEmpty && folder != name) {
    warnings.add('The name "$name" does not match its folder, "$folder".');
  }

  final compatibility = text0('compatibility');
  if (compatibility.length > kSkillCompatibilityMax) {
    warnings.add('The compatibility note is over $kSkillCompatibilityMax '
        'characters.');
  }

  final metadata = <String, String>{};
  final rawMeta = map['metadata'];
  if (rawMeta is Map) {
    rawMeta.forEach((k, v) => metadata['$k'] = '$v');
  } else if (rawMeta != null) {
    warnings.add('"metadata" should be a map of keys to values.');
  }

  final rawTools = map['allowed-tools'];
  final allowedTools = rawTools is String
      ? rawTools.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList()
      : rawTools is List
          ? [for (final t in rawTools) '$t']
          : const <String>[];

  if (body.isEmpty) warnings.add('The skill has no instructions below its frontmatter.');

  return StudioSkill(
    name: name,
    description: description,
    body: body,
    license: text0('license'),
    compatibility: compatibility,
    metadata: metadata,
    allowedTools: allowedTools,
    warnings: warnings,
  );
}

/// The frontmatter as a map. Skills written for other clients often carry
/// YAML their parsers let through — an unquoted value with a colon in it most
/// of all (`description: Use when: the user asks`) — so a first failure is
/// retried with such values quoted, as the format's client guide suggests.
Map<String, Object?> _readFrontmatter(String frontmatter) {
  Object? parsed;
  try {
    parsed = loadYaml(frontmatter);
  } on YamlException {
    try {
      parsed = loadYaml(_quoteBareColons(frontmatter));
    } on YamlException catch (e) {
      throw SkillParseException('The frontmatter is not valid YAML: ${e.message}');
    }
  }
  if (parsed == null) return const <String, Object?>{};
  if (parsed is! Map) {
    throw SkillParseException('The frontmatter should be a set of "key: value" '
        'lines.');
  }
  return {for (final e in parsed.entries) '${e.key}': _plain(e.value)};
}

Object? _plain(Object? value) {
  if (value is YamlMap) {
    return {for (final e in value.entries) '${e.key}': _plain(e.value)};
  }
  if (value is YamlList) return [for (final v in value) _plain(v)];
  return value;
}

String _quoteBareColons(String frontmatter) {
  final line = RegExp(r'^([A-Za-z][\w-]*):[ \t]+(.+)$');
  return frontmatter.split('\n').map((l) {
    final m = line.firstMatch(l);
    if (m == null) return l;
    final value = m.group(2)!.trim();
    final quoted = value.startsWith('"') ||
        value.startsWith("'") ||
        value.startsWith('[') ||
        value.startsWith('{') ||
        value.startsWith('|') ||
        value.startsWith('>');
    if (quoted || !value.contains(':')) return l;
    final escaped = value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
    return '${m.group(1)}: "$escaped"';
  }).join('\n');
}

/// A skill written back out as a `SKILL.md`, frontmatter first.
String renderSkill(StudioSkill skill) {
  String scalar(String v) {
    final escaped = v.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
    return '"$escaped"';
  }

  final lines = <String>[
    '---',
    'name: ${skill.name}',
    'description: ${scalar(skill.description)}',
    if (skill.license.isNotEmpty) 'license: ${scalar(skill.license)}',
    if (skill.compatibility.isNotEmpty)
      'compatibility: ${scalar(skill.compatibility)}',
    if (skill.allowedTools.isNotEmpty)
      'allowed-tools: ${scalar(skill.allowedTools.join(' '))}',
    if (skill.metadata.isNotEmpty) ...[
      'metadata:',
      for (final e in skill.metadata.entries) '  ${e.key}: ${scalar(e.value)}',
    ],
    '---',
    '',
    skill.body.trim(),
    '',
  ];
  return lines.join('\n');
}

/// A folder-safe version of [name]: what an imported skill with an unruly name
/// is stored under.
String skillFolderFor(String name) {
  final slug = name
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  final capped = slug.length > kSkillNameMax ? slug.substring(0, kSkillNameMax) : slug;
  return capped.isEmpty ? 'skill' : capped.replaceAll(RegExp(r'-+$'), '');
}
