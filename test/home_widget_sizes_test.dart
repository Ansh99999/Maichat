import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/home_layout.dart';
import 'package:maichat/screens/home/home_spec.dart';
import 'package:maichat/screens/home/home_widgets.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart' hide Provider;
import 'package:shared_preferences/shared_preferences.dart';

/// Every widget at every span, at the cell sizes of the smallest and densest
/// grids a 412 × 915 phone gets, at normal and large text: nothing may
/// overflow. Seeded with a chat, a character, a provider and a picture so the
/// filled layouts are drawn, not just the empty states.
void main() {
  const seed = <String, Object>{
    'flutter.conversations':
        '[{"id":"1","title":"A rather long chat title for a small tile",'
            '"updatedAt":"2026-01-01T00:00:00.000","pinned":true,'
            '"characterId":"c1",'
            '"messages":[{"role":"assistant","content":"A long last line that '
            'has to wrap or be cut short when the tile is small."}]}]',
    'flutter.characters':
        '[{"id":"c1","name":"Mira of the Lanterns","starred":true}]',
    'flutter.providers':
        '{"providers":[{"id":"p","name":"A provider with a long name",'
            '"kind":"openai","baseUrl":"https://h/v1","apiKey":"k",'
            '"model":"some-very-long-model-name-2026"}],"activeId":"p"}',
    'flutter.gallery':
        '[{"id":"g","image":"https://example.invalid/a.png","title":"A"}]',
    'flutter.folders':
        '[{"id":"f1","name":"A folder with a rather long name","characterIds":["c1"]}]',
    'flutter.homeNotes':
        '[{"id":"n1","title":"A note with a long title to test wrapping",'
            '"body":"Some body text that is long enough to wrap across '
            'several lines when the tile is small.",'
            '"updatedAt":"2026-01-01T00:00:00.000"}]',
  };

  // Cell sizes (width, height): a 3×4 grid and an 8×10 grid on a phone,
  // after page padding and the tile gutter.
  const cells = <(String, double, double)>[
    ('3x4', 130, 190),
    ('8x10', 49, 76),
  ];
  const spans = <(int, int)>[
    (1, 1), (2, 1), (1, 2), (2, 2), (3, 1), (4, 1), (3, 2), (4, 3),
  ];

  for (final kind in HomeWidgetKind.values) {
    for (final (grid, cw, ch) in cells) {
      for (final scale in const [1.0, 1.5]) {
        testWidgets('${kind.name} on a $grid grid at ×$scale text',
            (tester) async {
          SharedPreferences.setMockInitialValues(seed);
          final state = AppState();
          await state.init();
          for (final (w, h) in spans) {
            final tile = HomeTile(id: 't', kind: kind, x: 0, y: 0, w: w, h: h);
            final layout = HomeLayout(
              columns: 8,
              rows: 10,
              pages: [HomePage(id: 'p', tiles: [tile])],
            );
            final size = Size(w * cw - 12, h * ch - 12);
            await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
              value: state,
              child: MaterialApp(
                home: MediaQuery(
                  data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                  child: Scaffold(
                    body: Center(
                      child: SizedBox.fromSize(
                        size: size,
                        child: Builder(
                          builder: (c) => specFor(kind).build(
                            c,
                            HomeTileContext(
                              tile: tile,
                              size: size,
                              layout: layout,
                              editing: false,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ));
            await tester.pump();
            expect(tester.takeException(), isNull, reason: '${w}x$h');
          }
        });
      }
    }
  }
}
