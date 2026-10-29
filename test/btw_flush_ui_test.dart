import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('idle side queue flush completes outside the widget fake clock', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState();
    await state.init();
    // The queue's initial future was created in the widget's fake-async zone.
    // With no work, flushing from a real async scope or teardown must not await
    // a continuation that would need another widget pump to finish.
    await tester.runAsync(
      () => state.flushPendingSaves().timeout(const Duration(seconds: 2)),
    );
    addTearDown(() async {
      await state.flushPendingSaves().timeout(const Duration(seconds: 2));
      state.dispose();
    });
  });
}
