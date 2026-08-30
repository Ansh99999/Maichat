import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:maichat/models/backup.dart';
import 'package:maichat/services/drive_client.dart';

/// A stand-in for Google: the two OAuth endpoints and the four Drive calls this
/// app makes. Records what it was asked so the test can check the request, which
/// is the only way to be sure about a protocol nobody here can try for real.
class FakeGoogle {
  FakeGoogle(this.server) {
    server.listen(_handle);
  }

  static Future<FakeGoogle> start() async =>
      FakeGoogle(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer server;

  String get root => 'http://127.0.0.1:${server.port}';

  DriveEndpoints get endpoints => DriveEndpoints(
        authorize: '$root/auth',
        token: '$root/token',
        files: '$root/files',
        upload: '$root/upload',
        userInfo: '$root/userinfo',
      );

  /// Every form the token endpoint received, in order.
  final List<Map<String, String>> tokenCalls = <Map<String, String>>[];

  /// What was POSTed to the upload endpoint.
  List<int>? uploaded;
  String? uploadContentType;

  /// Set when the folder search should find one already there.
  String? existingFolder;

  /// What the folder listing answers with.
  List<Map<String, Object?>> files = <Map<String, Object?>>[];

  /// The bytes `alt=media` hands back.
  List<int> download = const <int>[];

  /// Ids the delete endpoint was asked for.
  final List<String> deleted = <String>[];

  /// What a 'files' request should answer with instead of the happy path.
  int? failWith;

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    if (path == '/token') {
      final body = await utf8.decoder.bind(request).join();
      final form = Uri.splitQueryString(body);
      tokenCalls.add(form);
      return _json(request, <String, Object?>{
        'access_token': 'access-${tokenCalls.length}',
        'expires_in': 3600,
        if (form['grant_type'] == 'authorization_code')
          'refresh_token': 'refresh-1',
      });
    }
    if (path == '/userinfo') {
      return _json(request, <String, Object?>{'email': 'someone@example.com'});
    }
    if (path == '/upload') {
      uploadContentType = request.headers.contentType?.toString();
      uploaded = await request.fold<List<int>>(
        <int>[],
        (bytes, chunk) => bytes..addAll(chunk),
      );
      return _json(request, <String, Object?>{
        'id': 'file-1',
        'name': 'maichat-backup.zip',
        'size': '${uploaded!.length}',
        'createdTime': '2026-08-30T12:00:00.000Z',
      });
    }
    if (path == '/files' && request.method == 'POST') {
      await utf8.decoder.bind(request).join();
      return _json(request, <String, Object?>{'id': 'made-folder'});
    }
    if (path == '/files') {
      if (failWith != null) {
        request.response.statusCode = failWith!;
        request.response.write('{"error":{"message":"nope"}}');
        return request.response.close();
      }
      final query = request.uri.queryParameters['q'] ?? '';
      // The folder search is the one that asks by mime type; anything else is
      // the listing of what is in the folder.
      if (query.contains('mimeType=')) {
        return _json(request, <String, Object?>{
          'files': existingFolder == null
              ? <Object?>[]
              : <Object?>[
                  {'id': existingFolder, 'name': 'MaiChat Backups'},
                ],
        });
      }
      return _json(request, <String, Object?>{'files': files});
    }
    if (path.startsWith('/files/')) {
      final id = path.substring('/files/'.length);
      if (request.method == 'DELETE') {
        deleted.add(id);
        request.response.statusCode = HttpStatus.noContent;
        return request.response.close();
      }
      request.response.add(download);
      return request.response.close();
    }
    request.response.statusCode = HttpStatus.notFound;
    return request.response.close();
  }

  Future<void> _json(HttpRequest request, Map<String, Object?> body) {
    request.response
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    return request.response.close();
  }

  Future<void> stop() => server.close(force: true);
}
void main() {
  late FakeGoogle google;
  late http.Client client;

  const auth = DriveAuth(
    clientId: 'client-1',
    clientSecret: 'secret-1',
    refreshToken: 'refresh-1',
    folderId: 'folder-1',
  );

  setUp(() async {
    google = await FakeGoogle.start();
    client = http.Client();
  });

  tearDown(() async {
    client.close();
    await google.stop();
  });

  /// The consent page, answered the way a browser would: come back to the
  /// loopback address with a code. [state] and [challenge] can be tampered with
  /// to test what the client refuses.
  UriLauncher browser({
    String code = 'the-code',
    String? state,
    String? error,
    void Function(String challenge)? onChallenge,
  }) =>
      (uri) async {
        final params = uri.queryParameters;
        onChallenge?.call(params['code_challenge'] ?? '');
        final reply = Uri.parse(params['redirect_uri']!).replace(
          queryParameters: <String, String>{
            if (error == null) 'code': code else 'error': error,
            'state': state ?? params['state']!,
          },
        );
        // Deliberately not awaited: the client is not listening until after
        // this returns, and a browser does not wait for the app either.
        client.get(reply).ignore();
        return true;
      };

  group('signing in', () {
    test('exchanges the code for a refresh token and names the account',
        () async {
      String? challenge;
      final drive = DriveClient(
        client: client,
        endpoints: google.endpoints,
        launcher: browser(onChallenge: (value) => challenge = value),
      );

      final connected = await drive.connect(const DriveAuth(
        clientId: 'client-1',
        clientSecret: 'secret-1',
      ));

      expect(connected.refreshToken, 'refresh-1');
      expect(connected.email, 'someone@example.com');
      final form = google.tokenCalls.single;
      expect(form['grant_type'], 'authorization_code');
      expect(form['code'], 'the-code');
      expect(form['client_secret'], 'secret-1');
      expect(form['redirect_uri'], startsWith('http://127.0.0.1:'));
      // The PKCE challenge really is the hash of the verifier that was sent.
      final expected = base64Url
          .encode(sha256.convert(ascii.encode(form['code_verifier']!)).bytes)
          .replaceAll('=', '');
      expect(challenge, expected);
    });

    test('refuses a reply that does not carry back its own state', () async {
      final drive = DriveClient(
        client: client,
        endpoints: google.endpoints,
        launcher: browser(state: 'somebody-elses-state'),
      );

      await expectLater(
        drive.connect(const DriveAuth(clientId: 'a', clientSecret: 'b')),
        throwsA(isA<DriveException>()),
      );
      expect(google.tokenCalls, isEmpty);
    });

    test('reports what Google said when the user declines', () async {
      final drive = DriveClient(
        client: client,
        endpoints: google.endpoints,
        launcher: browser(error: 'access_denied'),
      );

      await expectLater(
        drive.connect(const DriveAuth(clientId: 'a', clientSecret: 'b')),
        throwsA(isA<DriveException>().having(
          (e) => e.message,
          'message',
          contains('access_denied'),
        )),
      );
    });

    test('will not start without a client id and secret', () async {
      final drive = DriveClient(client: client, endpoints: google.endpoints);
      await expectLater(
        drive.connect(const DriveAuth()),
        throwsA(isA<DriveException>()),
      );
    });
  });
  group('the folder', () {
    test('is found when it is already there', () async {
      google.existingFolder = 'already-there';
      final drive = DriveClient(client: client, endpoints: google.endpoints);

      final ready = await drive.ensureFolder(
        const DriveAuth(clientId: 'a', clientSecret: 'b', refreshToken: 'r'),
      );

      expect(ready.folderId, 'already-there');
    });

    test('is created when it is not, and only looked up once', () async {
      final drive = DriveClient(client: client, endpoints: google.endpoints);

      final ready = await drive.ensureFolder(
        const DriveAuth(clientId: 'a', clientSecret: 'b', refreshToken: 'r'),
      );
      expect(ready.folderId, 'made-folder');

      // An auth that already knows its folder does not ask again.
      final same = await drive.ensureFolder(ready);
      expect(same.folderId, 'made-folder');
      expect(google.tokenCalls.length, 1);
    });
  });

  group('the four calls', () {
    test('an upload streams the metadata and the archive in one request',
        () async {
      final drive = DriveClient(client: client, endpoints: google.endpoints);
      final bytes = Uint8List.fromList(const [80, 75, 3, 4, 9, 9, 9]);
      final directory = Directory.systemTemp.createTempSync('drive-upload');
      addTearDown(() => directory.deleteSync(recursive: true));
      final archive = File('${directory.path}/maichat-backup.zip')
        ..writeAsBytesSync(bytes);

      final file = await drive.uploadFile(
        auth: auth,
        name: 'maichat-backup.zip',
        file: archive,
      );

      expect(file.id, 'file-1');
      expect(google.uploadContentType, contains('multipart/related'));
      final body = google.uploaded!;
      final text = latin1.decode(body);
      expect(text, contains('"name":"maichat-backup.zip"'));
      expect(text, contains('"parents":["folder-1"]'));
      expect(text, contains('application/zip'));
      // The archive itself is in there, byte for byte.
      expect(body.join(','), contains(bytes.join(',')));
    });

    test('a listing comes back newest first, with sizes and dates', () async {
      google.files = <Map<String, Object?>>[
        {
          'id': 'b',
          'name': 'newer.zip',
          'size': '2048',
          'createdTime': '2026-08-30T12:00:00.000Z',
        },
        {'id': 'a', 'name': 'older.zip'},
      ];
      final drive = DriveClient(client: client, endpoints: google.endpoints);

      final files = await drive.list(auth);

      expect(files.map((f) => f.name), ['newer.zip', 'older.zip']);
      expect(files.first.bytes, 2048);
      expect(files.first.createdAt, DateTime.utc(2026, 8, 30, 12));
    });

    test('a download is streamed into a file', () async {
      google.download = const [1, 2, 3, 4];
      final drive = DriveClient(client: client, endpoints: google.endpoints);
      final directory = Directory.systemTemp.createTempSync('drive-download');
      addTearDown(() => directory.deleteSync(recursive: true));
      final target = File('${directory.path}/deep/backup.zip');

      await drive.downloadToFile(auth, 'file-1', target);

      // The directory is made on the way, and the bytes arrive whole.
      expect(target.readAsBytesSync(), [1, 2, 3, 4]);
      // The in-memory read is still there for a caller with nowhere to write.
      expect(await drive.download(auth, 'file-1'), [1, 2, 3, 4]);
    });

    test('a delete asks for the right file', () async {
      final drive = DriveClient(client: client, endpoints: google.endpoints);

      await drive.delete(auth, 'file-1');

      expect(google.deleted, ['file-1']);
    });
  });
  group('the access token', () {
    test('is fetched once and reused while it lasts', () async {
      final drive = DriveClient(client: client, endpoints: google.endpoints);

      await drive.list(auth);
      await drive.list(auth);

      expect(google.tokenCalls.length, 1);
      expect(google.tokenCalls.single['grant_type'], 'refresh_token');
      expect(google.tokenCalls.single['refresh_token'], 'refresh-1');
    });

    test('is not asked for at all without a grant', () async {
      final drive = DriveClient(client: client, endpoints: google.endpoints);
      await expectLater(
        drive.list(const DriveAuth(clientId: 'a', clientSecret: 'b',
            folderId: 'f')),
        throwsA(isA<DriveException>().having(
          (e) => e.message,
          'message',
          contains('not connected'),
        )),
      );
    });

    test('a refusal from Drive says what it was and what Google said', () async {
      google.failWith = 403;
      final drive = DriveClient(client: client, endpoints: google.endpoints);

      await expectLater(
        drive.list(auth),
        throwsA(isA<DriveException>().having(
          (e) => e.message,
          'message',
          allOf(contains('403'), contains('nope')),
        )),
      );
    });
  });
}
