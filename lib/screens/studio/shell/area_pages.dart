import 'package:flutter/material.dart';

/// The Studio's three areas — conversation, draft, changes — as layers kept
/// alive side by side, switched by sliding one over the other.
///
/// Built this way, rather than as a [PageView], for smoothness:
///
/// - Every page is built once and kept. A PageView builds a page when it
///   first comes into view — on the first frame of the slide, which is where
///   the stutter was — and throws it away again once it has gone (only the
///   conversation opted into keep-alive). Here each page is built on the first
///   idle frame after the session opens, off screen, so no slide ever pays for
///   a build.
/// - A slide goes straight from one page to the other. Animating a PageView
///   from the conversation to the changes scrolled *through* the draft, and
///   built and laid it out on the way.
/// - The slide itself is two translations of cached layers: each page sits
///   behind a [RepaintBoundary], and only a [FractionalTranslation] changes per
///   frame — nothing is rebuilt, laid out or repainted while it moves.
/// - A page out of sight is [Offstage] with its tickers stopped, and tells its
///   listeners so through [StudioPageActivity]: the draft does not rebuild on
///   every streamed word while the conversation is on screen. It catches up
///   in one rebuild when it is shown again.
class StudioAreaPages extends StatefulWidget {
  const StudioAreaPages({
    super.key,
    required this.index,
    required this.pages,
    this.duration = const Duration(milliseconds: 380),
  });

  /// The page on screen.
  final int index;

  /// The pages. Hand in the same widget instances from build to build (the
  /// shell caches them), so a rebuild of the shell does not rebuild them.
  final List<Widget> pages;
  final Duration duration;

  @override
  State<StudioAreaPages> createState() => _StudioAreaPagesState();
}

class _StudioAreaPagesState extends State<StudioAreaPages>
    with SingleTickerProviderStateMixin {
  late final AnimationController _slide = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: 1,
  )..addStatusListener(_onStatus);

  late final CurvedAnimation _curve = CurvedAnimation(
    parent: _slide,
    curve: Easing.emphasizedDecelerate,
  );

  late int _to = widget.index;
  int? _from;

  /// Which pages have been built. The one on screen first; the rest on the
  /// first idle frame after that.
  late final Set<int> _built = {widget.index};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _built.addAll(
            List<int>.generate(widget.pages.length, (i) => i),
          ));
    });
  }

  @override
  void didUpdateWidget(StudioAreaPages old) {
    super.didUpdateWidget(old);
    if (widget.index == _to) return;
    // A switch mid-slide starts from wherever the eye is: the page that is
    // more than half on screen.
    final settledFrom =
        _from != null && _slide.isAnimating && _curve.value < 0.5 ? _from! : _to;
    _from = settledFrom == widget.index ? null : settledFrom;
    _to = widget.index;
    _built.add(_to);
    if (_from == null) {
      _slide.value = 1;
    } else {
      _slide.forward(from: 0);
    }
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && _from != null) {
      setState(() => _from = null);
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _slide.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final from = _from;
    // Moving to a later page, the new one comes in from the right.
    final direction = from == null ? 0.0 : (_to > from ? 1.0 : -1.0);
    return ClipRect(
      child: Stack(
        children: [
          for (var i = 0; i < widget.pages.length; i++)
            if (_built.contains(i))
              Positioned.fill(
                key: ValueKey<int>(i),
                child: _slot(i, from, direction),
              ),
        ],
      ),
    );
  }

  Widget _slot(int i, int? from, double direction) {
    final shown = i == _to || i == from;
    // One shape for every page, moving or not: swapping a wrapper in for the
    // slide would change the page's place in the tree and rebuild it whole.
    return StudioPageActivity(
      active: i == _to,
      child: Offstage(
        offstage: !shown,
        child: TickerMode(
          enabled: shown,
          // The page leaving takes no taps while it goes.
          child: IgnorePointer(
            ignoring: i != _to,
            child: AnimatedBuilder(
              animation: _curve,
              builder: (context, child) {
                final t = _curve.value;
                final dx = from == null
                    ? 0.0
                    : i == _to
                        ? direction * (1 - t)
                        : i == from
                            ? -direction * t
                            : 0.0;
                return FractionalTranslation(
                  translation: Offset(dx, 0),
                  child: child,
                );
              },
              child: RepaintBoundary(child: widget.pages[i]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Whether the page this sits in is the one on screen. Pages listen for
/// changes only while they are — see [ActiveListenableBuilder].
class StudioPageActivity extends InheritedWidget {
  const StudioPageActivity({
    super.key,
    required this.active,
    required super.child,
  });

  final bool active;

  /// Whether the enclosing page is on screen; true outside any page.
  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<StudioPageActivity>()
          ?.active ??
      true;

  @override
  bool updateShouldNotify(StudioPageActivity old) => old.active != active;
}

/// A [ListenableBuilder] that stops listening while its page is out of sight
/// ([StudioPageActivity]) and rebuilds once when the page comes back.
class ActiveListenableBuilder extends StatefulWidget {
  const ActiveListenableBuilder({
    super.key,
    required this.listenable,
    required this.builder,
  });

  final Listenable listenable;
  final WidgetBuilder builder;

  @override
  State<ActiveListenableBuilder> createState() =>
      _ActiveListenableBuilderState();
}

class _ActiveListenableBuilderState extends State<ActiveListenableBuilder> {
  bool _listening = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync(StudioPageActivity.of(context));
  }

  @override
  void didUpdateWidget(ActiveListenableBuilder old) {
    super.didUpdateWidget(old);
    if (old.listenable != widget.listenable && _listening) {
      old.listenable.removeListener(_changed);
      widget.listenable.addListener(_changed);
    }
  }

  void _sync(bool active) {
    if (active && !_listening) {
      // Whatever happened while it was away is drawn by the rebuild this
      // dependency change already causes.
      widget.listenable.addListener(_changed);
      _listening = true;
    } else if (!active && _listening) {
      widget.listenable.removeListener(_changed);
      _listening = false;
    }
  }

  void _changed() {
    if (mounted && _listening) setState(() {});
  }

  @override
  void dispose() {
    if (_listening) widget.listenable.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}
