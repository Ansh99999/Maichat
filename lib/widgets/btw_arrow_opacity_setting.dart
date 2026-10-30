import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/settings.dart';
import '../state/app_state.dart';

/// Preview slider movement locally and persist once the gesture finishes.
class BtwArrowOpacitySetting extends StatefulWidget {
  const BtwArrowOpacitySetting({super.key, required this.state});

  final AppState state;

  @override
  State<BtwArrowOpacitySetting> createState() => _BtwArrowOpacitySettingState();
}

class _BtwArrowOpacitySettingState extends State<BtwArrowOpacitySetting> {
  double? _preview;

  @override
  Widget build(BuildContext context) => ListenableProvider<AppState>.value(
    value: widget.state,
    child: Selector<AppState, double>(
      selector: (_, state) => state.btwSettings.mainChatArrowOpacity,
      builder: (context, saved, _) {
        final value = (_preview ?? saved).clamp(
          BtwSettings.minArrowOpacity,
          BtwSettings.maxArrowOpacity,
        );
        final percentage = '${(value * 100).round()}%';
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.chevron_left, size: 20),
                  const SizedBox(width: 12),
                  const Expanded(child: Text('Main-chat arrow opacity')),
                  const SizedBox(width: 8),
                  Text(
                    percentage,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ],
              ),
              Semantics(
                label: 'Main-chat arrow opacity',
                child: Slider(
                  key: const Key('btw-arrow-opacity'),
                  value: value,
                  min: BtwSettings.minArrowOpacity,
                  max: BtwSettings.maxArrowOpacity,
                  divisions: 18,
                  label: percentage,
                  semanticFormatterCallback: (value) =>
                      '${(value * 100).round()}%',
                  onChanged: (value) => setState(() => _preview = value),
                  onChangeEnd: (value) async {
                    await widget.state.updateBtwSettings(
                      widget.state.btwSettings.copyWith(
                        mainChatArrowOpacity: value,
                      ),
                    );
                    if (mounted) setState(() => _preview = null);
                  },
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}
