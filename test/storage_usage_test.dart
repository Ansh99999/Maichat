import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/services/storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('usage reports the biggest entry first', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.activeConversation': 'c1',
      'flutter.characters': 'x' * 5000,
      'flutter.conversations': 'y' * 200,
    });
    final usage = await Storage().usage();
    expect(usage.keys.first, 'characters');
    expect(usage['characters'], 5000);
    expect(usage['conversations'], 200);
  });

  test('clearCache drops only the rebuildable cache keys', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.modelCache': '{}',
      'flutter.discover': '{}',
      'flutter.conversations': 'keep me',
    });
    await Storage().clearCache();
    final usage = await Storage().usage();
    expect(usage.containsKey('modelCache'), isFalse);
    expect(usage.containsKey('discover'), isFalse);
    expect(usage['conversations'], isNotNull);
  });
}

