import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/provider.dart';
import '../../services/chat_client.dart';
import '../../state/app_state.dart';
import 'provider_draft.dart';

/// The API-key pool: one row per credential, each able to hide, reveal and test
/// itself, with a "Test all keys" action over the list.
///
/// Every row is the same shape. An earlier version gave only the first key the
/// reveal control and the rest a bare field, which made the extra keys look like
/// a lesser kind of key than the first — they are not; rotation treats them
/// alike.
class ProviderKeysSection extends StatefulWidget {
  const ProviderKeysSection({
    super.key,
    required this.draft,
    required this.onChanged,
  });

  final ProviderDraft draft;
  final VoidCallback onChanged;

  @override
  State<ProviderKeysSection> createState() => _ProviderKeysSectionState();
}

class _ProviderKeysSectionState extends State<ProviderKeysSection> {
  /// Reveal state per row, keyed by the controller itself rather than by index:
  /// removing key 2 must not hand its "revealed" state to whatever slides up
  /// into slot 2.
  final Map<TextEditingController, bool> _revealed = {};

  /// Test results, keyed the same way and for the same reason.
  final Map<TextEditingController, KeyTestResult> _results = {};

  /// Rows with a test in flight.
  final Set<TextEditingController> _testing = {};

  /// True while "Test all" is walking the list.
  bool _testingAll = false;

  Future<void> _test(TextEditingController controller) async {
    final key = controller.text.trim();
    if (key.isEmpty || _testing.contains(controller)) return;
    setState(() {
      _testing.add(controller);
      _results.remove(controller);
    });
    final result = await context
        .read<AppState>()
        .testProviderKey(widget.draft.toProvider(), key);
    if (!mounted) return;
    setState(() {
      _testing.remove(controller);
      _results[controller] = result;
    });
  }

  /// Tests every filled row in turn.
  ///
  /// Sequential on purpose: firing a pool of keys at one host at once is a good
  /// way to get rate-limited and told that working keys do not work.
  Future<void> _testAll() async {
    if (_testingAll) return;
    setState(() => _testingAll = true);
    for (final controller in widget.draft.keys) {
      if (!mounted) break;
      if (controller.text.trim().isEmpty) continue;
      await _test(controller);
    }
    if (!mounted) return;
    setState(() => _testingAll = false);

    final tested = widget.draft.keys
        .where((c) => _results.containsKey(c))
        .toList(growable: false);
    if (tested.isEmpty) return;
    final passed = tested.where((c) => _results[c]!.ok).length;
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          tested.length == 1
              ? (passed == 1 ? 'The key works.' : 'The key was refused.')
              : '$passed of ${tested.length} keys work.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final draft = widget.draft;
    final filled = draft.keys.where((c) => c.text.trim().isNotEmpty).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: _label(context, 'API KEYS')),
            if (filled > 1)
              _testingAll
                  ? const Padding(
                      padding: EdgeInsets.only(right: 12),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : TextButton.icon(
                      onPressed: _testAll,
                      icon: const Icon(Icons.playlist_add_check, size: 18),
                      label: const Text('Test all keys'),
                    ),
          ],
        ),
        for (var i = 0; i < draft.keys.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _keyRow(i),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () {
              setState(draft.addKey);
              widget.onChanged();
            },
            icon: const Icon(Icons.add),
            label: const Text('Add another key'),
          ),
        ),
        if (draft.keys.length > 1) _strategyField(),
        if (!draft.kind.requiresKey && filled == 0)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'This format usually needs no key. Leave it blank unless your '
              'server asks for one.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
      ],
    );
  }

  Widget _label(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
        child: Text(
          text,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
        ),
      );

  Widget _keyRow(int index) {
    final controller = widget.draft.keys[index];
    final revealed = _revealed[controller] ?? false;
    final result = _results[controller];
    final busy = _testing.contains(controller);
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: controller,
          obscureText: !revealed,
          autocorrect: false,
          enableSuggestions: false,
          // A pasted key must not be autocorrected or capitalised.
          keyboardType: TextInputType.visiblePassword,
          decoration: InputDecoration(
            labelText: widget.draft.keys.length == 1
                ? 'API key'
                : 'API key ${index + 1}',
            prefixIcon: const Icon(Icons.key_outlined),
            suffixIcon: _rowActions(index, controller, revealed, busy, result),
            errorText: result != null && !result.ok ? result.message : null,
            helperText: result != null && result.ok ? result.message : null,
            helperStyle: TextStyle(color: scheme.primary),
            helperMaxLines: 3,
            errorMaxLines: 4,
          ),
          onChanged: (_) {
            // A key that has been edited has not been tested.
            if (_results.remove(controller) != null) setState(() {});
            widget.onChanged();
          },
        ),
      ],
    );
  }

  /// The controls that ride inside a key field: reveal, test, and remove. Kept
  /// to a fixed-width row so the fields line up whatever state they are in.
  Widget _rowActions(
    int index,
    TextEditingController controller,
    bool revealed,
    bool busy,
    KeyTestResult? result,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: revealed ? 'Hide' : 'Show',
          icon: Icon(
            revealed
                ? Icons.visibility_off_outlined
                : Icons.visibility_outlined,
            size: 20,
          ),
          onPressed: () =>
              setState(() => _revealed[controller] = !revealed),
        ),
        // The test control and its outcome occupy one slot, so a result does not
        // shift the row's layout when it arrives.
        SizedBox(
          width: 48,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: busy
                ? const Center(
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IconButton(
                    key: ValueKey<String>(
                      result == null ? 'test' : (result.ok ? 'ok' : 'bad'),
                    ),
                    tooltip: result == null
                        ? 'Test this key'
                        : (result.ok ? 'Key works — test again' : 'Test again'),
                    icon: Icon(
                      result == null
                          ? Icons.check_circle_outline
                          : (result.ok
                              ? Icons.check_circle
                              : Icons.error_outline),
                      size: 20,
                      color: result == null
                          ? null
                          : (result.ok ? scheme.primary : scheme.error),
                    ),
                    onPressed: () => _test(controller),
                  ),
          ),
        ),
        if (widget.draft.keys.length > 1)
          IconButton(
            tooltip: 'Remove key',
            icon: const Icon(Icons.remove_circle_outline, size: 20),
            onPressed: () {
              _revealed.remove(controller);
              _results.remove(controller);
              setState(() => widget.draft.removeKey(index));
              widget.onChanged();
            },
          ),
      ],
    );
  }

  /// How the pool is spread across requests. Only meaningful with more than one
  /// key, so it appears with the second row rather than sitting there greyed out.
  Widget _strategyField() {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 4),
        InputDecorator(
          decoration: const InputDecoration(
            labelText: 'Key rotation',
            prefixIcon: Icon(Icons.sync),
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<KeyRotationStrategy>(
              isExpanded: true,
              value: widget.draft.keyStrategy,
              borderRadius: BorderRadius.circular(12),
              onChanged: (next) {
                if (next == null) return;
                setState(() => widget.draft.keyStrategy = next);
                widget.onChanged();
              },
              items: [
                for (final strategy in KeyRotationStrategy.values)
                  DropdownMenuItem<KeyRotationStrategy>(
                    value: strategy,
                    child: Text(strategy.label),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          switch (widget.draft.keyStrategy) {
            KeyRotationStrategy.roundRobin =>
              'Each reply uses the next key in the list, spreading the load.',
            KeyRotationStrategy.random =>
              'Each reply picks a key at random.',
            KeyRotationStrategy.errorBased =>
              'Stays on one key until it fails, then moves to the next.',
          },
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}
