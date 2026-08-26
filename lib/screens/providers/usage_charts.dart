/// The two charts on a provider's Costs tab.
///
/// Colours come out of the active [ColorScheme] rather than a fixed palette, so
/// they follow Material You, dark mode and the AMOLED theme instead of fighting
/// them. That rules out validating a hue list up front — under a monochrome
/// wallpaper palette two "different" roles can land close together — so identity
/// never rests on colour alone: the stacked series are always in the same order
/// (input below, output above) and both charts label their marks directly.
library;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../models/usage.dart';

/// Series colours, in fixed order. Input is the recessive half because output is
/// what a user is usually paying for and should read as the headline.
({Color input, Color output}) _seriesColors(ColorScheme scheme) =>
    (input: scheme.secondary, output: scheme.primary);

/// A number for an axis label: 1.2M, 48k, 900.
String _short(num value) {
  if (value >= 1000000) {
    final m = value / 1000000;
    return '${m.toStringAsFixed(m >= 10 ? 0 : 1)}M';
  }
  if (value >= 1000) {
    final k = value / 1000;
    return '${k.toStringAsFixed(k >= 10 ? 0 : 1)}k';
  }
  return value.round().toString();
}

/// The label under a bar, at the granularity being shown.
String _sliceLabel(DateTime at, UsageGranularity granularity) =>
    switch (granularity) {
      UsageGranularity.hourly => '${at.hour}',
      UsageGranularity.daily => '${at.day}/${at.month}',
      UsageGranularity.weekly => '${at.day}/${at.month}',
      UsageGranularity.monthly => _monthNames[at.month - 1],
    };

const List<String> _monthNames = <String>[
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// Tokens per time slice, input stacked under output.
///
/// Stacked rather than side-by-side because the question being asked is "how much
/// did I use", and the total is the answer — the split is the detail. Empty
/// slices are drawn as gaps rather than closed up, so a quiet week looks quiet.
class UsageOverTimeChart extends StatelessWidget {
  const UsageOverTimeChart({
    super.key,
    required this.series,
    required this.granularity,
  });

  final List<({DateTime start, UsageBucket bucket})> series;
  final UsageGranularity granularity;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final colors = _seriesColors(scheme);
    final peak = series.fold<int>(
      0,
      (max, slice) => slice.bucket.totalTokens > max
          ? slice.bucket.totalTokens
          : max,
    );

    if (peak == 0) {
      return _NoData(
        message: 'No usage in this window.',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Legend(
          entries: <({Color color, String label})>[
            (color: colors.output, label: 'Output'),
            (color: colors.input, label: 'Input'),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 180,
          child: BarChart(_data(context, peak, colors, scheme, text)),
        ),
      ],
    );
  }

  BarChartData _data(
    BuildContext context,
    int peak,
    ({Color input, Color output}) colors,
    ColorScheme scheme,
    TextTheme text,
  ) {
    // Only every nth label is drawn; 24 hourly labels in a phone's width is a
    // smear rather than an axis.
    final labelEvery = (series.length / 7).ceil().clamp(1, 12);

    return BarChartData(
      alignment: BarChartAlignment.spaceAround,
      maxY: peak * 1.15,
      barTouchData: _touch(scheme, text),
      titlesData: FlTitlesData(
        topTitles: const AxisTitles(),
        rightTitles: const AxisTitles(),
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 40,
            // Three gridlines is enough to read a magnitude against.
            interval: peak / 2 <= 0 ? 1 : peak / 2,
            getTitlesWidget: (value, _) => Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Text(
                _short(value),
                style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                textAlign: TextAlign.right,
              ),
            ),
          ),
        ),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 24,
            getTitlesWidget: (value, _) {
              final index = value.round();
              if (index < 0 || index >= series.length) {
                return const SizedBox.shrink();
              }
              // Always label the newest slice, then work backwards.
              final fromEnd = series.length - 1 - index;
              if (fromEnd % labelEvery != 0) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  _sliceLabel(series[index].start, granularity),
                  style:
                      text.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              );
            },
          ),
        ),
      ),
      gridData: FlGridData(
        show: true,
        drawVerticalLine: false,
        horizontalInterval: peak / 2 <= 0 ? 1 : peak / 2,
        getDrawingHorizontalLine: (_) => FlLine(
          color: scheme.outlineVariant.withValues(alpha: 0.5),
          strokeWidth: 1,
        ),
      ),
      borderData: FlBorderData(show: false),
      barGroups: _groups(colors, scheme, peak),
    );
  }

  List<BarChartGroupData> _groups(
    ({Color input, Color output}) colors,
    ColorScheme scheme,
    int peak,
  ) {
    return <BarChartGroupData>[
      for (var i = 0; i < series.length; i++)
        BarChartGroupData(
          x: i,
          barRods: [
            BarChartRodData(
              toY: series[i].bucket.totalTokens.toDouble(),
              width: 14,
              // Rounded at the top only: the base is anchored to the axis, and a
              // rounded foot would float the bar off its own baseline.
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(4),
              ),
              rodStackItems: [
                BarChartRodStackItem(
                  0,
                  series[i].bucket.inputTokens.toDouble(),
                  colors.input,
                ),
                BarChartRodStackItem(
                  series[i].bucket.inputTokens.toDouble(),
                  series[i].bucket.totalTokens.toDouble(),
                  colors.output,
                  // A hairline of the surface between the two segments, so the
                  // boundary reads even where the two colours are close.
                  borderSide: BorderSide(color: scheme.surface, width: 2),
                ),
              ],
            ),
          ],
        ),
    ];
  }

  BarTouchData _touch(ColorScheme scheme, TextTheme text) => BarTouchData(
        touchTooltipData: BarTouchTooltipData(
          getTooltipColor: (_) => scheme.inverseSurface,
          getTooltipItem: (group, _, _, _) {
            final slice = series[group.x];
            return BarTooltipItem(
              '${_sliceLabel(slice.start, granularity)}\n',
              text.labelMedium?.copyWith(
                    color: scheme.onInverseSurface,
                    fontWeight: FontWeight.w600,
                  ) ??
                  const TextStyle(),
              children: [
                TextSpan(
                  text: '${_short(slice.bucket.outputTokens)} out · '
                      '${_short(slice.bucket.inputTokens)} in',
                  style: text.labelSmall?.copyWith(
                    color: scheme.onInverseSurface.withValues(alpha: 0.85),
                  ),
                ),
              ],
            );
          },
        ),
      );
}

/// Tokens by model, as horizontal bars.
///
/// Horizontal because model ids are long strings and a vertical axis has room to
/// write them out. One hue for every bar: each bar is already named beside it, so
/// a second encoding would be decoration — and eight cycled hues is the thing the
/// colour rules exist to prevent.
class TokensByModelChart extends StatelessWidget {
  const TokensByModelChart({super.key, required this.rows, this.maxRows = 6});

  final List<({String model, UsageBucket bucket})> rows;

  /// Models past this many fold into one "Other" bar rather than growing the
  /// chart without limit.
  final int maxRows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return const _NoData(message: 'No models used yet.');
    }
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    // Ranked by tokens here rather than by cost: this chart is about volume, and
    // an unpriced model would otherwise sink to the bottom regardless of use.
    final ranked = List<({String model, UsageBucket bucket})>.of(rows)
      ..sort((a, b) => b.bucket.totalTokens.compareTo(a.bucket.totalTokens));
    final shown = ranked.take(maxRows).toList();
    final rest = ranked.skip(maxRows);
    var other = const UsageBucket();
    for (final row in rest) {
      other = other.merge(row.bucket);
    }

    final bars = <({String label, int tokens})>[
      for (final row in shown)
        (label: row.model, tokens: row.bucket.totalTokens),
      if (other.totalTokens > 0)
        (label: 'Other (${rest.length})', tokens: other.totalTokens),
    ];
    final peak = bars.first.tokens;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final bar in bars)
          _ModelBar(
            label: bar.label,
            tokens: bar.tokens,
            fraction: peak == 0 ? 0 : bar.tokens / peak,
            color: scheme.primary,
            track: scheme.surfaceContainerHighest,
            text: text,
            muted: scheme.onSurfaceVariant,
          ),
      ],
    );
  }
}

/// One named bar. Hand-drawn rather than an fl_chart horizontal bar because the
/// label belongs above its own bar, which a chart axis cannot do without
/// reserving a fixed width and truncating every model id to fit it.
class _ModelBar extends StatelessWidget {
  const _ModelBar({
    required this.label,
    required this.tokens,
    required this.fraction,
    required this.color,
    required this.track,
    required this.text,
    required this.muted,
  });

  final String label;
  final int tokens;
  final double fraction;
  final Color color;
  final Color track;
  final TextTheme text;
  final Color muted;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall,
                ),
              ),
              const SizedBox(width: 8),
              // The value is a direct label, so the bar never needs an axis.
              Text(
                _short(tokens),
                style: text.labelMedium?.copyWith(color: muted),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: fraction.clamp(0.0, 1.0),
              minHeight: 8,
              backgroundColor: track,
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
        ],
      ),
    );
  }
}

/// The legend. Present whenever there are two series, because identity must never
/// rest on colour alone — and the swatch is a shape beside text, not the text
/// itself, so the label stays in ink colours.
class _Legend extends StatelessWidget {
  const _Legend({required this.entries});

  final List<({Color color, String label})> entries;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Wrap(
      spacing: 16,
      runSpacing: 4,
      children: [
        for (final entry in entries)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: entry.color,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 6),
              Text(entry.label, style: text.labelSmall),
            ],
          ),
      ],
    );
  }
}

/// The empty state for a chart with nothing to draw. A short line where the
/// chart would be, rather than an axis around no data.
class _NoData extends StatelessWidget {
  const _NoData({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 88,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        message,
        style: Theme.of(context)
            .textTheme
            .bodySmall
            ?.copyWith(color: scheme.onSurfaceVariant),
      ),
    );
  }
}
