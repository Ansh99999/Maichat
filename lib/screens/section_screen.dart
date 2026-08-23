import 'package:flutter/material.dart';

/// A stand-in page for sections that are wired into the drawer but not built
/// out yet (Scenarios, Image Generation, Notifications).
///
/// It keeps navigation honest — every drawer entry lands somewhere real with a
/// back arrow — while signalling clearly that the feature is still to come.
class SectionScreen extends StatelessWidget {
  const SectionScreen({super.key, required this.title, required this.icon});

  final String title;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(32, 0, 32, 48),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 56, color: scheme.outline),
              const SizedBox(height: 16),
              Text('$title coming soon',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                'This section is on the way.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
