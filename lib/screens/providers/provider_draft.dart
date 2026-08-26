import 'package:flutter/material.dart';

import '../../models/budget.dart';
import '../../models/model_pricing.dart';
import '../../models/provider.dart';

/// The mutable working copy behind the provider editor.
///
/// The editor has three tabs, a save button that is not always in view, and
/// swipe navigation between them — so the edits have to live somewhere that
/// survives moving between tabs without being committed. This is that place: the
/// controllers and lists the tabs bind to, plus [toProvider] to fold them back
/// into an immutable [Provider] on save.
class ProviderDraft {
  ProviderDraft.from(Provider provider)
      : id = provider.id,
        name = TextEditingController(text: provider.name),
        baseUrl = TextEditingController(text: provider.baseUrl),
        model = TextEditingController(text: provider.model),
        kind = provider.kind,
        keyStrategy = provider.keyStrategy,
        claudeCodeHeaders = provider.claudeCodeHeaders,
        keys = [
          for (final key in provider.apiKeys) TextEditingController(text: key),
        ],
        prices = List<ModelPrice>.of(provider.prices),
        fallbackModels = List<String>.of(provider.fallbackModels),
        customHeaders = Map<String, String>.of(provider.customHeaders),
        budgets = List<Budget>.of(provider.budgets) {
    // Always show at least one key row, even where a key is optional — an empty
    // field explains the concept better than no field does.
    if (keys.isEmpty) keys.add(TextEditingController());
  }

  final String id;
  final TextEditingController name;
  final TextEditingController baseUrl;
  final TextEditingController model;
  final List<TextEditingController> keys;

  ProviderKind kind;
  KeyRotationStrategy keyStrategy;
  bool claudeCodeHeaders;
  List<ModelPrice> prices;
  List<String> fallbackModels;
  Map<String, String> customHeaders;
  List<Budget> budgets;

  /// A blank draft for a provider that does not exist yet.
  factory ProviderDraft.blank() =>
      ProviderDraft.from(Provider.create(ProviderKind.openai));

  /// The immutable provider these edits describe.
  ///
  /// An empty base URL falls back to the format's default rather than saving a
  /// provider that cannot be reached — the field being blank almost always means
  /// "the usual one".
  Provider toProvider() => Provider(
        id: id,
        name: name.text.trim(),
        kind: kind,
        baseUrl: baseUrl.text.trim().isEmpty
            ? kind.defaultBaseUrl
            : baseUrl.text.trim(),
        apiKeys: [
          for (final key in keys)
            if (key.text.trim().isNotEmpty) key.text.trim(),
        ],
        keyStrategy: keyStrategy,
        model: model.text.trim(),
        prices: prices,
        fallbackModels: fallbackModels,
        customHeaders: customHeaders,
        claudeCodeHeaders: claudeCodeHeaders,
        budgets: budgets,
      );

  /// Switches format, carrying the base URL across only when it was still a
  /// default. A URL the user typed is never clobbered — that rule predates the
  /// rewrite and is the one thing everybody notices when it breaks.
  void changeKind(ProviderKind next) {
    if (next == kind) return;
    final current = baseUrl.text.trim();
    final wasDefault = current.isEmpty ||
        ProviderKind.values.any((k) => k.defaultBaseUrl == current);
    kind = next;
    if (wasDefault) baseUrl.text = next.defaultBaseUrl;
  }

  void addKey() => keys.add(TextEditingController());

  /// Removes key [index], keeping one row on screen.
  void removeKey(int index) {
    if (keys.length <= 1) return;
    keys.removeAt(index).dispose();
  }

  void dispose() {
    name.dispose();
    baseUrl.dispose();
    model.dispose();
    for (final key in keys) {
      key.dispose();
    }
  }
}
