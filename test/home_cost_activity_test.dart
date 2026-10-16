import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/home_layout.dart';
import 'package:maichat/models/provider.dart' as app;
import 'package:maichat/models/usage.dart';
import 'package:maichat/screens/home/home_spec.dart';
import 'package:maichat/screens/home/widgets/cost_widget.dart';
import 'package:maichat/services/usage_ledger.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart';

class _Ledger extends UsageLedger {
  int scans = 0;
  @override
  UsageBucket totals(String providerId, {String? model, DateTime? since}) {
    scans++;
    return super.totals(providerId, model: model, since: since);
  }
}

class _State extends AppState {
  final ledger = _Ledger();
  @override
  UsageLedger get usage => ledger;
  @override
  app.Provider get activeProvider => app.Provider(
    id: 'p',
    name: 'Provider',
    kind: app.ProviderKind.openai,
    baseUrl: 'https://example.invalid/v1',
    model: 'm',
  );
  void changed() => notifyListeners();
}

void main() {
  testWidgets('cost history is scanned only when usage changes', (
    tester,
  ) async {
    final state = _State();
    addTearDown(state.dispose);
    const tile = HomeTile(
      id: 'cost',
      kind: HomeWidgetKind.cost,
      x: 0,
      y: 0,
      w: 2,
      h: 2,
    );
    final layout = HomeLayout(
      columns: 4,
      rows: 6,
      pages: [
        const HomePage(id: 'p', tiles: [tile]),
      ],
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 240,
              height: 240,
              child: Builder(
                builder: (context) => const CostSpec().build(
                  context,
                  HomeTileContext(
                    tile: tile,
                    size: const Size(240, 240),
                    layout: layout,
                    editing: false,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final initialScans = state.ledger.scans;
    expect(initialScans, greaterThan(0));
    for (var i = 0; i < 30; i++) {
      state.changed();
      await tester.pump();
    }
    expect(
      state.ledger.scans,
      initialScans,
      reason: 'streaming unrelated data must not aggregate cost history',
    );
    state.ledger.record(
      providerId: 'p',
      model: 'm',
      usage: const TokenUsage(inputTokens: 100, outputTokens: 20),
    );
    state.changed();
    await tester.pump();
    expect(state.ledger.scans, greaterThan(initialScans));
    expect(find.textContaining('120 tokens'), findsWidgets);
    state.ledger.clear();
    state.changed();
    await tester.pump();
    expect(find.textContaining('120 tokens'), findsNothing);
  });
}
