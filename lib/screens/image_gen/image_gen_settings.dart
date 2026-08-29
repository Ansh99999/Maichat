import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/image_gen.dart';
import '../../models/provider.dart';
import '../../services/image_client.dart';
import '../../state/app_state.dart';

/// The image studio's settings, shown *inside* the studio sheet rather than as a
/// route — so backing out of it returns to the studio with the sheet still open,
/// the same way the chat drawer's panels work.
///
/// Everything a request needs is here and nothing else is: which dialect, where
/// to send, the key, the model, the shape of the picture, and the standing
/// instructions every prompt is wrapped in. The endpoint is deliberately the
/// studio's own — that is what makes "every chat can generate a picture" true
/// regardless of which model the conversation runs on.
class ImageGenSettingsPage extends StatefulWidget {
  const ImageGenSettingsPage({super.key, required this.onBack});

  /// Return to the studio. The page is rendered inside the sheet, so popping the
  /// navigator here would close the whole sheet instead of going back one level.
  final VoidCallback onBack;

  @override
  State<ImageGenSettingsPage> createState() => _ImageGenSettingsPageState();
}

class _ImageGenSettingsPageState extends State<ImageGenSettingsPage> {
  late final AppState _state = context.read<AppState>();
  late final TextEditingController _baseUrl =
      TextEditingController(text: _state.imageGen.baseUrl);
  late final TextEditingController _apiKey =
      TextEditingController(text: _state.imageGen.apiKey);
  late final TextEditingController _model =
      TextEditingController(text: _state.imageGen.model);
  late final TextEditingController _system =
      TextEditingController(text: _state.imageGen.systemPrompt);
  late final TextEditingController _negative =
      TextEditingController(text: _state.imageGen.negativePrompt);

  late ImageGenConfig _draft = _state.imageGen;
  bool _showKey = false;

  @override
  void dispose() {
    _baseUrl.dispose();
    _apiKey.dispose();
    _model.dispose();
    _system.dispose();
    _negative.dispose();
    super.dispose();
  }

  /// Writes the draft through. Every field commits as it is edited: this page has
  /// no Save button because it has nothing to lose track of, and a settings page
  /// inside a sheet that could be dismissed by a swipe must not be holding
  /// unsaved work.
  void _commit(ImageGenConfig next) {
    setState(() => _draft = next);
    _state.updateImageGen(next);
  }

  /// Borrows the address and key from a configured chat provider — the common
  /// case, where the same OpenAI or Gemini account serves both.
  Future<void> _copyFromProvider() async {
    final providers = _state.providers;
    if (providers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('No providers are set up to copy from yet.'),
      ));
      return;
    }
    final chosen = await showModalBottomSheet<Provider>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final p in providers)
              ListTile(
                leading: const Icon(Icons.dns_outlined),
                title: Text(p.displayName),
                subtitle: Text(p.baseUrl, maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                onTap: () => Navigator.of(sheet).pop(p),
              ),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    _baseUrl.text = chosen.baseUrl;
    _apiKey.text = chosen.apiKey;
    _commit(_draft.copyWith(
      // A Gemini provider plainly means the Gemini dialect; everything else
      // speaks the OpenAI images API (or something imitating it).
      kind: chosen.kind == ProviderKind.gemini
          ? ImageGenKind.gemini
          : ImageGenKind.openai,
      baseUrl: chosen.baseUrl,
      apiKey: chosen.apiKey,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // What a request will actually go to, so nobody has to guess how the base URL
    // and the model combine.
    String endpoint;
    try {
      endpoint = ImageClient.uriFor(_draft).toString();
    } catch (_) {
      endpoint = 'Not a valid address yet';
    }

    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 16, 4),
              child: Row(
                children: [
                  IconButton(
                    key: const Key('imagegen-settings-back'),
                    tooltip: 'Back',
                    onPressed: widget.onBack,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Expanded(
                    child: Text('Image settings',
                        style: theme.textTheme.titleMedium),
                  ),
                  TextButton.icon(
                    onPressed: _copyFromProvider,
                    icon: const Icon(Icons.content_copy_outlined, size: 18),
                    label: const Text('From provider'),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                children: [
                  SegmentedButton<ImageGenKind>(
                    segments: [
                      for (final kind in ImageGenKind.values)
                        ButtonSegment<ImageGenKind>(
                          value: kind,
                          label: Text(kind.label),
                        ),
                    ],
                    selected: {_draft.kind},
                    onSelectionChanged: (picked) {
                      final kind = picked.first;
                      _commit(_draft.copyWith(kind: kind));
                    },
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _baseUrl,
                    decoration: InputDecoration(
                      labelText: 'Endpoint',
                      hintText: _draft.kind.defaultBaseUrl,
                      helperText: _draft.kind.baseUrlHelper,
                      helperMaxLines: 2,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (v) => _commit(_draft.copyWith(baseUrl: v)),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _apiKey,
                    obscureText: !_showKey,
                    decoration: InputDecoration(
                      labelText: 'API key',
                      helperText: 'Left empty for a server that needs none.',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        tooltip: _showKey ? 'Hide' : 'Show',
                        onPressed: () => setState(() => _showKey = !_showKey),
                        icon: Icon(_showKey
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined),
                      ),
                    ),
                    onChanged: (v) => _commit(_draft.copyWith(apiKey: v)),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _model,
                    decoration: InputDecoration(
                      labelText: 'Model',
                      hintText: _draft.kind.modelHint,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (v) => _commit(_draft.copyWith(model: v)),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    endpoint,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 18),
                  Text('Shape', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: kImageSizes.contains(_draft.size)
                        ? _draft.size
                        : 'auto',
                    decoration: const InputDecoration(
                      labelText: 'Size',
                      helperText: '“auto” sends no size, which is what the '
                          'newer models want.',
                      helperMaxLines: 2,
                    ),
                    items: [
                      for (final size in kImageSizes)
                        DropdownMenuItem<String>(value: size, child: Text(size)),
                    ],
                    onChanged: (v) =>
                        _commit(_draft.copyWith(size: v ?? 'auto')),
                  ),
                  const SizedBox(height: 14),
                  DropdownButtonFormField<String>(
                    initialValue: kImageQualities.contains(_draft.quality)
                        ? _draft.quality
                        : '',
                    decoration: const InputDecoration(labelText: 'Quality'),
                    items: [
                      for (final quality in kImageQualities)
                        DropdownMenuItem<String>(
                          value: quality,
                          child: Text(quality.isEmpty ? 'Host default' : quality),
                        ),
                    ],
                    onChanged: (v) => _commit(_draft.copyWith(quality: v ?? '')),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Expanded(child: Text('Pictures per prompt')),
                      IconButton(
                        onPressed: _draft.count > 1
                            ? () => _commit(
                                _draft.copyWith(count: _draft.count - 1))
                            : null,
                        icon: const Icon(Icons.remove),
                      ),
                      Text('${_draft.count}',
                          style: theme.textTheme.titleMedium),
                      IconButton(
                        onPressed: _draft.count < 8
                            ? () => _commit(
                                _draft.copyWith(count: _draft.count + 1))
                            : null,
                        icon: const Icon(Icons.add),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text('Standing instructions',
                      style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _system,
                    minLines: 3,
                    maxLines: 6,
                    decoration: const InputDecoration(
                      labelText: 'System prompt',
                      hintText: 'A style, a rendering brief, how to frame a '
                          'subject — wrapped around every prompt.',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) => _commit(_draft.copyWith(systemPrompt: v)),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _negative,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: 'Always avoid',
                      helperText: 'Neither API has a negative-prompt field, so '
                          'this is appended to the prompt as “Avoid: …”.',
                      helperMaxLines: 3,
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) =>
                        _commit(_draft.copyWith(negativePrompt: v)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
