import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/settings.dart';
import 'package:maichat/services/avatar_store.dart';
import 'package:maichat/services/backup_codec.dart';
import 'package:maichat/services/storage.dart';
import 'package:maichat/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _HeldBtwStorage extends Storage {
  bool holdNextSave = false;
  bool holdRestoreWrite = false;
  bool failRestoreWrite = false;
  int sideSaves = 0;
  final saveStarted = Completer<void>();
  final saveRelease = Completer<void>();
  final restoreWriteStarted = Completer<void>();
  final restoreWriteRelease = Completer<void>();
  Future<void> Function()? onReload;

  @override
  Future<void> saveBtwThreadsJson(String encoded) async {
    sideSaves++;
    if (holdNextSave) {
      holdNextSave = false;
      saveStarted.complete();
      await saveRelease.future;
    }
    await super.saveBtwThreadsJson(encoded);
  }

  @override
  Future<void> writeEntries(
    Map<String, Object?> entries, {
    bool replace = false,
    Set<String> protect = const {},
  }) async {
    if (!restoreWriteStarted.isCompleted) restoreWriteStarted.complete();
    if (holdRestoreWrite) await restoreWriteRelease.future;
    if (failRestoreWrite) throw StateError('Fixture restore write failed.');
    await super.writeEntries(entries, replace: replace, protect: protect);
  }

  @override
  Future<BtwSettings> loadBtwSettings() async {
    final settings = await super.loadBtwSettings();
    await onReload?.call();
    return settings;
  }
}

void main() {
  late Directory dir;
  late _HeldBtwStorage storage;
  late AppState state;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('btw-restore-race');
    storage = _HeldBtwStorage();
    state = AppState(
      storage: storage,
      avatars: AvatarStore(Directory('${dir.path}/pictures')..createSync()),
    );
    await state.init();
  });

  tearDown(() async {
    if (!storage.saveRelease.isCompleted) storage.saveRelease.complete();
    if (!storage.restoreWriteRelease.isCompleted) {
      storage.restoreWriteRelease.complete();
    }
    state.dispose();
    await dir.delete(recursive: true);
  });

  Future<String> backup() async {
    final raw = await storage.dump();
    final path = '${dir.path}/backup.zip';
    await writeBackupFile(
      BackupPlan(
        store: {
          for (final entry in raw.entries)
            entry.key: StoreEntry.of(entry.value),
        },
        createdAt: DateTime.now(),
      ),
      path,
    );
    return path;
  }

  test('flush still waits for an actual queued side write', () async {
    final thread = state.createBtwThread(
      state.active.id,
      question: 'Pending save',
    );
    storage.holdNextSave = true;
    final saving = state.saveBtwThread(thread);
    await storage.saveStarted.future;
    var flushed = false;
    final flushing = state.flushPendingSaves().then((_) => flushed = true);
    await Future<void>.delayed(Duration.zero);
    expect(flushed, isFalse);
    storage.saveRelease.complete();
    await saving;
    await flushing;
    expect(flushed, isTrue);
    expect((await storage.loadBtwThreads()).single.id, thread.id);
  });

  for (final replace in [true, false]) {
    test(
      'restore drains old side snapshots and fences callbacks through reload: replace=$replace',
      () async {
        final retained = state.createBtwThread(
          state.active.id,
          question: 'Retained',
        );
        final incoming = state.createBtwThread(
          state.active.id,
          question: 'Imported from backup',
        );
        await state.saveBtwThread(retained);
        await state.saveBtwThread(incoming);
        final path = await backup();
        await state.deleteBtwThread(incoming.id);
        final postBackup = state.createBtwThread(
          state.active.id,
          question: 'Created after backup',
        );
        storage.holdNextSave = true;
        final saving = state.saveBtwThread(postBackup);
        await storage.saveStarted.future;
        final before = storage.sideSaves;
        storage.holdRestoreWrite = true;
        final restoring = state.restoreBackupFile(path, replace: replace);
        expect(
          storage.restoreWriteStarted.isCompleted,
          isFalse,
          reason:
              'The prior side snapshot must finish before restoration writes.',
        );
        postBackup.title = 'Stale controller edit';
        await state.saveBtwThread(postBackup);
        expect(storage.sideSaves, before);
        expect(() => state.createBtwThread(state.active.id), throwsStateError);
        storage.saveRelease.complete();
        await saving;
        await storage.restoreWriteStarted.future;
        retained.title = 'Stale callback during replacement';
        await state.saveBtwThread(retained);
        storage.onReload = () async {
          retained.title = 'Stale callback during rehydration';
          await state.saveBtwThread(retained);
        };
        storage.restoreWriteRelease.complete();
        await restoring;
        storage.onReload = null;
        expect(storage.sideSaves, before);
        expect(state.btwThreadById(retained.id)!.title, 'Retained');
        expect(state.btwThreadById(incoming.id), isNotNull);
        expect(state.btwThreadById(postBackup.id) != null, !replace);
        if (!replace) {
          expect(
            state.btwThreadById(postBackup.id)!.title,
            'Created after backup',
          );
        }
        await state.saveBtwThread(retained);
        await state.saveBtwThread(postBackup);
        expect(
          storage.sideSaves,
          before,
          reason: 'Former controller instances must remain stale after reload.',
        );
        final reloaded = AppState(storage: storage);
        await reloaded.init();
        expect(reloaded.btwThreadById(retained.id)!.title, 'Retained');
        expect(reloaded.btwThreadById(incoming.id), isNotNull);
        expect(reloaded.btwThreadById(postBackup.id) != null, !replace);
        reloaded.dispose();
      },
    );
  }

  test('a failed restore releases the side-write guard', () async {
    final path = await backup();
    storage.failRestoreWrite = true;
    await expectLater(state.restoreBackupFile(path), throwsStateError);
    storage.failRestoreWrite = false;
    final thread = state.createBtwThread(
      state.active.id,
      question: 'Saved after failed restore',
    );
    await state.saveBtwThread(thread);
    await state.updateBtwSettings(
      const BtwSettings(titleMode: BtwTitleMode.generated),
    );
    final reloaded = AppState(storage: storage);
    await reloaded.init();
    expect(
      reloaded.btwThreadById(thread.id)!.title,
      'Saved after failed restore',
    );
    expect(reloaded.btwSettings.titleMode, BtwTitleMode.generated);
    reloaded.dispose();
  });
}
