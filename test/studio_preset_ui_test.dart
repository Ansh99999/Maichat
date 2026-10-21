import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/preset.dart';
import 'package:maichat/models/studio.dart';
import 'package:maichat/screens/presets/preset_editor_body.dart';
import 'package:maichat/screens/studio/draft/draft_preset_tab.dart';
import 'package:maichat/screens/studio/shell/studio_apply.dart';
import 'package:maichat/screens/studio/studio_draft_view.dart';
import 'package:maichat/services/studio/studio_controller.dart';
import 'package:maichat/services/studio/studio_store.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart' hide Provider;
import 'package:shared_preferences/shared_preferences.dart';

// Keep the real controller's edit/apply behavior without file futures in the
// widget binding's fake clock. Persistence is exercised by the controller tests.
class _MemoryStore extends StudioStore {
  _MemoryStore(super.directory);

  @override
  Future<void> save(StudioSession session) async {}
}

class _Controller extends StudioController {
  _Controller({
    required super.state,
    required super.store,
    required super.session,
  });

  bool _running = false;

  @override
  bool get running => _running;

  void setRunning(bool value) {
    _running = value;
    notifyListeners();
  }
}

void main() {
  late Directory dir;
  var serial = 0;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    dir = Directory.systemTemp.createTempSync('studio_preset_ui');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Preset voice() => Preset(
    id: 'voice',
    name: 'Voice Study',
    model: 'roleplay-model',
    temperature: 0.7,
    topP: 0.9,
    maxContext: 64000,
    maxResponseTokens: 1800,
    extensions: {
      'imported': {
        'values': ['original'],
      },
    },
  );

  Future<(AppState, _Controller)> boot({Preset? selected}) async {
    final state = AppState();
    await state.init();
    await state.savePreset(voice());
    await state.savePreset(Preset(id: 'other', name: 'Other preset'));
    final controller = _Controller(
      state: state,
      store: _MemoryStore(dir),
      session: StudioSession(
        id: 'preset-ui-${serial++}',
        title: 'Preset study',
        workspace: StudioWorkspace(
          character: Character(id: 'c', name: 'Maren'),
          preset: selected,
        ),
      ),
    );
    addTearDown(controller.dispose);
    addTearDown(state.dispose);
    return (state, controller);
  }

  Widget host(AppState state, Widget body) =>
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(home: Scaffold(body: body)),
      );

  Widget presetTab(_Controller controller) => ListenableBuilder(
    listenable: controller,
    builder: (_, _) => DraftPresetTab(controller: controller),
  );

  Finder nameField() => find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.labelText == 'Name',
  );

  Future<void> openEditor(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Edit Studio preset'));
    await tester.pumpAndSettle();
    expect(find.byType(PresetEditorBody), findsOneWidget);
  }

  testWidgets('Preset tab loads a searchable private copy and clears it', (
    tester,
  ) async {
    final (state, controller) = await boot();
    await tester.pumpWidget(
      host(state, StudioDraftView(controller: controller)),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.bySemanticsLabel('Preset'));
    await tester.tap(find.bySemanticsLabel('Preset'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No Studio preset selected'), findsOneWidget);

    await tester.tap(find.text('Choose preset'));
    await tester.pumpAndSettle();
    expect(find.text('Choose Studio preset'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Voice');
    await tester.pumpAndSettle();
    expect(find.text('Other preset'), findsNothing);
    await tester.tap(find.text('Voice Study'));
    await tester.pumpAndSettle();

    final selected = controller.session.workspace.preset!;
    final stored = state.presetById('voice')!;
    expect(selected.toJson(), stored.toJson());
    expect(identical(selected, stored), isFalse);
    expect(identical(selected.prompts.first, stored.prompts.first), isFalse);
    expect(find.text('Voice Study'), findsOneWidget);
    expect(
      find.text('64000 context tokens · 1800 response tokens'),
      findsOneWidget,
    );
    expect(find.text('Temperature 0.7 · Top P 0.9'), findsOneWidget);
    expect(
      find.textContaining('Playtests use the Studio copy'),
      findsOneWidget,
    );
    expect(controller.session.ops.single.tool, 'manual');
    ((selected.extensions['imported'] as Map)['values'] as List).add('draft');
    expect((stored.extensions['imported'] as Map)['values'], ['original']);

    await tester.tap(find.text('Clear selection'));
    await tester.pumpAndSettle();
    expect(controller.session.workspace.preset, isNull);
    expect(state.presetById('voice')!.name, 'Voice Study');
    expect(controller.session.ops, hasLength(2));
  });

  testWidgets(
    'editor Cancel discards; Save snapshots and changes only the draft',
    (tester) async {
      final (state, controller) = await boot(selected: voice());
      final libraryBefore = jsonEncode(state.presetById('voice')!.toJson());
      await tester.pumpWidget(host(state, presetTab(controller)));
      await tester.pumpAndSettle();
      await openEditor(tester);
      await tester.enterText(nameField(), 'Discard this');
      expect(controller.session.workspace.preset!.name, 'Voice Study');
      expect(jsonEncode(state.presetById('voice')!.toJson()), libraryBefore);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(controller.session.ops, isEmpty);
      expect(controller.session.workspace.preset!.name, 'Voice Study');

      await openEditor(tester);
      await tester.enterText(nameField(), 'Draft Voice');
      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await tester.pumpAndSettle();
      expect(controller.session.workspace.preset!.name, 'Draft Voice');
      expect(jsonEncode(state.presetById('voice')!.toJson()), libraryBefore);
      final op = controller.session.ops.single;
      expect(op.tool, 'manual');
      expect(jsonDecode(op.before)['preset']['name'], 'Voice Study');
      await controller.rewindTo(0);
      await tester.pumpAndSettle();
      expect(controller.session.workspace.preset!.name, 'Voice Study');
    },
  );

  testWidgets('running locks selection, clear, and the open editor', (
    tester,
  ) async {
    final (state, controller) = await boot(selected: voice());
    await tester.pumpWidget(host(state, presetTab(controller)));
    await tester.pumpAndSettle();
    controller.setRunning(true);
    await tester.pumpAndSettle();
    expect(
      find.text('Hand edits wait until the Studio finishes.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (w) => w is IconButton && w.tooltip == 'Edit Studio preset',
            ),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<ListTile>(find.widgetWithText(ListTile, 'Clear selection'))
          .onTap,
      isNull,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Choose another preset'),
          )
          .onPressed,
      isNull,
    );

    controller.setRunning(false);
    await tester.pumpAndSettle();
    await openEditor(tester);
    await tester.enterText(nameField(), 'Waiting edit');
    controller.setRunning(true);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Save'))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<AbsorbPointer>(
            find.byWidgetPredicate(
              (w) => w is AbsorbPointer && w.child is PresetEditorBody,
            ),
          )
          .absorbing,
      isTrue,
    );
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(controller.session.workspace.preset!.name, 'Voice Study');
    expect(controller.session.ops, isEmpty);
  });

  for (final running in [false, true]) {
    testWidgets(
      'picker ignores its result when ${running ? 'running starts' : 'the draft changes'}',
      (tester) async {
        final (state, controller) = await boot();
        await tester.pumpWidget(host(state, presetTab(controller)));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Choose preset'));
        await tester.pumpAndSettle();
        if (running) {
          controller.setRunning(true);
        } else {
          controller.editByHand(
            'External change',
            (ws) => ws.notes = 'New notes',
          );
        }
        await tester.pumpAndSettle();
        await tester.tap(find.text('Voice Study'));
        await tester.pumpAndSettle();
        expect(controller.session.workspace.preset, isNull);
        expect(
          find.textContaining(
            running
                ? 'Hand edits wait until the Studio finishes.'
                : 'The draft changed while this window was open.',
          ),
          findsWidgets,
        );
      },
    );
  }

  testWidgets('an open editor cannot overwrite a newer draft', (tester) async {
    final (state, controller) = await boot(selected: voice());
    await tester.pumpWidget(host(state, presetTab(controller)));
    await tester.pumpAndSettle();
    await openEditor(tester);
    await tester.enterText(nameField(), 'Stale edit');
    controller.editByHand(
      'Another edit',
      (ws) => ws.preset!.name = 'Newer edit',
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('The draft changed while this editor was open'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Save'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(controller.session.workspace.preset!.name, 'Newer edit');
    expect(state.presetById('voice')!.name, 'Voice Study');
    expect(controller.session.ops, hasLength(1));
  });

  for (final existing in [false, true]) {
    testWidgets(
      'Apply explains preset ${existing ? 'replacement' : 'addition'} and reports saving it',
      (tester) async {
        final draft = voice();
        final selected = existing
            ? draft
            : Preset.fromJson({...draft.toJson(), 'id': 'new-voice'});
        selected.name = 'Draft Voice';
        final (state, controller) = await boot(selected: selected);
        final beforeCount = state.presets.length;
        await tester.pumpWidget(
          host(
            state,
            Builder(
              builder: (context) => FilledButton(
                onPressed: () => showStudioApplyFlow(context, controller),
                child: const Text('Open Apply'),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Open Apply'));
        await tester.pumpAndSettle();
        expect(
          find.text(
            existing
                ? 'Replaces preset "Draft Voice" in your shared library with the Studio copy.'
                : 'Adds preset "Draft Voice" to your shared library.',
          ),
          findsOneWidget,
        );
        expect(
          find.text(
            'The character, its preset, lorebooks and documents, together.',
          ),
          findsOneWidget,
        );
        expect(
          state.presetById(selected.id)?.name,
          existing ? 'Voice Study' : isNull,
        );
        await tester.tap(find.byType(CheckboxListTile));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
        await tester.pumpAndSettle();

        expect(state.presetById(selected.id)!.name, 'Draft Voice');
        expect(state.presets.length, beforeCount + (existing ? 0 : 1));
        expect(state.folders.single.presetIds, [selected.id]);
        expect(state.folders.single.defaultPresetId, selected.id);
        expect(
          find.textContaining('Saved Maren, preset "Draft Voice"'),
          findsOneWidget,
        );
      },
    );
  }
}
