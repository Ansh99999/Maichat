import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/screens/providers/providers_screen.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart' hide Provider;
import 'package:shared_preferences/shared_preferences.dart';

/// The Providers hub: search, the active marker, and selection mode.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Widget host(AppState state) => ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: ProvidersScreen()),
      );

  Future<AppState> seeded(WidgetTester tester, List<Provider> providers) async {
    final state = AppState();
    await state.init();
    for (final provider in providers) {
      await state.addProvider(provider);
    }
    return state;
  }

  Provider make(String name, {String model = 'gpt-4o', String? url}) => Provider(
        id: name,
        name: name,
        kind: ProviderKind.openai,
        baseUrl: url ?? 'https://api.openai.com/v1',
        model: model,
      );

  testWidgets('lists every configured provider', (tester) async {
    final state = await seeded(tester, [make('Alpha'), make('Beta')]);
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
  });

  testWidgets('an empty section explains what a provider is', (tester) async {
    final state = await seeded(tester, const <Provider>[]);
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    expect(find.text('No providers yet'), findsOneWidget);
    expect(find.textContaining('where replies come from'), findsOneWidget);
  });

  testWidgets('search narrows by name', (tester) async {
    final state = await seeded(tester, [make('Alpha'), make('Beta')]);
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(SearchBar), 'alph');
    await tester.pumpAndSettle();

    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsNothing);
  });

  testWidgets('search also looks at the model and the host', (tester) async {
    final state = await seeded(tester, [
      make('Alpha', model: 'gpt-4o'),
      make('Beta', model: 'claude-sonnet-4-5', url: 'https://api.anthropic.com/v1'),
    ]);
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(SearchBar), 'sonnet');
    await tester.pumpAndSettle();
    expect(find.text('Beta'), findsOneWidget);
    expect(find.text('Alpha'), findsNothing);

    await tester.enterText(find.byType(SearchBar), 'anthropic.com');
    await tester.pumpAndSettle();
    expect(find.text('Beta'), findsOneWidget);
  });

  testWidgets('a search matching nothing says so', (tester) async {
    final state = await seeded(tester, [make('Alpha')]);
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(SearchBar), 'zzz');
    await tester.pumpAndSettle();

    expect(find.text('No provider matches that.'), findsOneWidget);
  });

  testWidgets('the active provider is marked, and the ring switches it',
      (tester) async {
    final state = await seeded(tester, [make('Alpha'), make('Beta')]);
    // addProvider makes the newest active, so Beta starts as the active one.
    expect(state.activeProvider?.id, 'Beta');

    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    // The filled ring carries a tick; only the active row has one.
    expect(find.byIcon(Icons.check), findsOneWidget);

    await tester.tap(find.byTooltip('Make active'));
    await tester.pumpAndSettle();

    expect(state.activeProvider?.id, 'Alpha');
    expect(find.byTooltip('Active'), findsOneWidget);
  });

  testWidgets('tapping the active ring does nothing — it is already active',
      (tester) async {
    final state = await seeded(tester, [make('Alpha')]);
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Active'));
    await tester.pumpAndSettle();

    expect(state.activeProvider?.id, 'Alpha');
  });

  testWidgets('long press enters selection and shows a count', (tester) async {
    final state = await seeded(tester, [make('Alpha'), make('Beta')]);
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Alpha'));
    await tester.pumpAndSettle();

    expect(find.text('1 selected'), findsOneWidget);
    // The FAB and the drawer step out of the way while selecting.
    expect(find.text('Add provider'), findsNothing);
  });

  testWidgets('tapping more rows adds to the selection', (tester) async {
    final state = await seeded(tester, [make('Alpha'), make('Beta')]);
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Alpha'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Beta'));
    await tester.pumpAndSettle();

    expect(find.text('2 selected'), findsOneWidget);
  });

  testWidgets('emptying the selection leaves selection mode', (tester) async {
    final state = await seeded(tester, [make('Alpha')]);
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Alpha'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();

    expect(find.textContaining('selected'), findsNothing);
    expect(find.text('Add provider'), findsOneWidget);
  });
}
