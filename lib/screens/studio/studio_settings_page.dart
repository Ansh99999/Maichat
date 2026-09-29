import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/studio.dart';
import '../../services/studio/studio_prompt.dart';
import '../../state/app_state.dart';
import 'settings/settings_parts.dart';
import 'settings/studio_agents_page.dart';
import 'settings/studio_commands_page.dart';
import 'settings/studio_memory_page.dart';
import 'settings/studio_skills_page.dart';
import 'settings/studio_web_page.dart';

/// How the Studio talks to its model: which provider and model build the
/// characters, how far one message may run, whether helpers are allowed, and
/// the builder's instructions.
class StudioSettingsPage extends StatefulWidget {
  const StudioSettingsPage({super.key});

  @override
  State<StudioSettingsPage> createState() => _StudioSettingsPageState();
}

class _StudioSettingsPageState extends State<StudioSettingsPage> {
  late final TextEditingController _model;
  late final TextEditingController _temperature;
  late final TextEditingController _maxTokens;
  late final TextEditingController _prompt;

  /// Held from the start: the text boxes are saved in [dispose], where the
  /// context can no longer be used to look it up.
  late final AppState _state;

  @override
  void initState() {
    super.initState();
    _state = context.read<AppState>();
    final config = _state.studioConfig;
    _model = TextEditingController(text: config.model);
    _temperature =
        TextEditingController(text: config.temperature?.toString() ?? '');
    _maxTokens = TextEditingController(text: config.maxTokens?.toString() ?? '');
    _prompt = TextEditingController(
      text: config.systemPrompt.isEmpty ? defaultStudioPrompt() : config.systemPrompt,
    );
  }

  @override
  void dispose() {
    // Text boxes save as the page closes rather than per keystroke: every save
    // is a preferences write.
    _commitText();
    _model.dispose();
    _temperature.dispose();
    _maxTokens.dispose();
    _prompt.dispose();
    super.dispose();
  }

  void _commitText() {
    final state = _state;
    final prompt = _prompt.text.trim();
    final temperature = double.tryParse(_temperature.text.trim());
    final maxTokens = int.tryParse(_maxTokens.text.trim());
    state.updateStudioConfig(state.studioConfig.copyWith(
      model: _model.text.trim(),
      temperature: () => temperature,
      maxTokens: () => maxTokens == null || maxTokens <= 0 ? null : maxTokens,
      // The built-in prompt is stored as "none", so it improves with the app.
      systemPrompt: prompt == defaultStudioPrompt().trim() ? '' : prompt,
    ));
  }

  void _update(StudioConfig next) => _state.updateStudioConfig(next);

  /// The budgets the slider stops at: roughly doubling, so both a small local
  /// model's window and a million-token one are a short drag away.
  static const List<int> kBudgetSteps = [
    16000, 32000, 64000, 96000, 120000, 160000, 200000, 300000, 500000,
    1000000,
  ];

  static int _budgetStep(int budget) {
    var best = 0;
    for (var i = 0; i < kBudgetSteps.length; i++) {
      if ((kBudgetSteps[i] - budget).abs() <
          (kBudgetSteps[best] - budget).abs()) {
        best = i;
      }
    }
    return best;
  }

  static String _budgetLabel(int tokens) => tokens >= 1000000
      ? '${(tokens / 1000000).toStringAsFixed(tokens % 1000000 == 0 ? 0 : 1)}M'
      : '${(tokens / 1000).round()}k';

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final config = state.studioConfig;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final providers = state.providers;
    final chosen =
        providers.any((p) => p.id == config.providerId) ? config.providerId : null;
    final using = state.studioProvider();

    return Scaffold(
      appBar: AppBar(title: const Text('Studio settings')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          8,
          16,
          24 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          Text('Model', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            'The model that builds characters. It must support tool calling. '
            'Playtests always use your chat setup, so you hear the card the '
            'way you will play it.',
            style: muted,
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String?>(
            initialValue: chosen,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Provider',
              border: OutlineInputBorder(),
            ),
            items: [
              const DropdownMenuItem<String?>(
                value: null,
                child: Text('Same as chats'),
              ),
              for (final p in providers)
                DropdownMenuItem<String?>(
                  value: p.id,
                  child: Text(p.name, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (id) => _update(config.copyWith(providerId: () => id)),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _model,
            decoration: InputDecoration(
              labelText: 'Model',
              hintText: using?.model.isNotEmpty == true
                  ? 'The provider\'s own (${using!.model})'
                  : 'The provider\'s own',
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _temperature,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Temperature',
                    hintText: 'Model default',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _maxTokens,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Max reply tokens',
                    hintText: 'Default',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Stream replies'),
            subtitle: const Text(
              'Turn off for a gateway that breaks tool calls while streaming.',
            ),
            value: config.stream,
            onChanged: (v) => _update(config.copyWith(stream: v)),
          ),
          const Divider(height: 24),
          Text('Agent', style: theme.textTheme.titleSmall),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Sub-agents'),
            subtitle: const Text(
              'Let the Studio split a build across sub-agents that work side '
              'by side on the same draft — as many as you ask it for. Faster on '
              'big builds; each sub-agent is its own set of requests, and its '
              'conversation can be opened from the button at the top right.',
            ),
            value: config.subAgents,
            onChanged: (v) => _update(config.copyWith(subAgents: v)),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Steps per message'),
            subtitle: Text(
              'How many model turns one message may run before the Studio '
              'stops and reports — the ceiling on what one "go" can spend.',
              style: muted,
            ),
            trailing: Text('${config.maxSteps}',
                style: theme.textTheme.titleMedium),
          ),
          Slider(
            value: config.maxSteps.toDouble().clamp(5, 100),
            min: 5,
            max: 100,
            divisions: 19,
            label: '${config.maxSteps}',
            onChanged: (v) => _update(config.copyWith(maxSteps: v.round())),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Context budget'),
            subtitle: Text(
              'When a conversation with the Studio grows past this many '
              'tokens, its older part is summarised so the agent can keep '
              'working. Never more than the model\'s own window.',
              style: muted,
            ),
            trailing: Text(
              _budgetLabel(config.contextBudget),
              style: theme.textTheme.titleMedium,
            ),
          ),
          Slider(
            key: const Key('studio-context-budget'),
            value: _budgetStep(config.contextBudget).toDouble(),
            min: 0,
            max: (kBudgetSteps.length - 1).toDouble(),
            divisions: kBudgetSteps.length - 1,
            label: _budgetLabel(config.contextBudget),
            onChanged: (v) => _update(
              config.copyWith(contextBudget: kBudgetSteps[v.round()]),
            ),
          ),
          const Divider(height: 24),
          Text('Knowledge', style: theme.textTheme.titleSmall),
          const SizedBox(height: 12),
          SettingsGroup(children: [
            SettingsLink(
              key: const Key('studio-settings-agents'),
              icon: Icons.groups_outlined,
              title: 'Sub-agent types',
              subtitle: config.customAgents.isEmpty
                  ? 'Four built in; add your own'
                  : '${config.customAgents.length} of your own, four built in',
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => const StudioAgentsPage(),
              )),
            ),
            SettingsLink(
              key: const Key('studio-settings-web'),
              icon: Icons.travel_explore_outlined,
              title: 'Web research',
              subtitle: config.webTools
                  ? config.searchProvider.label
                  : 'Off',
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => const StudioWebPage(),
              )),
            ),
            SettingsLink(
              key: const Key('studio-settings-memory'),
              icon: Icons.psychology_outlined,
              title: 'Memory',
              subtitle: config.memoryEnabled
                  ? 'What the Studio remembers about you'
                  : 'Off',
              onTap: () => openStudioMemory(context),
            ),
            SettingsLink(
              key: const Key('studio-settings-skills'),
              icon: Icons.auto_stories_outlined,
              title: 'Skills',
              subtitle: 'Instructions the Studio loads when the work fits',
              onTap: () => openStudioSkills(context),
            ),
            SettingsLink(
              key: const Key('studio-settings-commands'),
              icon: Icons.keyboard_command_key,
              title: 'Commands',
              subtitle: 'Your own / commands',
              onTap: () => openStudioCommands(context),
            ),
          ]),
          const Divider(height: 40),
          Row(
            children: [
              Expanded(
                child: Text('Instructions', style: theme.textTheme.titleSmall),
              ),
              TextButton(
                onPressed: () =>
                    setState(() => _prompt.text = defaultStudioPrompt()),
                child: const Text('Reset'),
              ),
            ],
          ),
          Text(
            'What the Studio is told before every message. The built-in '
            'version is kept up to date with the app until you change it.',
            style: muted,
          ),
          const SizedBox(height: 8),
          // A fixed-height box that scrolls inside, like the creator's long
          // fields, so the page does not move under the caret.
          SizedBox(
            height: 360,
            child: TextField(
              controller: _prompt,
              expands: true,
              maxLines: null,
              textAlignVertical: TextAlignVertical.top,
              style: theme.textTheme.bodySmall,
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
          ),
        ],
      ),
    );
  }
}
