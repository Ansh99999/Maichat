import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maichat/services/update_service.dart';

/// A GitHub API stand-in that answers [path] with [release] and 404s the rest,
/// recording what was asked for.
UpdateService _serving(String path, Map<String, dynamic> release,
    List<String> asked) {
  final client = MockClient((request) async {
    asked.add(request.url.path);
    if (request.url.path == '/repos/Ansh99999/Maichat/releases/$path') {
      return http.Response(jsonEncode(release), 200);
    }
    return http.Response('{"message":"Not Found"}', 404);
  });
  return UpdateService(client: client);
}

Map<String, dynamic> _release(String tag, List<String> assets) => {
      'tag_name': tag,
      'html_url': 'https://github.com/Ansh99999/Maichat/releases/tag/$tag',
      'body': 'notes',
      'assets': [
        for (final name in assets)
          {
            'browser_download_url':
                'https://github.com/Ansh99999/Maichat/releases/download/$tag/$name',
          },
      ],
    };

void main() {
  test('isNewer compares the semver core, ignoring build/pre-release', () {
    expect(UpdateService.isNewer('1.6.5', '1.6.4'), isTrue);
    expect(UpdateService.isNewer('1.7.0', '1.6.9'), isTrue);
    expect(UpdateService.isNewer('2.0.0', '1.9.9'), isTrue);
    expect(UpdateService.isNewer('1.6.5+12', '1.6.4'), isTrue);

    expect(UpdateService.isNewer('1.6.4', '1.6.4'), isFalse);
    expect(UpdateService.isNewer('1.6.3', '1.6.4'), isFalse);
    expect(UpdateService.isNewer('1.6.4+9', '1.6.4+8'), isFalse);
  });

  group('checkLatest (MaiChat)', () {
    test('offers a newer tagged release and its APK', () async {
      final asked = <String>[];
      final service = _serving(
          'latest', _release('v1.20.0', ['MaiChat-1.20.0.apk']), asked);
      final info = await service.checkLatest('1.19.3');
      expect(info, isNotNull);
      expect(info!.version, '1.20.0');
      expect(info.apkUrl, endsWith('/MaiChat-1.20.0.apk'));
      // Only the non-prerelease endpoint, so the beta can never leak in.
      expect(asked, ['/repos/Ansh99999/Maichat/releases/latest']);
    });

    test('stays quiet on the same version', () async {
      final service = _serving(
          'latest', _release('v1.19.3', ['MaiChat-1.19.3.apk']), []);
      expect(await service.checkLatest('1.19.3'), isNull);
    });
  });

  group('checkBeta (MaiChat Beta)', () {
    test('offers a later CI build of the rolling beta release', () async {
      final asked = <String>[];
      final service = _serving('tags/beta-latest',
          _release('beta-latest', ['MaiChat-Beta-1.19.3-b57.apk']), asked);
      final info = await service.checkBeta(42);
      expect(info, isNotNull);
      expect(info!.version, '1.19.3-b57');
      expect(info.apkUrl, endsWith('/MaiChat-Beta-1.19.3-b57.apk'));
      expect(asked, ['/repos/Ansh99999/Maichat/releases/tags/beta-latest']);
    });

    test('stays quiet on the build it is running, or an older one', () async {
      final release = _release('beta-latest', ['MaiChat-Beta-1.19.3-b57.apk']);
      expect(await _serving('tags/beta-latest', release, []).checkBeta(57),
          isNull);
      expect(await _serving('tags/beta-latest', release, []).checkBeta(60),
          isNull);
    });

    test('ignores a release whose APK carries no build number', () async {
      final service = _serving('tags/beta-latest',
          _release('beta-latest', ['MaiChat-1.19.3.apk']), []);
      expect(await service.checkBeta(0), isNull);
    });

    test('a missing beta release is silence, not an error', () async {
      final service = _serving('latest', _release('v9.9.9', []), []);
      expect(await service.checkBeta(0), isNull);
    });
  });
}
