import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/services/tokenizer.dart';
import 'package:tiktoken_tokenizer_gpt4o_o1/tiktoken_tokenizer_gpt4o_o1.dart';

void main() {
  group('encoding selection', () {
    test('OpenAI models map to the right BPE', () {
      expect(encodingForOpenAiModel('gpt-4'), BpeEncoding.cl100k);
      expect(encodingForOpenAiModel('gpt-3.5-turbo'), BpeEncoding.cl100k);
      expect(encodingForOpenAiModel('gpt-4o'), BpeEncoding.o200k);
      expect(encodingForOpenAiModel('gpt-4o-mini'), BpeEncoding.o200k);
      expect(encodingForOpenAiModel('o1-preview'), BpeEncoding.o200k);
      expect(encodingForOpenAiModel('o3-mini'), BpeEncoding.o200k);
      expect(encodingForOpenAiModel('gpt-4.1'), BpeEncoding.o200k);
    });

    test('AppTokenizer resolves encoding by kind + model', () {
      var config = const TokenizerConfig(kind: TokenizerKind.openai);
      var model = 'gpt-4';
      final tok = AppTokenizer(config: () => config, model: () => model);

      expect(tok.activeEncoding(), BpeEncoding.cl100k);
      model = 'gpt-4o';
      expect(tok.activeEncoding(), BpeEncoding.o200k);

      config = const TokenizerConfig(kind: TokenizerKind.anthropic);
      expect(tok.activeEncoding(), BpeEncoding.o200k); // Claude proxy
      expect(tok.isApproximate, isTrue);

      config = const TokenizerConfig(
          kind: TokenizerKind.custom, customEncoding: BpeEncoding.cl100k);
      expect(tok.activeEncoding(), BpeEncoding.cl100k);
      expect(tok.isApproximate, isFalse);
    });
  });

  group('counting', () {
    test('estimate matches a direct BPE encode and is > heuristic-free', () {
      const text = 'The quick brown fox jumps over the lazy dog.';
      var config = const TokenizerConfig(kind: TokenizerKind.openai);
      final tok = AppTokenizer(config: () => config, model: () => 'gpt-4o');

      final direct = Tiktoken.getEncoder(TiktokenEncodingType.o200k_base)
          .encodeOrdinary(text)
          .length;
      expect(tok.estimate(text), direct);
      expect(tok.estimate(text), greaterThan(0));
      // A real tokenizer is not the chars/4 heuristic: this sentence is 44
      // chars but well under 11 tokens.
      expect(tok.estimate(text), lessThan(text.length ~/ 4 + 5));
    });

    test('empty text is zero', () {
      final tok = AppTokenizer(
          config: () => const TokenizerConfig(), model: () => 'gpt-4o');
      expect(tok.estimate(''), 0);
    });

    test('handles text that looks like a special token without throwing', () {
      final tok = AppTokenizer(
          config: () => const TokenizerConfig(), model: () => 'gpt-4o');
      expect(() => tok.estimate('<|endoftext|> hi'), returnsNormally);
      expect(tok.estimate('<|endoftext|> hi'), greaterThan(0));
    });
  });

  test('counts are remembered per encoding, never across them', () {
    // The counts are memoised because a send re-counts the whole prompt and a
    // real BPE pass over a full context window is hundreds of milliseconds. The
    // same text counts differently under the two encodings, so the thing worth
    // pinning is that the memo is keyed by encoding and a switch is honoured.
    AppTokenizer.clearCountCache();
    const text = 'The quick brown fox jumps over the lazy dog, twice over.';
    var model = 'gpt-4o'; // o200k
    final tok = AppTokenizer(
        config: () => const TokenizerConfig(kind: TokenizerKind.openai),
        model: () => model);

    final o200k = tok.estimate(text);
    expect(tok.estimate(text), o200k, reason: 'a second look agrees');

    model = 'gpt-4'; // cl100k
    final cl100k = tok.estimate(text);
    expect(cl100k,
        Tiktoken.getEncoder(TiktokenEncodingType.cl100k_base)
            .encodeOrdinary(text)
            .length);
    expect(tok.estimate(text), cl100k);

    model = 'gpt-4o';
    expect(tok.estimate(text), o200k,
        reason: 'switching back returns the o200k count, not the cached cl100k');
  });

  test('TokenizerConfig round trips', () {
    const original = TokenizerConfig(
        kind: TokenizerKind.custom, customEncoding: BpeEncoding.cl100k);
    final restored = TokenizerConfig.fromJson(original.toJson());
    expect(restored, original);
    // Defaults on empty json.
    expect(TokenizerConfig.fromJson(const {}),
        const TokenizerConfig(kind: TokenizerKind.openai));
  });
}
