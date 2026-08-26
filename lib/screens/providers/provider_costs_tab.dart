import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/budget.dart';
import '../../models/provider.dart';
import '../../models/usage.dart';
import '../../state/app_state.dart';
import 'provider_draft.dart';
import 'usage_charts.dart';

/// What this provider has actually cost, and the ceilings set on it.
///
/// Reads the *saved* provider rather than the draft: usage was recorded against
/// prices as they stood at the time, and a rate being typed in the Advanced tab
/// has not been charged against anything yet. Showing the draft's numbers here
/// would imply a bill that was never sent.
class ProviderCostsTab extends StatefulWidget {
  const ProviderCostsTab({
    super.key,
    required this.draft,
    required this.saved,
    required this.onChanged,
  });

  final ProviderDraft draft;

  /// The provider as stored, or null when it has not been saved yet.
  final Provider? saved;

  final VoidCallback onChanged;

  @override
  State<ProviderCostsTab> createState() => _ProviderCostsTabState();
}

class _ProviderCostsTabState extends State<ProviderCostsTab> {
  UsageGranularity _granularity = UsageGranularity.daily;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final id = widget.draft.id;
    final totals = state.usage.totals(id);
    final rows = state.usage.byModel(id);

    if (totals.requests == 0) {
      return _EmptyCosts(unsaved: widget.saved == null);
    }

    return ListView(
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        96 + MediaQuery.paddingOf(context).bottom,
      ),
      children: [
        _TotalsHeader(totals: totals),
        const SizedBox(height: 8),
        if (totals.hasEstimates) _estimateNote(totals),
        _label('BY MODEL'),
        for (final row in rows) _ModelRow(model: row.model, bucket: row.bucket),
        _label('USAGE OVER TIME'),
        _granularityPicker(),
        const SizedBox(height: 8),
        UsageOverTimeChart(
          series: state.usage.series(
            id,
            granularity: _granularity,
            count: _sliceCount(_granularity),
          ),
          granularity: _granularity,
        ),
        const SizedBox(height: 16),
        _label('TOKENS BY MODEL'),
        TokensByModelChart(rows: rows),
        _label('BUDGETS'),
        _budgets(state),
      ],
    );
  }

  /// How many slices each granularity shows: a fortnight of days, a day of
  /// hours, a season of weeks, a year of months.
  static int _sliceCount(UsageGranularity granularity) =>
      switch (granularity) {
        UsageGranularity.hourly => 24,
        UsageGranularity.daily => 14,
        UsageGranularity.weekly => 12,
        UsageGranularity.monthly => 12,
      };

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
        child: Text(
          text,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
        ),
      );

  Widget _estimateNote(UsageBucket totals) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${totals.estimatedRequests} of ${totals.requests} '
              'replies were counted by this app rather than reported by the '
              'host, so those totals are close rather than exact.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.4,
                  ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _granularityPicker() => SegmentedButton<UsageGranularity>(
        showSelectedIcon: false,
        segments: [
          for (final value in UsageGranularity.values)
            ButtonSegment<UsageGranularity>(
              value: value,
              label: Text(value.label),
            ),
        ],
        selected: <UsageGranularity>{_granularity},
        onSelectionChanged: (next) =>
            setState(() => _granularity = next.first),
        style: const ButtonStyle(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      );

  /// Budgets need a saved provider to live on, since they are stored as a
  /// provider field rather than in the ledger.
  Widget _budgets(AppState state) {
    final saved = widget.saved;
    if (saved == null) {
      return Text(
        'Save this provider first, then you can set a budget on it.',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final budget in saved.budgets)
          _BudgetCard(
            budget: budget,
            spent: state.budgetSpend(saved, budget),
            onEdit: () => _editBudget(state, saved, budget),
            onDelete: () => state.deleteBudget(saved, budget.id),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => _editBudget(state, saved, null),
            icon: const Icon(Icons.add),
            label: Text(saved.budgets.isEmpty ? 'Set a budget' : 'Add another'),
          ),
        ),
      ],
    );
  }

  Future<void> _editBudget(
    AppState state,
    Provider saved,
    Budget? existing,
  ) async {
    final models = <String>{
      for (final row in state.usage.byModel(saved.id)) row.model,
      if (saved.model.trim().isNotEmpty) saved.model.trim(),
    }.toList()
      ..sort();
    final result = await showModalBottomSheet<Budget>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => _BudgetSheet(budget: existing, models: models),
    );
    if (result == null) return;
    await state.saveBudget(saved, result);
  }
}

/// A currency amount, or an em dash where nothing is priced. Never "$0.00" for
/// an unpriced model — that would read as free rather than as unknown.
String formatCost(double cost, {bool priced = true}) {
  if (!priced) return '—';
  if (cost == 0) return r'$0.00';
  // Sub-cent totals are the normal case early on; rounding them to $0.00 makes
  // the whole tab look broken.
  if (cost < 0.01) return '<\$0.01';
  return '\$${cost.toStringAsFixed(2)}';
}

/// A token count in the shortest honest form: 1.2M, 48.5k, 900.
String formatTokens(int tokens) {
  if (tokens >= 1000000) {
    final millions = tokens / 1000000;
    return '${millions.toStringAsFixed(millions >= 10 ? 0 : 1)}M';
  }
  if (tokens >= 1000) {
    final thousands = tokens / 1000;
    return '${thousands.toStringAsFixed(thousands >= 10 ? 0 : 1)}k';
  }
  return '$tokens';
}

/// The headline: output above input (output is what you are usually paying for),
/// with the combined total under a rule.
class _TotalsHeader extends StatelessWidget {
  const _TotalsHeader({required this.totals});

  final UsageBucket totals;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final priced = totals.totalCost > 0;

    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Text(
                    '${formatTokens(totals.outputTokens)} tokens out',
                    style: text.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                Text(
                  formatCost(totals.costOut, priced: priced),
                  style:
                      text.titleLarge?.copyWith(fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${formatTokens(totals.inputTokens)} tokens in',
                    style: text.bodyMedium
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
                Text(
                  formatCost(totals.costIn, priced: priced),
                  style: text.bodyMedium
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
            const Divider(height: 24),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Total cost',
                    style:
                        text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                Text(
                  formatCost(totals.totalCost, priced: priced),
                  style: text.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: scheme.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${totals.requests} '
              'repl${totals.requests == 1 ? 'y' : 'ies'}'
              '${priced ? '' : ' · no prices set'}',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// One model's line in the breakdown: tokens and cost, in and out.
class _ModelRow extends StatelessWidget {
  const _ModelRow({required this.model, required this.bucket});

  final String model;
  final UsageBucket bucket;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final priced = bucket.totalCost > 0;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  model,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                formatCost(bucket.totalCost, priced: priced),
                style: text.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '${formatTokens(bucket.inputTokens)} in '
            '(${formatCost(bucket.costIn, priced: priced)}) · '
            '${formatTokens(bucket.outputTokens)} out '
            '(${formatCost(bucket.costOut, priced: priced)})'
            '${bucket.hasEstimates ? ' · estimated' : ''}',
            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const Divider(height: 13),
        ],
      ),
    );
  }
}

/// A budget with a bar showing how much of it is gone.
class _BudgetCard extends StatelessWidget {
  const _BudgetCard({
    required this.budget,
    required this.spent,
    required this.onEdit,
    required this.onDelete,
  });

  final Budget budget;
  final double spent;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final fraction = budget.fractionOf(spent) ?? 0;
    final exceeded = budget.isExceededBy(spent);
    // Amber before the ceiling, error at it: a budget most of the way gone is
    // information, not yet a problem.
    final bar = exceeded
        ? scheme.error
        : (fraction >= 0.8 ? scheme.tertiary : scheme.primary);

    String amount(double value) => switch (budget.metric) {
          BudgetMetric.cost => formatCost(value),
          BudgetMetric.tokens => formatTokens(value.round()),
          BudgetMetric.requests => value.round().toString(),
        };

    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${budget.period.label} ${budget.metric.label.toLowerCase()}'
                    '${budget.isProviderWide ? '' : ' · ${budget.model}'}',
                    style:
                        text.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                if (budget.block)
                  Tooltip(
                    message: 'Blocks sending when reached',
                    child: Icon(Icons.block, size: 18, color: scheme.error),
                  ),
                IconButton(
                  tooltip: 'Edit',
                  icon: const Icon(Icons.edit_outlined, size: 20),
                  onPressed: onEdit,
                ),
                IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.remove_circle_outline, size: 20),
                  onPressed: onDelete,
                ),
              ],
            ),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: fraction,
                minHeight: 8,
                backgroundColor: scheme.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation<Color>(bar),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '${amount(spent)} of ${amount(budget.limit)}'
              '${exceeded ? ' · reached' : ''}',
              style: text.bodySmall?.copyWith(
                color: exceeded ? scheme.error : scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Nothing has been sent through this provider yet.
class _EmptyCosts extends StatelessWidget {
  const _EmptyCosts({required this.unsaved});

  final bool unsaved;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 0, 32, 64),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.savings_outlined, size: 56, color: scheme.outline),
            const SizedBox(height: 16),
            Text('Nothing spent yet',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              unsaved
                  ? 'Save this provider and send a message; what it costs will '
                      'be recorded here.'
                  : 'Send a message through this provider and its token use and '
                      'cost will appear here. Set prices in Advanced first, or '
                      'you will see tokens without money.',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}

/// The budget editor. A sheet rather than a page: four choices and a number.
class _BudgetSheet extends StatefulWidget {
  const _BudgetSheet({required this.budget, required this.models});

  final Budget? budget;
  final List<String> models;

  @override
  State<_BudgetSheet> createState() => _BudgetSheetState();
}

class _BudgetSheetState extends State<_BudgetSheet> {
  late BudgetMetric _metric = widget.budget?.metric ?? BudgetMetric.cost;
  late BudgetPeriod _period = widget.budget?.period ?? BudgetPeriod.monthly;
  late String _model = widget.budget?.model ?? '';
  late bool _block = widget.budget?.block ?? false;
  late final TextEditingController _limit = TextEditingController(
    text: (widget.budget?.limit ?? 0) == 0
        ? ''
        : _trim(widget.budget!.limit),
  );

  static String _trim(double value) {
    var s = value.toStringAsFixed(4).replaceFirst(RegExp(r'0+$'), '');
    if (s.endsWith('.')) s = s.substring(0, s.length - 1);
    return s;
  }

  @override
  void dispose() {
    _limit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        bottom: 16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.budget == null ? 'Set a budget' : 'Edit budget',
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 16),
            _row('Counts', _metricPicker()),
            const SizedBox(height: 12),
            _row('Resets', _periodPicker()),
            const SizedBox(height: 12),
            _row('Applies to', _modelPicker()),
            const SizedBox(height: 16),
            TextField(
              controller: _limit,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              autofocus: widget.budget == null,
              decoration: InputDecoration(
                labelText: 'Limit',
                prefixText: _metric == BudgetMetric.cost ? '\$ ' : null,
                suffixText: switch (_metric) {
                  BudgetMetric.cost => null,
                  BudgetMetric.tokens => 'tokens',
                  BudgetMetric.requests => 'replies',
                },
                helperText: 'Leave blank to track without a ceiling',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _block,
              onChanged: (on) => setState(() => _block = on),
              title: const Text('Refuse to send when reached'),
              subtitle: Text(
                _block
                    ? 'Replies will be blocked with an explanation until the '
                        'budget is raised.'
                    : 'Only warns. Sending continues past the limit.',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(onPressed: _save, child: const Text('Save')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _save() {
    Navigator.of(context).pop(
      Budget(
        id: widget.budget?.id ??
            DateTime.now().microsecondsSinceEpoch.toString(),
        model: _model,
        metric: _metric,
        period: _period,
        limit: double.tryParse(_limit.text.trim()) ?? 0,
        block: _block,
      ),
    );
  }

  Widget _row(String label, Widget control) => Row(
        children: [
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
          Expanded(child: control),
        ],
      );

  Widget _metricPicker() => DropdownButtonHideUnderline(
        child: DropdownButton<BudgetMetric>(
          isExpanded: true,
          value: _metric,
          borderRadius: BorderRadius.circular(12),
          onChanged: (next) {
            if (next != null) setState(() => _metric = next);
          },
          items: [
            for (final metric in BudgetMetric.values)
              DropdownMenuItem(value: metric, child: Text(metric.label)),
          ],
        ),
      );

  Widget _periodPicker() => DropdownButtonHideUnderline(
        child: DropdownButton<BudgetPeriod>(
          isExpanded: true,
          value: _period,
          borderRadius: BorderRadius.circular(12),
          onChanged: (next) {
            if (next != null) setState(() => _period = next);
          },
          items: [
            for (final period in BudgetPeriod.values)
              DropdownMenuItem(value: period, child: Text(period.label)),
          ],
        ),
      );

  /// Empty string means the whole provider, which is the sensible default and so
  /// sits at the top of the list.
  Widget _modelPicker() => DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          isExpanded: true,
          value: widget.models.contains(_model) ? _model : '',
          borderRadius: BorderRadius.circular(12),
          onChanged: (next) => setState(() => _model = next ?? ''),
          items: [
            const DropdownMenuItem(value: '', child: Text('Whole provider')),
            for (final model in widget.models)
              DropdownMenuItem(
                value: model,
                child: Text(model, overflow: TextOverflow.ellipsis),
              ),
          ],
        ),
      );
}
