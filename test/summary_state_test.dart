import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/models/summary.dart';
import 'package:maichat/services/summarizer.dart';
import 'package:maichat/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Records what a summary run asked for instead of calling a model. The bug this
/// file guards against was measured in requests — a chat imported with 2000
/// messages fired about a hundred — so the assertions are about how many arrive
/// here, not about what comes back.
class CountingSummarizer extends Summarizer {
  final List<SummaryRequest> requests = <SummaryRequest>[];

  @override
  Future<List<SummaryResult>> run({
    required Provider provider,
    required String systemPrompt,
    required int maxTokens,
    required List<SummaryRequest> requests,
  }) async {
    this.requests.addAll(requests);
    return [
      for (final r in requests)
        SummaryResult(
            startIndex: r.startIndex,
            endIndex: r.endIndex,
            text: 'condensed ${r.startIndex}-${r.endIndex}'),
    ];
  }
}

Provider _provider() => Provider(
      id: 'p',
      name: 'Test',
      kind: ProviderKind.openai,
      baseUrl: 'https://host.tld/v1',
      apiKey: 'k',
      model: 'm',
    );

Future<AppState> _state(CountingSummarizer summarizer) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final state = AppState(summarizer: summarizer);
  await state.init();
  await state.addProvider(_provider());
  return state;
}

/// Seeds [count] alternating turns straight onto the active chat — never through
/// `send()`, which would need a live client and a pumped clock.
void _seed(AppState state, int count) {
  for (var i = 0; i < count; i++) {
    state.active.messages.add(ChatMessage(
      role: i.isEven ? 'user' : 'assistant',
      content: 'turn $i',
    ));
  }
}

void main() {
  test('switching the memory on mid-chat starts it where the chat is', () async {
    final state = await _state(CountingSummarizer());
    _seed(state, 2000);

    await state.setSummaryEnabled(state.active.id, true);

    expect(state.active.summary!.baseIndex, 2000);
    expect(state.summaryCoverage(state.active.id), 2000);
  });

  test('switching it on for a fresh chat starts at the beginning', () async {
    final state = await _state(CountingSummarizer());

    await state.setSummaryEnabled(state.active.id, true);

    expect(state.active.summary!.baseIndex, 0);
  });

  test('toggling it off and on again leaves the start line alone', () async {
    final state = await _state(CountingSummarizer());
    _seed(state, 40);
    await state.setSummaryEnabled(state.active.id, true);
    _seed(state, 60);

    await state.setSummaryEnabled(state.active.id, false);
    await state.setSummaryEnabled(state.active.id, true);

    expect(state.active.summary!.baseIndex, 40,
        reason: 'moving it to 100 would orphan messages 41–100');
  });

  test('an imported chat with an older summary makes no requests', () async {
    // The bug as reported: a 2000-message chat whose config predates the start
    // line. Before the fix this fired about 67 condense requests on the next
    // reply, one per interval, from message 1.
    final summarizer = CountingSummarizer();
    final state = await _state(summarizer);
    _seed(state, 2000);
    state.active.summary = ChatSummary(
      enabled: true,
      interval: 30,
      method: SummaryMethod.incremental,
    );

    await state.maybeSummarize(state.active);

    expect(summarizer.requests, isEmpty);
    expect(state.active.summary!.baseIndex, 2000);
    expect(state.active.summary!.segments, isEmpty);
  });

  test('and then summarises forward from there, one window at a time', () async {
    final summarizer = CountingSummarizer();
    final state = await _state(summarizer);
    _seed(state, 2000);
    state.active.summary = ChatSummary(
      enabled: true,
      interval: 30,
      method: SummaryMethod.incremental,
    );
    await state.maybeSummarize(state.active);
    _seed(state, 30);

    await state.maybeSummarize(state.active);

    expect(summarizer.requests.length, 1);
    expect(summarizer.requests.single.startIndex, 2000);
    expect(summarizer.requests.single.endIndex, 2030);
    expect(state.active.summary!.segments.single.title, contains('2030'));
  });

  test('a chat that grew under its own memory still gets its history', () async {
    // The other side of the same decision: 40 messages with an interval of 30 is
    // a chat that has been summarising all along, not one that arrived with a
    // history, so messages 1–30 must still be condensed.
    final summarizer = CountingSummarizer();
    final state = await _state(summarizer);
    _seed(state, 40);
    state.active.summary = ChatSummary(
      enabled: true,
      interval: 30,
      method: SummaryMethod.incremental,
    );

    await state.maybeSummarize(state.active);

    expect(state.active.summary!.baseIndex, 0);
    expect(summarizer.requests.length, 1);
    expect(summarizer.requests.single.startIndex, 0);
    expect(summarizer.requests.single.endIndex, 30);
  });

  test('a pasted summary that says what it covers is believed', () async {
    final summarizer = CountingSummarizer();
    final state = await _state(summarizer);
    _seed(state, 2000);
    state.active.summary = ChatSummary(
      enabled: true,
      interval: 30,
      method: SummaryMethod.incremental,
      baseIndex: 0,
      segments: [
        SummarySegment(
          id: 'pasted',
          content: 'everything that happened up to now',
          manual: true,
          startIndex: 0,
          endIndex: 2000,
        ),
      ],
    );

    await state.summarizeNow(state.active.id);

    expect(summarizer.requests, isEmpty);
    expect(state.summaryCoverage(state.active.id), 2000);
  });

  test('clearing the generated blocks keeps the notes and the line', () async {
    final state = await _state(CountingSummarizer());
    _seed(state, 2000);
    state.active.summary = ChatSummary(
      enabled: true,
      interval: 30,
      baseIndex: 1900,
      lastSummarizedIndex: 1960,
      segments: [
        SummarySegment(id: 'g1', content: 'auto one', endIndex: 1930),
        SummarySegment(id: 'mine', content: 'my note', manual: true),
        SummarySegment(id: 'g2', content: 'auto two', endIndex: 1960),
      ],
    );

    await state.clearGeneratedSummary(state.active.id);

    final cfg = state.active.summary!;
    expect(cfg.segments.map((s) => s.id), ['mine']);
    expect(cfg.lastSummarizedIndex, 0);
    expect(cfg.baseIndex, 1900);
    expect(state.summaryCoverage(state.active.id), 1900);
  });

  test('Re-summarise walks the history and keeps the line', () async {
    final summarizer = CountingSummarizer();
    final state = await _state(summarizer);
    _seed(state, 90);
    state.active.summary = ChatSummary(
      enabled: true,
      interval: 30,
      method: SummaryMethod.incremental,
      baseIndex: 60,
    );

    await state.resummarize(state.active.id);

    expect(summarizer.requests.map((r) => (r.startIndex, r.endIndex)),
        [(0, 30), (30, 60), (60, 90)]);
    expect(state.active.summary!.baseIndex, 60,
        reason: 'the rebuild overrides the line, it does not erase it');
  });
}
