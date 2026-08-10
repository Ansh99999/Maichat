import 'package:flutter/material.dart';

/// Bottom sheet listing model ids, with a filter box because some endpoints
/// return hundreds. Returns the picked id via [Navigator.pop].
class ModelPicker extends StatefulWidget {
  const ModelPicker({super.key, required this.models, required this.selected});

  final List<String> models;
  final String selected;

  @override
  State<ModelPicker> createState() => _ModelPickerState();
}

class _ModelPickerState extends State<ModelPicker> {
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final needle = _filter.trim().toLowerCase();
    final visible = needle.isEmpty
        ? widget.models
        : widget.models
            .where((m) => m.toLowerCase().contains(needle))
            .toList(growable: false);

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.7,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: TextField(
                  autofocus: false,
                  decoration: const InputDecoration(
                    labelText: 'Filter',
                    prefixIcon: Icon(Icons.search),
                    isDense: true,
                  ),
                  onChanged: (value) => setState(() => _filter = value),
                ),
              ),
              Expanded(child: _list(visible)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _list(List<String> visible) {
    if (visible.isEmpty) {
      return const Center(child: Text('Nothing matches that filter'));
    }
    return ListView.builder(
      itemCount: visible.length,
      itemBuilder: (context, index) {
        final model = visible[index];
        final isSelected = model == widget.selected;
        return ListTile(
          title: Text(model),
          selected: isSelected,
          trailing: isSelected ? const Icon(Icons.check) : null,
          onTap: () => Navigator.of(context).pop(model),
        );
      },
    );
  }
}
