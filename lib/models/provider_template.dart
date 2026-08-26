/// Ready-made provider setups, so a known host is two taps rather than a
/// base URL the user has to go and look up.
///
/// A template is not a new [ProviderKind] — it is a kind plus the address and
/// model that host expects. Nvidia NIM and Google AI Studio speak formats the
/// app already knows; what made them awkward was remembering
/// `https://integrate.api.nvidia.com/v1`. Keeping them as data means adding the
/// next host costs one list entry and no `switch` anywhere.
library;

import 'provider.dart';

/// One pre-filled starting point offered in the API-format picker.
class ProviderTemplate {
  const ProviderTemplate({
    required this.id,
    required this.label,
    required this.kind,
    required this.baseUrl,
    this.blurb = '',
    this.defaultModel = '',
    this.docsUrl = '',
  });

  /// Stable id, used by the UI to pick an icon and to remember the choice.
  final String id;

  /// What the picker shows.
  final String label;

  /// The wire format this host speaks.
  final ProviderKind kind;

  /// The address to pre-fill.
  final String baseUrl;

  /// One line under the label explaining when to reach for it.
  final String blurb;

  /// A model to start on, where the host has an obvious default.
  final String defaultModel;

  /// Where to send a user who needs a key or the model list.
  final String docsUrl;

  /// A blank provider set up for this host. The name starts as the template's
  /// label, which is nearly always what the user would have typed.
  Provider toProvider() => Provider(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: label,
        kind: kind,
        baseUrl: baseUrl,
        model: defaultModel,
      );
}

/// The hosts offered under "Ready-made" in the format picker.
///
/// Deliberately short. Each entry has to earn its place by being a host whose
/// address is genuinely hard to remember — a list of every gateway in existence
/// would be a worse picker, not a better one.
const List<ProviderTemplate> kProviderTemplates = <ProviderTemplate>[
  ProviderTemplate(
    id: 'nvidia-nim',
    label: 'Nvidia NIM',
    kind: ProviderKind.openai,
    baseUrl: 'https://integrate.api.nvidia.com/v1',
    blurb: 'Nvidia’s hosted catalogue, OpenAI-compatible',
    docsUrl: 'https://build.nvidia.com/',
  ),
  ProviderTemplate(
    id: 'google-ai-studio',
    label: 'Google AI Studio',
    kind: ProviderKind.gemini,
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
    blurb: 'Gemini models with an AI Studio key',
    defaultModel: 'gemini-2.5-flash',
    docsUrl: 'https://aistudio.google.com/apikey',
  ),
  ProviderTemplate(
    id: 'openrouter',
    label: 'OpenRouter',
    kind: ProviderKind.openai,
    baseUrl: 'https://openrouter.ai/api/v1',
    blurb: 'One key, most models',
    docsUrl: 'https://openrouter.ai/keys',
  ),
  ProviderTemplate(
    id: 'koboldcpp',
    label: 'KoboldCPP',
    kind: ProviderKind.koboldCpp,
    baseUrl: 'http://127.0.0.1:5001/v1',
    blurb: 'A local KoboldCPP server on its default port',
  ),
  ProviderTemplate(
    id: 'ollama',
    label: 'Ollama',
    kind: ProviderKind.localLlm,
    baseUrl: 'http://127.0.0.1:11434/v1',
    blurb: 'A local Ollama server on its default port',
  ),
  ProviderTemplate(
    id: 'lm-studio',
    label: 'LM Studio',
    kind: ProviderKind.localLlm,
    baseUrl: 'http://127.0.0.1:1234/v1',
    blurb: 'A local LM Studio server on its default port',
  ),
];

/// The template with [id], or null when nothing matches.
ProviderTemplate? templateById(String? id) {
  if (id == null || id.isEmpty) return null;
  for (final template in kProviderTemplates) {
    if (template.id == id) return template;
  }
  return null;
}
