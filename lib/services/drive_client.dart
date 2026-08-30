/// Google Drive as a backup destination: the sign-in, and the four calls that
/// put a file there, list what is there, read one back and delete an old one.
///
/// The sign-in is deliberately the plainest thing that works on a phone with no
/// native plugin and no server of ours:
///
///  * the user pastes a client id and secret from their *own* Google Cloud
///    project ("Desktop app" OAuth client) — nothing here is shared with anyone,
///    and a desktop client's secret is not a confidential credential;
///  * the app opens a loopback listener, sends the browser to Google's consent
///    page with a PKCE challenge, and Google redirects back to
///    `http://127.0.0.1:<port>`, which is this app;
///  * the code is exchanged for a refresh token, and that is the whole grant.
///
/// This avoids a custom URL scheme (an intent filter plus a plugin to receive
/// it, and the AGP-9 Kotlin hook that follows) and keeps the flow pure Dart.
///
/// The scope asked for is `drive.file`, which grants access only to files this
/// app itself creates — it cannot read the rest of the user's Drive.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../models/backup.dart';

/// The OAuth client this app ships with, so connecting Drive is one tap rather
/// than a trip to the Google Cloud console.
///
/// A "Desktop app" client's secret is not a confidential credential — Google's
/// own guidance for installed apps says as much, and PKCE is what actually
/// protects the exchange. Nor does holding both strings grant anything: the only
/// scope asked for is `drive.file`, so the most they allow is asking a user to
/// consent to an app that can see the files it creates itself.
///
/// Either committed here or set at build time with
/// `--dart-define=MAICHAT_DRIVE_CLIENT_ID=…`. Empty in a fork that has not made
/// one, and then the Drive screen asks for a client of the user's own instead.
const String kBundledDriveClientId =
    String.fromEnvironment('MAICHAT_DRIVE_CLIENT_ID');
const String kBundledDriveClientSecret =
    String.fromEnvironment('MAICHAT_DRIVE_CLIENT_SECRET');

/// The Google endpoints, overridable so the flow can be pointed at a loopback
/// server in a test rather than at Google.
class DriveEndpoints {
  const DriveEndpoints({
    this.authorize = 'https://accounts.google.com/o/oauth2/v2/auth',
    this.token = 'https://oauth2.googleapis.com/token',
    this.files = 'https://www.googleapis.com/drive/v3/files',
    this.upload = 'https://www.googleapis.com/upload/drive/v3/files',
    this.userInfo = 'https://www.googleapis.com/oauth2/v3/userinfo',
  });

  final String authorize;
  final String token;
  final String files;
  final String upload;
  final String userInfo;
}

/// A file in the app's Drive folder.
class DriveFile {
  const DriveFile({
    required this.id,
    required this.name,
    this.bytes = 0,
    this.createdAt,
  });

  final String id;
  final String name;
  final int bytes;
  final DateTime? createdAt;

  factory DriveFile.fromJson(Map<String, dynamic> json) => DriveFile(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        bytes: int.tryParse(json['size']?.toString() ?? '') ?? 0,
        createdAt: DateTime.tryParse(json['createdTime']?.toString() ?? ''),
      );
}

/// Anything Drive or the sign-in refused, worded for a snackbar.
class DriveException implements Exception {
  const DriveException(this.message);
  final String message;
  @override
  String toString() => message;
}
/// Opens [uri] in the browser. Injectable so a test can answer the consent page
/// itself instead of launching one.
typedef UriLauncher = Future<bool> Function(Uri uri);

class DriveClient {
  DriveClient({
    http.Client? client,
    this.endpoints = const DriveEndpoints(),
    UriLauncher? launcher,
    this.folderName = 'MaiChat Backups',
    this.consentTimeout = const Duration(minutes: 5),
    this.loopbackHost = '127.0.0.1',
    String? bundledClientId,
    String? bundledClientSecret,
  })  : _http = client ?? http.Client(),
        bundledClientId = bundledClientId ?? kBundledDriveClientId,
        bundledClientSecret = bundledClientSecret ?? kBundledDriveClientSecret,
        _launch = launcher ??
            ((uri) => launchUrl(uri, mode: LaunchMode.externalApplication));

  /// The client the app ships with, used unless the user set one of their own.
  final String bundledClientId;
  final String bundledClientSecret;

  /// Which client a sign-in should use: the user's own where they have entered
  /// one, else the app's.
  String clientIdFor(DriveAuth auth) =>
      auth.clientId.trim().isEmpty ? bundledClientId : auth.clientId.trim();

  String clientSecretFor(DriveAuth auth) => auth.clientSecret.trim().isEmpty
      ? bundledClientSecret
      : auth.clientSecret.trim();

  /// Whether there is a client to sign in with at all.
  bool canConnect(DriveAuth auth) =>
      clientIdFor(auth).isNotEmpty && clientSecretFor(auth).isNotEmpty;

  final http.Client _http;
  final DriveEndpoints endpoints;
  final UriLauncher _launch;
  final String folderName;
  final Duration consentTimeout;

  /// The address the consent page is sent back to. Google's documented form for
  /// a desktop client is the loopback IP on a random port; `localhost` also
  /// works and is the fallback if a project ever answers
  /// `redirect_uri_mismatch`.
  final String loopbackHost;

  /// Only the files this app creates, plus the address of the account so the UI
  /// can say which one is connected.
  static const String scopes =
      'https://www.googleapis.com/auth/drive.file email';

  /// Access tokens live minutes and are worth not re-fetching per request, but
  /// they are never persisted — only the refresh token is.
  final Map<String, ({String token, DateTime expires})> _tokens = {};

  final Random _random = Random.secure();

  /// Runs the consent flow and returns [auth] with the grant filled in.
  ///
  /// Throws [DriveException] when the user declines, when the browser cannot be
  /// opened, or when Google refuses the exchange. The listener is always closed.
  Future<DriveAuth> connect(DriveAuth auth) async {
    if (!canConnect(auth)) {
      throw const DriveException(
        'This build has no Google client of its own — add a client ID and '
        'secret under Advanced.',
      );
    }
    final verifier = _randomString(64);
    final challenge = base64Url
        .encode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');
    final state = _randomString(24);

    HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    } catch (error) {
      throw DriveException('Could not listen for the sign-in reply ($error).');
    }
    final redirect = 'http://$loopbackHost:${server.port}';
    try {
      final consent = Uri.parse(endpoints.authorize).replace(
        queryParameters: <String, String>{
          'client_id': clientIdFor(auth),
          'redirect_uri': redirect,
          'response_type': 'code',
          'scope': scopes,
          'code_challenge': challenge,
          'code_challenge_method': 'S256',
          'state': state,
          // Offline access is the point: without a refresh token an automatic
          // backup would need the user present every time.
          'access_type': 'offline',
          'prompt': 'consent',
        },
      );
      if (!await _launch(consent)) {
        throw const DriveException('No browser would open the sign-in page.');
      }
      final code = await _awaitCode(server, state);
      return await _exchange(auth, code: code, verifier: verifier,
          redirect: redirect);
    } finally {
      await server.close(force: true);
    }
  }
  /// Waits for Google's redirect and returns the code. Every request that is not
  /// the redirect gets a polite page, so a browser prefetching `/favicon.ico`
  /// cannot be mistaken for the answer.
  Future<String> _awaitCode(HttpServer server, String state) async {
    final completer = Completer<String>();
    final subscription = server.listen((request) async {
      final params = request.uri.queryParameters;
      final code = params['code'];
      final error = params['error'];
      if (code == null && error == null) {
        request.response
          ..statusCode = HttpStatus.notFound
          ..headers.contentType = ContentType.html
          ..write(_page('Waiting for Google…'));
        await request.response.close();
        return;
      }
      final mismatch = params['state'] != state;
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.html
        ..write(_page(code != null && !mismatch
            ? 'MaiChat is connected to Google Drive. You can close this tab.'
            : 'Sign-in failed. Go back to MaiChat and try again.'));
      await request.response.close();
      if (completer.isCompleted) return;
      if (error != null) {
        completer.completeError(DriveException('Google said: $error.'));
      } else if (mismatch) {
        // A reply that does not carry back our own state is not our reply.
        completer.completeError(
          const DriveException('The sign-in reply did not match this request.'),
        );
      } else {
        completer.complete(code!);
      }
    });
    try {
      return await completer.future.timeout(consentTimeout);
    } on TimeoutException {
      throw const DriveException('The sign-in was not finished in time.');
    } finally {
      await subscription.cancel();
    }
  }

  static String _page(String message) =>
      '<!doctype html><html><head><meta charset="utf-8">'
      '<title>MaiChat</title></head>'
      '<body style="font-family:system-ui;padding:3rem;text-align:center">'
      '<h2>MaiChat</h2><p>$message</p></body></html>';

  Future<DriveAuth> _exchange(
    DriveAuth auth, {
    required String code,
    required String verifier,
    required String redirect,
  }) async {
    final json = await _postForm(endpoints.token, <String, String>{
      'code': code,
      'client_id': clientIdFor(auth),
      'client_secret': clientSecretFor(auth),
      'redirect_uri': redirect,
      'grant_type': 'authorization_code',
      'code_verifier': verifier,
    });
    final refresh = json['refresh_token']?.toString() ?? '';
    final access = json['access_token']?.toString() ?? '';
    if (refresh.isEmpty) {
      throw const DriveException(
        'Google did not send a refresh token. Remove MaiChat from your Google '
        'account permissions and connect again.',
      );
    }
    // Drive access is a *checkbox* on the consent screen (Google's granular
    // permissions), so a sign-in can succeed with the box unticked. Saying so
    // here beats a mystifying 403 on the first upload.
    final granted = json['scope']?.toString() ?? '';
    if (granted.isNotEmpty && !granted.contains('drive.file')) {
      throw const DriveException(
        'The Drive permission was not granted — connect again and tick the box '
        'for the Drive files MaiChat creates.',
      );
    }
    if (access.isNotEmpty) _cache(refresh, access, json['expires_in']);
    return auth.copyWith(
      refreshToken: refresh,
      email: await _email(access),
    );
  }

  /// Which account consented. Best-effort: a backup destination that works but
  /// cannot name itself is better than a sign-in that fails at the last step.
  Future<String> _email(String accessToken) async {
    if (accessToken.isEmpty) return '';
    try {
      final response = await _http.get(
        Uri.parse(endpoints.userInfo),
        headers: {'Authorization': 'Bearer $accessToken'},
      );
      if (response.statusCode != 200) return '';
      final json = jsonDecode(response.body);
      return json is Map ? json['email']?.toString() ?? '' : '';
    } catch (_) {
      return '';
    }
  }
  /// A usable access token for [auth], refreshing when the cached one is spent.
  Future<String> accessToken(DriveAuth auth) async {
    if (!auth.isConnected) {
      throw const DriveException('Google Drive is not connected.');
    }
    final cached = _tokens[auth.refreshToken];
    if (cached != null && cached.expires.isAfter(DateTime.now())) {
      return cached.token;
    }
    final json = await _postForm(endpoints.token, <String, String>{
      'client_id': clientIdFor(auth),
      'client_secret': clientSecretFor(auth),
      'refresh_token': auth.refreshToken,
      'grant_type': 'refresh_token',
    });
    final access = json['access_token']?.toString() ?? '';
    if (access.isEmpty) {
      throw const DriveException(
        'Google would not renew the sign-in. Connect Drive again.',
      );
    }
    _cache(auth.refreshToken, access, json['expires_in']);
    return access;
  }

  void _cache(String refreshToken, String access, Object? expiresIn) {
    final seconds = (expiresIn is num ? expiresIn.toInt() : 3600) - 60;
    _tokens[refreshToken] = (
      token: access,
      expires: DateTime.now().add(Duration(seconds: seconds.clamp(30, 3600))),
    );
  }

  /// Finds (or creates) the folder backups go into, returning [auth] with its id.
  Future<DriveAuth> ensureFolder(DriveAuth auth) async {
    if (auth.folderId.isNotEmpty) return auth;
    final token = await accessToken(auth);
    final query = "mimeType='application/vnd.google-apps.folder' and "
        "name='$folderName' and trashed=false";
    final found = await _getJson(
      Uri.parse(endpoints.files).replace(queryParameters: <String, String>{
        'q': query,
        'fields': 'files(id,name)',
        'pageSize': '1',
      }),
      token,
    );
    final files = found['files'];
    if (files is List && files.isNotEmpty && files.first is Map) {
      final id = (files.first as Map)['id']?.toString() ?? '';
      if (id.isNotEmpty) return auth.copyWith(folderId: id);
    }
    final created = await _postJson(
      Uri.parse(endpoints.files).replace(
        queryParameters: <String, String>{'fields': 'id'},
      ),
      token,
      <String, Object?>{
        'name': folderName,
        'mimeType': 'application/vnd.google-apps.folder',
      },
    );
    final id = created['id']?.toString() ?? '';
    if (id.isEmpty) {
      throw const DriveException('Drive would not create the backups folder.');
    }
    return auth.copyWith(folderId: id);
  }
  /// Uploads the archive at [file] as [name] into the app's folder.
  ///
  /// One multipart request — the metadata and the archive together, which is the
  /// shape Drive documents — but *streamed* from disk: a backup is far too large
  /// to hold in memory twice, and the body is built as it goes.
  Future<DriveFile> uploadFile({
    required DriveAuth auth,
    required String name,
    required File file,
  }) async {
    final token = await accessToken(auth);
    const boundary = 'maichat-backup-boundary';
    final metadata = jsonEncode(<String, Object?>{
      'name': name,
      if (auth.folderId.isNotEmpty) 'parents': <String>[auth.folderId],
      'appProperties': <String, String>{'maichat': 'backup'},
    });
    final head = utf8.encode('--$boundary\r\n'
        'Content-Type: application/json; charset=UTF-8\r\n\r\n'
        '$metadata\r\n'
        '--$boundary\r\n'
        'Content-Type: application/zip\r\n\r\n');
    final tail = utf8.encode('\r\n--$boundary--\r\n');
    final length = head.length + await file.length() + tail.length;

    final request = http.StreamedRequest(
      'POST',
      Uri.parse(endpoints.upload).replace(
        queryParameters: <String, String>{
          'uploadType': 'multipart',
          'fields': 'id,name,size,createdTime',
        },
      ),
    )
      ..headers['Authorization'] = 'Bearer $token'
      ..headers['Content-Type'] = 'multipart/related; boundary=$boundary'
      ..contentLength = length;

    // The body is fed while the response is awaited; a read error closes the
    // sink so the request fails rather than hanging.
    unawaited(() async {
      try {
        request.sink.add(head);
        await file.openRead().forEach(request.sink.add);
        request.sink.add(tail);
      } catch (error) {
        request.sink.addError(error);
      } finally {
        await request.sink.close();
      }
    }());

    final http.Response response;
    try {
      response = await http.Response.fromStream(await _http.send(request));
    } catch (error) {
      throw DriveException('The upload did not finish ($error).');
    }
    return DriveFile.fromJson(_json(response, 'upload the backup'));
  }

  /// The backups already in the folder, newest first.
  Future<List<DriveFile>> list(DriveAuth auth) async {
    if (auth.folderId.isEmpty) return const <DriveFile>[];
    final token = await accessToken(auth);
    final json = await _getJson(
      Uri.parse(endpoints.files).replace(queryParameters: <String, String>{
        'q': "'${auth.folderId}' in parents and trashed=false",
        'fields': 'files(id,name,size,createdTime)',
        'orderBy': 'createdTime desc',
        'pageSize': '100',
      }),
      token,
    );
    final files = json['files'];
    if (files is! List) return const <DriveFile>[];
    return files
        .whereType<Map<String, dynamic>>()
        .map(DriveFile.fromJson)
        .where((file) => file.id.isNotEmpty)
        .toList();
  }

  /// Reads one backup back out of Drive, straight into [file] — streamed, for
  /// the same reason the upload is.
  Future<void> downloadToFile(
    DriveAuth auth,
    String fileId,
    File file,
  ) async {
    final token = await accessToken(auth);
    final request = http.Request(
      'GET',
      Uri.parse('${endpoints.files}/$fileId').replace(
        queryParameters: <String, String>{'alt': 'media'},
      ),
    )..headers['Authorization'] = 'Bearer $token';
    final http.StreamedResponse response;
    try {
      response = await _http.send(request);
    } catch (error) {
      throw DriveException('Could not reach Google Drive ($error).');
    }
    if (response.statusCode >= 400) {
      throw DriveException(
        _failure(
          await http.Response.fromStream(response),
          'download the backup',
        ),
      );
    }
    final parent = file.parent;
    if (!parent.existsSync()) parent.createSync(recursive: true);
    final sink = file.openWrite();
    try {
      await response.stream.pipe(sink);
    } finally {
      await sink.close();
    }
  }

  /// Reads one backup back out of Drive into memory. Only for a caller that has
  /// nowhere to put a file.
  Future<Uint8List> download(DriveAuth auth, String fileId) async {
    final token = await accessToken(auth);
    final response = await _http.get(
      Uri.parse('${endpoints.files}/$fileId').replace(
        queryParameters: <String, String>{'alt': 'media'},
      ),
      headers: <String, String>{'Authorization': 'Bearer $token'},
    );
    if (response.statusCode != 200) {
      throw DriveException(_failure(response, 'download the backup'));
    }
    return response.bodyBytes;
  }

  /// Deletes one — how retention keeps the folder from growing for ever.
  Future<void> delete(DriveAuth auth, String fileId) async {
    final token = await accessToken(auth);
    final response = await _http.delete(
      Uri.parse('${endpoints.files}/$fileId'),
      headers: <String, String>{'Authorization': 'Bearer $token'},
    );
    // 404 means somebody already deleted it, which is the state we wanted.
    if (response.statusCode >= 400 && response.statusCode != 404) {
      throw DriveException(_failure(response, 'delete a backup'));
    }
  }
  Future<Map<String, dynamic>> _postForm(
    String url,
    Map<String, String> form,
  ) async {
    http.Response response;
    try {
      response = await _http.post(Uri.parse(url), body: form);
    } catch (error) {
      throw DriveException('Could not reach Google ($error).');
    }
    return _json(response, 'sign in');
  }

  Future<Map<String, dynamic>> _getJson(Uri uri, String token) async {
    http.Response response;
    try {
      response = await _http.get(
        uri,
        headers: <String, String>{'Authorization': 'Bearer $token'},
      );
    } catch (error) {
      throw DriveException('Could not reach Google Drive ($error).');
    }
    return _json(response, 'talk to Drive');
  }

  Future<Map<String, dynamic>> _postJson(
    Uri uri,
    String token,
    Map<String, Object?> body,
  ) async {
    http.Response response;
    try {
      response = await _http.post(
        uri,
        headers: <String, String>{
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(body),
      );
    } catch (error) {
      throw DriveException('Could not reach Google Drive ($error).');
    }
    return _json(response, 'talk to Drive');
  }

  Map<String, dynamic> _json(http.Response response, String what) {
    if (response.statusCode >= 400) {
      throw DriveException(_failure(response, what));
    }
    try {
      final json = jsonDecode(response.body);
      if (json is Map<String, dynamic>) return json;
    } catch (_) {
      // Fall through to the same complaint as an empty body.
    }
    throw DriveException('Google sent back something unreadable when asked to '
        '$what.');
  }

  /// Google's own error text where it gives one, so a wrong client secret says
  /// so instead of reporting a bare status code.
  String _failure(http.Response response, String what) {
    var detail = '';
    try {
      final json = jsonDecode(response.body);
      if (json is Map) {
        final error = json['error'];
        detail = (error is Map ? error['message']?.toString() : null) ??
            json['error_description']?.toString() ??
            (error is String ? error : '') ;
      }
    } catch (_) {
      // A non-JSON body (an HTML error page) tells the user nothing useful.
    }
    final suffix = detail.trim().isEmpty ? '' : ' — $detail';
    return 'Google would not $what (${response.statusCode})$suffix';
  }

  static const String _alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';

  String _randomString(int length) => List<String>.generate(
        length,
        (_) => _alphabet[_random.nextInt(_alphabet.length)],
      ).join();

  void close() => _http.close();
}
