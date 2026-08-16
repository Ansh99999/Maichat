import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/app_info.dart';

/// A guard, not a unit test. [kAppVersion] is what the update check compares the
/// newest GitHub tag against, so when it lags behind pubspec.yaml an install of
/// the newest release keeps being told to update to the version it is already
/// running — which is exactly what shipped in 1.13.1 (the build said 1.13.0).
void main() {
  test('kAppVersion matches the version in pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match =
        RegExp(r'^version:\s*([^\s+]+)', multiLine: true).firstMatch(pubspec);
    expect(match, isNotNull, reason: 'pubspec.yaml has no version: line');

    expect(
      kAppVersion,
      match!.group(1),
      reason: 'lib/app_info.dart must be bumped with pubspec.yaml, or the app '
          'reports the wrong version and prompts to update for ever',
    );
  });
}
