import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../services/prefs_repair.dart';
import '../state/app_state.dart';

/// What the app shows before its stored data has been read.
///
/// A bare spinner used to be the whole story, which meant a store the app could
/// not read looked exactly like a store it had not finished reading — the app
/// simply never opened. Startup now always completes, so this screen only lasts
/// as long as the read does, and it says so out loud when that is unusually
/// long.
class StartupScreen extends StatefulWidget {
  const StartupScreen({super.key});

  @override
  State<StartupScreen> createState() => _StartupScreenState();
}

class _StartupScreenState extends State<StartupScreen> {
  static const _slow = Duration(seconds: 6);
  Timer? _timer;
  bool _slowLoad = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(_slow, () {
      if (mounted) setState(() => _slowLoad = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(),
              if (_slowLoad) ...[
                const SizedBox(height: 20),
                Text(
                  'Still reading your saved chats…',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Shown once the app is open but the stored data could not be read. Explains
/// the situation, makes clear that nothing has been thrown away, and offers a
/// retry — plus, when the cause turns out to be pictures too big for the
/// platform to even parse, a way to get the store back under that ceiling.
/// While it is on screen the session is read-only (see `AppState.loadError`),
/// so an empty list of chats can never be saved over the real one.
class LoadErrorCard extends StatefulWidget {
  const LoadErrorCard({super.key, required this.message});

  final String message;

  @override
  State<LoadErrorCard> createState() => _LoadErrorCardState();
}

class _LoadErrorCardState extends State<LoadErrorCard> {
  PrefsScan? _scan;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    _look();
  }

  Future<void> _look() async {
    final scan = await scanPreferences();
    if (mounted) setState(() => _scan = scan);
  }

  static String _size(int bytes) => bytes >= 1024 * 1024
      ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB'
      : '${(bytes / 1024).toStringAsFixed(0)} KB';

  Future<void> _repair() async {
    final scan = _scan;
    if (scan == null || !scan.hasOversized) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove oversized pictures?'),
        content: Text(
          '${scan.oversized.length} character '
          '${scan.oversized.length == 1 ? 'picture' : 'pictures'} take '
          '${_size(scan.oversizedBytes)} of the '
          '${_size(scan.totalBytes)} stored here — more than the phone can load '
          'in one go, which is why nothing opens.\n\n'
          'Removing them leaves your chats, characters, presets and settings '
          'exactly as they are; the characters just lose their picture. The '
          'original file is kept alongside, so nothing is destroyed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove pictures'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _working = true);
    PrefsRepair? result;
    Object? failure;
    try {
      result = await repairPreferences();
    } catch (error) {
      failure = error;
    }
    if (!mounted) return;
    setState(() => _working = false);

    if (result == null) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Could not repair the store'),
          content: Text('${failure ?? 'The stored data was not found.'}'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      );
      return;
    }

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Pictures removed'),
        content: Text(
          'The store went from ${_size(result!.bytesBefore)} to '
          '${_size(result.bytesAfter)}.\n\n'
          'Android only reads the store once per run, so MaiChat has to be '
          'closed and opened again for this to take effect. Your chats will be '
          'there.',
        ),
        actions: [
          FilledButton(
            onPressed: () {
              // Not pop(): the platform holds the old, unreadable store for as
              // long as the process lives, so the process itself has to go.
              exit(0);
            },
            child: const Text('Close MaiChat'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final scan = _scan;
    return Card(
      elevation: 0,
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.warning_amber_outlined,
                    color: scheme.onErrorContainer),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    "Couldn't read your saved data",
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: scheme.onErrorContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              scan != null && scan.hasOversized
                  ? '${scan.oversized.length} character '
                      '${scan.oversized.length == 1 ? 'picture is' : 'pictures are'} '
                      'using ${_size(scan.oversizedBytes)} of the '
                      '${_size(scan.totalBytes)} stored here, which is more than '
                      'the phone can load at once.\n\nRemoving the pictures gets '
                      'everything else back. Nothing is deleted in the meantime: '
                      'saving is paused, so what is on disk stays as it is.'
                  : '${widget.message}\n\nNothing has been deleted: saving is '
                      'paused until this succeeds, so what is on disk stays as '
                      'it is.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: scheme.onErrorContainer),
            ),
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                if (scan != null && scan.hasOversized)
                  FilledButton.icon(
                    onPressed: _working ? null : _repair,
                    icon: _working
                        ? const SizedBox(
                            height: 16,
                            width: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.cleaning_services_outlined),
                    label: const Text('Remove pictures'),
                  ),
                OutlinedButton.icon(
                  onPressed: _working
                      ? null
                      : () => context.read<AppState>().retryLoad(),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Try again'),
                ),
                if (scan?.path != null)
                  TextButton(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Details'),
                        content: SingleChildScrollView(
                          child: SelectableText(
                            '${scan!.path}\n'
                            '${_size(scan.totalBytes)} total\n\n'
                            '${widget.message}',
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
                    child: const Text('Details'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
