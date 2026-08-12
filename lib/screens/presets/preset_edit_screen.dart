import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/preset.dart';
import '../../state/app_state.dart';
import 'preset_editor_body.dart';

/// Full-screen preset editor. Holds a working copy and commits every change to
/// the shared library live (the presets list is the source of truth here).
class PresetEditScreen extends StatefulWidget {
  const PresetEditScreen({super.key, required this.presetId});

  final String presetId;

  @override
  State<PresetEditScreen> createState() => _PresetEditScreenState();
}

class _PresetEditScreenState extends State<PresetEditScreen> {
  late Preset _p;
  bool _missing = false;

  @override
  void initState() {
    super.initState();
    final stored = context.read<AppState>().presetById(widget.presetId);
    if (stored == null) {
      _missing = true;
      _p = Preset.create();
    } else {
      _p = Preset.fromJson(stored.toJson()); // deep copy; commits explicitly
    }
  }

  void _commit() {
    if (_missing) return;
    context.read<AppState>().savePreset(_p);
  }

  @override
  Widget build(BuildContext context) {
    if (_missing) {
      return Scaffold(
        appBar: AppBar(title: const Text('Preset')),
        body: const Center(child: Text('This preset no longer exists.')),
      );
    }
    final state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit preset'),
        actions: [
          IconButton(
            tooltip: 'Set as default',
            icon: Icon(state.defaultPresetId == _p.id ? Icons.star : Icons.star_border),
            onPressed: () => state.setDefaultPreset(_p.id),
          ),
        ],
      ),
      body: PresetEditorBody(preset: _p, onChanged: _commit),
    );
  }
}
