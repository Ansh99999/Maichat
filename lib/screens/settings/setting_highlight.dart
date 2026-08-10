import 'package:flutter/material.dart';

/// Briefly tints [child] when [active] becomes true, drawing the eye after a
/// search result deep-links to a specific row — the way Android Settings
/// flashes the setting you searched for. When inactive it is a no-op wrapper.
class SettingHighlight extends StatefulWidget {
  const SettingHighlight({
    super.key,
    required this.active,
    required this.child,
  });

  final bool active;
  final Widget child;

  @override
  State<SettingHighlight> createState() => _SettingHighlightState();
}

class _SettingHighlightState extends State<SettingHighlight> {
  bool _lit = false;

  @override
  void initState() {
    super.initState();
    if (!widget.active) return;
    // Fade in on the next frame, then fade back out so the row settles.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _lit = true);
      Future.delayed(const Duration(milliseconds: 1100), () {
        if (mounted) setState(() => _lit = false);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return widget.child;
    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: Duration(milliseconds: _lit ? 180 : 650),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: _lit ? 0.55 : 0),
        borderRadius: BorderRadius.circular(12),
      ),
      child: widget.child,
    );
  }
}
