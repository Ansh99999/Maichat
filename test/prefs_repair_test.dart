import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/services/avatar_store.dart';
import 'package:maichat/services/prefs_repair.dart';

/// The shape Android writes: XML-escaped JSON, base64 embedded verbatim.
String androidXml(List<String> avatars) {
  final characters = <String>[];
  for (var i = 0; i < avatars.length; i++) {
    characters.add('{&quot;id&quot;:&quot;c$i&quot;,'
        '&quot;name&quot;:&quot;Sumire $i&quot;,'
        '&quot;avatar&quot;:&quot;${avatars[i]}&quot;}');
  }
  return '<?xml version=\'1.0\' encoding=\'utf-8\' standalone=\'yes\' ?>\n'
      '<map>\n'
      '    <string name="flutter.conversations">[{&quot;id&quot;:&quot;x&quot;,'
      '&quot;title&quot;:&quot;Kept chat&quot;}]</string>\n'
      '    <string name="flutter.characters">[${characters.join(',')}]</string>\n'
      '    <string name="flutter.activeConversation">x</string>\n'
      '</map>\n';
}

/// A real (tiny) PNG, repeated until it is [bytes] long — so what the repair
/// writes out can be checked as an actual picture, not just a byte count.
String bigPngBase64(int bytes) {
  const png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  final data = <int>[...png];
  var seed = 7;
  while (data.length < bytes) {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    data.add(seed & 0xff);
  }
  return base64Encode(data);
}

void main() {
  late Directory dir;
  late Directory pictures;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('prefs_repair');
    pictures = Directory('${dir.path}/avatars')..createSync();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  File write(String contents) =>
      File('${dir.path}/FlutterSharedPreferences.xml')
        ..writeAsStringSync(contents);

  group('scanning', () {
    test('finds the oversized pictures and nothing else', () async {
      final file = write(androidXml([
        bigPngBase64(3 * 1024 * 1024),
        bigPngBase64(2 * 1024 * 1024),
        bigPngBase64(700), // an ordinary little avatar
      ]));
      final scan = await scanPreferences(file: file);
      expect(scan.oversized.length, 2);
      expect(scan.oversized.first, greaterThan(scan.oversized.last));
      expect(scan.totalBytes, file.lengthSync());
    });

    test('a healthy store reports nothing to do', () async {
      final scan =
          await scanPreferences(file: write(androidXml([bigPngBase64(4000)])));
      expect(scan.hasOversized, isFalse);
      expect(scan.oversizedBytes, 0);
    });

    test('no store at all is not an error', () async {
      final scan =
          await scanPreferences(file: File('${dir.path}/nothing.xml'));
      expect(scan.path, isNull);
      expect(scan.hasOversized, isFalse);
    });
  });

  group('repairing', () {
    test('moves each picture to a file and keeps it on its character',
        () async {
      final bigA = bigPngBase64(3 * 1024 * 1024);
      final small = bigPngBase64(900);
      final file = write(androidXml([bigA, small]));
      final before = file.lengthSync();

      final result = await repairPreferences(file: file, pictures: pictures);
      expect(result, isNotNull);
      expect(result!.recovered, 1);
      expect(result.removed, 0);
      expect(result.bytesAfter, lessThan(before ~/ 2));

      final repaired = file.readAsStringSync();
      // Everything that was not a picture is still there.
      expect(repaired, contains('Kept chat'));
      expect(repaired, contains('Sumire 0'));
      expect(repaired, contains('Sumire 1'));
      expect(repaired, contains(small), reason: 'a small avatar is left alone');
      expect(repaired, startsWith('<?xml'));
      expect(repaired.trimRight(), endsWith('</map>'));

      // The big one is now a reference, in the very place it used to sit, so it
      // still belongs to character c0.
      final ref = RegExp(r'local:[\w.-]+').firstMatch(repaired)!.group(0)!;
      expect(repaired, contains('&quot;id&quot;:&quot;c0&quot;'));
      expect(repaired.indexOf(ref), lessThan(repaired.indexOf(small)));

      // And the file is the picture, byte for byte.
      final moved = File('${pictures.path}/${avatarRefName(ref)}');
      expect(moved.existsSync(), isTrue);
      expect(moved.readAsBytesSync(), base64Decode(bigA));
      expect(moved.path, endsWith('.png'));

      // The original store is kept, untouched.
      expect(File(result.backupPath).lengthSync(), before);
    });

    test('several pictures all move, across chunk boundaries', () async {
      final avatars = [
        bigPngBase64(1024 * 1024 + 7),
        bigPngBase64(65536 + 3),
        bigPngBase64(2 * 1024 * 1024 + 1),
      ];
      final file = write(androidXml(avatars));
      final result = await repairPreferences(file: file, pictures: pictures);
      expect(result!.recovered, 2);

      final repaired = file.readAsStringSync();
      expect(repaired, contains(avatars[1]), reason: 'the small one stays put');
      expect(RegExp(r'local:').allMatches(repaired).length, 2);

      final written = pictures
          .listSync()
          .whereType<File>()
          .map((f) => f.readAsBytesSync())
          .toList();
      expect(written.length, 2);
      expect(written.map((b) => b.length).toList()..sort(),
          [base64Decode(avatars[0]).length, base64Decode(avatars[2]).length]
            ..sort());
    });

    test('a giant blob that is not a picture is dropped, not misfiled',
        () async {
      // No "avatar" anywhere near it: nothing to attach it to.
      final file = write('<?xml version=\'1.0\'?>\n<map>\n'
          '    <string name="flutter.junk">${bigPngBase64(2 * 1024 * 1024)}'
          '</string>\n</map>\n');
      final result = await repairPreferences(file: file, pictures: pictures);
      expect(result!.recovered, 0);
      expect(result.removed, 1);
      expect(pictures.listSync(), isEmpty);
      expect(file.readAsStringSync(), contains('flutter.junk'));
    });

    test('the desktop JSON store repairs the same way', () async {
      final big = bigPngBase64(2 * 1024 * 1024);
      final store = File('${dir.path}/shared_preferences.json')
        ..writeAsStringSync(jsonEncode({
          'flutter.characters': '[{"name":"Sumire","avatar":"$big"}]',
          'flutter.conversations': '[{"title":"Kept chat"}]',
        }));

      final result = await repairPreferences(file: store, pictures: pictures);
      expect(result!.recovered, 1);

      final decoded =
          jsonDecode(store.readAsStringSync()) as Map<String, dynamic>;
      expect(decoded['flutter.conversations'], contains('Kept chat'));
      final characters = decoded['flutter.characters'] as String;
      expect(characters, contains('Sumire'));
      expect(characters, contains('"avatar":"local:'));

      final ref = RegExp(r'local:[\w.-]+').firstMatch(characters)!.group(0)!;
      expect(File('${pictures.path}/${avatarRefName(ref)}').readAsBytesSync(),
          base64Decode(big));
    });

    test('a healthy store is rewritten unchanged', () async {
      final original = androidXml([bigPngBase64(2000)]);
      final file = write(original);
      final result = await repairPreferences(file: file, pictures: pictures);
      expect(result!.recovered, 0);
      expect(result.removed, 0);
      expect(file.readAsStringSync(), original);
      expect(pictures.listSync(), isEmpty);
    });
  });
}
