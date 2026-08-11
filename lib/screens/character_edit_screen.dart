import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/character.dart';
import '../state/app_state.dart';

/// Create or edit a character. Passed a [character] it edits in place;
/// otherwise it builds a fresh one. Fields are grouped into calm sections
/// (Identity, Persona, Conversation, Advanced) rather than one long wall.
class CharacterEditScreen extends StatefulWidget {
  const CharacterEditScreen({super.key, this.character});

  final Character? character;

  @override
  State<CharacterEditScreen> createState() => _CharacterEditScreenState();
}

class _CharacterEditScreenState extends State<CharacterEditScreen> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _name;
  late final TextEditingController _avatar;
  late final TextEditingController _description;
  late final TextEditingController _personality;
  late final TextEditingController _scenario;
  late final TextEditingController _greeting;
  late final TextEditingController _example;
  late final TextEditingController _system;
  late final TextEditingController _postHistory;
  late final TextEditingController _creator;
  late final TextEditingController _notes;
  late final TextEditingController _tags;

  /// Preserved so an imported PNG's base64 avatar survives an edit even though
  /// we never dump the blob into the URL field.
  late final String _originalAvatar;

  /// A freshly chosen device image, base64-encoded (no `data:` prefix).
  String? _pickedBase64;

  /// Set when the user explicitly clears the avatar.
  bool _removed = false;

  bool get _isNew => widget.character == null;

  @override
  void initState() {
    super.initState();
    final c = widget.character;
    _originalAvatar = c?.avatar ?? '';
    _name = TextEditingController(text: c?.name ?? '');
    // Only surface a URL avatar for editing; a base64 card image is kept
    // silently via [_originalAvatar].
    _avatar = TextEditingController(
      text: (c?.avatarIsUrl ?? false) ? c!.avatar : '',
    );
    _description = TextEditingController(text: c?.description ?? '');
    _personality = TextEditingController(text: c?.personality ?? '');
    _scenario = TextEditingController(text: c?.scenario ?? '');
    _greeting = TextEditingController(text: c?.firstMes ?? '');
    _example = TextEditingController(text: c?.mesExample ?? '');
    _system = TextEditingController(text: c?.systemPrompt ?? '');
    _postHistory = TextEditingController(text: c?.postHistoryInstructions ?? '');
    _creator = TextEditingController(text: c?.creator ?? '');
    _notes = TextEditingController(text: c?.creatorNotes ?? '');
    _tags = TextEditingController(text: (c?.tags ?? const <String>[]).join(', '));
    // A typed URL should update the preview live.
    _avatar.addListener(_onAvatarUrlChanged);
  }

  void _onAvatarUrlChanged() => setState(() {});

  Future<void> _pickImage() async {
    final result = await FilePicker.pickFiles(
      type: FileType.image,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final bytes = result.files.first.bytes;
    if (bytes == null || bytes.isEmpty) return;
    setState(() {
      _pickedBase64 = base64Encode(bytes);
      _removed = false;
      _avatar.clear(); // a picked image takes over from any typed URL
    });
  }

  /// The avatar to persist / preview: a typed URL wins, then a freshly picked
  /// image, then the preserved original (unless it was explicitly removed).
  String _effectiveAvatar() {
    final url = _avatar.text.trim();
    if (url.isNotEmpty) return url;
    if (_pickedBase64 != null) return _pickedBase64!;
    if (_removed) return '';
    // A cleared URL original resolves to empty; a base64 image is kept.
    return _originalAvatar.startsWith('http') ? '' : _originalAvatar;
  }

  @override
  void dispose() {
    for (final controller in [
      _name, _avatar, _description, _personality, _scenario, _greeting,
      _example, _system, _postHistory, _creator, _notes, _tags,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final avatar = _effectiveAvatar();

    final character = widget.character ?? Character.empty();
    character
      ..name = _name.text.trim()
      ..avatar = avatar
      ..description = _description.text.trim()
      ..personality = _personality.text.trim()
      ..scenario = _scenario.text.trim()
      ..firstMes = _greeting.text.trim()
      ..mesExample = _example.text.trim()
      ..systemPrompt = _system.text.trim()
      ..postHistoryInstructions = _postHistory.text.trim()
      ..creator = _creator.text.trim()
      ..creatorNotes = _notes.text.trim()
      ..tags = _tags.text
          .split(',')
          .map((t) => t.trim())
          .where((t) => t.isNotEmpty)
          .toList();

    await context.read<AppState>().saveCharacter(character);
    if (mounted) Navigator.of(context).pop(character);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'New character' : 'Edit character'),
        actions: [
          TextButton(onPressed: _save, child: const Text('Save')),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            _avatarSection(),
            const _SectionLabel('Identity'),
            _field(_name, 'Name', required: true),
            _field(_avatar, 'Avatar image URL',
                hint: 'Optional — https://…'),
            _field(_tags, 'Tags', hint: 'Comma-separated'),
            const _SectionLabel('Persona'),
            _field(_description, 'Description', lines: 4),
            _field(_personality, 'Personality', lines: 2),
            _field(_scenario, 'Scenario', lines: 2),
            const _SectionLabel('Conversation'),
            _field(_greeting, 'Greeting (first message)', lines: 3),
            _field(_example, 'Example dialogue', lines: 3),
            const _SectionLabel('Advanced'),
            _field(_system, 'System prompt', lines: 3),
            _field(_postHistory, 'Post-history instructions', lines: 2),
            _field(_creator, 'Creator'),
            _field(_notes, 'Creator notes', lines: 2),
          ],
        ),
      ),
    );
  }

  /// The avatar preview + pick/remove controls shown atop the form.
  Widget _avatarSection() {
    final scheme = Theme.of(context).colorScheme;
    final eff = _effectiveAvatar();
    ImageProvider? image;
    if (eff.startsWith('http')) {
      image = NetworkImage(eff);
    } else if (eff.isNotEmpty) {
      try {
        image = MemoryImage(base64Decode(eff));
      } catch (_) {
        image = null;
      }
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        children: [
          CircleAvatar(
            radius: 44,
            backgroundColor: scheme.secondaryContainer,
            backgroundImage: image,
            onBackgroundImageError: image == null ? null : (_, _) {},
            child: image == null
                ? Icon(Icons.person_outline,
                    size: 40, color: scheme.onSecondaryContainer)
                : null,
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _pickImage,
                icon: const Icon(Icons.image_outlined),
                label: const Text('Choose image'),
              ),
              if (eff.isNotEmpty)
                TextButton.icon(
                  onPressed: () => setState(() {
                    _removed = true;
                    _pickedBase64 = null;
                    _avatar.clear();
                  }),
                  icon: const Icon(Icons.close),
                  label: const Text('Remove'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    String? hint,
    int lines = 1,
    bool required = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextFormField(
        controller: controller,
        minLines: lines,
        maxLines: lines == 1 ? 1 : lines + 4,
        textInputAction:
            lines == 1 ? TextInputAction.next : TextInputAction.newline,
        keyboardType:
            lines == 1 ? TextInputType.text : TextInputType.multiline,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          alignLabelWithHint: lines > 1,
        ),
        validator: required
            ? (v) => (v == null || v.trim().isEmpty) ? 'Required' : null
            : null,
      ),
    );
  }
}

/// A quiet run-in heading between field groups.
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 4),
      child: Text(
        text.toUpperCase(),
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: scheme.primary,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
      ),
    );
  }
}
