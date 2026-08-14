import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

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
/// retry. While it is on screen the session is read-only (see
/// `AppState.loadError`), so an empty list of chats can never be saved over the
/// real one.
class LoadErrorCard extends StatelessWidget {
  const LoadErrorCard({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
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
              '$message\n\nNothing has been deleted: saving is paused until '
              'this succeeds, so what is on disk stays as it is.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: scheme.onErrorContainer),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: () => context.read<AppState>().retryLoad(),
                icon: const Icon(Icons.refresh),
                label: const Text('Try again'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
