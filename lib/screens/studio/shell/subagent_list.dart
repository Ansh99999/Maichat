import 'package:flutter/material.dart';

import '../../../models/studio.dart';
import '../../../services/studio/studio_controller.dart';
import 'shell_format.dart';

/// What the liquid panel holds: Main, then every sub-agent with how long it has
/// run and what it has spent. Tapping a row shows that agent's conversation.
class SubagentList extends StatelessWidget {
  const SubagentList({
    super.key,
    required this.controller,
    required this.viewing,
    required this.onSelect,
  });

  final StudioController controller;

  /// The agent whose conversation is on screen.
  final String viewing;
  final ValueChanged<String> onSelect;

  /// Height of one row, for sizing the panel before it is laid out.
  static const double rowHeight = 52;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final agents = controller.subagents;
        final anyRunning = agents.any((a) => a.running);
        final subTokens = agents.fold<int>(0, (s, a) => s + a.tokens);
        final mainTokens = (controller.session.inputTokens +
                controller.session.outputTokens -
                subTokens)
            .clamp(0, 1 << 62);
        return Material(
          type: MaterialType.transparency,
          child: Ticking(
            active: anyRunning,
            builder: (context) => ListView(
              key: const Key('studio-subagent-list'),
              padding: const EdgeInsets.symmetric(vertical: 6),
              children: [
                _Row(
                  key: const Key('studio-agent-row-main'),
                  icon: Icons.hub_outlined,
                  title: 'Main',
                  detail: mainTokens > 0 ? '${formatTokens(mainTokens)} tokens' : null,
                  status: controller.running
                      ? StudioAgentStatus.running
                      : StudioAgentStatus.done,
                  showStatus: controller.running,
                  selected: viewing == kMainAgent,
                  onTap: () => onSelect(kMainAgent),
                ),
                for (final a in agents)
                  _Row(
                    key: Key('studio-agent-row-${a.id}'),
                    icon: Icons.smart_toy_outlined,
                    title: a.description.trim().isEmpty
                        ? a.label
                        : '${a.label} — ${a.description.trim()}',
                    detail: '${formatElapsed(a.elapsed())} • '
                        '${formatTokens(a.tokens)} tokens',
                    status: a.status,
                    selected: viewing == a.id,
                    onTap: () => onSelect(a.id),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    super.key,
    required this.icon,
    required this.title,
    required this.status,
    required this.selected,
    required this.onTap,
    this.detail,
    this.showStatus = true,
  });

  final IconData icon;
  final String title;
  final String? detail;
  final StudioAgentStatus status;
  final bool showStatus;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fg = selected ? scheme.onSecondaryContainer : scheme.onSurface;
    Widget? badge;
    if (showStatus) {
      badge = switch (status) {
        StudioAgentStatus.running => const SizedBox.square(
            dimension: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        StudioAgentStatus.done =>
          Icon(Icons.check_circle, size: 16, color: scheme.primary),
        StudioAgentStatus.failed =>
          Icon(Icons.error, size: 16, color: scheme.error),
        StudioAgentStatus.cancelled =>
          Icon(Icons.stop_circle_outlined, size: 16, color: scheme.outline),
      };
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      child: Material(
        color: selected ? scheme.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: SizedBox(
            height: SubagentList.rowHeight - 2,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Icon(icon, size: 20, color: fg),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: fg,
                        fontWeight: selected ? FontWeight.w600 : null,
                      ),
                    ),
                  ),
                  if (detail != null) ...[
                    const SizedBox(width: 8),
                    Text(
                      detail!,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: selected
                            ? scheme.onSecondaryContainer
                            : scheme.onSurfaceVariant,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                  if (badge != null) ...[const SizedBox(width: 10), badge],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
