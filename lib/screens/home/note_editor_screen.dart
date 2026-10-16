import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/home_note.dart';
import '../../state/app_state.dart';

/// A full-screen editor for one Home-screen note.
///
/// Autosaves 600ms after typing stops, on back/pop, and when the app is
/// paused — never per keystroke. A note left empty is deleted rather than
/// kept as a blank entry.
class NoteEditorScreen extends StatefulWidget {
  const NoteEditorScreen({super.key, required this.noteId});

  final String noteId;

  @override
  State<NoteEditorScreen> createState() => _NoteEditorScreenState();
}

class _NoteEditorScreenState extends State<NoteEditorScreen>
    with WidgetsBindingObserver {
  late TextEditingController _title;
  late TextEditingController _body;
  Timer? _debounce;
  DateTime _updatedAt = DateTime.now();
  bool _dirty = false;
  // Captured in initState/didChangeDependencies rather than read from
  // context in dispose(), which is unsafe: by the time dispose() runs the
  // widget may be unmounting as part of a larger subtree teardown, and an
  // ancestor InheritedWidget lookup can hit an already-deactivated element.
  AppState? _state;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _state = context.read<AppState>();
    final existing = _state!.homeNoteById(widget.noteId);
    _title = TextEditingController(text: existing?.title ?? '');
    _body = TextEditingController(text: existing?.body ?? '');
    _updatedAt = existing?.updatedAt ?? DateTime.now();
    _title.addListener(_onEdited);
    _body.addListener(_onEdited);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _state = context.read<AppState>();
  }

  void _onEdited() {
    _dirty = true;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), _save);
  }

  Future<void> _save() async {
    _debounce?.cancel();
    if (!_dirty) return;
    _dirty = false;
    final title = _title.text;
    final body = _body.text;
    final state = _state;
    if (state == null) return;
    if (title.trim().isEmpty && body.trim().isEmpty) {
      await state.deleteHomeNote(widget.noteId);
      return;
    }
    _updatedAt = DateTime.now();
    await state.saveHomeNote(HomeNote(
      id: widget.noteId,
      title: title,
      body: body,
      updatedAt: _updatedAt,
    ));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      unawaited(_save());
    }
  }

  Future<void> _confirmDelete() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete note?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    _dirty = false;
    _debounce?.cancel();
    await _state?.deleteHomeNote(widget.noteId);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _share() async {
    final text = [_title.text, _body.text].where((s) => s.trim().isNotEmpty).join('\n\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Copied to clipboard')),
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    unawaited(_save());
    WidgetsBinding.instance.removeObserver(this);
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) unawaited(_save());
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            _title.text.trim().isEmpty ? 'Note' : _title.text.trim(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            PopupMenuButton<String>(
              onSelected: (value) {
                switch (value) {
                  case 'delete':
                    unawaited(_confirmDelete());
                  case 'share':
                    unawaited(_share());
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'share', child: Text('Share')),
                PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
          ],
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _title,
                  style: theme.textTheme.headlineSmall,
                  decoration: const InputDecoration(
                    hintText: 'Title',
                    border: InputBorder.none,
                  ),
                  maxLines: 1,
                  textCapitalization: TextCapitalization.sentences,
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: TextField(
                    controller: _body,
                    style: theme.textTheme.bodyLarge,
                    decoration: const InputDecoration(
                      hintText: 'Write something…',
                      border: InputBorder.none,
                    ),
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    textCapitalization: TextCapitalization.sentences,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
