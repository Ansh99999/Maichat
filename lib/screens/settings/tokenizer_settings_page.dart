import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/tokenizer.dart';
import '../../state/app_state.dart';

/// Where the app-wide token counter is chosen, explained, and tried out.
///
/// It used to be a section at the top of the provider list, which put it in the
/// way of the thing that page is for and made the count it displays the first
/// work done on opening Providers. It is a page of its own now, reached from a
/// provider's Basic tab and from Settings.
class TokenizerSettingsPage extends StatefulWidget {
  const TokenizerSettingsPage({super.key});

  @override
  State<TokenizerSettingsPage> createState() => _TokenizerSettingsPageState();
}

class _TokenizerSettingsPageState extends State<TokenizerSettingsPage> {
  static const String _defaultSample =
      'The quick brown fox jumps over the lazy dog.';

  late final TextEditingController _sample =
      TextEditingController(text: _defaultSample);

  /// Null until the first count has run. Counting builds a BPE vocabulary the
  /// first time it is asked, which is far too much work to do inside `build` —
  /// so the field starts empty and fills in on the frame after.
  int? _count;

  @override
  void initState() {
    super.initState();
    _sample.addListener(_recount);
    WidgetsBinding.instance.addPostFrameCallback((_) => _recount());
  }

  @override
  void dispose() {
    _sample.removeListener(_recount);
    _sample.dispose();
    super.dispose();
  }

  void _recount() {
    if (!mounted) return;
    final next = context.read<AppState>().estimateTokens(_sample.text);
    if (next != _count) setState(() => _count = next);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final config = state.tokenizerConfig;

    return Scaffold(
      appBar: AppBar(title: const Text('Tokenizer')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          8,
          16,
          16 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          const _WhatIsATokenizer(),
          const SizedBox(height: 8),
          _label(context, 'COUNTER'),
          _kindTile(context, state, config),
          if (config.kind == TokenizerKind.custom)
            _encodingTile(context, state, config),
          const SizedBox(height: 16),
          _label(context, 'TRY IT'),
          _tryItCard(context, state),
        ],
      ),
    );
  }

  /// A run-in heading, matching the grouping used in the character editor.
  Widget _label(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
        child: Text(
          text,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
        ),
      );

  Widget _kindTile(
    BuildContext context,
    AppState state,
    TokenizerConfig config,
  ) {
    String subtitle() => switch (config.kind) {
          TokenizerKind.openai =>
            'Exact tiktoken counts; the encoding follows the active model.',
          TokenizerKind.anthropic =>
            'Approximate offline (o200k). Exact counts appear in a message’s '
                'Info when a Claude key is set.',
          TokenizerKind.custom => 'Uses the chosen BPE encoding everywhere.',
        };

    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: ListTile(
        leading: const Icon(Icons.calculate_outlined),
        title: const Text('Token counter'),
        subtitle: Text(subtitle()),
        trailing: DropdownButton<TokenizerKind>(
          value: config.kind,
          underline: const SizedBox.shrink(),
          borderRadius: BorderRadius.circular(12),
          onChanged: (kind) {
            if (kind == null) return;
            state.updateTokenizerConfig(config.copyWith(kind: kind));
            // The encoding may have changed under the sample.
            WidgetsBinding.instance.addPostFrameCallback((_) => _recount());
          },
          items: [
            for (final kind in TokenizerKind.values)
              DropdownMenuItem(value: kind, child: Text(kind.label)),
          ],
        ),
      ),
    );
  }

  Widget _encodingTile(
    BuildContext context,
    AppState state,
    TokenizerConfig config,
  ) {
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: ListTile(
        leading: const Icon(Icons.abc_outlined),
        title: const Text('Encoding'),
        subtitle: const Text('cl100k for GPT-4-era models, o200k for newer'),
        trailing: DropdownButton<BpeEncoding>(
          value: config.customEncoding,
          underline: const SizedBox.shrink(),
          borderRadius: BorderRadius.circular(12),
          onChanged: (encoding) {
            if (encoding == null) return;
            state.updateTokenizerConfig(
                config.copyWith(customEncoding: encoding));
            WidgetsBinding.instance.addPostFrameCallback((_) => _recount());
          },
          items: [
            for (final encoding in BpeEncoding.values)
              DropdownMenuItem(value: encoding, child: Text(encoding.label)),
          ],
        ),
      ),
    );
  }

  /// Type anything and watch the count follow. This is the part that turns the
  /// tokenizer from a setting into something a user can reason about.
  Widget _tryItCard(BuildContext context, AppState state) {
    final scheme = Theme.of(context).colorScheme;
    final count = _count;
    final approximate = state.tokenizerIsApproximate;

    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _sample,
              minLines: 2,
              maxLines: 6,
              decoration: const InputDecoration(
                labelText: 'Sample text',
                hintText: 'Type or paste anything',
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.numbers, size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    count == null
                        ? 'Counting…'
                        : '${approximate ? '~' : ''}$count '
                            'token${count == 1 ? '' : 's'} · '
                            '${state.activeTokenizerEncoding.id}',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
                if (_sample.text != _defaultSample)
                  TextButton(
                    onPressed: () => _sample.text = _defaultSample,
                    child: const Text('Reset'),
                  ),
              ],
            ),
            if (approximate) ...[
              const SizedBox(height: 4),
              Text(
                'Approximate: Anthropic publishes no offline tokenizer, so this '
                'is o200k standing in. Counts in the app are marked with ~.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The short explanation, so the setting is not a word the user has to go and
/// search for. Collapsed by default — anyone who already knows what a tokenizer
/// is should not have to scroll past a paragraph about it.
class _WhatIsATokenizer extends StatefulWidget {
  const _WhatIsATokenizer();

  @override
  State<_WhatIsATokenizer> createState() => _WhatIsATokenizerState();
}

class _WhatIsATokenizerState extends State<_WhatIsATokenizer> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: () => setState(() => _open = !_open),
              child: Row(
                children: [
                  Icon(Icons.help_outline, size: 20, color: scheme.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        'What is a tokenizer?',
                        style: Theme.of(context)
                            .textTheme
                            .titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                  AnimatedRotation(
                    turns: _open ? 0.5 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: const Icon(Icons.expand_more),
                  ),
                ],
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeInOut,
              alignment: Alignment.topCenter,
              child: _open
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(0, 0, 8, 8),
                      child: Text(
                        _body,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                              height: 1.45,
                            ),
                      ),
                    )
                  : const SizedBox(width: double.infinity, height: 0),
            ),
          ],
        ),
      ),
    );
  }

  static const String _body =
      'A model does not read letters — it reads tokens, which are chunks of a '
      'word. "tokenizer" might be three of them. Every model has a limit on how '
      'many tokens one conversation can hold, and hosts bill by the token.\n\n'
      'MaiChat counts tokens to decide how much history fits in a request, and '
      'to work out what a reply cost. Counting the way your model counts keeps '
      'both honest: the wrong counter either wastes room or overruns the limit.\n\n'
      'Pick OpenAI for GPT models and most OpenAI-compatible hosts — it is exact. '
      'Pick Anthropic for Claude; it has no public offline tokenizer, so the '
      'count is close rather than exact and is shown with a ~. Pick Custom to '
      'pin one encoding regardless of the model.';
}
