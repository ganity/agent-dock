import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_dock_mobile/src/shared/api/daemon_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DaemonClient', () {
    test('checks daemon health from /api/health', () async {
      final transport = RecordingTransport(
        responses: [
          TransportResponse(statusCode: 200, body: jsonEncode({'ok': true})),
        ],
      );
      final client = DaemonClient(
        baseUrl: Uri.parse('https://daemon.example.com'),
        transport: transport,
      );

      await client.healthCheck();

      expect(transport.requests, hasLength(1));
      expect(transport.requests.single.method, 'GET');
      expect(transport.requests.single.url.path, '/api/health');
    });

    test(
      'posts username and password to login and parses the current user',
      () async {
        final transport = RecordingTransport(
          responses: [
            TransportResponse(
              statusCode: 200,
              body: jsonEncode({
                'ok': true,
                'token': 'tok_workspace',
                'user': {'id': 'usr_workspace', 'displayName': 'Workspace'},
              }),
            ),
          ],
        );
        final client = DaemonClient(
          baseUrl: Uri.parse('https://daemon.example.com'),
          transport: transport,
        );

        final result = await client.login(
          username: 'workspace',
          password: '1234',
        );

        expect(result.token, 'tok_workspace');
        expect(result.user.id, 'usr_workspace');
        expect(result.user.displayName, 'Workspace');
        expect(transport.requests, hasLength(1));
        expect(transport.requests.single.method, 'POST');
        expect(transport.requests.single.url.path, '/api/auth/login');
        expect(jsonDecode(transport.requests.single.body!), {
          'username': 'workspace',
          'password': '1234',
        });
      },
    );

    test(
      'loads mobile bootstrap with bearer auth and parses sessions',
      () async {
        final transport = RecordingTransport(
          responses: [
            TransportResponse(
              statusCode: 200,
              body: jsonEncode({
                'daemonVersion': '0.1.0',
                'user': {'id': 'usr_workspace', 'displayName': 'Workspace'},
                'roots': [
                  {
                    'id': 'workspace',
                    'label': 'Workspace',
                    'path': '/home/jhz/projects',
                  },
                ],
                'sessions': [
                  {
                    'id': 'sess_1',
                    'title': 'Mobile migration',
                    'agentKind': 'codex',
                    'sourceKind': 'managed',
                    'runtimeSessionId': 'runtime_1',
                    'status': 'running',
                    'workspacePath': '/home/jhz/projects/agent-dock',
                  },
                ],
                'voice': {'doubaoDirectAvailable': false},
              }),
            ),
          ],
        );
        final client = DaemonClient(
          baseUrl: Uri.parse('https://daemon.example.com/'),
          transport: transport,
        );

        final bootstrap = await client.bootstrap(token: 'tok_workspace');

        expect(bootstrap.daemonVersion, '0.1.0');
        expect(bootstrap.user.displayName, 'Workspace');
        expect(bootstrap.roots.single.label, 'Workspace');
        expect(bootstrap.sessions.single.title, 'Mobile migration');
        expect(bootstrap.sessions.single.status, 'running');
        expect(bootstrap.voice.doubaoDirectAvailable, isFalse);
        expect(transport.requests.single.method, 'GET');
        expect(transport.requests.single.url.path, '/api/mobile/bootstrap');
        expect(
          transport.requests.single.headers['authorization'],
          'Bearer tok_workspace',
        );
      },
    );

    test(
      'loads mobile bootstrap provider voice credentials when available',
      () async {
        final transport = RecordingTransport(
          responses: [
            TransportResponse(
              statusCode: 200,
              body: jsonEncode({
                'daemonVersion': '0.1.0',
                'user': {'id': 'usr_workspace', 'displayName': 'Workspace'},
                'roots': <Object?>[],
                'sessions': <Object?>[],
                'voice': {
                  'doubaoDirectAvailable': true,
                  'providerCredentials': {
                    'appId': 'app-123',
                    'accessToken': 'token-abc',
                    'resourceId': 'volc.bigasr.sauc.duration',
                    'websocketUrl':
                        'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel',
                  },
                },
              }),
            ),
          ],
        );
        final client = DaemonClient(
          baseUrl: Uri.parse('https://daemon.example.com/'),
          transport: transport,
        );

        final bootstrap = await client.bootstrap(token: 'tok_workspace');

        expect(bootstrap.voice.doubaoDirectAvailable, isTrue);
        expect(bootstrap.voice.providerCredentials, isNotNull);
        expect(bootstrap.voice.providerCredentials!.appId, 'app-123');
        expect(bootstrap.voice.providerCredentials!.accessToken, 'token-abc');
        expect(
          bootstrap.voice.providerCredentials!.resourceId,
          'volc.bigasr.sauc.duration',
        );
        expect(
          bootstrap.voice.providerCredentials!.websocketUrl,
          'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel',
        );
      },
    );

    test(
      'loads a session snapshot with bearer auth and parses events',
      () async {
        final transport = RecordingTransport(
          responses: [
            TransportResponse(
              statusCode: 200,
              body: jsonEncode({
                'id': 'sess_1',
                'title': 'Mobile migration',
                'agentKind': 'codex',
                'sourceKind': 'managed',
                'runtimeSessionId': 'runtime_1',
                'workspacePath': '/home/jhz/projects/agent-dock',
                'status': 'running',
                'hasMoreHistory': true,
                'events': [
                  {
                    'id': 10,
                    'eventType': 'user.message',
                    'payload': {'text': 'please migrate mobile'},
                  },
                  {
                    'id': 11,
                    'eventType': 'assistant.message',
                    'payload': {'text': 'migrated'},
                  },
                ],
              }),
            ),
          ],
        );
        final client = DaemonClient(
          baseUrl: Uri.parse('https://daemon.example.com'),
          transport: transport,
        );

        final snapshot = await client.sessionSnapshot(
          sessionId: 'sess_1',
          token: 'tok_workspace',
        );

        expect(snapshot.id, 'sess_1');
        expect(snapshot.title, 'Mobile migration');
        expect(snapshot.hasMoreHistory, isTrue);
        expect(snapshot.events, hasLength(2));
        expect(snapshot.events.first.eventType, 'user.message');
        expect(snapshot.events.first.payload['text'], 'please migrate mobile');
        expect(transport.requests.single.method, 'GET');
        expect(transport.requests.single.url.path, '/api/sessions/sess_1');
        expect(transport.requests.single.url.queryParameters['limit'], '50');
        expect(
          transport.requests.single.headers['authorization'],
          'Bearer tok_workspace',
        );
      },
    );

    test('loads older session history before an event id', () async {
      final transport = RecordingTransport(
        responses: [
          TransportResponse(
            statusCode: 200,
            body: jsonEncode({
              'id': 'sess_1',
              'title': 'Mobile migration',
              'agentKind': 'codex',
              'sourceKind': 'managed',
              'runtimeSessionId': 'runtime_1',
              'workspacePath': '/home/jhz/projects/agent-dock',
              'status': 'running',
              'hasMoreHistory': false,
              'events': [
                {
                  'id': 7,
                  'eventType': 'assistant.message',
                  'payload': {'text': 'older reply'},
                },
              ],
            }),
          ),
        ],
      );
      final client = DaemonClient(
        baseUrl: Uri.parse('https://daemon.example.com'),
        transport: transport,
      );

      final snapshot = await client.sessionSnapshot(
        sessionId: 'sess_1',
        token: 'tok_workspace',
        beforeEventId: 10,
      );

      expect(snapshot.events.single.id, 7);
      expect(snapshot.events.single.payload['text'], 'older reply');
      expect(transport.requests.single.method, 'GET');
      expect(transport.requests.single.url.path, '/api/sessions/sess_1');
      expect(transport.requests.single.url.queryParameters, {
        'limit': '50',
        'before': '10',
      });
      expect(
        transport.requests.single.headers['authorization'],
        'Bearer tok_workspace',
      );
    });

    test(
      'resumes a session with bearer auth and parses the recovered snapshot',
      () async {
        final transport = RecordingTransport(
          responses: [
            TransportResponse(
              statusCode: 200,
              body: jsonEncode({
                'id': 'sess_1',
                'title': 'Mobile migration',
                'agentKind': 'codex',
                'sourceKind': 'managed',
                'runtimeSessionId': 'runtime_1',
                'workspacePath': '/home/jhz/projects/agent-dock',
                'status': 'running',
                'hasMoreHistory': false,
                'events': [
                  {
                    'id': 12,
                    'eventType': 'session.status.changed',
                    'payload': {'status': 'running'},
                  },
                ],
              }),
            ),
          ],
        );
        final client = DaemonClient(
          baseUrl: Uri.parse('https://daemon.example.com'),
          transport: transport,
        );

        final snapshot = await client.resumeSession(
          sessionId: 'sess_1',
          token: 'tok_workspace',
        );

        expect(snapshot.status, 'running');
        expect(snapshot.events.single.eventType, 'session.status.changed');
        expect(transport.requests.single.method, 'POST');
        expect(
          transport.requests.single.url.path,
          '/api/sessions/sess_1/resume',
        );
        expect(
          transport.requests.single.headers['authorization'],
          'Bearer tok_workspace',
        );
      },
    );

    test('loads workspace directories with bearer auth', () async {
      final transport = RecordingTransport(
        responses: [
          TransportResponse(
            statusCode: 200,
            body: jsonEncode({
              'currentPath': '/home/jhz/projects',
              'parentPath': '/home/jhz',
              'directories': [
                {'name': 'agent-dock', 'path': '/home/jhz/projects/agent-dock'},
              ],
            }),
          ),
        ],
      );
      final client = DaemonClient(
        baseUrl: Uri.parse('https://daemon.example.com'),
        transport: transport,
      );

      final listing = await client.workspaceDirectories(
        token: 'tok_workspace',
        path: '/home/jhz/projects',
      );

      expect(listing.currentPath, '/home/jhz/projects');
      expect(listing.parentPath, '/home/jhz');
      expect(listing.directories.single.name, 'agent-dock');
      expect(listing.directories.single.path, '/home/jhz/projects/agent-dock');
      expect(transport.requests.single.method, 'GET');
      expect(transport.requests.single.url.path, '/api/workspaces/directories');
      expect(transport.requests.single.url.queryParameters, {
        'path': '/home/jhz/projects',
      });
      expect(
        transport.requests.single.headers['authorization'],
        'Bearer tok_workspace',
      );
    });

    test('loads resume candidates with bearer auth', () async {
      final transport = RecordingTransport(
        responses: [
          TransportResponse(
            statusCode: 200,
            body: jsonEncode({
              'candidates': [
                {
                  'runtimeSessionId': 'thread-abc',
                  'title': 'Resume target',
                  'agentKind': 'codex',
                  'workspacePath': '/home/jhz/projects/agent-dock',
                  'updatedAt': '2026-06-17T01:02:03Z',
                  'status': 'idle',
                },
              ],
            }),
          ),
        ],
      );
      final client = DaemonClient(
        baseUrl: Uri.parse('https://daemon.example.com'),
        transport: transport,
      );

      final candidates = await client.listResumeCandidates(
        token: 'tok_workspace',
        rootId: 'workspace',
        agentKind: 'codex',
        path: '/home/jhz/projects/agent-dock',
      );

      expect(candidates, hasLength(1));
      expect(candidates.single.runtimeSessionId, 'thread-abc');
      expect(candidates.single.title, 'Resume target');
      expect(candidates.single.agentKind, 'codex');
      expect(candidates.single.workspacePath, '/home/jhz/projects/agent-dock');
      expect(candidates.single.updatedAt, '2026-06-17T01:02:03Z');
      expect(candidates.single.status, 'idle');
      expect(transport.requests.single.method, 'GET');
      expect(
        transport.requests.single.url.path,
        '/api/sessions/resume-candidates',
      );
      expect(transport.requests.single.url.queryParameters, {
        'rootId': 'workspace',
        'agentKind': 'codex',
        'path': '/home/jhz/projects/agent-dock',
      });
      expect(
        transport.requests.single.headers['authorization'],
        'Bearer tok_workspace',
      );
    });

    test('sends a session message with bearer auth', () async {
      final transport = RecordingTransport(
        responses: [
          TransportResponse(statusCode: 200, body: jsonEncode({'ok': true})),
        ],
      );
      final client = DaemonClient(
        baseUrl: Uri.parse('https://daemon.example.com'),
        transport: transport,
      );

      await client.sendMessage(
        sessionId: 'sess_1',
        token: 'tok_workspace',
        message: 'continue the Flutter work',
      );

      expect(transport.requests.single.method, 'POST');
      expect(
        transport.requests.single.url.path,
        '/api/sessions/sess_1/messages',
      );
      expect(
        transport.requests.single.headers['authorization'],
        'Bearer tok_workspace',
      );
      expect(
        transport.requests.single.headers['content-type'],
        'application/json',
      );
      expect(jsonDecode(transport.requests.single.body!), {
        'message': 'continue the Flutter work',
        'imagePaths': <String>[],
      });
    });

    test(
      'uploads an image attachment with bearer auth and raw bytes',
      () async {
        final transport = RecordingTransport(
          responses: [
            TransportResponse(
              statusCode: 200,
              body: jsonEncode({
                'path': '/tmp/attachments/sess_1/screenshot.png',
              }),
            ),
          ],
        );
        final client = DaemonClient(
          baseUrl: Uri.parse('https://daemon.example.com'),
          transport: transport,
        );
        final bytes = Uint8List.fromList(<int>[137, 80, 78, 71]);

        final uploadedPath = await client.uploadAttachment(
          sessionId: 'sess_1',
          token: 'tok_workspace',
          filename: 'screenshot.png',
          contentType: 'image/png',
          bytes: bytes,
        );

        expect(uploadedPath, '/tmp/attachments/sess_1/screenshot.png');
        expect(transport.requests.single.method, 'POST');
        expect(
          transport.requests.single.url.path,
          '/api/sessions/sess_1/attachments',
        );
        expect(
          transport.requests.single.url.queryParameters['filename'],
          'screenshot.png',
        );
        expect(
          transport.requests.single.headers['authorization'],
          'Bearer tok_workspace',
        );
        expect(transport.requests.single.headers['content-type'], 'image/png');
        expect(transport.requests.single.bodyBytes, bytes);
      },
    );

    test('creates a managed session with bearer auth', () async {
      final transport = RecordingTransport(
        responses: [
          TransportResponse(
            statusCode: 200,
            body: jsonEncode({
              'id': 'sess_new',
              'title': 'Fresh mobile session',
              'agentKind': 'codex',
              'sourceKind': 'managed',
              'runtimeSessionId': null,
              'workspacePath': 'agent-dock',
              'status': 'created',
              'hasMoreHistory': false,
              'events': <Object?>[],
            }),
          ),
        ],
      );
      final client = DaemonClient(
        baseUrl: Uri.parse('https://daemon.example.com'),
        transport: transport,
      );

      final snapshot = await client.createSession(
        token: 'tok_workspace',
        rootId: 'workspace',
        path: 'agent-dock',
        agentKind: 'codex',
        title: 'Fresh mobile session',
      );

      expect(snapshot.id, 'sess_new');
      expect(snapshot.title, 'Fresh mobile session');
      expect(transport.requests.single.method, 'POST');
      expect(transport.requests.single.url.path, '/api/sessions');
      expect(
        transport.requests.single.headers['authorization'],
        'Bearer tok_workspace',
      );
      expect(jsonDecode(transport.requests.single.body!), {
        'rootId': 'workspace',
        'path': 'agent-dock',
        'agentKind': 'codex',
        'title': 'Fresh mobile session',
      });
    });

    test('attaches an existing runtime session with bearer auth', () async {
      final transport = RecordingTransport(
        responses: [
          TransportResponse(
            statusCode: 200,
            body: jsonEncode({
              'id': 'sess_attached',
              'title': null,
              'agentKind': 'claude',
              'sourceKind': 'attached',
              'runtimeSessionId': 'thread-abc',
              'workspacePath': 'agent-dock',
              'status': 'attached',
              'hasMoreHistory': false,
              'events': [
                {
                  'id': 1,
                  'eventType': 'session.attached',
                  'payload': {'runtimeSessionId': 'thread-abc'},
                },
              ],
            }),
          ),
        ],
      );
      final client = DaemonClient(
        baseUrl: Uri.parse('https://daemon.example.com'),
        transport: transport,
      );

      final snapshot = await client.attachSession(
        token: 'tok_workspace',
        rootId: 'workspace',
        path: 'agent-dock',
        agentKind: 'claude',
        runtimeSessionId: 'thread-abc',
      );

      expect(snapshot.id, 'sess_attached');
      expect(snapshot.sourceKind, 'attached');
      expect(snapshot.runtimeSessionId, 'thread-abc');
      expect(transport.requests.single.method, 'POST');
      expect(transport.requests.single.url.path, '/api/sessions/attach');
      expect(
        transport.requests.single.headers['authorization'],
        'Bearer tok_workspace',
      );
      expect(jsonDecode(transport.requests.single.body!), {
        'rootId': 'workspace',
        'path': 'agent-dock',
        'agentKind': 'claude',
        'runtimeSessionId': 'thread-abc',
      });
    });

    test('deletes a session with bearer auth', () async {
      final transport = RecordingTransport(
        responses: [const TransportResponse(statusCode: 204, body: '')],
      );
      final client = DaemonClient(
        baseUrl: Uri.parse('https://daemon.example.com'),
        transport: transport,
      );

      await client.deleteSession(sessionId: 'sess_1', token: 'tok_workspace');

      expect(transport.requests.single.method, 'DELETE');
      expect(transport.requests.single.url.path, '/api/sessions/sess_1');
      expect(
        transport.requests.single.headers['authorization'],
        'Bearer tok_workspace',
      );
    });

    test('streams session events from the websocket endpoint', () async {
      final streamTransport = RecordingEventStreamTransport(
        events: Stream<String>.fromIterable([
          jsonEncode({
            'id': 12,
            'eventType': 'assistant.message',
            'payload': {'text': 'live update'},
          }),
        ]),
      );
      final client = DaemonClient(
        baseUrl: Uri.parse('https://daemon.example.com'),
        eventStreamTransport: streamTransport,
      );

      final events = await client
          .sessionEvents(
            sessionId: 'sess_1',
            token: 'tok_workspace',
            afterEventId: 11,
          )
          .toList();

      expect(events.single.id, 12);
      expect(events.single.eventType, 'assistant.message');
      expect(events.single.payload['text'], 'live update');
      expect(streamTransport.requests.single.url.scheme, 'wss');
      expect(
        streamTransport.requests.single.url.path,
        '/ws/sessions/sess_1/events',
      );
      expect(
        streamTransport.requests.single.url.queryParameters['after'],
        '11',
      );
      expect(
        streamTransport.requests.single.url.queryParameters['token'],
        'tok_workspace',
      );
      expect(
        streamTransport.requests.single.headers['authorization'],
        'Bearer tok_workspace',
      );
    });

    test('throws an API exception with the server error message', () async {
      final transport = RecordingTransport(
        responses: [
          TransportResponse(
            statusCode: 401,
            body: jsonEncode({
              'error': 'INVALID_CREDENTIALS',
              'message': 'Invalid username or password',
            }),
          ),
        ],
      );
      final client = DaemonClient(
        baseUrl: Uri.parse('https://daemon.example.com'),
        transport: transport,
      );

      await expectLater(
        client.login(username: 'workspace', password: 'wrong'),
        throwsA(
          isA<DaemonApiException>()
              .having((error) => error.statusCode, 'statusCode', 401)
              .having((error) => error.code, 'code', 'INVALID_CREDENTIALS')
              .having(
                (error) => error.message,
                'message',
                'Invalid username or password',
              ),
        ),
      );
    });
  });

  test(
    'IoDaemonHttpTransport sends JSON request bodies with UTF-8 encoding',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      final requestBody = Completer<List<int>>();
      final contentType = Completer<String?>();
      unawaited(() async {
        final request = await server.first;
        contentType.complete(request.headers.contentType?.toString());
        final bytes = await request.fold<List<int>>(
          <int>[],
          (buffer, chunk) => buffer..addAll(chunk),
        );
        requestBody.complete(bytes);
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'ok': true}));
        await request.response.close();
      }());

      final transport = IoDaemonHttpTransport();
      await transport.send(
        TransportRequest(
          method: 'POST',
          url: Uri.parse('http://127.0.0.1:${server.port}/messages'),
          headers: const {'content-type': 'application/json'},
          body: jsonEncode({'message': '项目里面有什么', 'imagePaths': <String>[]}),
        ),
      );

      expect(
        utf8.decode(await requestBody.future),
        jsonEncode({'message': '项目里面有什么', 'imagePaths': <String>[]}),
      );
      expect(await contentType.future, 'application/json');
    },
  );
}

class RecordingTransport implements DaemonHttpTransport {
  RecordingTransport({required List<TransportResponse> responses})
    : _responses = List<TransportResponse>.from(responses);

  final List<TransportResponse> _responses;
  final List<TransportRequest> requests = <TransportRequest>[];

  @override
  Future<TransportResponse> send(TransportRequest request) async {
    requests.add(request);
    return _responses.removeAt(0);
  }
}

class RecordingEventStreamTransport implements DaemonEventStreamTransport {
  RecordingEventStreamTransport({required this.events});

  final Stream<String> events;
  final List<EventStreamRequest> requests = <EventStreamRequest>[];

  @override
  Stream<String> connect(EventStreamRequest request) {
    requests.add(request);
    return events;
  }
}
