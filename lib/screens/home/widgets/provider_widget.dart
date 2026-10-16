import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../../models/home_layout.dart';
import '../../../models/provider.dart' as app_provider;
import '../../../services/chat_client.dart';
import '../../../state/app_state.dart';
import '../../chat_screen.dart' show showChatProviderSheet;
import '../../providers/providers_screen.dart';
import '../home_spec.dart';

/// The provider replies come from: its model, a status dot, and a Test button.
class ProviderSpec extends HomeWidgetSpec {
  const ProviderSpec();

  @override
  HomeWidgetKind get kind => HomeWidgetKind.provider;

  @override
  String get title => 'Provider';

  @override
  String get description => 'Current provider, its model, and a test button';

  @override
  IconData get icon => Icons.dns_outlined;

  @override
  ({int w, int h}) get minSpan => (w: 2, h: 1);

  @override
  List<HomeOption> options(HomeTile tile) => [
        HomePickOption(
          key: 'providerId',
          label: 'Provider',
          pick: HomePickKind.provider,
          allowNone: true,
          noneLabel: 'The active provider',
        ),
      ];

  @override
  String describe(BuildContext context, HomeTile tile) => 'Provider';

  @override
  Widget build(BuildContext context, HomeTileContext tile) {
    final providerId = tile.tile.str('providerId');
    app_provider.Provider? pick(AppState s) =>
        providerId == null ? s.activeProvider : s.providerById(providerId);
    final provider = pick(homeWatch(context, (s) {
      final p = pick(s);
      return (p, p?.displayName, p?.model, p?.kind, p?.isConfigured);
    }));
    return _ProviderCard(
      key: ValueKey('${tile.tile.id}-${provider?.id}'),
      provider: provider,
      editing: tile.editing,
      compact: tile.compact,
    );
  }
}

class _ProviderCard extends StatefulWidget {
  const _ProviderCard({
    super.key,
    required this.provider,
    required this.editing,
    required this.compact,
  });

  final app_provider.Provider? provider;
  final bool editing;
  final bool compact;

  @override
  State<_ProviderCard> createState() => _ProviderCardState();
}

class _ProviderCardState extends State<_ProviderCard> {
  KeyTestResult? _result;
  bool _testing = false;
  Timer? _clearTimer;

  @override
  void dispose() {
    _clearTimer?.cancel();
    super.dispose();
  }

  Future<void> _test(AppState state, app_provider.Provider provider) async {
    if (widget.editing || _testing) return;
    setState(() {
      _testing = true;
      _result = null;
    });
    final result = await state.testProviderKey(provider, provider.apiKey);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _result = result;
    });
    _clearTimer?.cancel();
    _clearTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _result = null);
    });
  }

  void _openSheet(BuildContext context) {
    if (widget.editing) return;
    showChatProviderSheet(context);
  }

  void _openProviders(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ProvidersScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = widget.provider;
    final state = context.read<AppState>();

    if (provider == null) {
      return HomeCard(
        semanticLabel: 'No provider configured',
        onTap: widget.editing ? null : () => _openProviders(context),
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.key_rounded, size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                'Finish setup',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
            ),
          ],
        ),
      );
    }

    final unconfigured = !provider.isConfigured;
    final model = provider.model.trim();

    return HomeCard(
      semanticLabel:
          '${provider.displayName}, ${provider.kind.label}, model ${model.isEmpty ? 'not set' : model}',
      onTap: widget.editing ? null : () => _openSheet(context),
      builder: (context, inner) {
        final titleStyle =
            theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600);
        final smallStyle = theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
        final titleH = homeLineHeight(context, titleStyle);
        final lineH = homeLineHeight(context, smallStyle) + 2;
        // What fits under the title, in the order it matters: the model,
        // then the dialect, then the last test's answer.
        var room = inner.height - (titleH > 36 ? titleH : 36);
        bool take(double h) {
          if (room < h) return false;
          room -= h;
          return true;
        }

        final showModel = take(lineH);
        final showKind = take(lineH);
        final showResult = _result != null && take(lineH + 2);
        final canTest = !unconfigured && inner.width >= 150;
        final status = unconfigured
            ? theme.colorScheme.error
            : theme.colorScheme.tertiary;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: status),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    provider.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: titleStyle,
                  ),
                ),
                if (canTest)
                  _TestButton(
                    testing: _testing,
                    disabled: widget.editing,
                    onPressed: () => _test(state, provider),
                  )
                else if (unconfigured && inner.width >= 150)
                  TextButton(
                    onPressed:
                        widget.editing ? null : () => _openProviders(context),
                    child: const Text('Set up'),
                  ),
              ],
            ),
            if (showModel)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  model.isEmpty ? 'No model set' : model,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            if (showKind)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  provider.kind.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: smallStyle,
                ),
              ),
            if (showResult)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _result!.ok
                      ? 'Working · ${_result!.latency?.inMilliseconds ?? 0} ms'
                      : _result!.message,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: _result!.ok
                        ? theme.colorScheme.tertiary
                        : theme.colorScheme.error,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _TestButton extends StatelessWidget {
  const _TestButton({
    required this.testing,
    required this.disabled,
    required this.onPressed,
  });

  final bool testing;
  final bool disabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton.filledTonal(
      tooltip: 'Test',
      iconSize: 18,
      visualDensity: VisualDensity.compact,
      onPressed: disabled || testing ? null : onPressed,
      icon: testing
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.network_check_rounded),
    );
  }
}
