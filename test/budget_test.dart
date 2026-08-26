import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/budget.dart';
import 'package:maichat/models/model_pricing.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/models/usage.dart';
import 'package:maichat/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Budgets: what counts as spent, and when a send is refused.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Provider withBudget(Budget budget, {List<ModelPrice> prices = const []}) =>
      Provider(
        id: 'p1',
        name: 'Test',
        kind: ProviderKind.openai,
        baseUrl: 'https://example.test/v1',
        model: 'gpt-4o',
        prices: prices,
        budgets: <Budget>[budget],
      );

  Future<AppState> ready() async {
    final state = AppState();
    await state.init();
    return state;
  }

  test('a limit of nothing is never enforced', () async {
    final state = await ready();
    final provider = withBudget(const Budget(id: 'b', limit: 0, block: true));
    await state.addProvider(provider);
    expect(state.blockingBudget(provider, 'gpt-4o'), isNull);
  });

  test('a non-blocking budget never refuses a send', () async {
    final state = await ready();
    const price = ModelPrice(model: 'gpt-4o', input: 1000000, output: 1000000);
    final provider = withBudget(
      const Budget(id: 'b', limit: 0.01),
      prices: const <ModelPrice>[price],
    );
    await state.addProvider(provider);
    state.recordUsage(
      provider,
      'gpt-4o',
      const TokenUsage(inputTokens: 1000000, outputTokens: 1000000),
    );
    // Well past the ceiling, but the budget only warns.
    expect(state.budgetSpend(provider, provider.budgets.single), greaterThan(0.01));
    expect(state.blockingBudget(provider, 'gpt-4o'), isNull);
  });

  test('a blocking budget refuses once the ceiling is reached', () async {
    final state = await ready();
    const price = ModelPrice(model: 'gpt-4o', input: 10, output: 10);
    final provider = withBudget(
      const Budget(id: 'b', limit: 5, block: true),
      prices: const <ModelPrice>[price],
    );
    await state.addProvider(provider);

    expect(state.blockingBudget(provider, 'gpt-4o'), isNull);

    // 1M in + 1M out at $10/M each = $20, past a $5 ceiling.
    state.recordUsage(
      provider,
      'gpt-4o',
      const TokenUsage(inputTokens: 1000000, outputTokens: 1000000),
    );

    final blocked = state.blockingBudget(provider, 'gpt-4o');
    expect(blocked, isNotNull);
    expect(blocked!.id, 'b');
  });

  test('a token budget counts tokens, price or no price', () async {
    final state = await ready();
    final provider = withBudget(
      const Budget(
        id: 'b',
        metric: BudgetMetric.tokens,
        limit: 1000,
        block: true,
      ),
    );
    await state.addProvider(provider);
    state.recordUsage(
      provider,
      'gpt-4o',
      const TokenUsage(inputTokens: 800, outputTokens: 300),
    );
    expect(state.blockingBudget(provider, 'gpt-4o'), isNotNull);
  });

  test('a request budget counts replies', () async {
    final state = await ready();
    final provider = withBudget(
      const Budget(
        id: 'b',
        metric: BudgetMetric.requests,
        limit: 2,
        block: true,
      ),
    );
    await state.addProvider(provider);
    for (var i = 0; i < 2; i++) {
      state.recordUsage(
        provider,
        'gpt-4o',
        const TokenUsage(inputTokens: 1, outputTokens: 1),
      );
    }
    expect(state.blockingBudget(provider, 'gpt-4o'), isNotNull);
  });

  test('a per-model budget ignores spend on other models', () async {
    final state = await ready();
    final provider = withBudget(
      const Budget(
        id: 'b',
        model: 'gpt-4o',
        metric: BudgetMetric.tokens,
        limit: 100,
        block: true,
      ),
    );
    await state.addProvider(provider);
    state.recordUsage(
      provider,
      'gpt-4o-mini',
      const TokenUsage(inputTokens: 5000, outputTokens: 5000),
    );
    // Spent heavily, but not on the model the budget covers.
    expect(state.blockingBudget(provider, 'gpt-4o'), isNull);

    state.recordUsage(
      provider,
      'gpt-4o',
      const TokenUsage(inputTokens: 200, outputTokens: 0),
    );
    expect(state.blockingBudget(provider, 'gpt-4o'), isNotNull);
  });
}
