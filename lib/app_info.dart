/// The app's version string, kept in step with the `version:` line in
/// pubspec.yaml. Lives here (not on a screen) so both the UI and the update
/// check can read it without a layering dependency.
///
/// The two really must agree: the update check compares the newest GitHub tag
/// against *this* string, so a stale value here makes an up-to-date install
/// offer an update it already has, for ever. `test/app_version_test.dart` reads
/// pubspec.yaml and fails when they drift.
const String kAppVersion = '1.19.3';

/// Whether this is MaiChat Beta: the same code built as a second app
/// (`me.maitavern.maichat.beta`) that installs beside MaiChat with its own data,
/// for trying out features before they reach the real one. Set by CI from the
/// `beta` branch with `--dart-define=MAICHAT_BETA=true`; Gradle reads the same
/// define to pick the package and launcher label.
const bool kIsBeta = bool.fromEnvironment('MAICHAT_BETA');

/// The CI run that built this beta, which is how the beta's update check tells
/// one build of the rolling `beta-latest` release from the next (the version
/// string does not move between them). 0 in a local or non-beta build.
const int kBetaBuild = int.fromEnvironment('MAICHAT_BETA_BUILD');

/// The name the app shows for itself where telling the two installs apart
/// matters (window title, About).
const String kAppDisplayName = kIsBeta ? 'MaiChat Beta' : 'MaiChat';

/// The version as the app shows it: a beta carries its build number, since
/// every beta build shares the release's version string.
const String kAppVersionLabel =
    kIsBeta ? '$kAppVersion-b$kBetaBuild' : kAppVersion;
