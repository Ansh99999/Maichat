import 'package:flutter/material.dart';

/// Asks for a piece of text, starting from [initial]; returns it, or null when
/// cancelled. [tall] gives a long text a fixed-height box that scrolls inside,
/// like the creator's fields, so the dialog does not grow and jump while it is
/// typed in.
///
/// The field's controller belongs to the dialog's own state, so it is disposed
/// only once the dialog has finished closing — disposing it when the future
/// completes would pull it out from under the closing animation.
Future<String?> showStudioTextDialog(
  BuildContext context, {
  required String title,
  required String initial,
  bool tall = false,
  String? hint,
}) =>
    showDialog<String>(
      context: context,
      builder: (_) => _TextDialog(
        title: title,
        initial: initial,
        tall: tall,
        hint: hint,
      ),
    );

class _TextDialog extends StatefulWidget {
  const _TextDialog({
    required this.title,
    required this.initial,
    required this.tall,
    this.hint,
  });

  final String title;
  final String initial;
  final bool tall;
  final String? hint;

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  late final TextEditingController _field =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final field = widget.tall
        ? SizedBox(
            width: double.maxFinite,
            height: MediaQuery.sizeOf(context).height * 0.45,
            child: TextField(
              controller: _field,
              expands: true,
              maxLines: null,
              autofocus: true,
              textAlignVertical: TextAlignVertical.top,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                hintText: widget.hint,
              ),
            ),
          )
        : TextField(
            controller: _field,
            autofocus: true,
            decoration: InputDecoration(hintText: widget.hint),
            onSubmitted: (v) => Navigator.of(context).pop(v),
          );
    return AlertDialog(
      title: Text(widget.title),
      contentPadding: EdgeInsets.fromLTRB(widget.tall ? 16 : 24, 12,
          widget.tall ? 16 : 24, 0),
      content: field,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_field.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
