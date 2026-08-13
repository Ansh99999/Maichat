import 'package:flutter/material.dart';

import '../services/reasoning.dart';

/// The model's thinking for one turn, as a collapsed disclosure above the reply:
/// a tappable "Thought for 12 seconds" bar that opens onto the reasoning itself.
///
/// Follows the Material 3 disclosure pattern rather than a plain
/// [ExpansionTile], which is sized for list rows and reads far too heavy sitting
/// inside a chat turn. While the model is still thinking the bar shows a live
/// spinner and starts open, then collapses itself once the answer begins — so
/// thinking is visible as it happens without permanently burying the reply.
class ThinkingBlock extends StatefulWidget {
  const ThinkingBlock({
    super.key,
    required this.reasoning,
    this.thinkingMs,
    this.inProgress = false,
    this.fontSize = 14,
  });

  /// The thinking text, tags already stripped.
  final String reasoning;

  /// How long it took, or null while still thinking.
  final int? thinkingMs;

  /// Whether the model is thinking right now.
  final bool inProgress;

  /// The chat's body text size; the reasoning sits a shade below it.
  final double fontSize;

  @override
  State<ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<ThinkingBlock> {
  /// Null until the user takes over, so the block can follow the model's state
  /// (open while thinking, shut afterwards) without fighting a manual choice.
  bool? _open;

  bool get _expanded => _open ?? widget.inProgress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final label = widget.inProgress
        ? 'Thinking…'
        : describeThinkingTime(widget.thinkingMs);

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(12),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: () => setState(() => _open = !_expanded),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _leading(scheme),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    AnimatedRotation(
                      turns: _expanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 180),
                      child: Icon(
                        Icons.expand_more,
                        size: 18,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeInOut,
              alignment: Alignment.topCenter,
              child: _expanded
                  ? Padding(
                      padding:
                          const EdgeInsets.fromLTRB(12, 0, 12, 10),
                      child: SelectableText(
                        widget.reasoning,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontSize: widget.fontSize - 1,
                          height: 1.35,
                        ),
                      ),
                    )
                  : const SizedBox(width: double.infinity, height: 0),
            ),
          ],
        ),
      ),
    );
  }

  /// A spinner while the model is thinking, the thinking glyph once it is done.
  Widget _leading(ColorScheme scheme) {
    if (!widget.inProgress) {
      return Icon(Icons.psychology_outlined,
          size: 18, color: scheme.onSurfaceVariant);
    }
    return SizedBox(
      width: 14,
      height: 14,
      child: CircularProgressIndicator(
        strokeWidth: 2,
        color: scheme.onSurfaceVariant,
      ),
    );
  }
}
