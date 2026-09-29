import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../../models/studio_skill.dart';
import 'studio_web.dart' show isPrivateAddress;

/// Where the Studio's skills live, as files: `studio/skills/<name>/SKILL.md`
/// and whatever else the skill carries. Never in preferences — a skill can be
/// long, and it is a folder the user may want to share as it is.
const String kSkillsFolder = 'skills';

/// Which starter skills have been copied in, and which skills are switched
/// off: one small file beside the skills (a dot-file, so no scan takes it for
/// a skill).
const String _stateFile = '.state.json';

/// Bump when the starter skills change enough that installs should receive
/// the new ones. A skill the user already has is never overwritten by this —
/// only [StudioSkillLibrary.restoreStarters] does that, when asked.
const int kStarterSkillsVersion = 1;

/// The limits on what a skill may bring in, and on what one file read hands an
/// agent.
const int kSkillFileMax = 256 * 1024;
const int kSkillImportMax = 2 * 1024 * 1024;
const int kSkillImportFiles = 60;
const int kSkillReadMax = 48 * 1024;

/// A skill could not be brought in, and why, in words for the user.
class SkillImportException implements Exception {
  SkillImportException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Bringing in a skill would replace one of the same name.
class SkillConflictException extends SkillImportException {
  SkillConflictException(this.name)
      : super('You already have a skill called "$name".');
  final String name;
}

/// A skill that failed to load, for the settings page to show.
class SkillProblem {
  const SkillProblem(this.folder, this.message);
  final String folder;
  final String message;
}

/// Where the starter skills come from: the app's bundled assets, or — in a
/// test — a map. Folder name → relative path → text.
abstract class StarterSkillSource {
  Future<Map<String, Map<String, String>>> load();
}

/// The starter skills shipped under `assets/studio_skills/`.
class AssetStarterSkills implements StarterSkillSource {
  const AssetStarterSkills({this.bundle, this.prefix = 'assets/studio_skills/'});

  final AssetBundle? bundle;
  final String prefix;

  @override
  Future<Map<String, Map<String, String>>> load() async {
    final source = bundle ?? rootBundle;
    final manifest = await AssetManifest.loadFromAssetBundle(source);
    final out = <String, Map<String, String>>{};
    for (final asset in manifest.listAssets()) {
      if (!asset.startsWith(prefix)) continue;
      final rest = asset.substring(prefix.length);
      final slash = rest.indexOf('/');
      if (slash <= 0) continue;
      final folder = rest.substring(0, slash);
      final path = rest.substring(slash + 1);
      out.putIfAbsent(folder, () => <String, String>{})[path] =
          await source.loadString(asset, cache: false);
    }
    return out;
  }
}

/// The Studio's skills: read from their folder once, then kept in step with
/// every change made through here. The settings page and the tools hold the
/// same one ([forDirectory]); [active] is the one the agents' instructions and
/// tools read.
class StudioSkillLibrary extends ChangeNotifier {
  StudioSkillLibrary(this.directory);

  /// `studio/skills`.
  final Directory directory;

  final Map<String, StudioSkill> _skills = <String, StudioSkill>{};
  final Map<String, Directory> _folders = <String, Directory>{};
  final List<SkillProblem> _problems = <SkillProblem>[];
  Set<String> _disabled = <String>{};
  int _startersInstalled = 0;

  static final Map<String, Future<StudioSkillLibrary>> _open =
      <String, Future<StudioSkillLibrary>>{};

  /// The library the agents use: the one opened last.
  static StudioSkillLibrary? active;

  /// The library in [studioFolder]'s `skills/`, read once and shared. On the
  /// first run the starter skills are copied in.
  static Future<StudioSkillLibrary> forDirectory(
    Directory studioFolder, {
    StarterSkillSource starters = const AssetStarterSkills(),
  }) async {
    final path = '${studioFolder.path}/$kSkillsFolder';
    final library = await _open.putIfAbsent(path, () async {
      final library = StudioSkillLibrary(Directory(path));
      await library._load();
      if (library._startersInstalled < kStarterSkillsVersion) {
        await library._installStarters(starters, overwrite: false);
      }
      return library;
    });
    active = library;
    return library;
  }

  /// Forgets the shared libraries; for tests.
  @visibleForTesting
  static void resetShared() {
    _open.clear();
    active = null;
  }

  /// Every skill that loaded, by name.
  List<StudioSkill> get skills {
    final list = _skills.values.toList()..sort((a, b) => a.name.compareTo(b.name));
    return List.unmodifiable(list);
  }

  /// The skills switched on: the ones agents are told about.
  List<StudioSkill> get enabled => [
        for (final s in skills)
          if (s.enabled) s,
      ];

  /// What failed to load.
  List<SkillProblem> get problems => List.unmodifiable(_problems);

  StudioSkill? skill(String name) => _skills[name];

  /// The folder [name] lives in.
  Directory? folderOf(String name) => _folders[name];

  // --- reading ---------------------------------------------------------------

  Future<void> _load() async {
    _skills.clear();
    _folders.clear();
    _problems.clear();
    await _readState();
    if (!directory.existsSync()) return;
    final entries = directory.listSync().whereType<Directory>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final dir in entries) {
      final folder = dir.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (folder.startsWith('.')) continue;
      final file = File('${dir.path}/SKILL.md');
      if (!file.existsSync()) continue;
      try {
        var skill = parseSkill(await file.readAsString(), folder: folder);
        if (_skills.containsKey(skill.name)) {
          _problems.add(SkillProblem(
            folder,
            'Another skill is already called "${skill.name}"; this one was '
            'left out.',
          ));
          continue;
        }
        skill = skill.copyWith(
          enabled: !_disabled.contains(skill.name),
          files: _listFiles(dir),
        );
        _skills[skill.name] = skill;
        _folders[skill.name] = dir;
      } on SkillParseException catch (e) {
        _problems.add(SkillProblem(folder, e.message));
      } catch (e) {
        _problems.add(SkillProblem(folder, 'Could not be read: $e'));
      }
    }
  }

  /// Every file in [dir] other than `SKILL.md`, relative to it.
  static List<String> _listFiles(Directory dir) {
    final base = dir.path.endsWith('/') ? dir.path : '${dir.path}/';
    final out = <String>[];
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final rel = entity.path.substring(base.length);
      if (rel == 'SKILL.md' || rel.split('/').any((s) => s.startsWith('.'))) {
        continue;
      }
      out.add(rel);
      if (out.length >= 200) break;
    }
    out.sort();
    return out;
  }

  Future<void> _readState() async {
    final file = File('${directory.path}/$_stateFile');
    if (!file.existsSync()) return;
    try {
      final json = jsonDecode(await file.readAsString());
      if (json is! Map) return;
      _disabled = {
        if (json['disabled'] is List)
          for (final n in json['disabled'] as List) '$n',
      };
      _startersInstalled = (json['starters'] as num?)?.toInt() ?? 0;
    } catch (_) {
      // A broken state file costs the on/off switches, never the skills.
    }
  }

  Future<void> _writeState() async {
    if (!directory.existsSync()) directory.createSync(recursive: true);
    await File('${directory.path}/$_stateFile').writeAsString(jsonEncode({
      'disabled': _disabled.toList()..sort(),
      'starters': _startersInstalled,
    }));
  }

  /// Reads the whole library from disk again.
  Future<void> reload() async {
    await _load();
    notifyListeners();
  }

  // --- changing ----------------------------------------------------------------

  Future<void> setEnabled(String name, bool on) async {
    final skill = _skills[name];
    if (skill == null) return;
    if (on) {
      _disabled.remove(name);
    } else {
      _disabled.add(name);
    }
    _skills[name] = skill.copyWith(enabled: on);
    await _writeState();
    notifyListeners();
  }

  /// Writes [skill]'s `SKILL.md` — a new skill, or an edit of [previousName]
  /// (renamed when the name changed; its other files move with it).
  Future<StudioSkill> save(StudioSkill skill, {String? previousName}) async {
    final problem = skillNameProblem(skill.name);
    if (problem != null) throw SkillImportException(problem);
    if (skill.description.trim().isEmpty) {
      throw SkillImportException('A skill needs a description: it is how an '
          'agent knows when to use it.');
    }
    final old = previousName == null ? null : _folders[previousName];
    if (skill.name != previousName && _skills.containsKey(skill.name)) {
      throw SkillConflictException(skill.name);
    }
    var dir = Directory('${directory.path}/${skillFolderFor(skill.name)}');
    if (old != null && old.path != dir.path) {
      if (dir.existsSync()) throw SkillConflictException(skill.name);
      dir = await old.rename(dir.path);
    }
    dir.createSync(recursive: true);
    await File('${dir.path}/SKILL.md').writeAsString(renderSkill(skill));
    if (previousName != null && previousName != skill.name) {
      _skills.remove(previousName);
      _folders.remove(previousName);
      if (_disabled.remove(previousName) && !skill.enabled) {
        _disabled.add(skill.name);
      }
    }
    final stored = skill.copyWith(files: _listFiles(dir));
    _skills[skill.name] = stored;
    _folders[skill.name] = dir;
    await _writeState();
    notifyListeners();
    return stored;
  }

  Future<void> delete(String name) async {
    final dir = _folders.remove(name);
    _skills.remove(name);
    _disabled.remove(name);
    if (dir != null && dir.existsSync()) await dir.delete(recursive: true);
    await _writeState();
    notifyListeners();
  }

  // --- bringing skills in -----------------------------------------------------

  /// A skill from the text of a `SKILL.md` — a file picked off the device, or
  /// text pasted in.
  Future<StudioSkill> importMarkdown(String text, {bool replace = false}) =>
      _install({'SKILL.md': utf8.encode(text)}, replace: replace);

  /// A skill from a `.zip` of its folder: the shallowest `SKILL.md` in the
  /// archive marks the folder, and everything under it comes along.
  Future<StudioSkill> importZip(Uint8List bytes, {bool replace = false}) async {
    Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw SkillImportException('That is not a zip file that can be read.');
    }
    ArchiveFile? marker;
    for (final f in archive.files) {
      if (!f.isFile) continue;
      final parts = f.name.split('/');
      if (parts.last != 'SKILL.md') continue;
      if (marker == null ||
          parts.length < marker.name.split('/').length) {
        marker = f;
      }
    }
    if (marker == null) {
      throw SkillImportException('The zip has no SKILL.md in it.');
    }
    final root = marker.name.substring(0, marker.name.length - 'SKILL.md'.length);
    final files = <String, List<int>>{};
    var total = 0;
    for (final f in archive.files) {
      if (!f.isFile || !f.name.startsWith(root)) continue;
      final rel = f.name.substring(root.length);
      if (rel.isEmpty || rel.endsWith('/')) continue;
      final data = f.readBytes() ?? Uint8List(0);
      total += data.length;
      if (data.length > kSkillFileMax) {
        throw SkillImportException('"$rel" is too big for a skill file.');
      }
      if (total > kSkillImportMax || files.length >= kSkillImportFiles) {
        throw SkillImportException('The skill is too big to bring in.');
      }
      files[rel] = data;
    }
    return _install(files, replace: replace);
  }

  /// A skill from the web: a `SKILL.md` address, or a GitHub folder
  /// (`github.com/<owner>/<repo>/tree/<ref>/<path>`, or a repository whose root
  /// holds the skill) — its files come by GitHub's keyless contents API.
  ///
  /// [githubApi] and [githubRaw] are there for tests; [allowPrivateHosts] too —
  /// in the app a skill never comes from a local or private address.
  Future<StudioSkill> importUrl(
    String address, {
    bool replace = false,
    http.Client? client,
    bool allowPrivateHosts = false,
    String githubApi = 'https://api.github.com',
    String githubRaw = 'https://raw.githubusercontent.com',
  }) async {
    final uri = Uri.tryParse(address.trim());
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      throw SkillImportException('That is not a web address.');
    }
    final http.Client web = client ?? http.Client();
    try {
      Future<List<int>> get(Uri u) async {
        if (!allowPrivateHosts) await _refusePrivate(u);
        final response = await web
            .get(u, headers: const {'User-Agent': 'MaiChat'})
            .timeout(const Duration(seconds: 20));
        if (response.statusCode != 200) {
          throw SkillImportException(
            'The address answered HTTP ${response.statusCode}.',
          );
        }
        if (response.bodyBytes.length > kSkillFileMax) {
          throw SkillImportException('That file is too big for a skill.');
        }
        return response.bodyBytes;
      }

      final gh = _gitHubFolder(uri);
      if (gh != null) {
        final files = <String, List<int>>{};
        var total = 0;
        Future<void> walk(String path, String rel, int depth) async {
          final listing = Uri.parse(
            '$githubApi/repos/${gh.owner}/${gh.repo}/contents/$path'
            '${gh.ref == null ? '' : '?ref=${Uri.encodeQueryComponent(gh.ref!)}'}',
          );
          final decoded = jsonDecode(utf8.decode(await get(listing)));
          if (decoded is! List) {
            throw SkillImportException('That GitHub address is a file, not a '
                'folder holding a skill.');
          }
          for (final item in decoded) {
            if (item is! Map) continue;
            final name = '${item['name']}';
            final type = item['type'];
            final childRel = rel.isEmpty ? name : '$rel/$name';
            if (name.startsWith('.')) continue;
            if (type == 'dir' && depth < 3) {
              await walk(item['path'] as String, childRel, depth + 1);
            } else if (type == 'file') {
              if (files.length >= kSkillImportFiles) {
                throw SkillImportException('The skill has too many files.');
              }
              final size = (item['size'] as num?)?.toInt() ?? 0;
              if (size > kSkillFileMax) {
                throw SkillImportException('"$childRel" is too big for a '
                    'skill file.');
              }
              total += size;
              if (total > kSkillImportMax) {
                throw SkillImportException('The skill is too big to bring in.');
              }
              final download = item['download_url'] as String?;
              final url = download == null
                  ? Uri.parse('$githubRaw/${gh.owner}/${gh.repo}/'
                      '${gh.ref ?? 'HEAD'}/${item['path']}')
                  : Uri.parse(download.replaceFirst(
                      'https://raw.githubusercontent.com', githubRaw));
              files[childRel] = await get(url);
            }
          }
        }

        await walk(gh.path, '', 0);
        if (!files.containsKey('SKILL.md')) {
          throw SkillImportException('That GitHub folder has no SKILL.md in '
              'it.');
        }
        return _install(files, replace: replace);
      }

      // A single SKILL.md — a GitHub "blob" page is read from its raw twin.
      final raw = _gitHubBlob(uri, githubRaw) ?? uri;
      final bytes = await get(raw);
      return _install({'SKILL.md': bytes}, replace: replace);
    } on SkillImportException {
      rethrow;
    } on TimeoutException {
      throw SkillImportException('The address did not answer in time.');
    } on FormatException {
      throw SkillImportException('The address did not send what a skill '
          'folder listing looks like.');
    } catch (e) {
      throw SkillImportException('Could not reach that address: $e');
    } finally {
      if (client == null) web.close();
    }
  }

  static Future<void> _refusePrivate(Uri uri) async {
    final host = uri.host;
    final literal = InternetAddress.tryParse(host);
    final addresses = literal != null
        ? [literal]
        : await InternetAddress.lookup(host)
            .timeout(const Duration(seconds: 10));
    if (addresses.any(isPrivateAddress)) {
      throw SkillImportException('That address is on a private network; '
          'skills only come from the public web.');
    }
  }

  static ({String owner, String repo, String? ref, String path})? _gitHubFolder(
    Uri uri,
  ) {
    if (uri.host != 'github.com' && uri.host != 'www.github.com') return null;
    final s = uri.pathSegments.where((p) => p.isNotEmpty).toList();
    if (s.length == 2) return (owner: s[0], repo: s[1], ref: null, path: '');
    if (s.length >= 4 && s[2] == 'tree') {
      return (
        owner: s[0],
        repo: s[1],
        ref: s[3],
        path: s.sublist(4).join('/'),
      );
    }
    return null;
  }

  static Uri? _gitHubBlob(Uri uri, String githubRaw) {
    if (uri.host != 'github.com' && uri.host != 'www.github.com') return null;
    final s = uri.pathSegments.where((p) => p.isNotEmpty).toList();
    if (s.length < 5 || s[2] != 'blob') return null;
    return Uri.parse('$githubRaw/${s[0]}/${s[1]}/${s.sublist(3).join('/')}');
  }

  /// Writes a skill's [files] into its folder, `SKILL.md` first parsed to
  /// learn its name.
  Future<StudioSkill> _install(
    Map<String, List<int>> files, {
    required bool replace,
    bool enabled = true,
  }) async {
    final markdown = files['SKILL.md'];
    if (markdown == null) throw SkillImportException('There is no SKILL.md.');
    final StudioSkill parsed;
    try {
      parsed = parseSkill(utf8.decode(markdown, allowMalformed: true));
    } on SkillParseException catch (e) {
      throw SkillImportException(e.message);
    }
    for (final rel in files.keys) {
      if (!isSafeSkillPath(rel)) {
        throw SkillImportException('The skill holds a file with an unsafe '
            'path, "$rel".');
      }
    }
    if (_skills.containsKey(parsed.name) && !replace) {
      throw SkillConflictException(parsed.name);
    }
    final dir = Directory('${directory.path}/${skillFolderFor(parsed.name)}');
    // Two names can come down to one folder ("Foo_Bar" and "foo-bar"); the
    // folder's owner is never overwritten by a different skill.
    for (final e in _folders.entries) {
      if (e.key != parsed.name && e.value.path == dir.path) {
        throw SkillConflictException(e.key);
      }
    }
    final existing = _folders[parsed.name];
    if (existing != null && existing.existsSync()) {
      await existing.delete(recursive: true);
    }
    if (dir.existsSync()) await dir.delete(recursive: true);
    dir.createSync(recursive: true);
    for (final e in files.entries) {
      final file = File('${dir.path}/${e.key}');
      file.parent.createSync(recursive: true);
      await file.writeAsBytes(e.value);
    }
    final folder = dir.uri.pathSegments.where((s) => s.isNotEmpty).last;
    final skill = parseSkill(
      utf8.decode(markdown, allowMalformed: true),
      folder: folder,
    ).copyWith(enabled: enabled, files: _listFiles(dir));
    if (enabled) {
      _disabled.remove(skill.name);
    } else {
      _disabled.add(skill.name);
    }
    _skills[skill.name] = skill;
    _folders[skill.name] = dir;
    await _writeState();
    notifyListeners();
    return skill;
  }

  /// The skill as a zip of its folder, to share.
  Uint8List exportZip(String name) {
    final dir = _folders[name];
    if (dir == null) throw SkillImportException('No skill called "$name".');
    final archive = Archive();
    final prefix = '${skillFolderFor(name)}/';
    archive.addFile(ArchiveFile.bytes(
      '${prefix}SKILL.md',
      File('${dir.path}/SKILL.md').readAsBytesSync(),
    ));
    for (final rel in _listFiles(dir)) {
      archive.addFile(ArchiveFile.bytes(
        '$prefix$rel',
        File('${dir.path}/$rel').readAsBytesSync(),
      ));
    }
    return ZipEncoder().encodeBytes(archive);
  }

  // --- the starter skills -------------------------------------------------------

  Future<void> _installStarters(
    StarterSkillSource source, {
    required bool overwrite,
  }) async {
    Map<String, Map<String, String>> starters;
    try {
      starters = await source.load();
    } catch (e) {
      debugPrint('MaiChat: could not read the starter skills ($e)');
      return;
    }
    for (final entry in starters.entries) {
      final files = {
        for (final f in entry.value.entries) f.key: utf8.encode(f.value),
      };
      if (!files.containsKey('SKILL.md')) continue;
      try {
        final name = parseSkill(entry.value['SKILL.md']!).name;
        if (_skills.containsKey(name) && !overwrite) continue;
        await _install(files, replace: true);
      } on Exception catch (e) {
        debugPrint('MaiChat: starter skill ${entry.key} failed: $e');
      }
    }
    _startersInstalled = kStarterSkillsVersion;
    await _writeState();
    notifyListeners();
  }

  /// Puts every starter skill back as it shipped — edited ones reset, deleted
  /// ones returned, all switched on. The user's own skills are untouched.
  Future<void> restoreStarters({
    StarterSkillSource source = const AssetStarterSkills(),
  }) =>
      _installStarters(source, overwrite: true);

  // --- what agents read ---------------------------------------------------------

  /// One of [name]'s files, for `read_skill_file`: [path] relative to the skill
  /// folder, never outside it; text only, and capped.
  Future<String> readFile(String name, String path) async {
    final dir = _folders[name];
    if (dir == null) throw SkillImportException('No skill called "$name".');
    final rel = path.trim().replaceFirst(RegExp(r'^\./'), '');
    if (!isSafeSkillPath(rel)) {
      throw SkillImportException('"$path" is not a path inside the skill. Use '
          'a path from its file list, like "references/notes.md".');
    }
    final file = File('${dir.path}/$rel');
    if (!file.existsSync()) {
      final known = skill(name)?.files ?? const <String>[];
      throw SkillImportException('The skill has no file "$rel". '
          '${known.isEmpty ? 'It has no files besides SKILL.md.' : 'Its files: ${known.join(', ')}.'}');
    }
    final real = file.resolveSymbolicLinksSync();
    final base = dir.resolveSymbolicLinksSync();
    if (!real.startsWith('$base/')) {
      throw SkillImportException('"$path" is not a path inside the skill.');
    }
    final bytes = await file.readAsBytes();
    String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      throw SkillImportException('"$rel" is a binary file (${bytes.length} '
          'bytes) and cannot be read as text.');
    }
    if (text.length > kSkillReadMax) {
      text = '${text.substring(0, kSkillReadMax)}\n… [the rest of the file, '
          '${text.length - kSkillReadMax} characters, is cut]';
    }
    return text;
  }
}

/// Whether [rel] is a plain relative path that stays inside a skill folder.
bool isSafeSkillPath(String rel) {
  if (rel.isEmpty || rel.startsWith('/') || rel.contains('\\')) return false;
  if (RegExp(r'^[A-Za-z]:').hasMatch(rel)) return false;
  for (final part in rel.split('/')) {
    if (part.isEmpty || part == '.' || part == '..') return false;
  }
  return true;
}

/// Why [name] cannot be a skill's name, or null when it can: the format's own
/// rules, applied strictly to skills made here.
String? skillNameProblem(String name) {
  if (name.isEmpty) return 'A skill needs a name.';
  if (name.length > kSkillNameMax) {
    return 'Keep the name to $kSkillNameMax characters.';
  }
  if (!kSkillNamePattern.hasMatch(name)) {
    return 'Use lower-case letters, digits and single hyphens — like '
        '"greeting-variety".';
  }
  return null;
}

// --- prompts and invocations ---------------------------------------------------

/// What every agent is told about the skills switched on — names and
/// descriptions only, the first tier of the format's progressive disclosure.
/// Empty when there are none, so no agent is told about an empty shelf.
String studioSkillsPrompt(List<StudioSkill> enabled) {
  if (enabled.isEmpty) return '';
  final lines = [for (final s in enabled) '- ${s.name}: ${_oneLine(s.description)}'];
  return 'Skills\n'
      'These skills hold specialised instructions for particular kinds of '
      'work. When a task matches a skill\'s description, call use_skill with '
      'its name before you start, then follow what it says; read its files '
      'with read_skill_file only when it points you to them. If a skill you '
      'loaded earlier has been summarised away, load it again.\n'
      '<available_skills>\n${lines.join('\n')}\n</available_skills>';
}

String _oneLine(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();

/// A skill's instructions as an agent receives them — from `use_skill`, or
/// when the user invokes it with `/name` — wrapped so they read as the
/// skill's, with its files listed (never read up front).
String skillContent(StudioSkill skill) {
  final files = skill.files;
  return [
    '<skill_content name="${skill.name}">',
    skill.body.trim(),
    if (files.isNotEmpty) ...[
      '',
      'Files in this skill (read one with read_skill_file):',
      for (final f in files.take(40)) '- $f',
      if (files.length > 40) '- … and ${files.length - 40} more',
    ],
    if (skill.hasScripts)
      'The scripts in this skill cannot run here; read them only for what '
          'they show about the method.',
    '</skill_content>',
  ].join('\n');
}

/// The header a message starts with when the user invoked a skill.
const String _invokedPrefix = '[Studio skill: ';

/// The turn sent when the user types `/name args`: the skill's instructions
/// first, then what the user wrote.
String skillInvocation(StudioSkill skill, String userText) {
  final text = userText.trim();
  return '$_invokedPrefix${skill.name}]\n'
      'The user invoked the skill "${skill.name}". Its instructions follow; '
      'apply them to what the user asks below.\n'
      '${skillContent(skill)}\n\n'
      '${text.isEmpty ? 'Apply this skill to the current draft.' : text}';
}

/// The skill a message invoked and what the user wrote after it, when [text]
/// is such a message — how the chat shows it as a chip and a bubble rather
/// than the whole skill.
({String skill, String userText})? parseSkillInvocation(String text) {
  if (!text.startsWith(_invokedPrefix)) return null;
  final close = text.indexOf(']');
  if (close < 0) return null;
  final name = text.substring(_invokedPrefix.length, close);
  const end = '</skill_content>';
  final at = text.indexOf(end);
  final rest = at < 0 ? '' : text.substring(at + end.length).trim();
  return (
    skill: name,
    userText: rest == 'Apply this skill to the current draft.' ? '' : rest,
  );
}
