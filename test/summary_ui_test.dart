import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/models/summary.dart';
import 'package:maichat/screens/summary/summary_edit_screen.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart' hide Provider;
import 'package:shared_preferences/shared_preferences.dart';

/// The memory page's start line: the warning that a chat brought its own history,
/// the one-tap fix, and the range a hand-written block declares for itself.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Future<AppState> boot({
    required int messages,
    ChatSummary? summary,
  }) async {
    final state = AppState();
    await state.init();
    await state.addProvider(Provider(
      id: 'p',
      name: 'local',
      kind: ProviderKind.openai,
      baseUrl: 'https://host.tld/v1',
      model: 'm',
      apiKey: 'k',
    ));
    state.active.messages.clear();
    for (var i = 0; i < messages; i++) {
      state.active.messages.add(ChatMessage(
          role: i.isEven ? 'user' : 'assistant', content: 'turn $i'));
    }
    state.active.summary = summary ??
        ChatSummary(
          enabled: true,
          interval: 30,
          method: SummaryMethod.incremental,
          baseIndex: 0,
        );
    return state;
  }

  Widget host(AppState state) => ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          home: SummaryEditScreen(conversationId: state.active.id),
        ),
      );

  /// The number in the "Already summarised up to" field. Its fold has to be open
  /// for the field to exist at all.
  Future<String> startLine(WidgetTester tester) async {
    await tester.tap(find.text('Configuration'));
    await tester.pumpAndSettle();
    return tester
        .widget<TextField>(find.ancestor(
          of: find.text('Already summarised up to'),
          matching: find.byType(TextField),
        ))
        .controller!
        .text;
  }

  testWidgets('a chat that arrived with a history says so, and can be fixed',
      (tester) async {
    final state = await boot(messages: 2000);
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    expect(find.textContaining('would summarise all of them'), findsOne);
    expect(find.textContaining('about 66 requests'), findsOne);

    await tester.tap(find.text('Start at 2000'));
    await tester.pumpAndSettle();

    // The warning answers to the field, so it goes as soon as the line moves —
    // before anything is saved.
    expect(find.textContaining('would summarise all of them'), findsNothing);
    expect(await startLine(tester), '2000');

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(state.active.summary!.baseIndex, 2000);
    expect(state.summaryCoverage(state.active.id), 2000);
  });

  testWidgets('a short chat is left alone', (tester) async {
    final state = await boot(messages: 12);
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    expect(find.textContaining('would summarise all of them'), findsNothing);
  });

  testWidgets('the warning stays away once a block declares its range',
      (tester) async {
    final state = await boot(
      messages: 2000,
      summary: ChatSummary(
        enabled: true,
        interval: 30,
        method: SummaryMethod.incremental,
        baseIndex: 0,
        segments: [
          SummarySegment(
            id: 'pasted',
            content: 'the story so far',
            manual: true,
            endIndex: 2000,
          ),
        ],
      ),
    );
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    expect(find.textContaining('would summarise all of them'), findsNothing);
    expect(find.text('Covers messages 1–2000'), findsOne);
  });

  testWidgets('a hand-written block declares what it covers', (tester) async {
    final state = await boot(messages: 2000);
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Write your own'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'to'), '1350');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(state.active.summary!.segments.single.endIndex, 1350);
    expect(state.summaryCoverage(state.active.id), 1350);
  });

  testWidgets('the generated blocks can be cleared in one go', (tester) async {
    final state = await boot(
      messages: 2000,
      summary: ChatSummary(
        enabled: true,
        interval: 30,
        method: SummaryMethod.incremental,
        baseIndex: 1900,
        lastSummarizedIndex: 1960,
        segments: [
          SummarySegment(id: 'g1', content: 'auto one', endIndex: 1930),
          SummarySegment(id: 'mine', content: 'my note', manual: true),
          SummarySegment(id: 'g2', content: 'auto two', endIndex: 1960),
        ],
      ),
    );
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Clear 2 generated'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(state.active.summary!.segments.map((s) => s.id), ['mine']);
    expect(state.active.summary!.baseIndex, 1900);
    expect(find.textContaining('Clear'), findsNothing);
  });
}
