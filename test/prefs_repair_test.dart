import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/services/prefs_repair.dart';

/// The shape Android writes: XML-escaped JSON, base64 embedded verbatim.
String androidXml(List<String> avatars) {
  final characters = avatars
      .map((a) => '{&quot;id&quot;:&quot;c${avatars.indexOf(a)}&quot;,'
          '&quot;name&quot;:&quot;Sumire&quot;,'
          '&quot;avatar&quot;:&quot;$a&quot;}')
      .join(',');
  return '<?xml version=\'1.0\' encoding=\'utf-8\' standalone=\'yes\' ?>\n'
      '<map>\n'
      '    <string name="flutter.conversations">[{&quot;id&quot;:&quot;x&quot;,'
      '&quot;title&quot;:&quot;Kept chat&quot;}]</string>\n'
      '    <string name="flutter.characters">[$characters]</string>\n'
      '    <string name="flutter.activeConversation">x</string>\n'
      '</map>\n';
}

String base64Run(int length) => 'A' * length;

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('prefs_repair'));
  tearDown(() => dir.deleteSync(recursive: true));

  File write(String contents) =>
      File('${dir.path}/FlutterSharedPreferences.xml')
        ..writeAsStringSync(contents);

  group('scanning', () {
    test('finds the oversized pictures and nothing else', () async {
      final file = write(androidXml([
        base64Run(3 * 1024 * 1024),
        base64Run(2 * 1024 * 1024),
        base64Run(1000), // an ordinary little avatar
      ]));
      final scan = await scanPreferences(file: file);
      expect(scan.oversized.length, 2);
      expect(scan.oversized.first, 3 * 1024 * 1024);
      expect(scan.oversizedBytes, 5 * 1024 * 1024);
      expect(scan.totalBytes, file.lengthSync());
    });

    test('a healthy store reports nothing to do', () async {
      final scan =
          await scanPreferences(file: write(androidXml([base64Run(4000)])));
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
    test('drops the pictures, keeps everything else byte for byte', () async {
      final file = write(androidXml([
        base64Run(4 * 1024 * 1024),
        base64Run(1500),
      ]));
      final before = file.lengthSync();

      final result = await repairPreferences(file: file);
      expect(result, isNotNull);
      expect(result!.removed, 1);
      expect(result.bytesBefore, before);
      expect(result.bytesAfter, lessThan(before ~/ 2));

      final repaired = file.readAsStringSync();
      // The chat, the character and the small avatar all survive.
      expect(repaired, contains('Kept chat'));
      expect(repaired, contains('Sumire'));
      expect(repaired, contains(base64Run(1500)));
      // The monster is gone, leaving an empty avatar behind.
      expect(repaired, isNot(contains(base64Run(2 * 1024 * 1024))));
      expect(repaired, contains('&quot;avatar&quot;:&quot;&quot;'));
      // Still well-formed, and still parses as the store it was.
      expect(repaired, startsWith('<?xml'));
      expect(repaired.trimRight(), endsWith('</map>'));

      // And the original is kept, untouched.
      final backup = File(result.backupPath);
      expect(backup.existsSync(), isTrue);
      expect(backup.lengthSync(), before);
    });

    test('the desktop JSON store repairs the same way', () async {
      final store = File('${dir.path}/shared_preferences.json')
        ..writeAsStringSync(jsonEncode({
          'flutter.characters':
              '[{"name":"Sumire","avatar":"${base64Run(3 * 1024 * 1024)}"}]',
          'flutter.conversations': '[{"title":"Kept chat"}]',
        }));

      final result = await repairPreferences(file: store);
      expect(result!.removed, 1);

      final decoded =
          jsonDecode(store.readAsStringSync()) as Map<String, dynamic>;
      expect(decoded['flutter.conversations'], contains('Kept chat'));
      expect(decoded['flutter.characters'], contains('Sumire'));
      expect(decoded['flutter.characters'], contains('"avatar":""'));
    });

    test('a healthy store is rewritten unchanged', () async {
      final original = androidXml([base64Run(2000)]);
      final file = write(original);
      final result = await repairPreferences(file: file);
      expect(result!.removed, 0);
      expect(file.readAsStringSync(), original);
    });

    test('several pictures spread across chunk boundaries all go', () async {
      // Runs sized to straddle the read buffer, which is where a byte-level
      // scanner would be most likely to lose track.
      final file = write(androidXml([
        base64Run(1024 * 1024 + 7),
        base64Run(65536 + 3),
        base64Run(2 * 1024 * 1024 + 1),
      ]));
      final result = await repairPreferences(file: file);
      expect(result!.removed, 2);
      final repaired = file.readAsStringSync();
      expect(repaired, contains(base64Run(65536 + 3)));
      expect(repaired.length, lessThan(200 * 1024));
    });
  });
}
