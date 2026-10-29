import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/btw_conversation.dart';
import 'package:maichat/models/conversation.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/settings.dart';
import 'package:maichat/services/backup_codec.dart';
import 'package:maichat/services/storage.dart';
import 'package:maichat/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<AppState> boot() async {
    final state = AppState();
    await state.init();
    return state;
  }

  test(
    'threads and overrides survive reload separately from RP and other threads',
    () async {
      final state = await boot();
      await state.importConversations([
        Conversation(
          id: 'rp',
          title: 'Story',
          updatedAt: DateTime.now(),
          messages: [ChatMessage(role: 'user', content: 'RP_ONLY')],
        ),
        Conversation(
          id: 'other',
          title: 'Other',
          updatedAt: DateTime.now(),
          messages: [],
        ),
      ]);
      final prefs = await SharedPreferences.getInstance();
      final rp = prefs.getString('conversations');
      final one =
          state.createBtwThread('rp', question: 'First line\nMore detail')
            ..systemPrompt = 'SIDE_PROMPT'
            ..providerId = 'provider-2'
            ..toolsEnabled = false;
      one.exchanges.add(
        BtwExchange('QUESTION_ONE', answer: 'ANSWER_ONE', done: true),
      );
      final two = state.createBtwThread('rp', question: 'Second question');
      two.exchanges.add(BtwExchange('QUESTION_TWO', answer: 'PARTIAL'));
      final other = state.createBtwThread('other', question: 'Other side');
      await state.saveBtwThread(one);
      await state.saveBtwThread(two);
      await state.saveBtwThread(other);
      expect(prefs.getString('conversations'), rp);
      final reloaded = await boot();
      expect(reloaded.btwThreadsFor('rp'), hasLength(2));
      expect(reloaded.btwThreadsFor('other').single.id, other.id);
      final saved = reloaded.btwThreadById(one.id)!;
      expect(saved.title, 'First line');
      expect(saved.systemPrompt, 'SIDE_PROMPT');
      expect(saved.providerId, 'provider-2');
      expect(saved.toolsEnabled, isFalse);
      expect(saved.exchanges.single.answer, 'ANSWER_ONE');
      final interrupted = reloaded.btwThreadById(two.id)!.exchanges.single;
      expect(interrupted.answer, 'PARTIAL');
      expect(interrupted.done && interrupted.stopped, isTrue);
      expect(
        jsonEncode(reloaded.conversations.map((c) => c.toJson()).toList()),
        isNot(contains('QUESTION_')),
      );
      state.dispose();
      reloaded.dispose();
    },
  );

  test(
    'deletion cannot be undone by a late controller save and chat deletion cleans side threads',
    () async {
      final state = await boot();
      final chat = state.active;
      final deleted = state.createBtwThread(chat.id);
      await state.saveBtwThread(deleted);
      await state.deleteBtwThread(deleted.id);
      deleted.exchanges.add(BtwExchange('Late', answer: 'Reply', done: true));
      await state.saveBtwThread(deleted);
      expect(state.btwThreadById(deleted.id), isNull);
      final keep = state.createBtwThread('unrelated');
      final remove = state.createBtwThread(chat.id);
      await state.saveBtwThread(keep);
      await state.saveBtwThread(remove);
      await state.deleteConversation(chat.id);
      final reloaded = await boot();
      expect(reloaded.btwThreadsFor(chat.id), isEmpty);
      expect(reloaded.btwThreadById(keep.id), isNotNull);
      state.dispose();
      reloaded.dispose();
    },
  );

  test(
    'whole-app backup restores side exchanges and global title preference',
    () async {
      final state = await boot();
      final thread = state.createBtwThread(
        state.active.id,
        question: 'Backup side',
      );
      thread.exchanges.add(
        BtwExchange('Kept question', answer: 'Kept answer', done: true),
      );
      await state.saveBtwThread(thread);
      await state.updateBtwSettings(
        const BtwSettings(titleMode: BtwTitleMode.generated),
      );
      final raw = await Storage().dump();
      final plan = BackupPlan(
        store: {for (final e in raw.entries) e.key: StoreEntry.of(e.value)},
        createdAt: DateTime.now(),
      );
      final dir = await Directory.systemTemp.createTemp('btw-backup');
      try {
        final path = '${dir.path}/backup.zip';
        await writeBackupFile(plan, path);
        await state.deleteBtwThread(thread.id);
        await state.updateBtwSettings(const BtwSettings());
        final retained = state.createBtwThread(
          'other',
          question: 'Keep during merge',
        );
        await state.saveBtwThread(retained);
        await state.restoreBackupFile(path, replace: false);
        expect(
          state.btwThreadById(thread.id)!.exchanges.single.answer,
          'Kept answer',
        );
        expect(state.btwThreadById(retained.id), isNotNull);
        expect(state.btwSettings.titleMode, BtwTitleMode.firstLine);
        await state.restoreBackupFile(path);
        expect(state.btwThreadById(retained.id), isNull);
        expect(
          state.btwThreadById(thread.id)!.exchanges.single.answer,
          'Kept answer',
        );
        expect(state.btwSettings.titleMode, BtwTitleMode.generated);
      } finally {
        state.dispose();
        await dir.delete(recursive: true);
      }
    },
  );

  test('malformed authored side-thread data makes startup read-only', () async {
    SharedPreferences.setMockInitialValues({'btwThreads': '{broken'});
    final state = await boot();
    expect(state.ready, isTrue);
    expect(state.loadError, isNotNull);
    final thread = state.createBtwThread('rp', question: 'Cannot overwrite');
    await state.saveBtwThread(thread);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('btwThreads'), '{broken');
    state.dispose();
  });
}
