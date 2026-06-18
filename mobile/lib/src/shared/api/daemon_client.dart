import 'dart:convert';
import 'dart:io';

import '../storage/voice_credentials_storage.dart';

abstract class DaemonApi {
  Future<void> healthCheck();

  Future<LoginResult> login({
    required String username,
    required String password,
  });

  Future<MobileBootstrap> bootstrap({required String token});

  Future<SessionSnapshot> sessionSnapshot({
    required String sessionId,
    required String token,
    int? beforeEventId,
  });

  Future<SessionSnapshot> resumeSession({
    required String sessionId,
    required String token,
  });

  Stream<SessionEvent> sessionEvents({
    required String sessionId,
    required String token,
    required int afterEventId,
  });

  Future<SendMessageAck> sendMessage({
    required String sessionId,
    required String token,
    required String clientMessageId,
    required String message,
    List<String> imagePaths = const <String>[],
  });

  Future<String> uploadAttachment({
    required String sessionId,
    required String token,
    required String filename,
    required String contentType,
    required List<int> bytes,
  });

  Future<SessionSnapshot> createSession({
    required String token,
    required String rootId,
    required String path,
    required String agentKind,
    required String title,
  });

  Future<SessionSnapshot> attachSession({
    required String token,
    required String rootId,
    required String path,
    required String agentKind,
    required String runtimeSessionId,
  });

  Future<void> deleteSession({
    required String sessionId,
    required String token,
  });

  Future<WorkspaceDirectoryListing> workspaceDirectories({
    required String token,
    required String path,
  });

  Future<List<ResumeCandidate>> listResumeCandidates({
    required String token,
    required String rootId,
    required String agentKind,
    required String path,
  });
}

abstract class DaemonHttpTransport {
  Future<TransportResponse> send(TransportRequest request);
}

abstract class DaemonEventStreamTransport {
  Stream<String> connect(EventStreamRequest request);
}

class TransportRequest {
  const TransportRequest({
    required this.method,
    required this.url,
    required this.headers,
    this.body,
    this.bodyBytes,
  });

  final String method;
  final Uri url;
  final Map<String, String> headers;
  final String? body;
  final List<int>? bodyBytes;
}

class EventStreamRequest {
  const EventStreamRequest({required this.url, required this.headers});

  final Uri url;
  final Map<String, String> headers;
}

class TransportResponse {
  const TransportResponse({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
}

class DaemonApiException implements Exception {
  const DaemonApiException({
    required this.statusCode,
    required this.code,
    required this.message,
  });

  final int statusCode;
  final String code;
  final String message;

  @override
  String toString() => 'DaemonApiException($statusCode, $code, $message)';
}

class DaemonClient implements DaemonApi {
  DaemonClient({
    required this.baseUrl,
    DaemonHttpTransport? transport,
    DaemonEventStreamTransport? eventStreamTransport,
  }) : _transport = transport ?? IoDaemonHttpTransport(),
       _eventStreamTransport =
           eventStreamTransport ?? IoDaemonEventStreamTransport();

  final Uri baseUrl;
  final DaemonHttpTransport _transport;
  final DaemonEventStreamTransport _eventStreamTransport;

  @override
  Future<void> healthCheck() async {
    final json = await _sendJson(
      TransportRequest(
        method: 'GET',
        url: _url('/api/health'),
        headers: const {},
      ),
    );
    if (json['ok'] != true) {
      throw const FormatException('Daemon responded but is not healthy');
    }
  }

  @override
  Future<LoginResult> login({
    required String username,
    required String password,
  }) async {
    final json = await _sendJson(
      TransportRequest(
        method: 'POST',
        url: _url('/api/auth/login'),
        headers: const {'content-type': 'application/json'},
        body: jsonEncode({'username': username, 'password': password}),
      ),
    );

    return LoginResult.fromJson(json);
  }

  @override
  Future<MobileBootstrap> bootstrap({required String token}) async {
    final json = await _sendJson(
      TransportRequest(
        method: 'GET',
        url: _url('/api/mobile/bootstrap'),
        headers: {'authorization': 'Bearer $token'},
      ),
    );

    return MobileBootstrap.fromJson(json);
  }

  @override
  Future<SessionSnapshot> sessionSnapshot({
    required String sessionId,
    required String token,
    int? beforeEventId,
  }) async {
    final queryParameters = <String, String>{'limit': '50'};
    if (beforeEventId != null) {
      queryParameters['before'] = '$beforeEventId';
    }
    final json = await _sendJson(
      TransportRequest(
        method: 'GET',
        url: _url(
          '/api/sessions/$sessionId',
        ).replace(queryParameters: queryParameters),
        headers: {'authorization': 'Bearer $token'},
      ),
    );

    return SessionSnapshot.fromJson(json);
  }

  @override
  Future<SessionSnapshot> resumeSession({
    required String sessionId,
    required String token,
  }) async {
    final json = await _sendJson(
      TransportRequest(
        method: 'POST',
        url: _url('/api/sessions/$sessionId/resume'),
        headers: {'authorization': 'Bearer $token'},
      ),
    );

    return SessionSnapshot.fromJson(json);
  }

  @override
  Stream<SessionEvent> sessionEvents({
    required String sessionId,
    required String token,
    required int afterEventId,
  }) {
    return _eventStreamTransport
        .connect(
          EventStreamRequest(
            url: _webSocketUrl('/ws/sessions/$sessionId/events').replace(
              queryParameters: {'after': '$afterEventId', 'token': token},
            ),
            headers: {'authorization': 'Bearer $token'},
          ),
        )
        .map((message) => SessionEvent.fromJson(_decodeObject(message)));
  }

  @override
  Future<SendMessageAck> sendMessage({
    required String sessionId,
    required String token,
    required String clientMessageId,
    required String message,
    List<String> imagePaths = const <String>[],
  }) async {
    final json = await _sendJson(
      TransportRequest(
        method: 'POST',
        url: _url('/api/sessions/$sessionId/messages'),
        headers: {
          'authorization': 'Bearer $token',
          'content-type': 'application/json',
        },
        body: jsonEncode({
          'clientMessageId': clientMessageId,
          'message': message,
          'imagePaths': imagePaths,
        }),
      ),
    );

    return SendMessageAck.fromJson(json);
  }

  @override
  Future<String> uploadAttachment({
    required String sessionId,
    required String token,
    required String filename,
    required String contentType,
    required List<int> bytes,
  }) async {
    final json = await _sendJson(
      TransportRequest(
        method: 'POST',
        url: _url(
          '/api/sessions/$sessionId/attachments',
        ).replace(queryParameters: {'filename': filename}),
        headers: {
          'authorization': 'Bearer $token',
          'content-type': contentType,
        },
        bodyBytes: bytes,
      ),
    );

    return json['path'] as String;
  }

  @override
  Future<SessionSnapshot> createSession({
    required String token,
    required String rootId,
    required String path,
    required String agentKind,
    required String title,
  }) async {
    final json = await _sendJson(
      TransportRequest(
        method: 'POST',
        url: _url('/api/sessions'),
        headers: {
          'authorization': 'Bearer $token',
          'content-type': 'application/json',
        },
        body: jsonEncode({
          'rootId': rootId,
          'path': path,
          'agentKind': agentKind,
          'title': title,
        }),
      ),
    );

    return SessionSnapshot.fromJson(json);
  }

  @override
  Future<SessionSnapshot> attachSession({
    required String token,
    required String rootId,
    required String path,
    required String agentKind,
    required String runtimeSessionId,
  }) async {
    final json = await _sendJson(
      TransportRequest(
        method: 'POST',
        url: _url('/api/sessions/attach'),
        headers: {
          'authorization': 'Bearer $token',
          'content-type': 'application/json',
        },
        body: jsonEncode({
          'rootId': rootId,
          'path': path,
          'agentKind': agentKind,
          'runtimeSessionId': runtimeSessionId,
        }),
      ),
    );

    return SessionSnapshot.fromJson(json);
  }

  @override
  Future<void> deleteSession({
    required String sessionId,
    required String token,
  }) async {
    await _sendEmpty(
      TransportRequest(
        method: 'DELETE',
        url: _url('/api/sessions/$sessionId'),
        headers: {'authorization': 'Bearer $token'},
      ),
    );
  }

  @override
  Future<WorkspaceDirectoryListing> workspaceDirectories({
    required String token,
    required String path,
  }) async {
    final json = await _sendJson(
      TransportRequest(
        method: 'GET',
        url: _url(
          '/api/workspaces/directories',
        ).replace(queryParameters: {'path': path}),
        headers: {'authorization': 'Bearer $token'},
      ),
    );

    return WorkspaceDirectoryListing.fromJson(json);
  }

  @override
  Future<List<ResumeCandidate>> listResumeCandidates({
    required String token,
    required String rootId,
    required String agentKind,
    required String path,
  }) async {
    final json = await _sendJson(
      TransportRequest(
        method: 'GET',
        url: _url('/api/sessions/resume-candidates').replace(
          queryParameters: {
            'rootId': rootId,
            'agentKind': agentKind,
            'path': path,
          },
        ),
        headers: {'authorization': 'Bearer $token'},
      ),
    );

    return _objects(json['candidates']).map(ResumeCandidate.fromJson).toList();
  }

  Uri _url(String path) {
    return baseUrl.replace(path: path, query: null, queryParameters: null);
  }

  Uri _webSocketUrl(String path) {
    final scheme = switch (baseUrl.scheme) {
      'https' => 'wss',
      'http' => 'ws',
      _ => baseUrl.scheme,
    };
    return baseUrl.replace(
      scheme: scheme,
      path: path,
      query: null,
      queryParameters: null,
    );
  }

  Future<void> _sendEmpty(TransportRequest request) async {
    final response = await _transport.send(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final json = response.body.isEmpty
          ? <String, Object?>{}
          : _decodeObject(response.body);
      final code = json['error'] as String? ?? 'HTTP_${response.statusCode}';
      final message = json['message'] as String? ?? code;
      throw DaemonApiException(
        statusCode: response.statusCode,
        code: code,
        message: message,
      );
    }
  }

  Future<Map<String, Object?>> _sendJson(TransportRequest request) async {
    final response = await _transport.send(request);
    final json = _decodeObject(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final code = json['error'] as String? ?? 'HTTP_${response.statusCode}';
      final message = json['message'] as String? ?? code;
      throw DaemonApiException(
        statusCode: response.statusCode,
        code: code,
        message: message,
      );
    }
    return json;
  }
}

class IoDaemonHttpTransport implements DaemonHttpTransport {
  IoDaemonHttpTransport({HttpClient? client})
    : _client = client ?? HttpClient();

  final HttpClient _client;

  @override
  Future<TransportResponse> send(TransportRequest request) async {
    final httpRequest = await _client.openUrl(request.method, request.url);
    request.headers.forEach(httpRequest.headers.set);
    final body = request.body;
    if (body != null) {
      httpRequest.add(utf8.encode(body));
    }
    final bodyBytes = request.bodyBytes;
    if (bodyBytes != null) {
      httpRequest.add(bodyBytes);
    }

    final response = await httpRequest.close();
    final responseBody = await response.transform(utf8.decoder).join();
    return TransportResponse(
      statusCode: response.statusCode,
      body: responseBody,
    );
  }
}

class IoDaemonEventStreamTransport implements DaemonEventStreamTransport {
  @override
  Stream<String> connect(EventStreamRequest request) async* {
    final socket = await WebSocket.connect(
      request.url.toString(),
      headers: request.headers,
    );
    try {
      await for (final message in socket) {
        if (message is String) {
          yield message;
        }
      }
    } finally {
      await socket.close();
    }
  }
}

class LoginResult {
  const LoginResult({required this.token, required this.user});

  factory LoginResult.fromJson(Map<String, Object?> json) {
    return LoginResult(
      token: json['token'] as String,
      user: CurrentUser.fromJson(_object(json['user'])),
    );
  }

  final String token;
  final CurrentUser user;
}

class CurrentUser {
  const CurrentUser({required this.id, required this.displayName});

  factory CurrentUser.fromJson(Map<String, Object?> json) {
    return CurrentUser(
      id: json['id'] as String,
      displayName: json['displayName'] as String,
    );
  }

  final String id;
  final String displayName;
}

class MobileBootstrap {
  const MobileBootstrap({
    required this.daemonVersion,
    required this.user,
    required this.roots,
    required this.sessions,
    required this.voice,
  });

  factory MobileBootstrap.fromJson(Map<String, Object?> json) {
    return MobileBootstrap(
      daemonVersion: json['daemonVersion'] as String,
      user: CurrentUser.fromJson(_object(json['user'])),
      roots: _objects(json['roots']).map(WorkspaceRoot.fromJson).toList(),
      sessions: _objects(
        json['sessions'],
      ).map(SessionSummary.fromJson).toList(),
      voice: VoiceConfig.fromJson(_object(json['voice'])),
    );
  }

  final String daemonVersion;
  final CurrentUser user;
  final List<WorkspaceRoot> roots;
  final List<SessionSummary> sessions;
  final VoiceConfig voice;
}

class WorkspaceRoot {
  const WorkspaceRoot({
    required this.id,
    required this.label,
    required this.path,
  });

  factory WorkspaceRoot.fromJson(Map<String, Object?> json) {
    return WorkspaceRoot(
      id: json['id'] as String,
      label: json['label'] as String,
      path: json['path'] as String,
    );
  }

  final String id;
  final String label;
  final String path;
}

class WorkspaceDirectoryEntry {
  const WorkspaceDirectoryEntry({required this.name, required this.path});

  factory WorkspaceDirectoryEntry.fromJson(Map<String, Object?> json) {
    return WorkspaceDirectoryEntry(
      name: json['name'] as String,
      path: json['path'] as String,
    );
  }

  final String name;
  final String path;
}

class WorkspaceDirectoryListing {
  const WorkspaceDirectoryListing({
    required this.currentPath,
    required this.parentPath,
    required this.directories,
  });

  factory WorkspaceDirectoryListing.fromJson(Map<String, Object?> json) {
    return WorkspaceDirectoryListing(
      currentPath: json['currentPath'] as String,
      parentPath: json['parentPath'] as String?,
      directories: _objects(
        json['directories'],
      ).map(WorkspaceDirectoryEntry.fromJson).toList(),
    );
  }

  final String currentPath;
  final String? parentPath;
  final List<WorkspaceDirectoryEntry> directories;
}

class ResumeCandidate {
  const ResumeCandidate({
    required this.runtimeSessionId,
    required this.title,
    required this.agentKind,
    required this.workspacePath,
    required this.updatedAt,
    required this.status,
  });

  factory ResumeCandidate.fromJson(Map<String, Object?> json) {
    return ResumeCandidate(
      runtimeSessionId: json['runtimeSessionId'] as String,
      title: json['title'] as String?,
      agentKind: json['agentKind'] as String,
      workspacePath: json['workspacePath'] as String,
      updatedAt: json['updatedAt'] as String?,
      status: json['status'] as String?,
    );
  }

  final String runtimeSessionId;
  final String? title;
  final String agentKind;
  final String workspacePath;
  final String? updatedAt;
  final String? status;
}

class SessionSummary {
  const SessionSummary({
    required this.id,
    required this.title,
    required this.agentKind,
    required this.sourceKind,
    required this.runtimeSessionId,
    this.runtimeHealth = 'unknown',
    this.runtimeErrorKind,
    this.runtimeErrorMessage,
    required this.status,
    required this.workspacePath,
  });

  factory SessionSummary.fromJson(Map<String, Object?> json) {
    return SessionSummary(
      id: json['id'] as String,
      title: json['title'] as String?,
      agentKind: json['agentKind'] as String,
      sourceKind: json['sourceKind'] as String,
      runtimeSessionId: json['runtimeSessionId'] as String?,
      runtimeHealth: (json['runtimeHealth'] as String?) ?? 'unknown',
      runtimeErrorKind: json['runtimeErrorKind'] as String?,
      runtimeErrorMessage: json['runtimeErrorMessage'] as String?,
      status: json['status'] as String,
      workspacePath: json['workspacePath'] as String,
    );
  }

  final String id;
  final String? title;
  final String agentKind;
  final String sourceKind;
  final String? runtimeSessionId;
  final String runtimeHealth;
  final String? runtimeErrorKind;
  final String? runtimeErrorMessage;
  final String status;
  final String workspacePath;
}

class SessionSnapshot {
  const SessionSnapshot({
    required this.id,
    required this.title,
    required this.agentKind,
    required this.sourceKind,
    required this.runtimeSessionId,
    this.runtimeHealth = 'unknown',
    this.runtimeErrorKind,
    this.runtimeErrorMessage,
    required this.workspacePath,
    required this.status,
    required this.hasMoreHistory,
    required this.events,
  });

  factory SessionSnapshot.fromJson(Map<String, Object?> json) {
    final events = _objects(json['events']).map(SessionEvent.fromJson).toList();
    return SessionSnapshot(
      id: json['id'] as String,
      title: json['title'] as String?,
      agentKind: json['agentKind'] as String,
      sourceKind: json['sourceKind'] as String,
      runtimeSessionId: json['runtimeSessionId'] as String?,
      runtimeHealth: (json['runtimeHealth'] as String?) ?? 'unknown',
      runtimeErrorKind: json['runtimeErrorKind'] as String?,
      runtimeErrorMessage: json['runtimeErrorMessage'] as String?,
      workspacePath: json['workspacePath'] as String,
      status: json['status'] as String,
      hasMoreHistory: json['hasMoreHistory'] as bool,
      events: events,
    );
  }

  final String id;
  final String? title;
  final String agentKind;
  final String sourceKind;
  final String? runtimeSessionId;
  final String runtimeHealth;
  final String? runtimeErrorKind;
  final String? runtimeErrorMessage;
  final String workspacePath;
  final String status;
  final bool hasMoreHistory;
  final List<SessionEvent> events;
}

class SendMessageAck {
  const SendMessageAck({
    required this.accepted,
    required this.clientMessageId,
    required this.eventId,
    required this.sessionStatus,
  });

  factory SendMessageAck.fromJson(Map<String, Object?> json) {
    return SendMessageAck(
      accepted: json['accepted'] as bool,
      clientMessageId: json['clientMessageId'] as String,
      eventId: json['eventId'] as int,
      sessionStatus: json['sessionStatus'] as String,
    );
  }

  final bool accepted;
  final String clientMessageId;
  final int eventId;
  final String sessionStatus;
}

extension SessionSnapshotSummary on SessionSnapshot {
  SessionSummary toSummary() {
    return SessionSummary(
      id: id,
      title: title,
      agentKind: agentKind,
      sourceKind: sourceKind,
      runtimeSessionId: runtimeSessionId,
      runtimeHealth: runtimeHealth,
      runtimeErrorKind: runtimeErrorKind,
      runtimeErrorMessage: runtimeErrorMessage,
      status: status,
      workspacePath: workspacePath,
    );
  }
}

class SessionEvent {
  const SessionEvent({
    required this.id,
    required this.eventType,
    required this.payload,
  });

  factory SessionEvent.fromJson(Map<String, Object?> json) {
    return SessionEvent(
      id: json['id'] as int,
      eventType: json['eventType'] as String,
      payload: _object(json['payload']),
    );
  }

  final int id;
  final String eventType;
  final Map<String, Object?> payload;
}

class VoiceConfig {
  const VoiceConfig({
    required this.doubaoDirectAvailable,
    this.providerCredentials,
  });

  factory VoiceConfig.fromJson(Map<String, Object?> json) {
    return VoiceConfig(
      doubaoDirectAvailable: json['doubaoDirectAvailable'] as bool,
      providerCredentials: switch (json['providerCredentials']) {
        Map<String, Object?> value => DoubaoVoiceCredentials.fromJson(value),
        _ => null,
      },
    );
  }

  final bool doubaoDirectAvailable;
  final DoubaoVoiceCredentials? providerCredentials;
}

Map<String, Object?> _decodeObject(String body) {
  final decoded = jsonDecode(body);
  if (decoded is Map<String, Object?>) {
    return decoded;
  }
  throw const FormatException('Expected JSON object response');
}

Map<String, Object?> _object(Object? value) {
  if (value is Map<String, Object?>) {
    return value;
  }
  throw const FormatException('Expected nested JSON object');
}

Iterable<Map<String, Object?>> _objects(Object? value) {
  if (value is List<Object?>) {
    return value.map(_object);
  }
  throw const FormatException('Expected JSON array');
}
