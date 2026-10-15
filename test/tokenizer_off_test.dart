import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/screens/settings/tokenizer_settings_page.dart';
import 'package:maichat/services/token_estimator.dart';
import 'package:maichat/services/tokenizer.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart' hide Provider;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const heuristic = HeuristicTokenEstimator();
  const sample = 'The quick brown fox jumps over the lazy dog, twice over.';

  setUp(AppTokenizer.release);

  test('off counts with the estimate and builds no vocabulary', () {
    final tok = AppTokenizer(
      config: () => const TokenizerConfig(kind: TokenizerKind.none),
      model: () => 'gpt-4o',
    );
    expect(tok.usesBpe, isFalse);
    expect(tok.isApproximate, isTrue);
    expect(tok.estimate(sample), heuristic.estimate(sample));
    expect(tok.estimate(''), 0);
    expect(AppTokenizer.isWarm(BpeEncoding.o200k), isFalse);
    expect(AppTokenizer.isWarm(BpeEncoding.cl100k), isFalse);
  });

  test('the choice is stored and read back', () {
    const off = TokenizerConfig(kind: TokenizerKind.none);
    expect(TokenizerConfig.fromJson(off.toJson()), off);
  });

  test('a store with tokenizers off launches without building one', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.tokenizer': jsonEncode({'kind': 'none'}),
    });
    final state = AppState();
    await state.init();
    // init's warm-up is a microtask in tests; let it run.
    await Future<void>.delayed(Duration.zero);
    expect(state.tokenizerConfig.kind, TokenizerKind.none);
    expect(AppTokenizer.isWarm(BpeEncoding.o200k), isFalse);
    expect(AppTokenizer.isWarm(BpeEncoding.cl100k), isFalse);
    expect(state.estimateTokens(sample), heuristic.estimate(sample));
    expect(state.tokenizerIsApproximate, isTrue);
  });

  test('switching off releases what was built', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.tokenizer': jsonEncode(
        {'kind': 'custom', 'customEncoding': 'cl100k'},
      ),
    });
    final state = AppState();
    await state.init();
    expect(state.estimateTokens('hello world'), 2);
    expect(AppTokenizer.isWarm(BpeEncoding.cl100k), isTrue);
    await state.updateTokenizerConfig(
      state.tokenizerConfig.copyWith(kind: TokenizerKind.none),
    );
    expect(AppTokenizer.isWarm(BpeEncoding.cl100k), isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(jsonDecode(prefs.getString('tokenizer')!)['kind'], 'none');
  });

  testWidgets('the settings switch turns local tokenizers off and back on',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.tokenizer': jsonEncode({'kind': 'anthropic'}),
    });
    final state = AppState();
    await state.init();
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const MaterialApp(home: TokenizerSettingsPage()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Token counter'), findsOneWidget);

    await tester.tap(find.text('Local tokenizers'));
    await tester.pumpAndSettle();
    expect(state.tokenizerConfig.kind, TokenizerKind.none);
    // The counter picker goes away while there is no counter to pick.
    expect(find.text('Token counter'), findsNothing);
    expect(find.textContaining('estimate'), findsWidgets);

    await tester.tap(find.text('Local tokenizers'));
    await tester.pumpAndSettle();
    // Back to the counter that was in use.
    expect(state.tokenizerConfig.kind, TokenizerKind.anthropic);
  });
}
