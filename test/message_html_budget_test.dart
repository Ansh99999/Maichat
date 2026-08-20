import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/widgets/message_html.dart';

/// Guards the chat-open freeze fix: a real device measured a ~600ms UI-thread
/// build when a chat opened and a whole screenful of HTML message bubbles parsed
/// in a single frame. [MessageHtml] now caps how many expensive flutter_html
/// renders happen per frame and spreads the rest over the next frames, so no one
/// frame carries the whole screenful.
void main() {
  const style = HtmlMessageStyle(
    base: Color(0xFF000000),
    emphasis: Color(0xFF222222),
    quote: Color(0xFF444444),
    codeBackground: Color(0xFFEEEEEE),
    codeForeground: Color(0xFF000000),
    link: Color(0xFF0000FF),
    fontSize: 14,
  );

  testWidgets('a screenful of HTML messages does not all parse in one frame',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: Column(
            children: [
              for (var i = 0; i < 8; i++)
                buildMessageHtml('<b>message $i</b>', style),
            ],
          ),
        ),
      ),
    ));

    // First frame: the per-frame budget caps the expensive renders; the rest
    // show a cheap text stand-in. So not all eight are full HTML yet — that is
    // exactly what keeps the open off the freeze cliff.
    await tester.pump();
    expect(find.byType(Html).evaluate().length, lessThan(8),
        reason: 'a screenful must not all parse in a single frame');

    // They fill in over the next frames.
    await tester.pumpAndSettle();
    expect(find.byType(Html), findsNWidgets(8),
        reason: 'every message upgrades to full HTML shortly after');
  });

  testWidgets('a single HTML message renders immediately (no placeholder)',
      (tester) async {
    // The budget only bites under load. One message — the streaming case —
    // must render straight to HTML with no deferral, so a reply never flashes.
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: buildMessageHtml('<b>hello</b>', style)),
    ));
    await tester.pump();
    expect(find.byType(Html), findsOneWidget,
        reason: 'light load renders immediately, no placeholder frame');
  });
}
