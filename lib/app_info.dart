/// The app's version string, kept in step with the `version:` line in
/// pubspec.yaml. Lives here (not on a screen) so both the UI and the update
/// check can read it without a layering dependency.
///
/// The two really must agree: the update check compares the newest GitHub tag
/// against *this* string, so a stale value here makes an up-to-date install
/// offer an update it already has, for ever. `test/app_version_test.dart` reads
/// pubspec.yaml and fails when they drift.
const String kAppVersion = '1.15.7';
