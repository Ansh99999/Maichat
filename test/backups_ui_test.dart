import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/backup.dart';
import 'package:maichat/screens/backups/backup_import_screen.dart';
import 'package:maichat/screens/backups/backups_screen.dart';
import 'package:maichat/screens/backups/drive_settings_page.dart';
import 'package:maichat/screens/settings_screen.dart';
import 'package:maichat/services/backup_store.dart';
import 'package:maichat/services/drive_client.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Drives the real Backups screens. The archive has its own tests; what these
/// check is the wiring — that the section is reachable, that the search bar
/// searches, that the export window offers every destination, and that the
/// import screen names the apps it can read.
void main() {
  /// One backup already taken, seeded straight into the store so no file has to
  /// be written (a `testWidgets` body never pumps real file I/O).
  Map<String, Object> withRecords() => <String, Object>{
        // The mock store needs the platform prefix the real one uses.
        'flutter.backups': jsonEncode([
          {
            'id': '1',
            'name': 'maichat-backup-2026-08-30-120000.zip',
            'createdAt': DateTime.now()
                .subtract(const Duration(hours: 2))
                .toIso8601String(),
            'bytes': 2048,
            'destination': 'device',
            'path': '/tmp/kept/maichat-backup-2026-08-30-120000.zip',
            'counts': {'characters': 3, 'chats': 4, 'messages': 120},
          },
          {
            'id': '2',
            'name': 'maichat-backup-2026-08-29-090000-auto.zip',
            'createdAt': DateTime.now()
                .subtract(const Duration(days: 1))
                .toIso8601String(),
            'bytes': 4096,
            'destination': 'drive',
            'driveFileId': 'abc',
            'automatic': true,
            'counts': {'characters': 3, 'chats': 4, 'messages': 118},
          },
        ]),
      };

  Future<AppState> ready([Map<String, Object>? store]) async {
    SharedPreferences.setMockInitialValues(store ?? <String, Object>{});
    final state = AppState();
    await state.init();
    return state;
  }

  /// A tall window, so a sliver list further down the screen is actually built
  /// — the default 800x600 test surface cuts off everything below the statistics.
  void tall(WidgetTester tester) {
    tester.view.physicalSize = const Size(420, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  Widget host(AppState state, Widget screen) =>
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(home: screen),
      );
  group('the Backups section', () {
    testWidgets('says so when there is nothing to show yet', (tester) async {
      final state = await ready();
      await tester.pumpWidget(host(state, const BackupsScreen()));
      await tester.pumpAndSettle();

      // The large app bar draws its title twice: toolbar and headline.
      expect(find.text('Backups'), findsNWidgets(2));
      expect(find.widgetWithText(TextField, 'Search backups'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Export'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Import'), findsOneWidget);
      expect(find.text('Exported so far'), findsOneWidget);
      expect(find.textContaining('No backups yet'), findsOneWidget);
    });

    testWidgets('lists what has been taken, with its statistics',
        (tester) async {
      tall(tester);
      final state = await ready(withRecords());
      await tester.pumpWidget(host(state, const BackupsScreen()));
      await tester.pumpAndSettle();

      expect(find.textContaining('maichat-backup-2026-08-30'), findsOneWidget);
      expect(find.textContaining('maichat-backup-2026-08-29'), findsOneWidget);
      expect(find.text('SNAPSHOTS · 2 of 2'), findsOneWidget);
      // 6 KB across two backups.
      expect(find.text('6.0 KB'), findsOneWidget);
      // The one the schedule took says so on its own row.
      expect(find.textContaining('· on a schedule'), findsOneWidget);
      // …and what is in the newest one.
      expect(find.textContaining('120 messages'), findsOneWidget);
    });

    testWidgets('the search bar narrows the list to one', (tester) async {
      tall(tester);
      final state = await ready(withRecords());
      await tester.pumpWidget(host(state, const BackupsScreen()));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, '08-29');
      await tester.pumpAndSettle();

      expect(find.text('SNAPSHOTS · 1 of 2'), findsOneWidget);
      expect(find.textContaining('maichat-backup-2026-08-29'), findsOneWidget);
      expect(find.textContaining('maichat-backup-2026-08-30'), findsNothing);

      await tester.enterText(find.byType(TextField).first, 'nothing like this');
      await tester.pumpAndSettle();
      expect(find.textContaining('No backup matches'), findsOneWidget);
    });
  });
  group('the export window', () {
    testWidgets('comes up from below with every destination on it',
        (tester) async {
      final state = await ready();
      await tester.pumpWidget(host(state, const BackupsScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Export'));
      await tester.pumpAndSettle();

      expect(find.text('Export'), findsWidgets);
      expect(find.byIcon(Icons.arrow_back), findsOneWidget);
      expect(find.text('Save a zip file'), findsOneWidget);
      expect(find.text('Google Drive'), findsWidgets);
      expect(find.text('Keep a copy in the app'), findsOneWidget);
      expect(find.text('Export settings'), findsOneWidget);
    });

    testWidgets('the settings fold sets the schedule, and it is remembered',
        (tester) async {
      final state = await ready();
      await tester.pumpWidget(host(state, const BackupsScreen()));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Export'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Export settings'));
      await tester.pumpAndSettle();
      expect(find.text('Only when I ask'), findsWidgets);

      await tester.tap(find.byType(DropdownButtonFormField<BackupSchedule>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Every week').last);
      await tester.pumpAndSettle();

      expect(state.backupPrefs.schedule, BackupSchedule.weekly);
      // Where a scheduled backup goes is only a question once there is one.
      expect(find.text('Where they go'), findsOneWidget);
      expect(
        find.textContaining('cannot open a save dialog'),
        findsOneWidget,
      );
      // And it survives a fresh read of the store.
      final again = AppState();
      await again.init();
      expect(again.backupPrefs.schedule, BackupSchedule.weekly);
    });

    testWidgets('the back arrow closes it and leaves the list alone',
        (tester) async {
      tall(tester);
      final state = await ready(withRecords());
      await tester.pumpWidget(host(state, const BackupsScreen()));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Export'));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      expect(find.text('Save a zip file'), findsNothing);
      expect(find.text('SNAPSHOTS · 2 of 2'), findsOneWidget);
    });
  });
  group('the import screen', () {
    testWidgets('names every app it can read, and searches them',
        (tester) async {
      tall(tester);
      final state = await ready();
      await tester.pumpWidget(host(state, const BackupImportScreen()));
      await tester.pumpAndSettle();

      expect(find.text('Import'), findsNWidgets(2));
      expect(find.text('A MaiChat backup'), findsOneWidget);
      expect(find.text('SillyTavern'), findsOneWidget);
      expect(find.text('Agnai / Agnaistic'), findsOneWidget);
      expect(find.text('Chub / Venus'), findsOneWidget);
      expect(find.text('Any file or archive'), findsOneWidget);

      // Searching by a word that is not in any title still finds the right row.
      await tester.enterText(find.byType(TextField).first, 'jsonl');
      await tester.pumpAndSettle();
      expect(find.text('SillyTavern'), findsOneWidget);
      expect(find.text('Chub / Venus'), findsNothing);
    });

    testWidgets('offers the backups already on the device', (tester) async {
      tall(tester);
      final state = await ready(withRecords());
      await tester.pumpWidget(host(state, const BackupImportScreen()));
      await tester.pumpAndSettle();

      expect(find.text('ALREADY ON THIS DEVICE'), findsOneWidget);
      expect(find.textContaining('maichat-backup-2026-08-30'), findsOneWidget);
      // The Drive one is not in this list: it belongs under the Drive fold,
      // which is where it can actually be fetched from.
      expect(find.textContaining('maichat-backup-2026-08-29'), findsNothing);
    });
  });

  testWidgets('exporting from the button really writes a backup',
      (tester) async {
    final kept = Directory.systemTemp.createTempSync('ui-backups');
    addTearDown(() => kept.deleteSync(recursive: true));
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final state = AppState(backups: BackupStore(kept));
    await state.init();
    tall(tester);
    await tester.pumpWidget(host(state, const BackupsScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Export'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep a copy in the app'));
    await tester.pump();
    // Writing the archive is real file I/O, which a fake-async test body never
    // pumps on its own (see CLAUDE.md).
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(kept.listSync().whereType<File>().length, 1);
    final record = state.backups.single;
    expect(record.destination, BackupDestination.device);
    expect(record.bytes, greaterThan(0));
    // The window closed behind it and the list now has the snapshot in it.
    expect(find.text('Keep a copy in the app'), findsNothing);
    expect(find.text('SNAPSHOTS · 1 of 1'), findsOneWidget);
  });

  group('the Google Drive page', () {
    testWidgets('is one button when the app ships a client of its own',
        (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final state = AppState(
        drive: DriveClient(
          bundledClientId: 'shipped',
          bundledClientSecret: 'shh',
        ),
      );
      await state.init();
      await tester.pumpWidget(host(state, const DriveSettingsPage()));
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(FilledButton, 'Connect Google Drive'),
        findsOneWidget,
      );
      expect(find.textContaining('creates itself'), findsOneWidget);
      // The client id and secret are folded away, not gone.
      expect(find.text('Use my own Google client'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Client ID'), findsNothing);

      await tester.tap(find.text('Use my own Google client'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'Client ID'), findsOneWidget);
    });

    testWidgets('asks for a client when the build has none', (tester) async {
      tall(tester);
      final state = await ready();
      await tester.pumpWidget(host(state, const DriveSettingsPage()));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(FilledButton, 'Connect Google Drive'),
          findsNothing);
      expect(find.textContaining('Desktop app'), findsWidgets);
      expect(find.widgetWithText(TextField, 'Client ID'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Client secret'), findsOneWidget);
    });

    testWidgets('walks you to the console page for every step', (tester) async {
      tall(tester);
      final state = await ready();
      await tester.pumpWidget(host(state, const DriveSettingsPage()));
      await tester.pumpAndSettle();

      expect(find.text('HOW TO GET THEM'), findsOneWidget);
      expect(find.text('Make a Google Cloud project'), findsOneWidget);
      expect(find.text('Switch the Drive API on'), findsOneWidget);
      expect(find.text('Name the app on the sign-in page'), findsOneWidget);
      expect(find.text('Publish it'), findsOneWidget);
      expect(find.text('Create the client'), findsOneWidget);
      // Five steps, five taps out to the right page.
      expect(find.byIcon(Icons.open_in_new), findsNWidgets(5));
      // The reason a backup silently stops if you skip step 4.
      expect(find.textContaining('every 7 days'), findsOneWidget);
    });
  });

  testWidgets('Settings has a Backups section, and search finds it',
      (tester) async {    final state = await ready(withRecords());
    await tester.pumpWidget(host(state, const SettingsScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Backups'), findsOneWidget);
    expect(find.textContaining('2 backups · newest'), findsOneWidget);

    await tester.tap(find.byType(SearchBar));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'google drive');
    await tester.pumpAndSettle();
    expect(find.text('Google Drive'), findsWidgets);
  });
}
