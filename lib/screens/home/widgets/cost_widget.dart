import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../../models/budget.dart';
import '../../../models/home_layout.dart';
import '../../../models/provider.dart' as app_provider;
import '../../../state/app_state.dart';
import '../../providers/provider_edit_screen.dart';
import '../../providers/providers_screen.dart';
import '../home_spec.dart';

/// What a provider has cost, and what is left of its budget.
class CostSpec extends HomeWidgetSpec {
  const CostSpec();

  @override
  HomeWidgetKind get kind => HomeWidgetKind.cost;

  @override
  String get title => 'Cost';

  @override
  String get description => 'Quota remaining and spend on a provider';

  @override
  IconData get icon => Icons.payments_outlined;

  @override
  ({int w, int h}) get minSpan => (w: 2, h: 1);

  @override
  List<HomeOption> options(HomeTile tile) => [
        HomePickOption(
          key: 'providerId',
          label: 'Provider',
          pick: HomePickKind.provider,
          allowNone: true,
          noneLabel: 'The active provider',
        ),
        const HomeChoiceOption(
          key: 'period',
          label: 'Period',
          choices: {
            'today': 'Today',
            'week': 'This week',
            'month': 'This month',
            'all': 'All time',
          },
        ),
      ];

  @override
  String describe(BuildContext context, HomeTile tile) {
    final period = tile.str('period') ?? 'month';
    return 'Cost · ${_periodLabel(period)}';
  }

  static String _periodLabel(String period) => switch (period) {
        'today' => 'Today',
        'week' => 'This week',
        'all' => 'All time',
        _ => 'This month',
      };

  static DateTime? _since(String period) {
    final now = DateTime.now();
    return switch (period) {
      'today' => DateTime(now.year, now.month, now.day),
      'week' => now.subtract(const Duration(days: 7)),
      'all' => null,
      _ => DateTime(now.year, now.month, 1),
    };
  }

  @override
  Widget build(BuildContext context, HomeTileContext tile) {
    final state = context.watch<AppState>();
    final providerId = tile.tile.str('providerId');
    final period = tile.tile.str('period') ?? 'month';
    final provider = providerId == null
        ? state.activeProvider
        : state.providerById(providerId);

    if (provider == null) {
      return HomeCard(
        semanticLabel: 'Cost, no provider configured',
        onTap: tile.editing
            ? null
            : () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const ProvidersScreen()),
                ),
        alignment: Alignment.center,
        child: Text(
          'No provider yet',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );
    }

    final since = _since(period);
    final totals = state.usage.totals(provider.id, since: since);
    final budget = _budgetFor(provider, period);

    return HomeCard(
      semanticLabel: '${provider.displayName}, ${_periodLabel(period)} cost',
      onTap: tile.editing
          ? null
          : () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ProviderEditScreen(providerId: provider.id),
                ),
              ),
      builder: (context, inner) {
        final theme = Theme.of(context);
        final hasCost = totals.totalCost > 0;
        final spendText = hasCost
            ? '\$${totals.totalCost.toStringAsFixed(2)}'
            : (totals.totalTokens > 0 ? '${_compact(totals.totalTokens)} tokens' : '—');
        final labelStyle = theme.textTheme.labelMedium
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
        final bigStyle = (inner.height >= 64
                ? theme.textTheme.headlineSmall
                : theme.textTheme.titleLarge)
            ?.copyWith(fontWeight: FontWeight.w700);
        final smallStyle = theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
        var room = inner.height - homeLineHeight(context, bigStyle);
        bool take(double h) {
          if (room < h) return false;
          room -= h;
          return true;
        }

        final showBudget = budget != null &&
            budget.isSet &&
            take(homeLineHeight(context, theme.textTheme.labelSmall) + 18);
        final showLabel = take(homeLineHeight(context, labelStyle) + 2);
        final showDetail = take(homeLineHeight(context, smallStyle) + 2);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showLabel)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  '${provider.displayName} · ${_periodLabel(period).toLowerCase()}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: labelStyle,
                ),
              ),
            Text(spendText, maxLines: 1, overflow: TextOverflow.ellipsis, style: bigStyle),
            if (showDetail)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '${totals.requests} ${totals.requests == 1 ? 'reply' : 'replies'}'
                  '${hasCost ? ' · ${_compact(totals.totalTokens)} tokens' : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: smallStyle,
                ),
              ),
            if (showBudget) ...[
              const SizedBox(height: 8),
              _BudgetBar(provider: provider, budget: budget, state: state),
            ],
          ],
        );
      },
    );
  }

  /// 12 345 → "12.3k", the way a glance wants a number.
  static String _compact(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 10000) return '${(n / 1000).toStringAsFixed(0)}k';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '$n';
  }

  /// A budget matching the period when one is set that way, else the first set
  /// budget on the provider.
  Budget? _budgetFor(app_provider.Provider provider, String period) {
    if (provider.budgets.isEmpty) return null;
    final wantPeriod = switch (period) {
      'today' => BudgetPeriod.daily,
      'week' => BudgetPeriod.weekly,
      'all' => BudgetPeriod.total,
      _ => BudgetPeriod.monthly,
    };
    for (final b in provider.budgets) {
      if (b.isSet && b.period == wantPeriod) return b;
    }
    for (final b in provider.budgets) {
      if (b.isSet) return b;
    }
    return null;
  }
}

class _BudgetBar extends StatelessWidget {
  const _BudgetBar({
    required this.provider,
    required this.budget,
    required this.state,
  });

  final app_provider.Provider provider;
  final Budget budget;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final spent = state.budgetSpend(provider, budget);
    final fraction = budget.fractionOf(spent) ?? 0;
    final exceeded = budget.isExceededBy(spent);
    final unit = budget.metric.name == 'cost' ? '\$' : '';
    final remaining = (budget.limit - spent).clamp(0, budget.limit);
    final remainingText = budget.metric.name == 'cost'
        ? '\$${remaining.toStringAsFixed(2)} left of \$${budget.limit.toStringAsFixed(2)}'
        : '${remaining.toStringAsFixed(0)}$unit left of ${budget.limit.toStringAsFixed(0)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            value: fraction,
            minHeight: 8,
            color: exceeded ? theme.colorScheme.error : theme.colorScheme.primary,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          remainingText,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelSmall?.copyWith(
            color: exceeded ? theme.colorScheme.error : theme.colorScheme.outline,
          ),
        ),
      ],
    );
  }
}
