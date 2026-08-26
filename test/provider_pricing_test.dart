import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/model_pricing.dart';

void main() {
  group('cost maths', () {
    test('a per-million rate scales with the tokens used', () {
      const price = ModelPrice(model: 'gpt-4o', input: 2.5, output: 10);
      final cost = price.costOf(500000, 250000);
      expect(cost.input, closeTo(1.25, 1e-9));
      expect(cost.output, closeTo(2.5, 1e-9));
    });

    test('a per-request charge ignores how much came back', () {
      const price = ModelPrice(
        model: 'dalle',
        mode: PriceMode.perRequest,
        input: 0.04,
      );
      final cheap = price.costOf(10, 10);
      final dear = price.costOf(1000000, 1000000);
      expect(cheap.input, 0.04);
      expect(dear.input, 0.04);
      expect(dear.output, 0);
    });

    test('a price with nothing in it is not set', () {
      expect(const ModelPrice(model: 'x').isSet, isFalse);
      expect(const ModelPrice(model: 'x', input: 1).isSet, isTrue);
      expect(const ModelPrice(model: 'x', output: 1).isSet, isTrue);
    });
  });

  group('matching a model to a price', () {
    const prices = <ModelPrice>[
      ModelPrice(model: 'gpt-4', input: 30, output: 60),
      ModelPrice(model: 'gpt-4o-mini', input: 0.15, output: 0.6),
      ModelPrice(model: 'gpt-4o', input: 2.5, output: 10),
      ModelPrice(model: 'claude-sonnet', input: 3, output: 15),
    ];

    test('an exact id wins', () {
      expect(priceFor(prices, 'gpt-4o')?.input, 2.5);
    });

    test('the longest match wins, so a dated id does not fall to gpt-4', () {
      expect(priceFor(prices, 'gpt-4o-mini-2024-07-18')?.input, 0.15);
      expect(priceFor(prices, 'gpt-4o-2024-11-20')?.input, 2.5);
    });

    test('a gateway prefix is stripped before matching', () {
      expect(priceFor(prices, 'openai/gpt-4o')?.input, 2.5);
      expect(priceFor(prices, 'anthropic/claude-sonnet-4-5')?.input, 3);
    });

    test('a routing suffix is stripped too', () {
      expect(priceFor(prices, 'openai/gpt-4o:free')?.input, 2.5);
    });

    test('case does not matter', () {
      expect(priceFor(prices, 'GPT-4O')?.input, 2.5);
    });

    test('an unknown model is unpriced rather than free', () {
      expect(priceFor(prices, 'llama-3.1-70b'), isNull);
      expect(priceFor(prices, ''), isNull);
      expect(priceFor(const <ModelPrice>[], 'gpt-4o'), isNull);
    });

    test('a price row with a blank model never matches anything', () {
      expect(priceFor(const <ModelPrice>[ModelPrice(model: '')], 'gpt-4o'),
          isNull);
    });
  });

  group('storage', () {
    test('a price round trips', () {
      const price = ModelPrice(
        model: 'gpt-4o',
        mode: PriceMode.perRequest,
        input: 0.04,
        output: 0.5,
      );
      final restored = ModelPrice.fromJson(price.toJson());
      expect(restored, price);
    });

    test('an unknown stored mode falls back to per-million', () {
      expect(PriceMode.byName('nonsense'), PriceMode.perMillionTokens);
      expect(PriceMode.byName(null), PriceMode.perMillionTokens);
    });
  });
}
