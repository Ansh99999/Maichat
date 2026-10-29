import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/services/btw.dart';
import 'package:maichat/state/app_state.dart';
import 'package:maichat/widgets/btw_thread.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<AppState> boot() async {
    final state = AppState();
    await state.init();
    addTearDown(state.dispose);
    return state;
  }

  test(
    'binding is silent and keeps selection across chats; starts preserve saved threads',
    () async {
      final state = await boot();
      final firstChat = state.active.id;
      final controller = BtwThreadController(
        ask: (_, _, _, _) async => 'Answer',
      );
      addTearDown(controller.dispose);
      var notifications = 0;
      controller.addListener(() => notifications++);
      controller.bind(state, firstChat);
      expect(notifications, 0);
      controller.startThread();
      await controller.submit('First question\nMore context');
      final first = controller.activeThread!;
      expect(first.displayTitle, 'First question');
      controller.startThread();
      await controller.submit('Second question');
      final second = controller.activeThread!;
      expect(state.btwThreadsFor(firstChat), containsAll([first, second]));
      controller.selectThread(first);
      final before = notifications;
      controller.bind(state, 'other-chat');
      controller.startThread();
      await controller.submit('Other chat');
      controller.bind(state, firstChat);
      expect(controller.activeThread, same(first));
      expect(controller.exchanges.single.answer, 'Answer');
      expect(notifications, greaterThan(before));
      final restored = await boot();
      expect(
        restored.btwThreadById(first.id)!.exchanges.single.answer,
        'Answer',
      );
      expect(restored.btwThreadById(second.id), isNotNull);
    },
  );

  test(
    'follow-ups use completed exchanges; stopping and deleting cannot restore stale replies',
    () async {
      final state = await boot();
      final histories = <List<ChatMessage>>[];
      Completer<String>? gate;
      void Function(String)? progress;
      BtwRun? run;
      final controller = BtwThreadController(
        ask: (_, history, r, p) {
          histories.add(history);
          run = r;
          progress = p;
          return gate?.future ?? Future.value('Complete answer');
        },
      );
      addTearDown(controller.dispose);
      controller.bind(state, state.active.id);
      await controller.submit('First');
      gate = Completer<String>();
      final pending = controller.submit('Second');
      progress!('Partial answer');
      controller.stop();
      expect(run!.cancelled, isTrue);
      expect(controller.exchanges.last.stopped, isTrue);
      gate.complete('Old late answer');
      await pending;
      gate = null;
      await controller.submit('Third');
      expect(histories.last.map((m) => m.content), [
        'First',
        'Complete answer',
      ]);
      final deleted = controller.activeThread!;
      await controller.deleteThread(deleted);
      expect(state.btwThreadById(deleted.id), isNull);
      await state.saveBtwThread(deleted);
      final restored = await boot();
      expect(restored.btwThreadById(deleted.id), isNull);
    },
  );

  test(
    'opening a blank side thread persists it without sending a question',
    () async {
      final state = await boot();
      var questions = 0;
      final controller = BtwThreadController(
        ask: (_, _, _, _) async {
          questions++;
          return 'Answer';
        },
      );
      addTearDown(controller.dispose);
      controller.bind(state, state.active.id);
      controller.startThread();
      final id = controller.activeThread!.id;
      await Future<void>.delayed(Duration.zero);
      final restored = await boot();
      expect(questions, 0);
      expect(restored.btwThreadById(id), isNotNull);
      expect(restored.btwThreadById(id)!.exchanges, isEmpty);
    },
  );

  test(
    'unbound controller remains usable and failed exchanges stay out of history',
    () async {
      var calls = 0;
      final controller = BtwThreadController(
        ask: (_, history, _, _) async {
          expect(history, isEmpty);
          if (calls++ == 0) throw StateError('No answer');
          return 'Recovered';
        },
      );
      addTearDown(controller.dispose);
      await controller.submit('Fail');
      expect(controller.exchanges.single.error, contains('No answer'));
      await controller.submit('Retry');
      expect(controller.exchanges.last.answer, 'Recovered');
      controller.reset();
      expect(controller.exchanges, isEmpty);
    },
  );

  test('edits persist on the selected side thread only', () async {
    final state = await boot();
    final controller = BtwThreadController(ask: (_, _, _, _) async => 'Answer');
    addTearDown(controller.dispose);
    controller.bind(state, state.active.id);
    controller.startThread();
    final untouched = controller.activeThread!;
    controller.startThread();
    await controller.updateThread(
      systemPrompt: 'Use short answers',
      providerId: 'p2',
      setProvider: true,
      toolsEnabled: false,
      setTools: true,
    );
    final edited = controller.activeThread!;
    expect(untouched.systemPrompt, isEmpty);
    expect(untouched.toolsEnabled, isNull);
    final restored = await boot();
    final saved = restored.btwThreadById(edited.id)!;
    expect(saved.systemPrompt, 'Use short answers');
    expect(saved.providerId, 'p2');
    expect(saved.toolsEnabled, isFalse);
    expect(saved.exchanges, isEmpty);
  });
}
