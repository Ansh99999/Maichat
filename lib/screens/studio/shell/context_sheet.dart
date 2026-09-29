import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../services/studio/studio_context.dart';
import '../../../services/studio/studio_controller.dart';
import 'context_meter.dart';
import 'shell_format.dart';

/// Opens the context inspector: what the next request of [agentId] (the main
/// agent by default) is made of, category by category, down to single turns —
/// and the raw request itself, with its keys redacted.
Future<void> showStudioContextSheet(
  BuildContext context,
  StudioController controller, {
  String agentId = kMainAgent,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheet) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.86,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: (context, scroll) => StudioContextView(
          controller: controller,
          agentId: agentId,
          scrollController: scroll,
        ),
      ),
    );

/// The body of [showStudioContextSheet], exposed for tests.
class StudioContextView extends StatefulWidget {
  const StudioContextView({
    super.key,
    required this.controller,
    required this.agentId,
    this.scrollController,
  });

  final StudioController controller;
  final String agentId;
  final ScrollController? scrollController;

  @override
  State<StudioContextView> createState() => _StudioContextViewState();
}

class _StudioContextViewState extends State<StudioContextView>
    with ThrottledStudioListener<StudioContextView> {
  late String _agent = widget.agentId;
  StudioContextReport? _report;

  @override
  StudioController get listenedController => widget.controller;

  @override
  void initState() {
    super.initState();
    refresh();
    startListening();
  }

  @override
  void dispose() {
    stopListening();
    super.dispose();
  }

  @override
  void refresh() {
    // A sub-agent can only disappear with its session; fall back to Main.
    if (_agent != kMainAgent && widget.controller.subagent(_agent) == null) {
      _agent = kMainAgent;
    }
    _report = widget.controller.contextFor(_agent);
  }

  void _pick(String agent) {
    if (agent == _agent) return;
    setState(() {
      _agent = agent;
      refresh();
    });
  }

  String? _raw() => widget.controller.nextRequestFor(_agent)?.wire?.preview();

  void _viewRaw() {
    final raw = _raw();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheet) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.9,
        maxChildSize: 0.95,
        builder: (context, scroll) => _RawRequest(
          text: raw,
          scrollController: scroll,
          onCopy: () => _copy(context),
        ),
      ),
    );
  }

  Future<void> _copy(BuildContext from) async {
    final raw = _raw();
    final messenger = ScaffoldMessenger.maybeOf(from);
    if (raw == null) {
      messenger?.showSnackBar(const SnackBar(
        content: Text('Set up a provider first — there is no request yet.'),
      ));
      return;
    }
    await Clipboard.setData(ClipboardData(text: raw));
    messenger?.showSnackBar(const SnackBar(
      content: Text('Raw request copied. Keys are redacted.'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final report = _report;
    final agents = widget.controller.subagents;
    final muted = theme.textTheme.bodyMedium
        ?.copyWith(color: scheme.onSurfaceVariant);
    return ListView(
      key: const Key('studio-context-sheet'),
      controller: widget.scrollController,
      padding: EdgeInsets.fromLTRB(
        24,
        0,
        24,
        32 + MediaQuery.viewPaddingOf(context).bottom,
      ),
      children: [
        Text('Context', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(
          'What the next request carries, and where its tokens go.',
          style: muted,
        ),
        if (agents.isNotEmpty) ...[
          const SizedBox(height: 16),
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _AgentChip(
                  label: 'Main',
                  selected: _agent == kMainAgent,
                  onTap: () => _pick(kMainAgent),
                ),
                for (final a in agents)
                  _AgentChip(
                    label: a.label,
                    selected: _agent == a.id,
                    onTap: () => _pick(a.id),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 24),
        if (report == null)
          Text('Nothing to show yet.', style: muted)
        else ...[
          _Headline(report: report),
          const SizedBox(height: 16),
          _UsageBar(report: report),
          const SizedBox(height: 12),
          _Legend(report: report),
          if (report.lastRequest != null) ...[
            const SizedBox(height: 20),
            _Callout(
              icon: Icons.fact_check_outlined,
              text: 'Last request: the host counted '
                  '${_grouped(report.lastRequest!.reported)} tokens; '
                  'the Studio estimated ${_grouped(report.lastRequest!.estimated)}.',
            ),
          ],
          if (report.wouldCompact) ...[
            const SizedBox(height: 12),
            const _Callout(
              icon: Icons.compress,
              text: 'Before its next step, the older conversation will be '
                  'summarised to make room.',
              emphasis: true,
            ),
          ] else if (report.summarisedTurns > 0) ...[
            const SizedBox(height: 12),
            _Callout(
              icon: Icons.compress,
              text: 'The first ${report.summarisedTurns} turns are sent as a '
                  'summary.',
            ),
          ],
          const SizedBox(height: 32),
          Text('What goes where', style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          for (final section in report.sections)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _SectionTile(
                key: ValueKey('ctx-$_agent-${section.category.name}'),
                section: section,
                total: report.total,
              ),
            ),
        ],
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: FilledButton.tonalIcon(
                key: const Key('studio-context-view-raw'),
                onPressed: _viewRaw,
                icon: const Icon(Icons.data_object),
                label: const Text('View raw request'),
              ),
            ),
            const SizedBox(width: 12),
            IconButton.outlined(
              key: const Key('studio-context-copy-raw'),
              tooltip: 'Copy raw request',
              onPressed: () => _copy(context),
              icon: const Icon(Icons.copy_all_outlined),
            ),
          ],
        ),
      ],
    );
  }
}

class _AgentChip extends StatelessWidget {
  const _AgentChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(
          label: Text(label),
          selected: selected,
          onSelected: (_) => onTap(),
        ),
      );
}

class _Headline extends StatelessWidget {
  const _Headline({required this.report});

  final StudioContextReport report;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final percent = (report.fraction * 100).round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: formatTokens(report.total),
                style: theme.textTheme.displaySmall,
              ),
              TextSpan(
                text: '  of ${formatTokens(report.budget)} tokens',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '$percent% used · summarising starts at '
          '${formatTokens(report.compactAt)}',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// The request's tokens by colour group, in the bar's order, empty groups
/// left out.
List<(StudioContextGroup, int)> _groups(StudioContextReport report) {
  final totals = <StudioContextGroup, int>{};
  for (final s in report.sections) {
    final g = StudioContextGroup.of(s.category);
    totals[g] = (totals[g] ?? 0) + s.tokens;
  }
  return [
    for (final g in StudioContextGroup.values)
      if ((totals[g] ?? 0) > 0) (g, totals[g]!),
  ];
}

/// One bar for the whole budget: a coloured run per group, the rest of the
/// budget as track, and a notch where summarising starts.
class _UsageBar extends StatelessWidget {
  const _UsageBar({required this.report});

  final StudioContextReport report;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final budget = report.budget <= 0 ? 1 : report.budget;
    final used = report.total.clamp(0, budget);
    // Past the budget the runs share the whole bar rather than overflow it.
    final scale = report.total > budget ? budget / report.total : 1.0;
    return SizedBox(
      key: const Key('studio-context-bar'),
      height: 16,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          return Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Row(
                  children: [
                    for (final (group, tokens) in _groups(report))
                      _Segment(
                        width: width * tokens / budget * scale,
                        color: group.colorIn(theme.brightness),
                        gap: scheme.surfaceContainerLow,
                      ),
                    Expanded(
                      child: ColoredBox(color: scheme.surfaceContainerHighest),
                    ),
                  ],
                ),
              ),
              if (used < budget)
                Positioned(
                  left: width * report.threshold - 1,
                  top: 0,
                  bottom: 0,
                  child: Container(width: 2, color: scheme.outline),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({required this.width, required this.color, required this.gap});

  final double width;
  final Color color;
  final Color gap;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
        duration: const Duration(milliseconds: 360),
        curve: Easing.emphasizedDecelerate,
        width: width,
        // A 2dp gap of the sheet between runs, inside the run's own width, so
        // neighbours read apart without the row ever overflowing.
        decoration: BoxDecoration(
          color: color,
          border: width > 4
              ? Border(right: BorderSide(color: gap, width: 2))
              : null,
        ),
      );
}

class _Legend extends StatelessWidget {
  const _Legend({required this.report});

  final StudioContextReport report;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Wrap(
      spacing: 16,
      runSpacing: 8,
      children: [
        for (final (group, tokens) in _groups(report))
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Dot(color: group.colorIn(theme.brightness)),
              const SizedBox(width: 6),
              Text(
                '${group.label} ${formatTokens(tokens)}',
                style: theme.textTheme.labelMedium
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
      ],
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );
}

class _Callout extends StatelessWidget {
  const _Callout({
    required this.icon,
    required this.text,
    this.emphasis = false,
  });

  final IconData icon;
  final String text;
  final bool emphasis;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fg = emphasis ? scheme.onTertiaryContainer : scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: emphasis
            ? scheme.tertiaryContainer
            : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: fg),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(color: fg),
            ),
          ),
        ],
      ),
    );
  }
}

/// One category: a single line folded; its turns, results or schemas opened.
class _SectionTile extends StatefulWidget {
  const _SectionTile({super.key, required this.section, required this.total});

  final StudioContextSection section;
  final int total;

  @override
  State<_SectionTile> createState() => _SectionTileState();
}

class _SectionTileState extends State<_SectionTile> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final s = widget.section;
    final share = widget.total <= 0 ? 0 : (s.tokens * 100 / widget.total).round();
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          InkWell(
            key: Key('studio-context-section-${s.category.name}'),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 16, 16),
              child: Row(
                children: [
                  _Dot(color: contextColor(s.category, theme)),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      s.category.label,
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  Text(
                    '${formatTokens(s.tokens)} · $share%',
                    style: theme.textTheme.labelLarge
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(width: 8),
                  AnimatedRotation(
                    turns: _open ? 0.5 : 0,
                    duration: const Duration(milliseconds: 240),
                    curve: Easing.emphasizedDecelerate,
                    child: Icon(Icons.expand_more,
                        color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 280),
            curve: Easing.emphasizedDecelerate,
            alignment: Alignment.topCenter,
            child: !_open
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
                    child: Column(
                      children: [
                        for (final item in s.items) _ItemRow(item: item),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.item});

  final StudioContextItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(item.label),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: SelectableText(
                item.full,
                style: theme.textTheme.bodySmall
                    ?.copyWith(fontFamily: 'monospace', height: 1.4),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.label, style: theme.textTheme.labelLarge),
                  const SizedBox(height: 2),
                  Text(
                    item.preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  if (item.note != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      item.note!,
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: scheme.tertiary),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              formatTokens(item.tokens),
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _RawRequest extends StatelessWidget {
  const _RawRequest({
    required this.text,
    required this.scrollController,
    required this.onCopy,
  });

  final String? text;
  final ScrollController scrollController;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      key: const Key('studio-context-raw'),
      controller: scrollController,
      padding: EdgeInsets.fromLTRB(
        24,
        0,
        24,
        32 + MediaQuery.viewPaddingOf(context).bottom,
      ),
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Raw request', style: theme.textTheme.headlineSmall),
            ),
            IconButton.filledTonal(
              tooltip: 'Copy raw request',
              onPressed: onCopy,
              icon: const Icon(Icons.copy_all_outlined),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Exactly what the next request sends. Keys are redacted and picture '
          'data is left out.',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(20),
          ),
          child: SelectableText(
            text ?? 'Set up a provider first — there is no request yet.',
            style: theme.textTheme.bodySmall
                ?.copyWith(fontFamily: 'monospace', height: 1.4),
          ),
        ),
      ],
    );
  }
}

String _grouped(int n) {
  final s = '$n';
  final out = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) out.write(',');
    out.write(s[i]);
  }
  return out.toString();
}
