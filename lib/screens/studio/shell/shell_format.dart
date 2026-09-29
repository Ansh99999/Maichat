import 'dart:async';

import 'package:flutter/material.dart';

import '../../../models/studio.dart';

/// "4m 20s", "35s", "1h 4m" — how long an agent has run.
String formatElapsed(Duration d) {
  final s = d.inSeconds.clamp(0, 1 << 30);
  if (s < 60) return '${s}s';
  final m = s ~/ 60;
  if (m < 60) return '${m}m ${s % 60}s';
  return '${m ~/ 60}h ${m % 60}m';
}

/// "812", "20k", "49.5k", "1.2M" — a token count, short enough for a row.
String formatTokens(int n) {
  String trim(double v) {
    final text = v.toStringAsFixed(1);
    return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
  }

  if (n < 1000) return '$n';
  if (n < 1000000) return '${trim(n / 1000)}k';
  return '${trim(n / 1000000)}M';
}

/// What a session has cost so far — "12k in · 3.4k out · \$0.021" — or that it
/// has cost nothing yet.
String formatSpend(StudioSession s) {
  if (s.inputTokens + s.outputTokens == 0) return 'Nothing spent yet';
  final cost = s.cost > 0
      ? ' · \$${s.cost.toStringAsFixed(s.cost < 1 ? 3 : 2)}'
      : '';
  return '${formatTokens(s.inputTokens)} in · '
      '${formatTokens(s.outputTokens)} out$cost';
}

/// Rebuilds [builder] once a second while [active] — the elapsed time of a
/// running agent keeps ticking even when nothing else about it changes. Idle,
/// it holds no timer at all.
class Ticking extends StatefulWidget {
  const Ticking({super.key, required this.active, required this.builder});

  final bool active;
  final WidgetBuilder builder;

  @override
  State<Ticking> createState() => _TickingState();
}

class _TickingState extends State<Ticking> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(Ticking old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (widget.active && _timer == null) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!widget.active && _timer != null) {
      _timer!.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}
