import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:timezone/data/latest_10y.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// One clock for every clock widget on Home.
///
/// A single timer, aligned to the next whole minute (or second, while any clock
/// shows seconds), feeds a [ValueListenable]. Each clock widget listens only
/// while it is on screen and its page is current (see [ClockListener]), so a
/// hidden page or a backgrounded app costs nothing — and nothing ticks at all
/// when there is no clock on the home screen.
class ClockTicker extends ChangeNotifier implements ValueListenable<DateTime> {
  ClockTicker._();

  static final ClockTicker instance = ClockTicker._();

  /// What "now" is, for tests.
  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  DateTime _now = clock();
  Timer? _timer;
  int _seconds = 0;

  @override
  DateTime get value => _now;

  /// A listener that wants second-by-second ticks.
  void wantSeconds() {
    _seconds++;
    _reschedule();
  }

  void releaseSeconds() {
    if (_seconds > 0) _seconds--;
    _reschedule();
  }

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    if (hasListeners) _reschedule();
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _reschedule() {
    _timer?.cancel();
    _timer = null;
    if (!hasListeners) return;
    _now = clock();
    final next = _seconds > 0
        ? Duration(milliseconds: 1000 - _now.millisecond)
        : Duration(
            seconds: 60 - _now.second,
            milliseconds: -_now.millisecond,
          );
    _timer = Timer(next, () {
      _now = clock();
      notifyListeners();
      _reschedule();
    });
  }
}

/// Rebuilds [builder] as the [ClockTicker] ticks, but only while ticking is
/// on for this subtree ([TickerMode] — off on a page that is not showing and
/// while a route covers Home).
class ClockListener extends StatefulWidget {
  const ClockListener({
    super.key,
    required this.builder,
    this.seconds = false,
  });

  final Widget Function(BuildContext context, DateTime now) builder;

  /// Tick every second rather than every minute.
  final bool seconds;

  @override
  State<ClockListener> createState() => _ClockListenerState();
}

class _ClockListenerState extends State<ClockListener> {
  ValueListenable<TickerModeData>? _mode;
  bool _listening = false;
  bool _seconds = false;

  void _tick() {
    if (mounted) setState(() {});
  }

  void _sync() {
    final on = _mode?.value.enabled ?? true;
    final ticker = ClockTicker.instance;
    if (on && !_listening) {
      ticker.addListener(_tick);
      _listening = true;
    } else if (!on && _listening) {
      ticker.removeListener(_tick);
      _listening = false;
    }
    final wantSeconds = on && widget.seconds;
    if (wantSeconds != _seconds) {
      wantSeconds ? ticker.wantSeconds() : ticker.releaseSeconds();
      _seconds = wantSeconds;
    }
  }

  void _modeChanged() {
    _sync();
    // Back on screen: show the time as it is now, not as it was left.
    if (_mode?.value.enabled ?? true) _tick();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final mode = TickerMode.getValuesNotifier(context);
    if (!identical(mode, _mode)) {
      _mode?.removeListener(_modeChanged);
      _mode = mode..addListener(_modeChanged);
    }
    _sync();
  }

  @override
  void didUpdateWidget(ClockListener old) {
    super.didUpdateWidget(old);
    if (old.seconds != widget.seconds) _sync();
  }

  @override
  void dispose() {
    _mode?.removeListener(_modeChanged);
    if (_listening) ClockTicker.instance.removeListener(_tick);
    if (_seconds) ClockTicker.instance.releaseSeconds();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, ClockTicker.clock());
}

/// The IANA time-zone database, loaded the first time a clock needs a zone
/// other than the device's own (~35 ms, never at launch).
abstract final class HomeTimeZones {
  static bool _ready = false;

  static void _ensure() {
    if (_ready) return;
    tzdata.initializeTimeZones();
    _ready = true;
  }

  /// Every zone name, sorted.
  static List<String> names() {
    _ensure();
    return tz.timeZoneDatabase.locations.keys.toList()..sort();
  }

  /// The wall-clock time in [zone] at [now], or null for an unknown zone.
  static DateTime? at(String zone, DateTime now) {
    _ensure();
    try {
      final t = tz.TZDateTime.from(now, tz.getLocation(zone));
      return DateTime(t.year, t.month, t.day, t.hour, t.minute, t.second);
    } catch (_) {
      return null;
    }
  }

  /// The zone's short abbreviation right now ("IST", "CET"), or null.
  static String? abbreviation(String zone, DateTime now) {
    _ensure();
    try {
      return tz.TZDateTime.from(now, tz.getLocation(zone)).timeZoneName;
    } catch (_) {
      return null;
    }
  }

  /// "Asia/Kolkata" → "Kolkata", "America/Argentina/Buenos_Aires" →
  /// "Buenos Aires".
  static String cityOf(String zone) =>
      zone.split('/').last.replaceAll('_', ' ');
}
