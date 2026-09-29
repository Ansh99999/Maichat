import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/studio.dart';
import 'package:maichat/models/studio_skill.dart';
import 'package:maichat/services/studio/custom_agents.dart';
import 'package:maichat/services/studio/skill_tools.dart';
import 'package:maichat/services/studio/studio_commands.dart';
import 'package:maichat/services/studio/studio_skills.dart';
import 'package:maichat/services/studio/studio_tools.dart';

/// Starter skills from a map, standing in for the bundled assets.
class _Starters implements StarterSkillSource {
  _Starters(this.skills);
  final Map<String, Map<String, String>> skills;
  int loads = 0;

  @override
  Future<Map<String, Map<String, String>>> load() async {
    loads++;
    return skills;
  }
}

String skillMd(
  String name, {
  String description = 'Does a thing. Use when a thing needs doing.',
  String body = '# Steps\n\n1. Do it well.',
  String extra = '',
}) =>
    '---\nname: $name\ndescription: $description\n$extra---\n\n$body\n';

void main() {
  late Directory dir;

  setUp(() {
    StudioSkillLibrary.resetShared();
    StudioCommandStore.resetShared();
    dir = Directory.systemTemp.createTempSync('studio_skills');
  });
  tearDown(() {
    StudioSkillLibrary.resetShared();
    StudioCommandStore.resetShared();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<StudioSkillLibrary> open({Map<String, Map<String, String>>? starters}) =>
      StudioSkillLibrary.forDirectory(dir, starters: _Starters(starters ?? {}));

  group('parsing a SKILL.md', () {
    test('reads every field the format defines', () {
      final s = parseSkill('''
---
name: pdf-tools
description: Extract text from PDFs. Use when handling PDFs.
license: Apache-2.0
compatibility: Needs network access
allowed-tools: get_draft set_fields
metadata:
  author: someone
  version: "1.0"
---

# PDF tools

Read carefully.
''', folder: 'pdf-tools');
      expect(s.name, 'pdf-tools');
      expect(s.description, startsWith('Extract text'));
      expect(s.license, 'Apache-2.0');
      expect(s.compatibility, 'Needs network access');
      expect(s.allowedTools, ['get_draft', 'set_fields']);
      expect(s.metadata, {'author': 'someone', 'version': '1.0'});
      expect(s.body, '# PDF tools\n\nRead carefully.');
      expect(s.warnings, isEmpty);
    });

    test('what stops a skill loading', () {
      expect(() => parseSkill('# just markdown'),
          throwsA(isA<SkillParseException>()
              .having((e) => e.message, 'message', contains('frontmatter'))));
      expect(() => parseSkill(skillMd('x', description: '')),
          throwsA(isA<SkillParseException>()
              .having((e) => e.message, 'message', contains('description'))));
      expect(() => parseSkill('---\nname: [unclosed\ndescription: d\n---\nbody'),
          throwsA(isA<SkillParseException>()));
      expect(() => parseSkill('---\n- a\n- b\n---\nbody'),
          throwsA(isA<SkillParseException>()));
    });

    test('cosmetic problems load with a warning', () {
      final noName = parseSkill('---\ndescription: d\n---\nb', folder: 'tidy');
      expect(noName.name, 'tidy');
      expect(noName.warnings.single, contains('folder'));

      final badChars = parseSkill(skillMd('Bad_Name'));
      expect(badChars.warnings.single, contains('lower-case'));

      final long = parseSkill(skillMd('a' * 70));
      expect(long.warnings, contains(contains('64')));

      final wordy = parseSkill(skillMd('w', description: 'x' * 1100));
      expect(wordy.warnings.single, contains('1024'));

      final mismatch = parseSkill(skillMd('one'), folder: 'two');
      expect(mismatch.warnings.single, contains('does not match'));

      expect(parseSkill(skillMd('e', body: '')).warnings.single,
          contains('no instructions'));
    });

    test('an unquoted colon in a value is repaired, as other clients allow', () {
      final s = parseSkill(
          '---\nname: colons\ndescription: Use when: the user asks\n---\nbody');
      expect(s.description, 'Use when: the user asks');
    });

    test('a skill written back out reads the same', () {
      final s = parseSkill(skillMd('round-trip',
          description: 'Says "hello": to everyone.',
          extra: 'license: MIT\nmetadata:\n  origin: x\n'));
      final again = parseSkill(renderSkill(s), folder: 'round-trip');
      expect(again.name, s.name);
      expect(again.description, s.description);
      expect(again.license, 'MIT');
      expect(again.metadata, {'origin': 'x'});
      expect(again.body, s.body);
    });
  });

  group('the library', () {
    final starters = {
      'greeting-variety': {
        'SKILL.md': skillMd('greeting-variety',
            extra: 'metadata:\n  origin: maichat-starter\n'),
      },
      'lorebook-hygiene': {
        'SKILL.md': skillMd('lorebook-hygiene',
            extra: 'metadata:\n  origin: maichat-starter\n'),
        'references/keys.md': '# Keys',
      },
    };

    test('starter skills are installed once, and can be restored', () async {
      var lib = await open(starters: starters);
      expect(lib.skills.map((s) => s.name),
          ['greeting-variety', 'lorebook-hygiene']);
      expect(lib.skill('lorebook-hygiene')!.files, ['references/keys.md']);
      expect(lib.skill('greeting-variety')!.isStarter, isTrue);

      // Deleted by the user, it stays deleted on the next launch…
      await lib.delete('greeting-variety');
      StudioSkillLibrary.resetShared();
      final source = _Starters(starters);
      lib = await StudioSkillLibrary.forDirectory(dir, starters: source);
      expect(source.loads, 0);
      expect(lib.skill('greeting-variety'), isNull);

      // …until restored, which also resets an edited one.
      final edited = StudioSkill(
        name: 'lorebook-hygiene',
        description: 'Changed.',
        body: 'Mine now.',
        metadata: lib.skill('lorebook-hygiene')!.metadata,
      );
      await lib.save(edited, previousName: 'lorebook-hygiene');
      await lib.restoreStarters(source: source);
      expect(lib.skill('greeting-variety'), isNotNull);
      expect(lib.skill('lorebook-hygiene')!.body, '# Steps\n\n1. Do it well.');
    });

    test('on and off survive a relaunch, and only "on" is told to agents',
        () async {
      var lib = await open(starters: starters);
      await lib.setEnabled('greeting-variety', false);
      StudioSkillLibrary.resetShared();
      lib = await open(starters: starters);
      expect(lib.skill('greeting-variety')!.enabled, isFalse);
      expect(lib.enabled.map((s) => s.name), ['lorebook-hygiene']);
      final prompt = studioSkillsPrompt(lib.enabled);
      expect(prompt, contains('lorebook-hygiene'));
      expect(prompt, isNot(contains('greeting-variety')));
      expect(studioSkillsPrompt(const []), isEmpty);
    });

    test('a folder that cannot be read is reported, not fatal', () async {
      final broken = Directory('${dir.path}/skills/broken')
        ..createSync(recursive: true);
      File('${broken.path}/SKILL.md').writeAsStringSync('no frontmatter');
      final lib = await open();
      expect(lib.skills, isEmpty);
      expect(lib.problems.single.folder, 'broken');
    });

    test('pasted text becomes a skill; a second of the same name asks first',
        () async {
      final lib = await open();
      final s = await lib.importMarkdown(skillMd('pasted'));
      expect(s.name, 'pasted');
      expect(File('${dir.path}/skills/pasted/SKILL.md').existsSync(), isTrue);
      await expectLater(
        lib.importMarkdown(skillMd('pasted', description: 'Newer.')),
        throwsA(isA<SkillConflictException>()),
      );
      await lib.importMarkdown(skillMd('pasted', description: 'Newer.'),
          replace: true);
      expect(lib.skill('pasted')!.description, 'Newer.');
      expect(() => lib.importMarkdown('nothing here'),
          throwsA(isA<SkillImportException>()));
    });

    test('a zip brings the folder, from its shallowest SKILL.md', () async {
      final archive = Archive()
        ..addFile(ArchiveFile.string('repo/zipped/SKILL.md', skillMd('zipped')))
        ..addFile(ArchiveFile.string('repo/zipped/references/a.md', 'A'))
        ..addFile(ArchiveFile.string('repo/zipped/scripts/run.py', 'print(1)'))
        ..addFile(ArchiveFile.string('repo/other.txt', 'not mine'));
      final lib = await open();
      final s = await lib.importZip(ZipEncoder().encodeBytes(archive));
      expect(s.files, ['references/a.md', 'scripts/run.py']);
      expect(s.hasScripts, isTrue);
      expect(lib.skill('zipped'), isNotNull);

      // And a skill goes out as the same zip.
      StudioSkillLibrary.resetShared();
      final dir2 = Directory.systemTemp.createTempSync('studio_skills2');
      addTearDown(() => dir2.deleteSync(recursive: true));
      final other = await StudioSkillLibrary.forDirectory(dir2,
          starters: _Starters({}));
      final back = await other.importZip(lib.exportZip('zipped'));
      expect(back.files, s.files);
    });

    test('a zip that tries to write outside the skill is refused', () async {
      final archive = Archive()
        ..addFile(ArchiveFile.string('SKILL.md', skillMd('sneaky')))
        ..addFile(ArchiveFile.string('references/../../escape.md', 'x'));
      final lib = await open();
      await expectLater(
        lib.importZip(ZipEncoder().encodeBytes(archive)),
        throwsA(isA<SkillImportException>()
            .having((e) => e.message, 'message', contains('unsafe'))),
      );
      expect(File('${dir.path}/escape.md').existsSync(), isFalse);
      await expectLater(
        lib.importZip(Uint8List.fromList([1, 2, 3])),
        throwsA(isA<SkillImportException>()),
      );
    });

    test('a skill file is read only from inside the skill', () async {
      final lib = await open(starters: starters);
      expect(await lib.readFile('lorebook-hygiene', 'references/keys.md'),
          '# Keys');
      for (final bad in ['../SKILL.md', '/etc/passwd', 'references/../../x',
                         r'references\keys.md']) {
        await expectLater(lib.readFile('lorebook-hygiene', bad),
            throwsA(isA<SkillImportException>()),
            reason: bad);
      }
      await expectLater(
        lib.readFile('lorebook-hygiene', 'references/nope.md'),
        throwsA(isA<SkillImportException>()
            .having((e) => e.message, 'message', contains('references/keys.md'))),
      );
      // A link that points out of the folder is not followed.
      final secret = File('${dir.path}/secret.txt')..writeAsStringSync('no');
      Link('${lib.folderOf('lorebook-hygiene')!.path}/references/link.md')
          .createSync(secret.path);
      await expectLater(
        lib.readFile('lorebook-hygiene', 'references/link.md'),
        throwsA(isA<SkillImportException>()),
      );
      // Binary files are named, not dumped.
      File('${lib.folderOf('lorebook-hygiene')!.path}/assets/pic.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync([0x89, 0x50, 0x4e, 0x47, 0xff, 0xfe, 0x00]);
      await expectLater(
        lib.readFile('lorebook-hygiene', 'assets/pic.png'),
        throwsA(isA<SkillImportException>()
            .having((e) => e.message, 'message', contains('binary'))),
      );
    });

    test('a long file is capped', () async {
      final lib = await open();
      await lib.importMarkdown(skillMd('big'));
      File('${lib.folderOf('big')!.path}/references/long.md')
        ..createSync(recursive: true)
        ..writeAsStringSync('y' * (kSkillReadMax + 500));
      final text = await lib.readFile('big', 'references/long.md');
      expect(text.length, lessThan(kSkillReadMax + 200));
      expect(text, contains('500 characters, is cut'));
    });
  });

  group('importing from the web (loopback)', () {
    late HttpServer server;
    late String base;
    final hits = <String>[];

    setUp(() async {
      hits.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://127.0.0.1:${server.port}';
      server.listen((request) async {
        final path = request.uri.path;
        hits.add('${request.uri}');
        final r = request.response;
        switch (path) {
          case '/raw/SKILL.md':
            r.write(skillMd('from-link'));
          case '/api/repos/owner/repo/contents/skills/folder':
            r.write(jsonEncode([
              {
                'name': 'SKILL.md',
                'path': 'skills/folder/SKILL.md',
                'type': 'file',
                'size': 60,
                'download_url':
                    'https://raw.githubusercontent.com/owner/repo/main/skills/folder/SKILL.md',
              },
              {
                'name': 'references',
                'path': 'skills/folder/references',
                'type': 'dir',
              },
              {'name': '.hidden', 'path': 'skills/folder/.hidden', 'type': 'file'},
            ]));
          case '/api/repos/owner/repo/contents/skills/folder/references':
            r.write(jsonEncode([
              {
                'name': 'notes.md',
                'path': 'skills/folder/references/notes.md',
                'type': 'file',
                'size': 5,
                'download_url':
                    'https://raw.githubusercontent.com/owner/repo/main/skills/folder/references/notes.md',
              },
            ]));
          case '/gh/owner/repo/main/skills/folder/SKILL.md':
            r.write(skillMd('from-github'));
          case '/gh/owner/repo/main/skills/folder/references/notes.md':
            r.write('Notes');
          default:
            r.statusCode = 404;
        }
        await r.close();
      });
    });
    tearDown(() => server.close(force: true));

    test('a SKILL.md address', () async {
      final lib = await open();
      final s = await lib.importUrl('$base/raw/SKILL.md', allowPrivateHosts: true);
      expect(s.name, 'from-link');
    });

    test('a GitHub folder, with its references, keyless', () async {
      final lib = await open();
      final s = await lib.importUrl(
        'https://github.com/owner/repo/tree/main/skills/folder',
        allowPrivateHosts: true,
        githubApi: '$base/api',
        githubRaw: '$base/gh',
      );
      expect(s.name, 'from-github');
      expect(s.files, ['references/notes.md']);
      expect(hits, contains(contains('contents/skills/folder?ref=main')));
      expect(hits, isNot(contains(contains('.hidden'))));
    });

    test('a private address is refused in the app', () async {
      final lib = await open();
      await expectLater(
        lib.importUrl('$base/raw/SKILL.md'),
        throwsA(isA<SkillImportException>()
            .having((e) => e.message, 'message', contains('private'))),
      );
      expect(hits, isEmpty);
    });

    test('a missing page says so', () async {
      final lib = await open();
      await expectLater(
        lib.importUrl('$base/nothing', allowPrivateHosts: true),
        throwsA(isA<SkillImportException>()
            .having((e) => e.message, 'message', contains('404'))),
      );
    });
  });

  group('what agents get', () {
    Future<StudioSkillLibrary> withSkills() async {
      final lib = await open(starters: {
        'voice': {
          'SKILL.md': skillMd('voice', body: 'Make every line sound like them.'),
          'references/samples.md': 'Sample lines.',
        },
      });
      return lib;
    }

    StudioToolContext ctx() => StudioToolContext(
          session: StudioSession(
            id: 's',
            title: '',
            workspace: StudioWorkspace(character: Character(id: 'c', name: '')),
          ),
          services: _NoServices(),
        );

    test('every agent is told about the skills that are on', () async {
      await withSkills();
      const config = StudioConfig();
      final main = studioSystemPrompt(config);
      expect(main, contains('<available_skills>'));
      expect(main, contains('- voice: Does a thing'));
      expect(main, isNot(contains('Make every line')),
          reason: 'only names and descriptions, until loaded');
      expect(
        studioSystemPromptParts(config).map((p) => p.$1),
        contains(StudioPromptPart.skills),
      );
      expect(studioAgentSystemPrompt('writer', config), contains('- voice:'));

      final tools = studioToolsForType('studio', config).map((t) => t.name);
      expect(tools, containsAll(kSkillToolNames));
      for (final type in ['writer', 'lore_writer', 'critic', 'general']) {
        expect(studioToolsForType(type, config).map((t) => t.name),
            containsAll(kSkillToolNames),
            reason: type);
      }
    });

    test('with no skill on, neither the listing nor the tools appear', () async {
      final lib = await withSkills();
      await lib.setEnabled('voice', false);
      const config = StudioConfig();
      expect(studioSystemPrompt(config), isNot(contains('available_skills')));
      expect(studioToolsForType('studio', config).map((t) => t.name),
          isNot(contains('use_skill')));
    });

    test('use_skill hands over the instructions and lists the files', () async {
      await withSkills();
      final r = await useSkillTool.call(ctx(), {'name': 'voice'});
      expect(r.isError, isFalse);
      expect(r.text, startsWith('<skill_content name="voice">'));
      expect(r.text, contains('Make every line sound like them.'));
      expect(r.text, contains('- references/samples.md'));
      expect(r.text, isNot(contains('Sample lines.')));

      final missing = await useSkillTool.call(ctx(), {'name': 'nope'});
      expect(missing.isError, isTrue);
      expect(missing.text, contains('voice'));
    });

    test('read_skill_file reads one file, inside the skill only', () async {
      await withSkills();
      final r = await readSkillFileTool
          .call(ctx(), {'name': 'voice', 'path': 'references/samples.md'});
      expect(r.text, contains('Sample lines.'));
      final escape = await readSkillFileTool
          .call(ctx(), {'name': 'voice', 'path': '../voice/SKILL.md'});
      expect(escape.isError, isTrue);
    });

    test('a user-invoked skill: instructions first, then what they wrote',
        () async {
      final lib = await withSkills();
      final turn = skillInvocation(lib.skill('voice')!, 'make her drier');
      expect(turn, contains('Make every line sound like them.'));
      expect(turn.trim(), endsWith('make her drier'));
      final back = parseSkillInvocation(turn)!;
      expect(back.skill, 'voice');
      expect(back.userText, 'make her drier');
      expect(parseSkillInvocation(skillInvocation(lib.skill('voice')!, ''))!
          .userText, isEmpty);
      expect(parseSkillInvocation('hello'), isNull);
    });
  });

  group('commands', () {
    test('a line is a command only when it starts with one', () {
      expect(parseSlash('/playtest who are you?')!.name, 'playtest');
      expect(parseSlash('/playtest who are you?')!.args, 'who are you?');
      expect(parseSlash('/help')!.args, '');
      expect(parseSlash('/Remember likes tea')!.name, 'remember');
      expect(parseSlash('hello /help'), isNull);
      expect(parseSlash('/ nothing'), isNull);
      expect(parseSlash('/'), isNull);
    });

    test('the panel shows while the name is being typed, and not after', () {
      expect(slashQuery('/'), '');
      expect(slashQuery('/pla'), 'pla');
      expect(slashQuery('/playtest '), isNull);
      expect(slashQuery('tell me /pla'), isNull);
      expect(slashQuery(''), isNull);
    });

    test('templates fill in their blanks', () {
      expect(expandTemplate('Add a villain who \$ARGUMENTS.', 'hates tea'),
          'Add a villain who hates tea.');
      expect(expandTemplate('\$1 vs \$2', '"Old Tom" Maren'), 'Old Tom vs Maren');
      expect(expandTemplate('\$1 and \$3', 'a'), 'a and');
      expect(expandTemplate('Tidy the lore.', 'the marsh ones'),
          'Tidy the lore.\n\nthe marsh ones');
      expect(expandTemplate('Tidy the lore.', ''), 'Tidy the lore.');
    });

    test('built-ins come first; a skill cannot take their names', () {
      final all = studioCommands(
        skills: [
          parseSkill(skillMd('help')),
          parseSkill(skillMd('voice')),
          parseSkill(skillMd('off')).copyWith(enabled: false),
        ],
        custom: [
          const StudioCommand(
            name: 'villain',
            description: 'Add a villain',
            kind: StudioCommandKind.custom,
            template: 'Add a villain.',
          ),
          const StudioCommand(
            name: 'voice',
            description: 'Mine',
            kind: StudioCommandKind.custom,
            template: 'x',
          ),
        ],
      );
      expect(all.where((c) => c.name == 'help').single.kind,
          StudioCommandKind.builtIn);
      expect(all.where((c) => c.name == 'voice').single.kind,
          StudioCommandKind.custom);
      expect(all.any((c) => c.name == 'off'), isFalse);
      final ranked = matchCommands(all, 'p');
      expect(ranked.first.name, 'playtest');
      expect(matchCommands(all, 'll').map((c) => c.name), contains('villain'));
    });

    test('the user\'s commands are files, saved, renamed and deleted', () async {
      final store = await StudioCommandStore.forDirectory(dir);
      await store.save(const StudioCommand(
        name: 'villain',
        description: 'Add a villain',
        kind: StudioCommandKind.custom,
        argumentHint: '<who>',
        template: 'Add a villain who \$ARGUMENTS.',
      ));
      expect(File('${dir.path}/commands/villain.md').readAsStringSync(),
          contains('argument-hint: "<who>"'));
      StudioCommandStore.resetShared();
      final again = await StudioCommandStore.forDirectory(dir);
      final c = again.commands.single;
      expect(c.argumentHint, '<who>');
      expect(c.template, 'Add a villain who \$ARGUMENTS.');

      await again.save(
        StudioCommand(
          name: 'rival',
          description: c.description,
          kind: c.kind,
          template: c.template,
        ),
        previousName: 'villain',
      );
      expect(again.commands.map((c) => c.name), ['rival']);
      expect(() => again.save(const StudioCommand(
            name: 'help',
            description: '',
            kind: StudioCommandKind.custom,
            template: 'x',
          )), throwsArgumentError);
      await again.delete('rival');
      expect(again.commands, isEmpty);
    });

    test('a command file without a description uses its first line', () {
      final c = parseCommandFile('tidy', 'Tidy every lore entry.\nThen report.');
      expect(c.description, 'Tidy every lore entry.');
      expect(c.template, 'Tidy every lore entry.\nThen report.');
    });
  });

  test('the starter skills ship whole, and every one reads cleanly', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final starters = await const AssetStarterSkills().load();
    expect(starters.keys.toSet(), {
      'lorebook-hygiene',
      'greeting-variety',
      'chub-ready-card',
      'distinct-voices',
      'avoid-purple-prose',
      'playtest-checklist',
    });
    for (final e in starters.entries) {
      final s = parseSkill(e.value['SKILL.md']!, folder: e.key);
      expect(s.warnings, isEmpty, reason: e.key);
      expect(s.isStarter, isTrue, reason: e.key);
      expect(s.description.length, lessThan(kSkillDescriptionMax));
      // Every file a skill points to is shipped with it.
      for (final m in RegExp(r'`((?:references|assets)/[^`]+)`')
          .allMatches(s.body)) {
        expect(e.value.keys, contains(m.group(1)), reason: '${e.key}: ${m.group(1)}');
      }
    }
    // Every folder under assets/studio_skills is listed in pubspec.yaml —
    // Flutter does not recurse, and an unlisted folder silently ships empty.
    final pubspec = File('pubspec.yaml').readAsStringSync();
    for (final d in Directory('assets/studio_skills')
        .listSync(recursive: true)
        .whereType<Directory>()) {
      expect(pubspec, contains('- ${d.path}/'), reason: d.path);
    }
    await rootBundle.loadString('assets/studio_skills/lorebook-hygiene/SKILL.md');
  });
}

class _NoServices implements StudioServices {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
