import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// A tiny always-on-top read-out of the last couple of seconds of frame times,
/// split into the two threads that matter: **UI** (build/layout/paint on the
/// Dart thread) and **raster** (the GPU compositing thread). Shows the average
/// and the worst frame of each.
///
/// This exists to chase the floating-picture stutter on real hardware without a
/// debugger attached: [SchedulerBinding.addTimingsCallback] reports real
/// [FrameTiming]s even in a release build, so the numbers on screen are the
/// genuine device cost. A frame budget is ~16.7ms at 60Hz (or ~11.1ms at 90Hz);
/// anything well above that during a gesture is a dropped frame the eye reads as
/// lag. Whichever number climbs while pinching a picture is the thread at fault.
class FrameStatsHud extends StatefulWidget {
  const FrameStatsHud({super.key});

  @override
  State<FrameStatsHud> createState() => _FrameStatsHudState();
}

class _FrameStatsHudState extends State<FrameStatsHud> {
  /// A rolling window of recent frames (~2s at 60Hz).
  final List<FrameTiming> _recent = <FrameTiming>[];
  static const int _window = 120;

  Timer? _tick;
  String _line1 = 'warming up…';
  String _line2 = '';

  void _onTimings(List<FrameTiming> timings) {
    _recent.addAll(timings);
    if (_recent.length > _window) {
      _recent.removeRange(0, _recent.length - _window);
    }
  }

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    // Recompute a few times a second rather than on every frame, so the read-out
    // itself never becomes part of the cost it is measuring.
    _tick = Timer.periodic(const Duration(milliseconds: 400), (_) => _recompute());
  }

  @override
  void dispose() {
    _tick?.cancel();
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    super.dispose();
  }

  double _ms(int micros) => micros / 1000.0;

  void _recompute() {
    if (!mounted || _recent.isEmpty) return;
    var uiSum = 0, uiMax = 0, rasterSum = 0, rasterMax = 0;
    for (final t in _recent) {
      final ui = t.buildDuration.inMicroseconds;
      final raster = t.rasterDuration.inMicroseconds;
      uiSum += ui;
      rasterSum += raster;
      if (ui > uiMax) uiMax = ui;
      if (raster > rasterMax) rasterMax = raster;
    }
    final n = _recent.length;
    setState(() {
      _line1 = 'UI  ${_ms(uiSum ~/ n).toStringAsFixed(1)} / '
          '${_ms(uiMax).toStringAsFixed(1)} ms';
      _line2 = 'GPU ${_ms(rasterSum ~/ n).toStringAsFixed(1)} / '
          '${_ms(rasterMax).toStringAsFixed(1)} ms';
    });
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('avg / worst',
                style: TextStyle(
                    color: Colors.white70,
                    fontSize: 10,
                    fontFeatures: [FontFeature.tabularFigures()])),
            Text(_line1,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontFamily: 'monospace',
                    fontFeatures: [FontFeature.tabularFigures()])),
            Text(_line2,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontFamily: 'monospace',
                    fontFeatures: [FontFeature.tabularFigures()])),
          ],
        ),
      ),
    );
  }
}
