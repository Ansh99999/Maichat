import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/conversation.dart';
import 'package:maichat/screens/home_screen.dart';
import 'package:maichat/services/storage.dart';
import 'package:maichat/state/app_state.dart';
import 'package:maichat/widgets/startup_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A store that fails the way a real one can: the platform channel refuses, or
/// never answers. [healed] flips it back to working so a retry can succeed.
class BrokenStorage extends Storage {
  BrokenStorage({this.hang = false});

  final bool hang;
  bool healed = false;
  int conversationWrites = 0;
  int characterWrites = 0;
  int presetWrites = 0;

  @override
  Future<List<Conversation>> loadConversations() async {
    if (healed) return super.loadConversations();
    if (hang) await Future<void>.delayed(const Duration(seconds: 30));
    throw StateError('prefs unavailable');
  }

  @override
  Future<void> saveConversations(List<Conversation> conversations) async {
    conversationWrites++;
    await super.saveConversations(conversations);
  }

  @override
  Future<void> saveCharacters(List<dynamic> characters) async {
    characterWrites++;
  }

  @override
  Future<void> savePresets(PresetState state) async {
    presetWrites++;
    await super.savePresets(state);
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('startup always finishes', () {
    test('a store that throws still opens the app, and says why', () async {
      final storage = BrokenStorage();
      final state = AppState(storage: storage);
      await state.init();

      // The bug this replaces: ready stayed false forever and the app sat on a
      // spinner with no way out.
      expect(state.ready, isTrue);
      expect(state.loadError, isNotNull);
      expect(state.loadError, contains('could not be read'));
    });

    test('a store that never answers is given up on, not waited on forever',
        () async {
      final state = AppState(
        storage: BrokenStorage(hang: true),
        loadTimeout: const Duration(milliseconds: 30),
      );
      await state.init();
      expect(state.ready, isTrue);
      expect(state.loadError, contains('took too long'));
    });
  });

  group('a failed load never overwrites what is on disk', () {
    test('nothing is persisted while the session is broken', () async {
      final storage = BrokenStorage();
      final state = AppState(storage: storage);
      await state.init();

      // Exactly the actions a user would take on opening an app that looks
      // empty — none of them may reach the store.
      state.newConversation();
      await state.send('hello?');
      await state.deleteConversation(state.active.id);
      await state.renameConversation(state.active.id, 'x');

      expect(storage.conversationWrites, 0);
      expect(storage.characterWrites, 0);
      // Presets are the one thing a fresh store legitimately writes during the
      // load itself (the built-in default is seeded before conversations are
      // read), so they are not part of this assertion.
    });

    test('retrying picks the data back up and re-enables saving', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.conversations': '[{"id":"c1","title":"Kept",'
            '"updatedAt":"2026-08-13T10:00:00.000","messages":'
            '[{"role":"user","content":"still here"}]}]',
      });
      final storage = BrokenStorage();
      final state = AppState(storage: storage);
      await state.init();
      expect(state.conversations, isEmpty);

      storage.healed = true;
      await state.retryLoad();

      expect(state.loadError, isNull);
      expect(state.ready, isTrue);
      expect(state.conversations.single.title, 'Kept');
      expect(state.conversations.single.messages.single.content, 'still here');

      await state.renameConversation('c1', 'Renamed');
      expect(storage.conversationWrites, greaterThan(0));
    });
  });

  group('what the user sees', () {
    Widget host(AppState state) => ChangeNotifierProvider<AppState>.value(
          value: state,
          child: const MaterialApp(home: HomeScreen()),
        );

    testWidgets('a spinner while loading, never after', (tester) async {
      final state = AppState(storage: BrokenStorage());
      // Before the read finishes there is nothing but the spinner...
      await tester.pumpWidget(host(state));
      expect(find.byType(StartupScreen), findsOneWidget);

      // ...and once it fails, the app opens anyway and explains itself.
      await state.init();
      await tester.pumpAndSettle();
      expect(find.byType(StartupScreen), findsNothing);
      expect(find.byType(LoadErrorCard), findsOneWidget);
      expect(find.text('Home'), findsWidgets);
    });

    testWidgets('the error card retries', (tester) async {
      final storage = BrokenStorage();
      final state = AppState(storage: storage);
      await state.init();
      await tester.pumpWidget(host(state));
      await tester.pumpAndSettle();
      expect(find.byType(LoadErrorCard), findsOneWidget);

      storage.healed = true;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.byType(LoadErrorCard), findsNothing);
    });
  });
}
