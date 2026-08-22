import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/screens/presets/preset_controls.dart';

/// A [PresetSlider]'s numeric box must persist what is typed even when the user
/// never presses the keyboard "done" action — they just type a number and then
/// tap Save (or anywhere else), which merely blurs the field. Before the fix
/// only slider-dragged values were kept: typing 92000 into the context box and
/// hitting Save silently dropped it.
void main() {
  Widget host(void Function(double) onChanged) => MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              PresetSlider(
                label: 'Context size',
                value: 4096,
                min: 16,
                max: 200000,
                integer: true,
                onChanged: onChanged,
              ),
              const TextField(key: Key('elsewhere')),
            ],
          ),
        ),
      );

  testWidgets('a typed value commits when the field loses focus', (tester) async {
    double? committed;
    await tester.pumpWidget(host((v) => committed = v));

    // Type into the slider's numeric box (the first field on screen).
    await tester.enterText(find.byType(TextField).first, '92000');
    expect(committed, isNull, reason: 'nothing committed while still editing');

    // Move focus away — as tapping a Save button elsewhere would.
    await tester.tap(find.byKey(const Key('elsewhere')));
    await tester.pump();

    expect(committed, 92000.0);
  });

  testWidgets('a typed value is clamped into range on blur', (tester) async {
    double? committed;
    await tester.pumpWidget(host((v) => committed = v));

    await tester.enterText(find.byType(TextField).first, '9999999');
    await tester.tap(find.byKey(const Key('elsewhere')));
    await tester.pump();

    expect(committed, 200000.0);
  });
}
