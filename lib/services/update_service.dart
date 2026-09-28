import 'dart:convert';

import 'package:http/http.dart' as http;

/// A newer release the app found on GitHub.
class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.releaseUrl,
    this.apkUrl,
    this.notes = '',
  });

  final String version;
  final String releaseUrl;

  /// Direct link to the release's `.apk` asset, when it has one.
  final String? apkUrl;
  final String notes;

  /// What tapping "Update" should open: the APK if present, else the release
  /// page.
  String get downloadUrl => apkUrl ?? releaseUrl;
}

/// Checks the public GitHub Releases API for a newer version. Entirely
/// best-effort: any network/parse failure just yields null (no update shown),
/// so it never gets in the user's way.
class UpdateService {
  UpdateService({http.Client? client, this.repo = 'Ansh99999/Maichat'})
      : _client = client ?? http.Client();

  final http.Client _client;
  final String repo;

  Future<UpdateInfo?> checkLatest(String currentVersion) async {
    // `releases/latest` never returns a prerelease, which is what keeps the
    // rolling beta release out of the real app's update prompt.
    final json = await _release('latest');
    if (json == null) return null;

    final tag = (json['tag_name'] as String? ?? '').trim();
    final latest = tag.startsWith('v') ? tag.substring(1) : tag;
    if (latest.isEmpty || !isNewer(latest, currentVersion)) return null;

    return UpdateInfo(
      version: latest,
      releaseUrl:
          json['html_url'] as String? ?? 'https://github.com/$repo/releases',
      apkUrl: _apkAsset(json),
      notes: (json['body'] as String? ?? '').trim(),
    );
  }

  /// The tag CI republishes on every push to the `beta` branch.
  static const String betaTag = 'beta-latest';

  /// MaiChat Beta's check: the one rolling prerelease under [betaTag], newer
  /// when its APK was built by a later CI run than [currentBuild]. The version
  /// string cannot tell two beta builds apart, so the run number rides in the
  /// asset's name (`MaiChat-Beta-<version>-b<run>.apk`) and is read back here.
  Future<UpdateInfo?> checkBeta(int currentBuild) async {
    final json = await _release('tags/$betaTag');
    if (json == null) return null;
    final apk = _apkAsset(json);
    if (apk == null) return null;
    final match = RegExp(r'-b(\d+)\.apk$', caseSensitive: false).firstMatch(apk);
    final build = match == null ? null : int.tryParse(match.group(1)!);
    if (build == null || build <= currentBuild) return null;

    final named = RegExp(r'MaiChat-Beta-([^/]+)\.apk$', caseSensitive: false)
        .firstMatch(apk);
    return UpdateInfo(
      version: named?.group(1) ?? 'b$build',
      releaseUrl:
          json['html_url'] as String? ?? 'https://github.com/$repo/releases',
      apkUrl: apk,
      notes: (json['body'] as String? ?? '').trim(),
    );
  }

  /// One release from the GitHub API, or null on any failure.
  Future<Map<String, dynamic>?> _release(String path) async {
    final uri = Uri.parse('https://api.github.com/repos/$repo/releases/$path');
    http.Response response;
    try {
      response = await _client.get(uri, headers: {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'MaiChat',
      }).timeout(const Duration(seconds: 20));
    } catch (_) {
      return null;
    }
    if (response.statusCode != 200) return null;
    try {
      final decoded = jsonDecode(response.body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// The release's first `.apk` download link.
  static String? _apkAsset(Map<String, dynamic> json) {
    final assets = json['assets'];
    if (assets is! List) return null;
    for (final asset in assets) {
      final url = asset is Map ? asset['browser_download_url'] as String? : null;
      if (url != null && url.toLowerCase().endsWith('.apk')) return url;
    }
    return null;
  }

  /// Whether semantic version [a] is strictly greater than [b], comparing the
  /// numeric major.minor.patch and ignoring any build/pre-release suffix.
  static bool isNewer(String a, String b) {
    final pa = _parts(a);
    final pb = _parts(b);
    for (var i = 0; i < 3; i++) {
      if (pa[i] != pb[i]) return pa[i] > pb[i];
    }
    return false;
  }

  static List<int> _parts(String v) {
    final core = v.split('+').first.split('-').first;
    final segs = core.split('.');
    return [
      for (var i = 0; i < 3; i++)
        i < segs.length ? (int.tryParse(segs[i]) ?? 0) : 0,
    ];
  }
}
