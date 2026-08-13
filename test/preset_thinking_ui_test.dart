import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/preset.dart';
import 'package:maichat/screens/presets/advanced_section.dart';
import 'package:maichat/screens/presets/general_section.dart';

/// The preset editor's thinking controls, and the context row that now reports
/// what "use the model's limit" actually resolves to.
void main() {
  Widget host(Widget child) => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 500,
            height: 900,
            child: SingleChildScrollView(child: child),
          ),
        ),
      );

  group('Advanced tab', () {
    testWidgets('thinking is off, with effort and budget kept out of the way',
        (tester) async {
      final preset = Preset.create();
      await tester.pumpWidget(host(
        AdvancedSection(preset: preset, onChanged: () {}),
      ));

      expect(find.text('Thinking'), findsOneWidget);
      expect(find.text('Enable thinking'), findsOneWidget);
      expect(find.text('Reasoning effort'), findsNothing);
      expect(find.text('Thinking budget (tokens)'), findsNothing);
    });

    testWidgets('enabling it reveals the controls and seeds a visible effort',
        (tester) async {
      final preset = Preset.create();
      var changes = 0;
      await tester.pumpWidget(host(
        AdvancedSection(preset: preset, onChanged: () => changes++),
      ));

      await tester.ensureVisible(find.text('Enable thinking'));
      await tester.tap(find.text('Enable thinking'));
      await tester.pumpAndSettle();

      expect(preset.thinking, isTrue);
      // Without an effort an OpenAI-compatible request would say nothing at all.
      expect(preset.reasoningEffort, 'medium');
      expect(changes, greaterThan(0));
      expect(find.text('Reasoning effort'), findsOneWidget);
      expect(find.text('Thinking budget (tokens)'), findsOneWidget);
    });

    testWidgets('the effort dropdown writes the chosen value', (tester) async {
      final preset = Preset.create()
        ..thinking = true
        ..reasoningEffort = 'medium';
      await tester.pumpWidget(host(
        AdvancedSection(preset: preset, onChanged: () {}),
      ));

      await tester.ensureVisible(find.text('Medium'));
      await tester.tap(find.text('Medium'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('High').last);
      await tester.pumpAndSettle();

      expect(preset.reasoningEffort, 'high');
    });

    testWidgets('an imported effort we do not offer falls back to the default',
        (tester) async {
      // A dropdown whose value is absent from its items throws, so this guards a
      // real crash on an imported preset.
      final preset = Preset.create()
        ..thinking = true
        ..reasoningEffort = 'xhigh';
      await tester.pumpWidget(host(
        AdvancedSection(preset: preset, onChanged: () {}),
      ));

      expect(tester.takeException(), isNull);
      expect(find.text('Model default'), findsOneWidget);
    });

    testWidgets('the tag fields start on the standard pair and are editable',
        (tester) async {
      final preset = Preset.create();
      await tester.pumpWidget(host(
        AdvancedSection(preset: preset, onChanged: () {}),
      ));

      expect(find.text('Thinking tags'), findsOneWidget);
      final start = find.byKey(const Key('thinkStartTag'));
      final end = find.byKey(const Key('thinkEndTag'));
      expect(
        tester.widget<TextField>(find.descendant(
            of: start, matching: find.byType(TextField))).controller!.text,
        '<think>',
      );
      expect(
        tester.widget<TextField>(find.descendant(
            of: end, matching: find.byType(TextField))).controller!.text,
        '</think>',
      );

      await tester.ensureVisible(start);
      await tester.enterText(start, '<thinking>');
      await tester.pump();
      expect(preset.thinkStartTag, '<thinking>');
    });
  });

  group('use model max context if known', () {
    testWidgets('names the limit it resolved for a known model',
        (tester) async {
      final preset = Preset.create()..useMaxContext = true;
      await tester.pumpWidget(host(
        GeneralSection(preset: preset, onChanged: () {}, model: 'gpt-4o'),
      ));

      expect(find.text('Using 128,000 tokens for gpt-4o.'), findsOneWidget);
    });

    testWidgets('says so when the model has no known limit', (tester) async {
      final preset = Preset.create()..useMaxContext = true;
      await tester.pumpWidget(host(
        GeneralSection(preset: preset, onChanged: () {}, model: 'my-finetune'),
      ));

      expect(
        find.text('No known limit for my-finetune — using the value above.'),
        findsOneWidget,
      );
    });

    testWidgets('explains itself while switched off', (tester) async {
      final preset = Preset.create();
      await tester.pumpWidget(host(
        GeneralSection(preset: preset, onChanged: () {}, model: 'gpt-4o'),
      ));

      expect(
        find.text('Prefer the model\'s own limit over the value above.'),
        findsOneWidget,
      );
    });
  });
}
