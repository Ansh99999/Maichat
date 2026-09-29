import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../services/studio/studio_context.dart';
import '../../../services/studio/studio_controller.dart';
import 'context_sheet.dart';

/// How often a live context view recomputes while an agent streams. Counting
/// is cached per turn, so this is cheap, but a streamed reply notifies every
/// few dozen milliseconds and the ring has nothing new to say that often.
const Duration kContextRefresh = Duration(milliseconds: 500);

/// Follows [controller] at most once every [kContextRefresh]: the first change
/// after a quiet spell is drawn at once, and a burst after it is drawn once,
/// when it has settled. Mixed into the ring and the inspector.
mixin ThrottledStudioListener<T extends StatefulWidget> on State<T> {
  StudioController get listenedController;

  /// Recompute (called inside setState).
  void refresh();

  StudioController? _listening;
  Timer? _timer;
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  void startListening() =>
      _listening = listenedController..addListener(_changed);

  void stopListening() {
    _listening?.removeListener(_changed);
    _listening = null;
    _timer?.cancel();
    _timer = null;
  }

  void _changed() {
    if (!mounted || _timer != null) return;
    final since = DateTime.now().difference(_last);
    if (since >= kContextRefresh) {
      _draw();
    } else {
      _timer = Timer(kContextRefresh - since, () {
        _timer = null;
        if (mounted) _draw();
      });
    }
  }

  void _draw() {
    _last = DateTime.now();
    setState(refresh);
  }
}

/// A small ring showing how full an agent's next request is — the share of
/// its context budget, with a tick where the older conversation starts being
/// summarised. Tapping it opens the context inspector for that agent.
class StudioContextMeter extends StatefulWidget {
  const StudioContextMeter({
    super.key,
    required this.controller,
    required this.agentId,
    this.size = 40,
  });

  final StudioController controller;
  final String agentId;
  final double size;

  @override
  State<StudioContextMeter> createState() => _StudioContextMeterState();
}

class _StudioContextMeterState extends State<StudioContextMeter>
    with ThrottledStudioListener<StudioContextMeter> {
  double _fraction = 0;
  double _threshold = 0.75;
  bool _near = false;

  @override
  StudioController get listenedController => widget.controller;

  @override
  void initState() {
    super.initState();
    refresh();
    startListening();
  }

  @override
  void didUpdateWidget(StudioContextMeter old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      stopListening();
      startListening();
    }
    if (old.agentId != widget.agentId || old.controller != widget.controller) {
      refresh();
    }
  }

  @override
  void dispose() {
    stopListening();
    super.dispose();
  }

  @override
  void refresh() {
    final report = widget.controller.contextFor(widget.agentId);
    if (report == null) return;
    _fraction = report.fraction;
    _threshold = report.threshold;
    _near = report.wouldCompact;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final percent = (_fraction * 100).round();
    final label = 'Context $percent% used';
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        child: SizedBox.square(
          dimension: widget.size,
          child: Material(
            type: MaterialType.transparency,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: Key('studio-context-meter-${widget.agentId}'),
              customBorder: const CircleBorder(),
              onTap: () => showStudioContextSheet(
                context,
                widget.controller,
                agentId: widget.agentId,
              ),
              child: Center(
                // The ring eases to each new value rather than jumping.
                child: TweenAnimationBuilder<double>(
                  tween: Tween<double>(end: _fraction.clamp(0.0, 1.0)),
                  duration: const Duration(milliseconds: 520),
                  curve: Easing.emphasizedDecelerate,
                  builder: (context, value, _) => RepaintBoundary(
                    child: CustomPaint(
                      size: Size.square(widget.size * 0.6),
                      painter: _RingPainter(
                        value: value,
                        threshold: _threshold,
                        // A track the eye reads as a whole gauge, not as a
                        // spinner's tail, on every composer surface.
                        track: scheme.outlineVariant,
                        fill: _near ? scheme.tertiary : scheme.primary,
                        tick: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.value,
    required this.threshold,
    required this.track,
    required this.fill,
    required this.tick,
  });

  final double value;
  final double threshold;
  final Color track;
  final Color fill;
  final Color tick;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.16;
    final rect = Offset.zero & size;
    final arc = rect.deflate(stroke / 2);
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(arc, 0, math.pi * 2, false, base..color = track);
    if (value > 0) {
      canvas.drawArc(
        arc,
        -math.pi / 2,
        math.pi * 2 * value.clamp(0.0, 1.0),
        false,
        base..color = fill,
      );
    }
    // The tick where summarising starts.
    final angle = -math.pi / 2 + math.pi * 2 * threshold;
    final center = rect.center;
    final r = arc.width / 2;
    // Across the ring's own width, so it reads as a notch rather than a dash.
    final inner = r - stroke * 0.5;
    final outer = r + stroke * 0.5;
    canvas.drawLine(
      center + Offset(math.cos(angle) * inner, math.sin(angle) * inner),
      center + Offset(math.cos(angle) * outer, math.sin(angle) * outer),
      Paint()
        ..color = tick
        ..strokeWidth = stroke * 0.35,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.value != value ||
      old.threshold != threshold ||
      old.track != track ||
      old.fill != fill ||
      old.tick != tick;
}

/// What a category is coloured as. The bar and legend colour by these six
/// groups rather than by the ten categories: ten hues cannot all stay apart
/// on one bar for colour-blind readers, whichever categories happen to be
/// present, while these six — in this order, on these colours — pass the
/// dataviz validator for every combination of them that can appear, in light,
/// dark and pure-black themes. Each row still names its own category.
enum StudioContextGroup {
  // Named apart from the categories it gathers, so the legend's "Set-up 1.8k"
  // is not read against the row "Instructions 1.6k".
  instructions('Set-up', Color(0xFFEB6834), Color(0xFFD95926)),
  tools('Tools', Color(0xFF2A78D6), Color(0xFF3987E5)),
  summary('Summary', Color(0xFFEDA100), Color(0xFFC98500)),
  conversation('Conversation', Color(0xFFE87BA4), Color(0xFFD55181)),
  toolResults('Tool results', Color(0xFF008300), Color(0xFF008300)),
  pictures('Pictures', Color(0xFF4A3AA7), Color(0xFF9085E9));

  const StudioContextGroup(this.label, this.light, this.dark);
  final String label;
  final Color light;
  final Color dark;

  Color colorIn(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  static StudioContextGroup of(StudioContextCategory category) =>
      switch (category) {
        StudioContextCategory.instructions ||
        StudioContextCategory.web ||
        StudioContextCategory.agentTypes ||
        StudioContextCategory.memory =>
          instructions,
        StudioContextCategory.tools => tools,
        StudioContextCategory.summary => summary,
        StudioContextCategory.conversation ||
        StudioContextCategory.waiting =>
          conversation,
        StudioContextCategory.toolResults => toolResults,
        StudioContextCategory.pictures => pictures,
      };
}

/// The colour a category is drawn in: its group's, for the theme.
Color contextColor(StudioContextCategory category, ThemeData theme) =>
    StudioContextGroup.of(category).colorIn(theme.brightness);
