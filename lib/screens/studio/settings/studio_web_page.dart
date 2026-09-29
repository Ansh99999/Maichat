import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../../models/studio.dart';
import '../../../state/app_state.dart';
import 'settings_parts.dart';

/// Whether the Studio may search and read the web, and where it searches.
/// Wikipedia and Fandom need nothing; Brave Search needs a key, SearXNG an
/// address.
class StudioWebPage extends StatefulWidget {
  const StudioWebPage({super.key});

  @override
  State<StudioWebPage> createState() => _StudioWebPageState();
}

class _StudioWebPageState extends State<StudioWebPage> {
  late final AppState _state;
  late final TextEditingController _key;
  late final TextEditingController _url;
  bool _showKey = false;

  @override
  void initState() {
    super.initState();
    _state = context.read<AppState>();
    _key = TextEditingController(text: _state.studioConfig.searchKey);
    _url = TextEditingController(text: _state.studioConfig.searchUrl);
  }

  @override
  void dispose() {
    // Saved as the page closes, not per keystroke: each save is a
    // preferences write.
    _commit();
    _key.dispose();
    _url.dispose();
    super.dispose();
  }

  void _commit() {
    final config = _state.studioConfig;
    final key = _key.text.trim();
    final url = _url.text.trim();
    if (key == config.searchKey && url == config.searchUrl) return;
    unawaited(_state.updateStudioConfig(
      config.copyWith(searchKey: key, searchUrl: url),
    ));
  }

  void _update(StudioConfig next) => unawaited(_state.updateStudioConfig(next));

  @override
  Widget build(BuildContext context) {
    final config = context.watch<AppState>().studioConfig;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Scaffold(
      appBar: AppBar(title: const Text('Web research')),
      body: ListView(
        padding: settingsPagePadding(context),
        children: [
          SettingsGroup(children: [
            SwitchListTile(
              key: const Key('studio-web-switch'),
              contentPadding: const EdgeInsets.fromLTRB(20, 8, 16, 8),
              title: const Text('Let the Studio look things up'),
              subtitle: const Text('Search the web and read pages — for a '
                  'franchise\'s canon, a real place or a period.'),
              value: config.webTools,
              onChanged: (v) => _update(config.copyWith(webTools: v)),
            ),
          ]),
          // What follows only matters while research is on; it folds away
          // rather than sitting there greyed out.
          AnimatedSize(
            duration: const Duration(milliseconds: 280),
            curve: Easing.emphasizedDecelerate,
            alignment: Alignment.topCenter,
            child: !config.webTools
                ? const SizedBox(width: double.infinity)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SettingsGroup(
                        title: 'Search with',
                        children: [
                          RadioGroup<StudioSearchProvider>(
                            groupValue: config.searchProvider,
                            onChanged: (p) {
                              if (p != null) {
                                _update(config.copyWith(searchProvider: p));
                              }
                            },
                            child: Column(
                              children: [
                                for (final p in StudioSearchProvider.values)
                                  RadioListTile<StudioSearchProvider>(
                                    key: Key('studio-search-${p.name}'),
                                    contentPadding:
                                        const EdgeInsets.fromLTRB(12, 4, 16, 4),
                                    value: p,
                                    title: Text(p.label),
                                    subtitle: Text(switch (p) {
                                      StudioSearchProvider.wiki =>
                                        'No key needed.',
                                      StudioSearchProvider.brave =>
                                        'The whole web, with your API key.',
                                      StudioSearchProvider.searxng =>
                                        'The whole web, through your own '
                                            'instance.',
                                    }),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      if (config.searchProvider ==
                          StudioSearchProvider.brave) ...[
                        const SizedBox(height: 24),
                        TextField(
                          key: const Key('studio-search-key'),
                          controller: _key,
                          obscureText: !_showKey,
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: InputDecoration(
                            labelText: 'Brave Search API key',
                            border: const OutlineInputBorder(),
                            suffixIcon: IconButton(
                              tooltip: _showKey ? 'Hide' : 'Show',
                              icon: Icon(_showKey
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined),
                              onPressed: () =>
                                  setState(() => _showKey = !_showKey),
                            ),
                          ),
                        ),
                      ],
                      if (config.searchProvider ==
                          StudioSearchProvider.searxng) ...[
                        const SizedBox(height: 24),
                        TextField(
                          key: const Key('studio-search-url'),
                          controller: _url,
                          keyboardType: TextInputType.url,
                          autocorrect: false,
                          decoration: const InputDecoration(
                            labelText: 'SearXNG address',
                            hintText: 'https://searx.example.org',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Text(
                            'The instance must allow JSON results '
                            '(search.formats includes json).',
                            style: muted,
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Text(
                          'Whichever you pick, the Studio can still search a '
                          'Fandom wiki or a Wikipedia by name, and read any '
                          'public page. It never reads addresses on your own '
                          'network.',
                          style: muted,
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
