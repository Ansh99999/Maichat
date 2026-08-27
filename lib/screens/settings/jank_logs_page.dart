import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/jank_logger.dart';

/// **Temporary** diagnostics screen: shows the janky frames [JankLogger] has
/// caught and lets the log be copied or saved out, to hand to Claude. Delete
/// alongside [JankLogger] once the stutter is understood.
class JankLogsPage extends StatefulWidget {
  const JankLogsPage({super.key});

  @override
  State<JankLogsPage> createState() => _JankLogsPageState();
}

class _JankLogsPageState extends State<JankLogsPage> {
  // The logger is not a listenable; poll it while this screen is open so newly
  // caught frames appear without a manual refresh.
  late final _ticker = Stream<void>.periodic(const Duration(seconds: 1));

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: JankLogger.instance.report()));
    if (mounted) _toast('Log copied to clipboard');
  }

  Future<void> _save() async {
    final bytes = Uint8List.fromList(utf8.encode(JankLogger.instance.report()));
    final name = 'maichat-jank-${DateTime.now().millisecondsSinceEpoch}.txt';
    try {
      final path = await FilePicker.saveFile(
        dialogTitle: 'Save jank log',
        fileName: name,
        bytes: bytes,
        type: FileType.custom,
        allowedExtensions: const ['txt'],
      );
      if (mounted) _toast(path == null ? 'Save cancelled' : 'Saved to $path');
    } catch (_) {
      // Some platforms cannot write bytes from the save dialog; the clipboard
      // is always there as a fallback.
      await _copy();
    }
  }

  void _toast(String msg) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg)));

  Widget _sectionHeader(BuildContext context, String text) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: scheme.primary,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<void>(
      stream: _ticker,
      builder: (context, _) => _build(context),
    );
  }
  Widget _build(BuildContext context) {
    final logger = JankLogger.instance;
    final s = logger.summary;
    final events = logger.events.reversed.toList(); // newest first on screen
    final placements = logger.placements.reversed.toList(); // newest first
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Jank logs'),
        actions: [
          IconButton(
            tooltip: 'Clear',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => setState(logger.clear),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              s.recording
                  ? 'Recording. Use the app normally; when it stutters or '
                      'freezes, the frame is caught here. To trace the float '
                      '"placed further away" glitch, float a picture, drag/pinch '
                      'and let go — each release is listed below. Then Copy or '
                      'Save and send it over.'
                  : 'Not recording. Turn on "Record jank logs" in Appearance '
                      'first.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          ),
          _SummaryStrip(summary: s, placements: placements.length),
          const Divider(height: 1),
          Expanded(
            child: (events.isEmpty && placements.isEmpty)
                ? Center(
                    child: Text(
                      s.recording
                          ? 'No janky frames or placements yet.'
                          : 'Nothing recorded.',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  )
                : ListView(
                    children: [
                      if (placements.isNotEmpty) ...[
                        _sectionHeader(context, 'Float placements (release '
                            'trace) — newest first'),
                        for (final p in placements)
                          _PlacementTile(placement: p),
                      ],
                      if (events.isNotEmpty) ...[
                        _sectionHeader(context, 'Janky frames — newest first'),
                        for (final e in events) _EventTile(event: e),
                      ],
                    ],
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _copy,
                      icon: const Icon(Icons.copy_all_outlined),
                      label: const Text('Copy'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _save,
                      icon: const Icon(Icons.download_outlined),
                      label: const Text('Save log'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
/// The at-a-glance counters across the top.
class _SummaryStrip extends StatelessWidget {
  const _SummaryStrip({required this.summary, required this.placements});

  final JankSummary summary;
  final int placements;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _chip(context, 'frames', '${summary.framesSeen}'),
          _chip(context, 'janky', '${summary.jankyFrames}'),
          _chip(context, 'placements', '$placements'),
          _chip(context, 'freezes', '${summary.freezes}',
              alert: summary.freezes > 0),
          _chip(context, 'worst build',
              '${summary.worstBuildMs.toStringAsFixed(0)}ms',
              alert: summary.worstBuildMs >= JankLogger.budgetMs),
          _chip(context, 'worst raster',
              '${summary.worstRasterMs.toStringAsFixed(0)}ms',
              alert: summary.worstRasterMs >= JankLogger.budgetMs),
        ],
      ),
    );
  }

  Widget _chip(BuildContext context, String label, String value,
      {bool alert = false}) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: alert ? scheme.errorContainer : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '$label  $value',
        style: TextStyle(
          fontSize: 12,
          color: alert ? scheme.onErrorContainer : scheme.onSurface,
          fontWeight: alert ? FontWeight.w600 : FontWeight.w500,
        ),
      ),
    );
  }
}

/// One floating-picture release: how far it shifted at lift-off and the raw
/// tail of frames behind that number.
class _PlacementTile extends StatelessWidget {
  const _PlacementTile({required this.placement});

  final FloatPlacement placement;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // A lift-off jump is the tell: the last frame moved far more than a typical
    // one, or moved at all after the finger had effectively stopped.
    final suspect = placement.lastShiftPx > placement.typicalShiftPx * 3 + 2 ||
        (placement.gapBeforeUpMs > 40 && placement.lastShiftPx > 2);
    return ExpansionTile(
      dense: true,
      leading: Icon(
        suspect ? Icons.error_outline : Icons.open_with,
        color: suspect ? scheme.error : scheme.tertiary,
      ),
      title: Text(
        'shift@release ${placement.releaseShiftPx.toStringAsFixed(1)}px'
        '${suspect ? '  ⚠ lift-off jump' : ''}',
        style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
      ),
      subtitle: Text(
        '${placement.hadTwoFingers ? '2+finger' : '1finger'} '
        '(max ${placement.maxFingers}) · last '
        '${placement.lastShiftPx.toStringAsFixed(1)} vs typ '
        '${placement.typicalShiftPx.toStringAsFixed(1)}px · '
        'gap ${placement.gapBeforeUpMs}ms · moves ${placement.moves}',
      ),
      childrenPadding: const EdgeInsets.fromLTRB(56, 0, 16, 12),
      children: [
        for (final line in placement.tail)
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              line,
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
      ],
    );
  }
}

/// One over-budget frame: which thread blew the budget, by how much, and what
/// the app was doing.
class _EventTile extends StatelessWidget {
  const _EventTile({required this.event});

  final JankEvent event;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final buildHot = event.buildMs >= JankLogger.budgetMs;
    final rasterHot = event.rasterMs >= JankLogger.budgetMs;
    final blame = event.isFreeze
        ? 'FREEZE'
        : (buildHot && rasterHot)
            ? 'UI + GPU'
            : buildHot
                ? 'UI thread (build)'
                : 'GPU (raster)';
    return ListTile(
      dense: true,
      leading: Icon(
        event.isFreeze ? Icons.ac_unit : Icons.warning_amber_rounded,
        color: event.isFreeze ? scheme.error : scheme.tertiary,
      ),
      title: Text(
        'build ${event.buildMs.toStringAsFixed(1)}ms · '
        'raster ${event.rasterMs.toStringAsFixed(1)}ms · '
        'total ${event.totalMs.toStringAsFixed(1)}ms',
        style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
      ),
      subtitle: Text(
        '$blame — ${event.activity}'
        '${event.crumb.isEmpty ? '' : '  ·  ${event.crumb}'}',
      ),
      trailing: Text('#${event.frame}',
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11)),
    );
  }
}
