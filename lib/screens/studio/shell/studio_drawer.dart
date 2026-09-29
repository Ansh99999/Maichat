import 'package:flutter/material.dart';

/// The Studio's drawer: back to MaiChat's home, the Studio's settings, and the
/// list of sessions — and, at its head, which session this is and what it has
/// cost, since there is no bar across the page to say so. Tapping the name
/// renames the session.
class StudioDrawer extends StatelessWidget {
  const StudioDrawer({
    super.key,
    required this.onHome,
    required this.onSettings,
    required this.onSessions,
    this.sessionTitle,
    this.sessionDetail,
    this.onRename,
    this.onContext,
  });

  /// Opens the context inspector for the agent on screen, when a session is
  /// open.
  final VoidCallback? onContext;

  /// The open session's name and a line about it (its spend), when a session
  /// is open.
  final String? sessionTitle;
  final String? sessionDetail;
  final VoidCallback? onRename;

  final VoidCallback onHome;
  final VoidCallback onSettings;
  final VoidCallback onSessions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    void go(VoidCallback action) {
      Navigator.of(context).pop();
      action();
    }

    return NavigationDrawer(
      key: const Key('studio-drawer'),
      selectedIndex: null,
      onDestinationSelected: (i) => go([
        onHome,
        onSettings,
        ?onContext,
        onSessions,
      ][i]),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 20, 16, 12),
          child: Row(
            children: [
              Icon(Icons.auto_awesome, color: theme.colorScheme.primary),
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  'Character Studio',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge,
                ),
              ),
            ],
          ),
        ),
        if (sessionTitle != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Material(
              color: theme.colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(24),
              child: InkWell(
                key: const Key('studio-drawer-session'),
                borderRadius: BorderRadius.circular(24),
                onTap: onRename == null
                    ? null
                    : () {
                        Navigator.of(context).pop();
                        onRename!();
                      },
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              sessionTitle!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleMedium,
                            ),
                            if (sessionDetail != null) ...[
                              const SizedBox(height: 4),
                              Text(
                                sessionDetail!,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (onRename != null)
                        Icon(
                          Icons.edit_outlined,
                          size: 20,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        const NavigationDrawerDestination(
          icon: Icon(Icons.home_outlined),
          selectedIcon: Icon(Icons.home),
          label: Text('Home'),
        ),
        const NavigationDrawerDestination(
          icon: Icon(Icons.tune_outlined),
          selectedIcon: Icon(Icons.tune),
          label: Text('Settings'),
        ),
        if (onContext != null)
          const NavigationDrawerDestination(
            key: Key('studio-drawer-context'),
            icon: Icon(Icons.donut_large_outlined),
            selectedIcon: Icon(Icons.donut_large),
            label: Text('Context'),
          ),
        const NavigationDrawerDestination(
          icon: Icon(Icons.view_list_outlined),
          selectedIcon: Icon(Icons.view_list),
          label: Text('Sessions'),
        ),
      ],
    );
  }
}
