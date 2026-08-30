import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/services/backup_codec.dart';

/// A store shaped like the real one: JSON lists, a JSON envelope, and a scalar.
Map<String, StoreEntry> _store() => <String, StoreEntry>{
      'characters': StoreEntry.of(jsonEncode([
        {'id': 'c1', 'name': 'Aqua'},
        {'id': 'c2', 'name': 'Megumin'},
      ])),
      'conversations': StoreEntry.of(jsonEncode([
        {
          'id': 'k1',
          'title': 'First',
          'messages': [
            {'role': 'user', 'content': 'hi'},
            {'role': 'assistant', 'content': 'hello'},
          ],
        },
      ])),
      'providers': StoreEntry.of(jsonEncode({
        'providers': [
          {
            'id': 'p1',
            'name': 'Test',
            'apiKey': 'sk-secret',
            'apiKeys': ['sk-secret', 'sk-other'],
          },
        ],
        'activeId': 'p1',
      })),
      'presets': StoreEntry.of(jsonEncode({
        'presets': [
          {'id': 'x1', 'name': 'Marinara'},
        ],
        'defaultId': 'x1',
      })),
      'gallery': StoreEntry.of(jsonEncode([
        {'id': 'g1', 'image': 'local:pic.png'},
      ])),
      'imageGen': StoreEntry.of(jsonEncode({'apiKey': 'img-key'})),
      'activeConversation': StoreEntry.of('k1'),
      'somethingNew': StoreEntry.of('a future version wrote this'),
    };
void main() {
  late Directory root;
  late Directory pictures;
  late Directory vectors;
  late File picture;
  late File vector;

  /// A picture big enough to cross the stream's buffers a few times, so the
  /// streaming write is really exercised rather than a single chunk.
  Uint8List big() {
    final random = Random(7);
    return Uint8List.fromList(
      List<int>.generate(300 * 1024, (_) => random.nextInt(256)),
    );
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('codec');
    pictures = Directory('${root.path}/pictures')..createSync();
    vectors = Directory('${root.path}/vectors')..createSync();
    picture = File('${pictures.path}/pic.png')..writeAsBytesSync(big());
    vector = File('${vectors.path}/chat-k1.json')
      ..writeAsStringSync('{"model":"m","records":[]}');
  });

  tearDown(() => root.deleteSync(recursive: true));

  BackupPlan plan({bool includesKeys = true}) => BackupPlan(
        store: includesKeys ? _store() : stripSecrets(_store()),
        pictures: <File>[picture],
        vectors: <File>[vector],
        createdAt: DateTime.utc(2026, 8, 30, 12),
        appVersion: '1.17.0',
        includesKeys: includesKeys,
      );

  Future<File> archiveOf([BackupPlan? source]) async {
    final file = File('${root.path}/backup.zip');
    await writeBackupFile(source ?? plan(), file.path);
    return file;
  }

  group('the archive', () {
    test('round-trips the store, the pictures and the vectors', () async {
      final file = await archiveOf();
      final read = BackupArchive.openFile(file.path);
      addTearDown(read.close);

      expect(read.appVersion, '1.17.0');
      expect(read.createdAt, DateTime.utc(2026, 8, 30, 12));
      expect(read.includesKeys, isTrue);
      expect(read.store.keys, containsAll(_store().keys));
      expect(read.pictureNames, ['pic.png']);
      expect(read.vectorNames, ['chat-k1.json']);

      // Extraction goes back to a *different* pair of directories, which is what
      // restoring onto another device amounts to.
      final toPictures = Directory('${root.path}/back-pictures');
      final toVectors = Directory('${root.path}/back-vectors');
      expect(
        await read.extractFiles(pictures: toPictures, vectors: toVectors),
        2,
      );
      expect(
        File('${toPictures.path}/pic.png').readAsBytesSync(),
        picture.readAsBytesSync(),
      );
      expect(
        File('${toVectors.path}/chat-k1.json').readAsStringSync(),
        '{"model":"m","records":[]}',
      );
    });

    test('an entry comes back byte-identical to what the store held', () async {
      final original = _store();
      final read = BackupArchive.openFile((await archiveOf()).path);
      addTearDown(read.close);

      for (final key in original.keys) {
        expect(read.store[key]!.stored, original[key]!.stored,
            reason: 'entry "$key" did not survive the round trip');
      }
    });

    test('a key nobody has heard of is carried anyway', () async {
      final read = BackupArchive.openFile((await archiveOf()).path);
      addTearDown(read.close);
      expect(read.store['somethingNew']!.stored, 'a future version wrote this');
    });

    test('the backup settings and history are never in a backup', () async {
      final source = BackupPlan(
        store: _store()
          ..['backupPrefs'] = StoreEntry.of('{"schedule":"daily"}')
          ..['backups'] = StoreEntry.of('[]'),
        createdAt: DateTime.utc(2026),
      );
      // The manifest carries them (the plan was handed them), but a reader
      // refuses to hand them back, so a hand-edited file cannot smuggle them in.
      final read = BackupArchive.openFile((await archiveOf(source)).path);
      addTearDown(read.close);
      expect(read.store.containsKey('backupPrefs'), isFalse);
      expect(read.store.containsKey('backups'), isFalse);
    });

    test('counts what is in it, messages included', () {
      final counts = plan().counts;
      expect(counts.characters, 2);
      expect(counts.chats, 1);
      expect(counts.messages, 2);
      expect(counts.presets, 1);
      expect(counts.providers, 1);
      expect(counts.gallery, 1);
      expect(counts.pictures, 1);
      expect(counts.vectors, 1);
      expect(counts.summary(limit: 2), '2 characters · 2 messages');
    });

    test('a bare manifest is a backup too', () {
      final json = jsonEncode(plan().manifest);
      final read = BackupArchive.openBytes(
        Uint8List.fromList(utf8.encode(json)),
      );
      addTearDown(read.close);
      expect(read.counts.characters, 2);
      // Nothing to stream out of a manifest on its own.
      expect(read.extractFiles(pictures: pictures), completion(0));
    });
  });
  group('what it refuses', () {
    test('an empty file', () {
      expect(() => BackupArchive.openBytes(Uint8List(0)),
          throwsA(isA<BackupFormatException>()));
    });

    test('somebody else\'s JSON', () {
      final bytes =
          Uint8List.fromList(utf8.encode('{"kind":"agnai-user-backup"}'));
      expect(
        () => BackupArchive.openBytes(bytes),
        throwsA(isA<BackupFormatException>().having(
          (e) => e.message,
          'message',
          contains('not a MaiChat backup'),
        )),
      );
    });

    test('a backup from a newer app', () {
      final json = plan().manifest..['formatVersion'] = 99;
      expect(
        () => BackupArchive.openBytes(
          Uint8List.fromList(utf8.encode(jsonEncode(json))),
        ),
        throwsA(isA<BackupFormatException>().having(
          (e) => e.message,
          'message',
          contains('newer version'),
        )),
      );
    });

    test('a file that is not there', () {
      expect(
        () => BackupArchive.openFile('${root.path}/nothing.zip'),
        throwsA(isA<BackupFormatException>()),
      );
    });

    test('and it recognises one of ours by looking at the file', () async {
      final ours = await archiveOf();
      expect(looksLikeOurBackupFile(ours.path), isTrue);

      final theirs = File('${root.path}/theirs.json')
        ..writeAsStringSync('{"characters":[]}');
      expect(looksLikeOurBackupFile(theirs.path), isFalse);
      expect(looksLikeOurBackupFile('${root.path}/gone.zip'), isFalse);
    });
  });
  group('API keys', () {
    test('are blanked but kept in shape when left out', () {
      final store = stripSecrets(_store());
      final providers = store['providers']!.asMap!['providers'] as List;
      expect((providers.first as Map)['apiKey'], '');
      expect((providers.first as Map)['apiKeys'], ['', '']);
      expect(store['imageGen']!.asMap!['apiKey'], '');
      // Everything else is untouched.
      expect((providers.first as Map)['name'], 'Test');
      expect(store['characters']!.asList!.length, 2);
    });

    test('a blank key defers to the one live on the device', () {
      final restored = preserveSecrets(
        current: _store(),
        incoming: stripSecrets(_store()),
      );
      final providers = restored['providers']!.asMap!['providers'] as List;
      expect((providers.first as Map)['apiKey'], 'sk-secret');
      expect((providers.first as Map)['apiKeys'], ['sk-secret', 'sk-other']);
      expect(restored['imageGen']!.asMap!['apiKey'], 'img-key');
    });

    test('a key in the backup wins over the one on the device', () {
      final incoming = _store();
      final current = <String, StoreEntry>{
        ...(_store()),
        'providers': StoreEntry.of(jsonEncode({
          'providers': [
            {'id': 'p1', 'name': 'Test', 'apiKey': 'stale', 'apiKeys': ['stale']},
          ],
          'activeId': 'p1',
        })),
      };
      final restored = preserveSecrets(current: current, incoming: incoming);
      final providers = restored['providers']!.asMap!['providers'] as List;
      expect((providers.first as Map)['apiKey'], 'sk-secret');
    });
  });
  group('merging instead of replacing', () {
    Map<String, StoreEntry> device() => <String, StoreEntry>{
          'characters': StoreEntry.of(jsonEncode([
            {'id': 'c1', 'name': 'Aqua the elder'},
            {'id': 'mine', 'name': 'Kazuma'},
          ])),
          'appearance': StoreEntry.of(jsonEncode({'mode': 'amoled'})),
          'presets': StoreEntry.of(jsonEncode({
            'presets': [
              {'id': 'mine', 'name': 'My preset'},
            ],
            'defaultId': 'mine',
          })),
        };

    test('an item in both takes the incoming one, and mine is kept', () {
      final merged = mergeStores(device(), _store());
      final characters = merged['characters']!.asList!;
      final byId = {
        for (final c in characters) (c as Map)['id']: c['name'],
      };
      expect(byId['c1'], 'Aqua');          // the file's version won
      expect(byId['c2'], 'Megumin');       // arrived from the file
      expect(byId['mine'], 'Kazuma');      // mine survived
      expect(characters.length, 3);
    });

    test('my settings and my pointers are left alone', () {
      final merged = mergeStores(device(), _store());
      expect(merged['appearance']!.asMap!['mode'], 'amoled');
      expect(merged['presets']!.asMap!['defaultId'], 'mine');
      final presets = merged['presets']!.asMap!['presets'] as List;
      expect(presets.length, 2);
    });

    test('a key I have never written arrives from the file', () {
      final merged = mergeStores(device(), _store());
      expect(merged['imageGen']!.asMap!['apiKey'], 'img-key');
      expect(merged['activeConversation']!.stored, 'k1');
    });

    test('an empty pointer of mine adopts the file\'s', () {
      final merged = mergeStores(
        <String, StoreEntry>{
          'providers': StoreEntry.of(jsonEncode({
            'providers': <dynamic>[],
            'activeId': null,
          })),
        },
        _store(),
      );
      expect(merged['providers']!.asMap!['activeId'], 'p1');
      expect((merged['providers']!.asMap!['providers'] as List).length, 1);
    });
  });
}
