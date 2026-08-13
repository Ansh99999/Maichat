import 'package:flutter/material.dart';

/// One selectable row in a [showSearchPicker] dialog.
class PickerEntry {
  const PickerEntry({required this.id, required this.title, this.subtitle});
  final String id;
  final String title;
  final String? subtitle;
}

/// Thrown by a picker's `onRefresh` to surface a message in the dialog.
class PickerRefreshException implements Exception {
  PickerRefreshException(this.message);
  final String message;
}

/// Shows a searchable "window" picker and resolves to the chosen entry id, or
/// null if dismissed. Optionally supports a refresh action (with a spinner) and
/// a "use what I typed" custom entry.
Future<String?> showSearchPicker({
  required BuildContext context,
  required String title,
  required List<PickerEntry> entries,
  String? selectedId,
  Future<List<PickerEntry>> Function()? onRefresh,
  bool refreshOnEmpty = false,
  bool allowCustom = false,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _SearchPickerDialog(
      title: title,
      entries: entries,
      selectedId: selectedId,
      onRefresh: onRefresh,
      refreshOnEmpty: refreshOnEmpty,
      allowCustom: allowCustom,
    ),
  );
}

class _SearchPickerDialog extends StatefulWidget {
  const _SearchPickerDialog({
    required this.title,
    required this.entries,
    required this.selectedId,
    required this.onRefresh,
    required this.refreshOnEmpty,
    required this.allowCustom,
  });

  final String title;
  final List<PickerEntry> entries;
  final String? selectedId;
  final Future<List<PickerEntry>> Function()? onRefresh;
  final bool refreshOnEmpty;
  final bool allowCustom;

  @override
  State<_SearchPickerDialog> createState() => _SearchPickerDialogState();
}

class _SearchPickerDialogState extends State<_SearchPickerDialog> {
  late List<PickerEntry> _entries = widget.entries;
  String _query = '';
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.refreshOnEmpty && _entries.isEmpty && widget.onRefresh != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
    }
  }

  Future<void> _refresh() async {
    if (widget.onRefresh == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final fresh = await widget.onRefresh!();
      if (mounted) setState(() => _entries = fresh);
    } on PickerRefreshException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not refresh the list.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final filtered = q.isEmpty
        ? _entries
        : _entries.where((e) => e.title.toLowerCase().contains(q)).toList();
    final exact = _entries.any((e) => e.id == _query.trim());
    final offerCustom = widget.allowCustom && _query.trim().isNotEmpty && !exact;

    return AlertDialog(
      contentPadding: const EdgeInsets.fromLTRB(0, 12, 0, 0),
      title: Row(
        children: [
          Expanded(child: Text(widget.title)),
          if (widget.onRefresh != null)
            _loading
                ? const Padding(
                    padding: EdgeInsets.all(8),
                    child: SizedBox(
                      height: 18, width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IconButton(
                    tooltip: 'Refresh list',
                    icon: const Icon(Icons.refresh),
                    onPressed: _refresh,
                  ),
        ],
      ),
      content: SizedBox(
        width: 360,
        height: MediaQuery.sizeOf(context).height * 0.55,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                autofocus: false,
                decoration: const InputDecoration(
                  hintText: 'Search',
                  prefixIcon: Icon(Icons.search),
                  isDense: true,
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 8),
            Expanded(
              child: (_loading && _entries.isEmpty)
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      children: [
                        if (offerCustom)
                          ListTile(
                            leading: const Icon(Icons.add),
                            title: Text('Use "${_query.trim()}"'),
                            onTap: () => Navigator.of(context).pop(_query.trim()),
                          ),
                        for (final e in filtered)
                          ListTile(
                            title: Text(e.title),
                            subtitle: e.subtitle == null ? null : Text(e.subtitle!),
                            selected: e.id == widget.selectedId,
                            trailing: e.id == widget.selectedId
                                ? const Icon(Icons.check)
                                : null,
                            onTap: () => Navigator.of(context).pop(e.id),
                          ),
                        if (filtered.isEmpty && !offerCustom)
                          const Padding(
                            padding: EdgeInsets.all(24),
                            child: Center(child: Text('Nothing matches')),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
