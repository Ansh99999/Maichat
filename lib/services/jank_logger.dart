import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:path_provider/path_provider.dart';

import '../app_info.dart';

/// A **temporary** on-device jank recorder.
///
/// Registers a frame-timings callback and keeps every frame whose UI (build) or
/// raster (GPU) phase blew the frame budget, tagged with what the app was doing
/// at the time (a breadcrumb trail). A true freeze shows up as a single frame
/// with a huge build/raster duration, reported once the engine catches back up.
/// Everything is flushed to a file, so a hard hang the OS eventually kills still
/// leaves a record on disk.
///
/// It exists to answer one thing with real device data instead of a guess:
/// *when the phone stutters, is the UI thread or the GPU over budget, and what
/// was running?* BUILD over budget points at widget/layout cost; RASTER over
/// budget points at paint/compositing. Delete this once that is answered.
class JankLogger {
  JankLogger._();
  static final JankLogger instance = JankLogger._();

  /// A frame is "janky" when either phase crosses this — the device's real
  /// per-frame budget. Set from the display refresh rate on [start] (≈11ms on a
  /// 90Hz panel, ≈8ms on 120Hz), because a fixed 16ms (60Hz) budget silently
  /// hid every dropped frame on this high-refresh phone — which is exactly why
  /// a drag that *felt* laggy looked "clean" in the log. Defaults to 16 until
  /// the rate is known.
  static double budgetMs = 16.0;

  /// Above this a dropped frame is really a freeze, and is called out on its own.
  static const double freezeMs = 100.0;

  static const int _maxEvents = 400;
  static const int _maxCrumbs = 40;

  bool _on = false;
  bool get isOn => _on;

  final List<JankEvent> _events = <JankEvent>[];
  final List<_Crumb> _crumbs = <_Crumb>[];
  String _activity = 'idle';

  DateTime? _startedAt;
  int _framesSeen = 0;

  /// Running totals of message-bubble builds and (uncached) flutter_html parses.
  /// Recorded on each jank event so the *delta* between two events shows how much
  /// of a spike frame was bubbles building / HTML being parsed — the decisive
  /// test of whether the chat-open freeze is flutter_html volume or something
  /// else (an image decode relaying out).
  int _bubbleBuilds = 0;
  int _htmlParses = 0;
  void noteBubbleBuild() {
    if (_on) _bubbleBuilds++;
  }

  void noteHtmlParse() {
    if (_on) _htmlParses++;
  }

  File? _file;
  Timer? _flush;
  bool _dirty = false;

  /// Begins recording. Safe to call more than once.
  Future<void> start() async {
    if (_on) return;
    _on = true;
    _startedAt = DateTime.now();
    _events.clear();
    _crumbs.clear();
    _framesSeen = 0;
    // Calibrate the jank threshold to the panel's real refresh rate.
    try {
      final views = ui.PlatformDispatcher.instance.views;
      if (views.isNotEmpty) {
        final hz = views.first.display.refreshRate;
        if (hz > 30) budgetMs = 1000.0 / hz;
      }
    } catch (_) {
      // Keep the 16ms default if the rate can't be read.
    }
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _crumb('logging started');
    // Open the backing file lazily; a diagnostic must never throw.
    try {
      final dir = await getApplicationSupportDirectory();
      _file = File('${dir.path}/jank_log.txt');
    } catch (_) {
      _file = null;
    }
    _flush = Timer.periodic(const Duration(seconds: 3), (_) => _persist());
  }

  /// Stops recording and writes a final copy.
  Future<void> stop() async {
    if (!_on) return;
    _on = false;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _flush?.cancel();
    _flush = null;
    await _persist();
  }

  /// A durable state the app is in ('streaming', 'float:drag', 'idle'). Attached
  /// to every jank event recorded while it is set.
  void activity(String name) {
    if (!_on || _activity == name) return;
    _activity = name;
    _crumb('→ $name');
  }

  /// A one-shot thing that just happened ('save conversations', 'open chat').
  void breadcrumb(String label) {
    if (!_on) return;
    _crumb(label);
  }

  void _crumb(String label) {
    _crumbs.add(_Crumb(DateTime.now(), label));
    if (_crumbs.length > _maxCrumbs) _crumbs.removeAt(0);
  }
  void _onTimings(List<FrameTiming> timings) {
    if (!_on) return;
    try {
      for (final t in timings) {
        _framesSeen++;
        final build = t.buildDuration.inMicroseconds / 1000.0;
        final raster = t.rasterDuration.inMicroseconds / 1000.0;
        if (build < budgetMs && raster < budgetMs) continue;
        _events.add(JankEvent(
          at: DateTime.now(),
          frame: t.frameNumber,
          buildMs: build,
          rasterMs: raster,
          totalMs: t.totalSpan.inMicroseconds / 1000.0,
          activity: _activity,
          crumb: _crumbs.isEmpty ? '' : _crumbs.last.label,
          bubbleBuilds: _bubbleBuilds,
          htmlParses: _htmlParses,
        ));
        if (_events.length > _maxEvents) _events.removeAt(0);
        _dirty = true;
      }
    } catch (_) {
      // A diagnostic must never take the app down.
    }
  }

  Future<void> _persist() async {
    if (!_dirty || _file == null) return;
    _dirty = false;
    try {
      await _file!.writeAsString(report(), flush: true);
    } catch (_) {}
  }

  /// Throws the collected data away and starts the window fresh.
  void clear() {
    _events.clear();
    _crumbs.clear();
    _framesSeen = 0;
    if (_on) _startedAt = DateTime.now();
    _dirty = true;
    unawaited(_persist());
  }

  List<JankEvent> get events => List.unmodifiable(_events);

  /// A quick numeric summary for the screen.
  JankSummary get summary {
    var wb = 0.0, wr = 0.0, wt = 0.0, freezes = 0;
    for (final e in _events) {
      if (e.buildMs > wb) wb = e.buildMs;
      if (e.rasterMs > wr) wr = e.rasterMs;
      if (e.totalMs > wt) wt = e.totalMs;
      if (e.buildMs >= freezeMs || e.rasterMs >= freezeMs) freezes++;
    }
    return JankSummary(
      recording: _on,
      framesSeen: _framesSeen,
      jankyFrames: _events.length,
      freezes: freezes,
      worstBuildMs: wb,
      worstRasterMs: wr,
      worstTotalMs: wt,
      since: _startedAt,
    );
  }
  /// The full report — what to hand to Claude. Plain text on purpose.
  String report() {
    final b = StringBuffer();
    final s = summary;
    b.writeln('MaiChat jank log');
    b.writeln('app version: $kAppVersion');
    b.writeln('platform: ${Platform.operatingSystem} '
        '${Platform.operatingSystemVersion}');
    b.writeln('recording: $_on');
    b.writeln('started: ${_startedAt?.toIso8601String() ?? '-'}');
    b.writeln('generated: ${DateTime.now().toIso8601String()}');
    b.writeln('frames seen: $_framesSeen');
    b.writeln('budget: ${budgetMs.toStringAsFixed(1)}ms/frame; '
        'freeze >= ${freezeMs.toStringAsFixed(0)}ms');
    b.writeln('janky frames: ${s.jankyFrames} (freezes: ${s.freezes})');
    b.writeln('worst build: ${s.worstBuildMs.toStringAsFixed(1)}ms  '
        'worst raster: ${s.worstRasterMs.toStringAsFixed(1)}ms  '
        'worst total: ${s.worstTotalMs.toStringAsFixed(1)}ms');
    b.writeln('');
    b.writeln('legend: BUILD = UI thread (widget/layout cost); '
        'RASTER = GPU thread (paint/compositing cost).');
    b.writeln('bubbles/parses are running totals — the JUMP between two rows is '
        'how many message bubbles built / HTML strings were parsed in that '
        'spike. A big parse jump on the freeze row = flutter_html is the cost.');
    b.writeln('');
    b.writeln('# janky frames (oldest first)');
    b.writeln('time                          frame     build   raster    total  '
        ' bubbles  parses  what');
    for (final e in _events) {
      final freeze =
          (e.buildMs >= freezeMs || e.rasterMs >= freezeMs) ? '  <== FREEZE' : '';
      b.writeln('${e.at.toIso8601String().padRight(26)}  '
          '${e.frame.toString().padLeft(7)}  '
          '${e.buildMs.toStringAsFixed(1).padLeft(6)}  '
          '${e.rasterMs.toStringAsFixed(1).padLeft(6)}  '
          '${e.totalMs.toStringAsFixed(1).padLeft(7)}  '
          '${e.bubbleBuilds.toString().padLeft(7)}  '
          '${e.htmlParses.toString().padLeft(6)}  '
          '${e.activity}${e.crumb.isEmpty ? '' : ' | ${e.crumb}'}$freeze');
    }
    b.writeln('');
    b.writeln('# recent breadcrumb trail (oldest first)');
    for (final c in _crumbs) {
      b.writeln('${c.at.toIso8601String().padRight(26)}  ${c.label}');
    }
    return b.toString();
  }
}

/// One over-budget frame.
class JankEvent {
  JankEvent({
    required this.at,
    required this.frame,
    required this.buildMs,
    required this.rasterMs,
    required this.totalMs,
    required this.activity,
    required this.crumb,
    this.bubbleBuilds = 0,
    this.htmlParses = 0,
  });

  final DateTime at;
  final int frame;
  final double buildMs;
  final double rasterMs;
  final double totalMs;
  final String activity;
  final String crumb;
  final int bubbleBuilds;
  final int htmlParses;

  bool get isFreeze =>
      buildMs >= JankLogger.freezeMs || rasterMs >= JankLogger.freezeMs;
}

class _Crumb {
  _Crumb(this.at, this.label);
  final DateTime at;
  final String label;
}

/// The at-a-glance numbers the diagnostics screen shows.
class JankSummary {
  JankSummary({
    required this.recording,
    required this.framesSeen,
    required this.jankyFrames,
    required this.freezes,
    required this.worstBuildMs,
    required this.worstRasterMs,
    required this.worstTotalMs,
    required this.since,
  });

  final bool recording;
  final int framesSeen;
  final int jankyFrames;
  final int freezes;
  final double worstBuildMs;
  final double worstRasterMs;
  final double worstTotalMs;
  final DateTime? since;
}
