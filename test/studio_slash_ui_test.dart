import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/agent_message.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/studio.dart';
import 'package:maichat/screens/studio/settings/studio_commands_page.dart';
import 'package:maichat/screens/studio/settings/studio_skills_page.dart';
import 'package:maichat/screens/studio/studio_screen.dart';
import 'package:maichat/services/studio/studio_commands.dart';
import 'package:maichat/services/studio/studio_skills.dart';
import 'package:maichat/services/studio/studio_store.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart' hide Provider;
import 'package:shared_preferences/shared_preferences.dart';

class _Starters implements StarterSkillSource {
  _Starters(this.skills);
  final Map<String, Map<String, String>> skills;
  @override
  Future<Map<String, Map<String, String>>> load() async => skills;
}

/// The `/` panel, the skill chip and the Skills / Commands pages, driven as a
/// user would. The skills and commands are read from disk *before* pumping
/// (inside `runAsync` — a widget test's fake-async zone never finishes real
/// file I/O), so the screen finds them already loaded.
void main() {
  late Directory dir;
  var serial = 0;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StudioSkillLibrary.resetShared();
    StudioCommandStore.resetShared();
    dir = Directory.systemTemp.createTempSync('studio_slash_ui');
  });
  tearDown(() {
    StudioSkillLibrary.resetShared();
    StudioCommandStore.resetShared();
    dir.deleteSync(recursive: true);
  });

  const skills = {
    'voice': {
      'SKILL.md': '---\nname: voice\ndescription: Sharpens how a character '
          'talks.\nmetadata:\n  origin: maichat-starter\n---\n\nVOICE_RULES here.',
    },
  };

  Future<(AppState, StudioSkillLibrary, StudioCommandStore)> boot(
    WidgetTester tester,
  ) async {
    final state = AppState();
    await state.init();
    late StudioSkillLibrary lib;
    late StudioCommandStore commands;
    await tester.runAsync(() async {
      lib = await StudioSkillLibrary.forDirectory(dir, starters: _Starters(skills));
      commands = await StudioCommandStore.forDirectory(dir);
      await commands.save(const StudioCommand(
        name: 'villain',
        description: 'Add a villain',
        kind: StudioCommandKind.custom,
        template: 'Add a villain who \$ARGUMENTS.',
      ));
    });
    return (state, lib, commands);
  }

  StudioSession session([List<AgentMessage>? transcript]) => StudioSession(
        id: 'slash-${serial++}',
        title: 'Keeper',
        workspace: StudioWorkspace(character: Character(id: 'c', name: 'Maren')),
        transcript: transcript,
      );

  Widget host(AppState state, Widget child) =>
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(home: child),
      );

  Future<void> open(WidgetTester tester, AppState state, StudioSession s) async {
    await tester.pumpWidget(
      host(state, StudioScreen(store: StudioStore(dir), session: s)),
    );
    await tester.pumpAndSettle();
  }

  Finder field() => find.byKey(const Key('studio-composer-field'));
  Finder panel() => find.byKey(const Key('studio-slash-panel'));

  String text(WidgetTester tester) =>
      tester.widget<TextField>(field()).controller!.text;

  testWidgets('typing / opens the panel above the composer, filtered as you type',
      (tester) async {
    final (state, _, _) = await boot(tester);
    await open(tester, state, session());
    expect(panel(), findsNothing);

    await tester.enterText(field(), '/');
    await tester.pumpAndSettle();
    expect(panel(), findsOneWidget);
    // Above the composer, not over it.
    expect(tester.getBottomLeft(panel()).dy,
        lessThanOrEqualTo(tester.getTopLeft(field()).dy));
    expect(find.text('/help'), findsOneWidget);
    expect(find.text('Built-in'), findsWidgets);

    // Skills and the user's commands, each marked with its kind.
    await tester.enterText(field(), '/v');
    await tester.pumpAndSettle();
    expect(find.text('Skill'), findsOneWidget);
    expect(find.text('Command'), findsOneWidget);

    await tester.enterText(field(), '/vi');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('studio-slash-villain')), findsOneWidget);
    expect(find.byKey(const Key('studio-slash-help')), findsNothing);

    await tester.enterText(field(), '/voi');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('studio-slash-voice')), findsOneWidget);
  });

  testWidgets('tapping a row completes it, and the panel steps aside for the '
      'arguments', (tester) async {
    final (state, _, _) = await boot(tester);
    await open(tester, state, session());
    await tester.enterText(field(), '/pla');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('studio-slash-playtest')));
    await tester.pumpAndSettle();
    expect(text(tester), '/playtest ');
    expect(panel(), findsNothing);
  });

  testWidgets('Enter from a soft keyboard completes the highlighted match',
      (tester) async {
    final (state, _, _) = await boot(tester);
    await open(tester, state, session());
    await tester.enterText(field(), '/rem');
    await tester.pumpAndSettle();
    await tester.enterText(field(), '/rem\n');
    await tester.pumpAndSettle();
    expect(text(tester), '/remember ');
  });

  testWidgets('arrows move the highlight, Tab completes, Escape closes',
      (tester) async {
    final (state, _, _) = await boot(tester);
    await open(tester, state, session());
    await tester.tap(field());
    await tester.enterText(field(), '/');
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    // The second built-in, /skills.
    expect(text(tester), '/skills ');

    await tester.enterText(field(), '/h');
    await tester.pumpAndSettle();
    expect(panel(), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(panel(), findsNothing);
  });

  testWidgets('the panel never opens mid-sentence', (tester) async {
    final (state, _, _) = await boot(tester);
    await open(tester, state, session());
    await tester.enterText(field(), 'tell me /help');
    await tester.pumpAndSettle();
    expect(panel(), findsNothing);
    await tester.enterText(field(), 'a/b');
    await tester.pumpAndSettle();
    expect(panel(), findsNothing);
  });

  testWidgets('an unknown command comes back with an offer to send it as text',
      (tester) async {
    final (state, _, _) = await boot(tester);
    final s = session();
    await open(tester, state, s);
    await tester.enterText(field(), '/wizard do magic');
    await tester.pump();
    await tester.tap(find.byKey(const Key('studio-send')));
    await tester.pumpAndSettle();
    expect(find.text('No command /wizard'), findsOneWidget);
    expect(text(tester), '/wizard do magic');
    expect(s.transcript, isEmpty);

    await tester.tap(find.byKey(const Key('studio-slash-send-as-text')));
    await tester.pump();
    expect(s.transcript.single.text, '/wizard do magic');
    expect(text(tester), isEmpty);
  });

  testWidgets('/help lists the commands in a sheet', (tester) async {
    final (state, _, _) = await boot(tester);
    await open(tester, state, session());
    await tester.enterText(field(), '/help');
    await tester.pump();
    await tester.tap(find.byKey(const Key('studio-send')));
    await tester.pumpAndSettle();
    final sheet = find.byKey(const Key('studio-commands-sheet'));
    expect(sheet, findsOneWidget);
    expect(find.text('Built in'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Your commands'),
      200,
      scrollable: find.descendant(of: sheet, matching: find.byType(Scrollable)),
    );
    expect(find.text('/villain'), findsOneWidget);
    expect(find.text('Skills'), findsOneWidget);
  });

  testWidgets('a skill turn shows as a chip and the user\'s words, not the skill',
      (tester) async {
    final (state, lib, _) = await boot(tester);
    final turn = skillInvocation(lib.skill('voice')!, 'make her drier');
    await open(tester, state, session([AgentMessage.user(turn)]));
    expect(find.byKey(const Key('studio-skill-chip-voice')), findsOneWidget);
    expect(find.text('Using skill: voice'), findsOneWidget);
    expect(find.text('make her drier'), findsOneWidget);
    expect(find.textContaining('VOICE_RULES'), findsNothing);
  });

  testWidgets('the Skills page lists skills, marks starters, and switches them',
      (tester) async {
    final (state, lib, _) = await boot(tester);
    await tester.pumpWidget(host(state, StudioSkillsPage(library: lib)));
    await tester.pumpAndSettle();
    expect(find.text('voice'), findsOneWidget);
    expect(find.text('Starter'), findsOneWidget);
    expect(find.text('1 of 1 on'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('skill-switch-voice')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(lib.skill('voice')!.enabled, isFalse);
    expect(find.text('0 of 1 on'), findsOneWidget);

    // The detail page shows the instructions as they read.
    await tester.tap(find.text('voice'));
    await tester.pumpAndSettle();
    expect(find.textContaining('VOICE_RULES here.'), findsOneWidget);

    // Adding offers the four ways in.
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('studio-skills-add')));
    await tester.pumpAndSettle();
    for (final k in ['file', 'link', 'paste', 'write']) {
      expect(find.byKey(Key('skill-import-$k')), findsOneWidget);
    }
  });

  testWidgets('the Commands page lists the user\'s commands', (tester) async {
    final (state, _, commands) = await boot(tester);
    await tester.pumpWidget(host(state, StudioCommandsPage(store: commands)));
    await tester.pumpAndSettle();
    expect(find.text('/villain'), findsOneWidget);
    expect(find.text('Add a villain'), findsOneWidget);
  });
}
