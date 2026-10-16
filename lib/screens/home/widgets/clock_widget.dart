import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../models/home_layout.dart';
import '../clock_ticker.dart';
import '../home_spec.dart';

/// Local time, and optional other time zones.
///
/// Ticking goes through the one shared [ClockTicker] via [ClockListener], so
/// a page that is not showing (or the app backgrounded) costs nothing — and
/// when no clock is on Home at all, nothing ticks.
class ClockSpec extends HomeWidgetSpec {
  const ClockSpec();

  @override
  HomeWidgetKind get kind => HomeWidgetKind.clock;

  @override
  String get title => 'Clock';

  @override
  String get description => 'Local time, and other time zones';

  @override
  IconData get icon => Icons.access_time_rounded;

  @override
  List<HomeOption> options(HomeTile tile) => const [
        HomeChoiceOption(
          key: 'style',
          label: 'Style',
          choices: {
            'digital': 'Digital',
            'analog': 'Analog',
            'expressive': 'Expressive',
          },
        ),
        HomePickOption(
          key: 'zones',
          label: 'Other time zones',
          pick: HomePickKind.timezone,
          multiple: true,
          help: 'Shown alongside local time when there is room',
        ),
        HomeToggleOption(key: 'seconds', label: 'Show seconds'),
        HomeToggleOption(key: 'date', label: 'Show date'),
        HomeChoiceOption(
          key: 'hour24',
          label: '24-hour clock',
          choices: {
            'auto': 'Follow system',
            '12': '12-hour',
            '24': '24-hour',
          },
        ),
      ];

  @override
  String describe(BuildContext context, HomeTile tile) {
    final zones = _zonesOf(tile);
    if (zones.isEmpty) return 'Clock';
    return 'Clock · ${zones.map(HomeTimeZones.cityOf).join(', ')}';
  }

  @override
  Widget build(BuildContext context, HomeTileContext tile) =>
      _ClockCard(key: ValueKey(tile.tile.id), tile: tile);
}

List<String> _zonesOf(HomeTile tile) =>
    [for (final z in (tile.str('zones') ?? '').split(',')) if (z.isNotEmpty) z];

bool _resolve24h(BuildContext context, HomeTile tile) {
  final mode = tile.str('hour24') ?? 'auto';
  if (mode == '12') return false;
  if (mode == '24') return true;
  return MediaQuery.alwaysUse24HourFormatOf(context);
}

String _two(int n) => n.toString().padLeft(2, '0');

String _timeText(DateTime t, {required bool hour24, required bool seconds}) {
  final h = hour24 ? t.hour : (t.hour % 12 == 0 ? 12 : t.hour % 12);
  final buf = StringBuffer('${hour24 ? _two(h) : h}:${_two(t.minute)}');
  if (seconds) buf.write(':${_two(t.second)}');
  if (!hour24) buf.write(t.hour >= 12 ? ' PM' : ' AM');
  return buf.toString();
}

String _dateText(DateTime t) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  return '${weekdays[t.weekday - 1]}, ${months[t.month - 1]} ${t.day}';
}

/// A zone's offset against local time, as "+1h", "-30m" or "+1 day".
String _offsetLabel(DateTime local, DateTime there) {
  final diff = there.difference(local);
  final dayDiff = there.day != local.day || there.month != local.month
      ? (there.isAfter(local) ? 1 : -1)
      : 0;
  if (dayDiff != 0) return dayDiff > 0 ? '+1 day' : '-1 day';
  final minutes = diff.inMinutes;
  if (minutes == 0) return 'same time';
  final sign = minutes > 0 ? '+' : '-';
  final abs = minutes.abs();
  final h = abs ~/ 60;
  final m = abs % 60;
  if (h == 0) return '$sign${m}m';
  if (m == 0) return '$sign${h}h';
  return '$sign${h}h${m}m';
}

class _ClockCard extends StatelessWidget {
  const _ClockCard({super.key, required this.tile});

  final HomeTileContext tile;

  @override
  Widget build(BuildContext context) {
    final t = tile.tile;
    final style = t.str('style') ?? 'digital';
    final showSeconds = t.flag('seconds', false);
    final showDate = t.flag('date', false);
    final zones = _zonesOf(t);
    final hour24 = _resolve24h(context, t);

    return HomeCard(
      semanticLabel: 'Clock',
      builder: (context, inner) => ClockListener(
        seconds: showSeconds,
        builder: (context, now) => _ClockLayout(
          now: now,
          inner: inner,
          style: style,
          showSeconds: showSeconds,
          showDate: showDate,
          hour24: hour24,
          zones: zones,
        ),
      ),
    );
  }
}

class _ClockLayout extends StatelessWidget {
  const _ClockLayout({
    required this.now,
    required this.inner,
    required this.style,
    required this.showSeconds,
    required this.showDate,
    required this.hour24,
    required this.zones,
  });

  final DateTime now;
  final Size inner;
  final String style;
  final bool showSeconds;
  final bool showDate;
  final bool hour24;
  final List<String> zones;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final wide = inner.width >= inner.height * 1.6 && inner.width > 160;
    final big = inner.width >= 320;

    final timeText = _timeText(now, hour24: hour24, seconds: showSeconds);
    final dateText = _dateText(now);

    Widget faceOf(double side) => style == 'analog'
        ? RepaintBoundary(
            child: _AnalogClock(now: now, size: side),
          )
        : Text(
            timeText,
            maxLines: 1,
            style: style == 'expressive'
                ? theme.textTheme.displaySmall?.copyWith(
                    fontWeight: FontWeight.w900,
                  )
                : theme.textTheme.headlineMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
          );

    Widget expressiveTime() {
      // Two tonal colours for hour and minute, per the M3 Expressive brief.
      final parts = timeText.split(':');
      final hourPart = parts[0];
      final rest = parts.length > 1 ? parts.sublist(1).join(':') : '';
      final numStyle = theme.textTheme.displayMedium?.copyWith(
        fontWeight: FontWeight.w900,
        height: 1.0,
      );
      return RichText(
        text: TextSpan(
          children: [
            TextSpan(
              text: hourPart,
              style: numStyle?.copyWith(color: scheme.primary),
            ),
            TextSpan(text: ':', style: numStyle?.copyWith(color: scheme.outline)),
            TextSpan(
              text: rest,
              style: numStyle?.copyWith(color: scheme.tertiary),
            ),
          ],
        ),
      );
    }

    // A wide strip (4x1 and the like) with zones: the local time on the left
    // and as many zones as fit beside it, rather than a lone time and a
    // stretch of empty card.
    if (zones.isNotEmpty && inner.width >= 240 && inner.height < 160) {
      final local = style == 'analog'
          ? faceOf(math.min(inner.height, 96))
          : FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  style == 'expressive' ? expressiveTime() : faceOf(0),
                  if (showDate)
                    Text(
                      dateText,
                      maxLines: 1,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                ],
              ),
            );
      final fit = ((inner.width * 0.58) / 88).floor().clamp(1, zones.length);
      return Row(
        children: [
          Expanded(child: Align(alignment: Alignment.centerLeft, child: local)),
          for (final z in zones.take(fit)) ...[
            const SizedBox(width: 8),
            _ZoneChip(zone: z, now: now, hour24: hour24),
          ],
        ],
      );
    }

    // 1x1 and small: just the local time (and a tiny dial for analog).
    if (zones.isEmpty || inner.width < 160 || inner.height < 160) {
      if (style == 'analog') {
        final side = math.min(inner.width, inner.height);
        return Center(child: faceOf(side));
      }
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          style == 'expressive' ? expressiveTime() : faceOf(0),
          if (showDate && inner.height > 60)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                dateText,
                maxLines: 1,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
        ],
      );
    }

    // 4x2 and larger with zones: local big on the left, zones as a column.
    if (big) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 3,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (style == 'analog')
                  SizedBox(
                    width: math.min(inner.height, 120),
                    height: math.min(inner.height, 120),
                    child: faceOf(math.min(inner.height, 120)),
                  )
                else if (style == 'expressive')
                  expressiveTime()
                else
                  faceOf(0),
                if (showDate)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(dateText, style: theme.textTheme.bodyMedium),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: _ZoneGrid(zones: zones, now: now, hour24: hour24),
          ),
        ],
      );
    }

    // 2x2-ish: time+date on top, up to 2 zones listed below.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (wide)
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              style == 'expressive' ? expressiveTime() : faceOf(0),
              if (showDate) ...[
                const SizedBox(width: 10),
                Text(dateText, style: theme.textTheme.bodyMedium),
              ],
            ],
          )
        else ...[
          style == 'expressive' ? expressiveTime() : faceOf(0),
          if (showDate)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(dateText, style: theme.textTheme.bodyMedium),
            ),
        ],
        const SizedBox(height: 8),
        _ZoneList(zones: zones.take(2).toList(), now: now, hour24: hour24),
      ],
    );
  }
}

/// One zone as a compact tonal block: city over its time and offset.
class _ZoneChip extends StatelessWidget {
  const _ZoneChip({required this.zone, required this.now, required this.hour24});

  final String zone;
  final DateTime now;
  final bool hour24;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final there = HomeTimeZones.at(zone, now);
    if (there == null) return const SizedBox.shrink();
    return Container(
      width: 80,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: ShapeDecoration(
        color: scheme.surfaceContainerHighest,
        shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(16)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            HomeTimeZones.cityOf(zone),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              _timeText(there, hour24: hour24, seconds: false),
              maxLines: 1,
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          Text(
            _offsetLabel(now, there),
            maxLines: 1,
            style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline),
          ),
        ],
      ),
    );
  }
}

class _ZoneList extends StatelessWidget {
  const _ZoneList({required this.zones, required this.now, required this.hour24});

  final List<String> zones;
  final DateTime now;
  final bool hour24;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final z in zones)
          () {
            final there = HomeTimeZones.at(z, now);
            if (there == null) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      HomeTimeZones.cityOf(z),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _timeText(there, hour24: hour24, seconds: false),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _offsetLabel(now, there),
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            );
          }(),
      ],
    );
  }
}

class _ZoneGrid extends StatelessWidget {
  const _ZoneGrid({required this.zones, required this.now, required this.hour24});

  final List<String> zones;
  final DateTime now;
  final bool hour24;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final z in zones)
          () {
            final there = HomeTimeZones.at(z, now);
            if (there == null) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    HomeTimeZones.cityOf(z),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  Text(
                    _timeText(there, hour24: hour24, seconds: false),
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    _offsetLabel(now, there),
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: scheme.outline),
                  ),
                ],
              ),
            );
          }(),
      ],
    );
  }
}

/// An M3 Expressive analog face: a soft scalloped "cookie" dial in
/// `surfaceContainerHighest`, a thick rounded hour hand in `primary` and a
/// minute hand in `tertiary`. No tick marks.
class _AnalogClock extends StatelessWidget {
  const _AnalogClock({required this.now, required this.size});

  final DateTime now;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (size <= 0) return const SizedBox.shrink();
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _AnalogClockPainter(
          now: now,
          faceColor: scheme.surfaceContainerHighest,
          hourColor: scheme.primary,
          minuteColor: scheme.tertiary,
        ),
      ),
    );
  }
}

class _AnalogClockPainter extends CustomPainter {
  _AnalogClockPainter({
    required this.now,
    required this.faceColor,
    required this.hourColor,
    required this.minuteColor,
  });

  final DateTime now;
  final Color faceColor;
  final Color hourColor;
  final Color minuteColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final r = size.shortestSide / 2;

    // Soft scalloped "cookie" face.
    final facePaint = Paint()..color = faceColor;
    canvas.drawPath(_cookiePath(center, r), facePaint);

    void drawHand(double angle, double length, double width, Color color) {
      final paint = Paint()
        ..color = color
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round;
      final end = Offset(
        center.dx + length * math.sin(angle),
        center.dy - length * math.cos(angle),
      );
      canvas.drawLine(center, end, paint);
    }

    final hourAngle =
        (now.hour % 12 + now.minute / 60) / 12 * 2 * math.pi;
    final minuteAngle = now.minute / 60 * 2 * math.pi;

    drawHand(hourAngle, r * 0.5, r * 0.14, hourColor);
    drawHand(minuteAngle, r * 0.72, r * 0.09, minuteColor);

    canvas.drawCircle(center, r * 0.07, Paint()..color = hourColor);
  }

  Path _cookiePath(Offset center, double r) {
    const lobes = 10;
    const depth = 0.06;
    final base = r * (1 - depth);
    final amp = r * depth;
    const steps = 120;
    final path = Path();
    for (var i = 0; i <= steps; i++) {
      final a = (i / steps) * 2 * math.pi - math.pi / 2;
      final rr = base + amp * math.cos(lobes * a);
      final p = Offset(
        center.dx + rr * math.cos(a),
        center.dy + rr * math.sin(a),
      );
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    return path..close();
  }

  @override
  bool shouldRepaint(_AnalogClockPainter oldDelegate) =>
      oldDelegate.now != now ||
      oldDelegate.faceColor != faceColor ||
      oldDelegate.hourColor != hourColor ||
      oldDelegate.minuteColor != minuteColor;
}
