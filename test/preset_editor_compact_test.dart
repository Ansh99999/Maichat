import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/preset.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/services/chat_client.dart';
import 'package:maichat/screens/presets/preset_editor_body.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart' hide Provider;
import 'package:shared_preferences/shared_preferences.dart';

class _Fake extends ChatClient {
  @override
  Future<List<String>> listModels(p) async => const [];
}

Future<AppState> _state() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final s = AppState(client: _Fake());
  await s.init();
  await s.addProvider(Provider(
    id: 'p1',
    name: 'OpenAI',
    kind: ProviderKind.openai,
    baseUrl: 'https://a/v1',
    model: 'gpt-4o',
    apiKey: 'k',
  ));
  return s;
}

void main() {
  testWidgets('compact preset editor mirrors the active provider + model',
      (tester) async {
    final state = await _state();
    // A preset carrying a STALE binding — the sidebar editor must ignore it and
    // show the app's active connection instead.
    final preset = Preset.create(name: 'P')
      ..providerId = 'old-provider'
      ..model = 'old-model';

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          home: Scaffold(
            body: PresetEditorBody(
              preset: preset,
              compact: true,
              onChanged: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Shows the active provider + its model, not the preset's stale binding.
    expect(find.text('OpenAI'), findsWidgets);
    expect(find.text('gpt-4o'), findsWidgets);
    expect(find.text('old-model'), findsNothing);
  });
}
