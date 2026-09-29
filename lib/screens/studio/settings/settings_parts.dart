import 'package:flutter/material.dart';

/// A group of rows on a Studio settings page, in Material 3 Expressive's
/// segmented-list style: one rounded surface per group, rows joined by a thin
/// seam, the outer corners large and the inner ones small.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, required this.children, this.title});

  final String? title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 24, 8, 12),
            child: Text(
              title!,
              style: theme.textTheme.titleMedium
                  ?.copyWith(color: scheme.primary),
            ),
          ),
        for (var i = 0; i < children.length; i++)
          Padding(
            padding: EdgeInsets.only(bottom: i == children.length - 1 ? 0 : 2),
            child: ClipRRect(
              borderRadius: BorderRadius.vertical(
                top: Radius.circular(i == 0 ? 24 : 6),
                bottom: Radius.circular(i == children.length - 1 ? 24 : 6),
              ),
              child: Material(
                color: scheme.surfaceContainerLow,
                child: children[i],
              ),
            ),
          ),
      ],
    );
  }
}

/// A row that opens another page: a leading icon in a tonal square, a title,
/// one line of what is there, a chevron.
class SettingsLink extends StatelessWidget {
  const SettingsLink({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      leading: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: scheme.secondaryContainer,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Icon(icon, color: scheme.onSecondaryContainer),
      ),
      title: Text(title),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

/// The padding every Studio settings sub-page's list uses: roomy gutters, and
/// the bottom kept clear of the gesture bar (and a floating button).
EdgeInsets settingsPagePadding(BuildContext context, {bool fab = false}) =>
    EdgeInsets.fromLTRB(
      16,
      8,
      16,
      (fab ? 104 : 32) + MediaQuery.paddingOf(context).bottom,
    );
