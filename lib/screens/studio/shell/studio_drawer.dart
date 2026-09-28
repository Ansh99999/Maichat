import 'package:flutter/material.dart';

/// The Studio's drawer: back to MaiChat's home, the Studio's settings, and the
/// list of sessions.
class StudioDrawer extends StatelessWidget {
  const StudioDrawer({
    super.key,
    required this.onHome,
    required this.onSettings,
    required this.onSessions,
  });

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
      onDestinationSelected: (i) => switch (i) {
        0 => go(onHome),
        1 => go(onSettings),
        _ => go(onSessions),
      },
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
        const NavigationDrawerDestination(
          icon: Icon(Icons.view_list_outlined),
          selectedIcon: Icon(Icons.view_list),
          label: Text('Sessions'),
        ),
      ],
    );
  }
}
