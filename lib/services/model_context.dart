/// Known context-window sizes, keyed by model id.
///
/// Backs the preset's "Use model max context if known" switch: rather than
/// trusting a number typed into a preset months ago (or whatever a downloaded
/// preset happened to ship — SillyTavern's own default is a GPT-3.5-era 4095),
/// the prompt budget follows the model actually selected.
///
/// The table is deliberately conservative in shape: a *substring* match on the
/// normalised id, longest pattern first, so `gpt-4o-mini-2024-07-18` resolves
/// through `gpt-4o-mini` and never through `gpt-4`. An id carrying its window in
/// its name (`…-128k`, `…-1m`) is trusted over the table, since that is the
/// host's own statement about the deployment.
library;

/// Vendor prefixes gateways bolt onto a model id (OpenRouter, LiteLLM, …).
final RegExp _vendorPrefix = RegExp(
  r'^(openai|anthropic|google|meta-llama|meta|mistralai|mistral|deepseek|'
  r'qwen|alibaba|x-ai|xai|moonshotai|moonshot|z-ai|zhipu|cohere|'
  r'microsoft|nvidia|perplexity|groq|together|fireworks|azure|vertex[_-]ai|'
  r'bedrock|openrouter)/',
);

/// A window stated in the id itself: `-128k`, `:32k`, `-1m`.
final RegExp _statedSize = RegExp(r'(?:^|[-_:.])(\d{1,4})([km])(?:$|[-_:.])');

/// Context windows for the model families this app is pointed at, largest
/// (most specific) key first at lookup time. Values are the vendor's published
/// total window in tokens.
const Map<String, int> _windows = <String, int>{
  // --- OpenAI ---
  'gpt-3.5-turbo': 16385,
  'gpt-4-32k': 32768,
  'gpt-4-turbo': 128000,
  'gpt-4o-mini': 128000,
  'gpt-4o': 128000,
  'gpt-4.1': 1047576,
  'gpt-4.5': 128000,
  'gpt-4': 8192,
  'gpt-5': 400000,
  'o1-mini': 128000,
  'o1': 200000,
  'o3-mini': 200000,
  'o3': 200000,
  'o4-mini': 200000,
  // --- Anthropic ---
  'claude-2.0': 100000,
  'claude-2': 200000,
  'claude-3': 200000,
  'claude-4': 200000,
  'claude-sonnet': 200000,
  'claude-opus': 200000,
  'claude-haiku': 200000,
  // --- Google ---
  'gemini-1.0': 32760,
  'gemini-1.5-pro': 2097152,
  'gemini-1.5-flash': 1048576,
  'gemini-1.5': 1048576,
  'gemini-2.0': 1048576,
  'gemini-2.5': 1048576,
  'gemini-3': 1048576,
  'gemma-3': 131072,
  'gemma-2': 8192,
  // --- Meta ---
  'llama-4-scout': 10485760,
  'llama-4': 1048576,
  'llama-3.1': 131072,
  'llama-3.2': 131072,
  'llama-3.3': 131072,
  'llama-3': 8192,
  'llama-2': 4096,
  // --- DeepSeek ---
  'deepseek-r1': 65536,
  'deepseek-reasoner': 65536,
  'deepseek-chat': 65536,
  'deepseek-v3': 65536,
  'deepseek': 65536,
  // --- Qwen ---
  'qwen3': 131072,
  'qwen-3': 131072,
  'qwen2.5': 131072,
  'qwen-2.5': 131072,
  'qwen-max': 32768,
  'qwen': 32768,
  // --- Mistral ---
  'mistral-large': 131072,
  'mistral-medium': 131072,
  'mistral-small': 131072,
  'mistral-nemo': 131072,
  'magistral': 131072,
  'codestral': 262144,
  'mixtral': 32768,
  'mistral': 32768,
  // --- xAI ---
  'grok-4': 256000,
  'grok-3': 131072,
  'grok-2': 131072,
  'grok': 131072,
  // --- Others in common use ---
  'kimi-k2': 131072,
  'glm-4.6': 200000,
  'glm-4': 131072,
  'command-r-plus': 131072,
  'command-r': 131072,
  'command-a': 262144,
  'nemotron': 131072,
  'yi-large': 32768,
};

/// The published context window for [model], or null when the model is not one
/// this table knows — in which case the caller keeps the preset's own number
/// rather than guessing.
int? knownMaxContext(String model) {
  final id = normaliseModelId(model);
  if (id.isEmpty) return null;

  // A window stated in the id wins: it describes this specific deployment.
  final stated = _statedSize.firstMatch(id);
  if (stated != null) {
    final n = int.tryParse(stated.group(1)!);
    if (n != null && n > 0) {
      final multiplier = stated.group(2) == 'm' ? 1024 * 1024 : 1024;
      return n * multiplier;
    }
  }

  String? best;
  for (final key in _windows.keys) {
    if (!id.contains(key)) continue;
    if (best == null || key.length > best.length) best = key;
  }
  return best == null ? null : _windows[best];
}

/// Lowercases [model] and drops a gateway's vendor prefix and any `:free` /
/// `:nitro` style routing suffix, so `OpenAI/GPT-4o:free` looks like `gpt-4o`.
///
/// Public because pricing matches model ids by the same rule, and two copies of
/// it would drift apart.
String normaliseModelId(String model) {
  var id = model.trim().toLowerCase();
  id = id.replaceFirst(_vendorPrefix, '');
  for (final suffix in const <String>['free', 'nitro', 'beta', 'floor', 'extended']) {
    if (id.endsWith(':$suffix')) id = id.substring(0, id.length - suffix.length - 1);
  }
  return id;
}
