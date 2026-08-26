/// Reading and writing providers as JSON, for moving a setup between installs.
///
/// Keys are left out unless the user asks for them. An export is a file that
/// lands in Downloads and gets shared into chats; a provider export with keys in
/// it is a credential file, and the default should not quietly make one.
library;

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../models/provider.dart';
import '../../widgets/export_sheet.dart';

/// The JSON for [providers], as a single object when there is one and a
/// `{providers: [...]}` envelope when there are several.
///
/// [includeKeys] governs the credentials. With it off the key pool is dropped
/// entirely rather than blanked, so the importing install shows empty key fields
/// instead of a row of meaningless placeholders.
String encodeProviders(List<Provider> providers, {bool includeKeys = false}) {
  Map<String, dynamic> one(Provider provider) {
    final json = provider.toJson();
    if (!includeKeys) {
      json.remove('apiKey');
      json.remove('apiKeys');
    }
    return json;
  }

  final encoder = const JsonEncoder.withIndent('  ');
  if (providers.length == 1) return encoder.convert(one(providers.first));
  return encoder.convert(<String, dynamic>{
    'providers': [for (final provider in providers) one(provider)],
  });
}

/// Providers found in [text], accepting either shape [encodeProviders] writes
/// plus a bare list. Ids are reissued so importing a provider that is already
/// installed adds a second one rather than colliding with the first.
///
/// Throws [FormatException] with something a person can read, since the message
/// goes straight into a SnackBar.
List<Provider> decodeProviders(String text) {
  final Object? json;
  try {
    json = jsonDecode(text);
  } on FormatException {
    throw const FormatException('That is not JSON.');
  }

  final List<dynamic> entries;
  if (json is Map<String, dynamic> && json['providers'] is List) {
    entries = json['providers'] as List<dynamic>;
  } else if (json is Map<String, dynamic>) {
    entries = <dynamic>[json];
  } else if (json is List) {
    entries = json;
  } else {
    throw const FormatException('No provider in that file.');
  }

  final providers = <Provider>[];
  var stamp = DateTime.now().microsecondsSinceEpoch;
  for (final entry in entries) {
    if (entry is! Map<String, dynamic>) continue;
    // Anything with neither an address nor a format is not a provider — most
    // likely the wrong export was picked.
    if (entry['baseUrl'] == null && entry['kind'] == null) continue;
    providers.add(Provider.fromJson(entry).withId((stamp++).toString()));
  }
  if (providers.isEmpty) {
    throw const FormatException('No provider in that file.');
  }
  return providers;
}

/// Asks whether to include the keys, then hands off to the shared save-or-copy
/// chooser. The question is asked every time rather than remembered: the answer
/// depends on where this particular file is going.
Future<void> exportProviders(
  BuildContext context,
  List<Provider> providers,
) async {
  if (providers.isEmpty) return;
  final hasKeys = providers.any((p) => p.usableKeys.isNotEmpty);

  var includeKeys = false;
  if (hasKeys) {
    final answer = await showDialog<bool>(
      context: context,
      builder: (context) => _KeyChoiceDialog(count: providers.length),
    );
    if (answer == null || !context.mounted) return;
    includeKeys = answer;
  }

  final name = providers.length == 1
      ? safeFileName(providers.first.displayName)
      : 'providers';
  await offerExport(
    context,
    text: encodeProviders(providers, includeKeys: includeKeys),
    fileName: '$name.json',
    subtitle: includeKeys
        ? 'MaiChat provider · includes API keys'
        : 'MaiChat provider · no API keys',
    dialogTitle: 'Save provider',
  );
}

/// The keys-or-no-keys question. Two buttons rather than a checkbox, so neither
/// answer is the one you get by not reading.
class _KeyChoiceDialog extends StatelessWidget {
  const _KeyChoiceDialog({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('Include API keys?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            count == 1
                ? 'The export can carry this provider’s keys, or just its '
                    'address, format and prices.'
                : 'The export can carry these providers’ keys, or just their '
                    'addresses, formats and prices.',
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.warning_amber_outlined, size: 18, color: scheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'A file with keys in it is a credential. Anyone who opens it '
                  'can spend on your account.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Include keys'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Without keys'),
        ),
      ],
    );
  }
}

/// Picks one or more JSON files and returns every provider read out of them.
///
/// A file that will not parse is reported rather than skipped silently, but one
/// bad file does not discard the good ones alongside it.
Future<List<Provider>> importProviders(BuildContext context) async {
  FilePickerResult? result;
  try {
    result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json'],
      allowMultiple: true,
      withData: true,
    );
  } catch (_) {
    result = null;
  }
  if (result == null || !context.mounted) return const <Provider>[];

  final providers = <Provider>[];
  String? firstError;
  for (final file in result.files) {
    final bytes = file.bytes;
    if (bytes == null) {
      firstError ??= 'Could not read ${file.name}.';
      continue;
    }
    try {
      providers.addAll(decodeProviders(utf8.decode(bytes)));
    } on FormatException catch (e) {
      firstError ??= '${file.name}: ${e.message}';
    } catch (_) {
      firstError ??= 'Could not read ${file.name}.';
    }
  }

  if (firstError != null && context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(firstError)));
  }
  return providers;
}
