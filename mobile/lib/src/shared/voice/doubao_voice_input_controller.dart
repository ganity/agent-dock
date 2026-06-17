import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:record/record.dart';

import '../storage/voice_credentials_storage.dart';
import 'voice_input_controller.dart';

const _messageTypeFullClientRequest = 0x1;
const _messageTypeAudioOnlyRequest = 0x2;
const _messageTypeFullServerResponse = 0x9;
const _messageTypeErrorResponse = 0xF;
const _messageFlagNone = 0x0;
const _messageFlagSequence = 0x1;
const _messageFlagFinalPacket = 0x2;
const _messageFlagFinalResponse = 0x3;
const _serializationNone = 0x0;
const _serializationJson = 0x1;
const _compressionNone = 0x0;
const _compressionGzip = 0x1;

abstract class DoubaoVoiceTransport {
  Stream<String> connect(DoubaoVoiceCredentials credentials);

  Future<void> send(String message);

  Future<void> sendAudioChunk(List<int> bytes, {required bool isFinal});
}

abstract class DoubaoAudioSource {
  Future<void> prepare();

  Future<bool> requestPermission();

  Stream<Uint8List> startPcmStream();

  Future<void> stop();
}

abstract class DoubaoRecorder {
  Future<bool> hasPermission({bool request = true});

  Future<Stream<Uint8List>> startStream(RecordConfig config);

  Future<String?> stop();
}

abstract class DoubaoSocketConnection {
  Stream<Object?> get messages;

  Future<void> send(List<int> bytes);

  Future<void> sendText(String message);

  Future<void> close();
}

abstract class DoubaoSocketClient {
  Future<DoubaoSocketConnection> connect(DoubaoConnectRequest request);
}

class DoubaoConnectRequest {
  const DoubaoConnectRequest({required this.url, required this.headers});

  final String url;
  final Map<String, String> headers;
}

class DoubaoProviderFrame {
  const DoubaoProviderFrame({
    required this.type,
    this.text,
    this.message,
    required this.isFinal,
  });

  final String type;
  final String? text;
  final String? message;
  final bool isFinal;
}

class VoiceInputException implements Exception {
  const VoiceInputException(this.message);

  final String message;

  @override
  String toString() => message;
}

class DoubaoVoiceInputController implements VoiceInputController {
  DoubaoVoiceInputController({
    required this.credentials,
    required this.transport,
    this.audioSource,
  });

  final DoubaoVoiceCredentials credentials;
  final DoubaoVoiceTransport transport;
  final DoubaoAudioSource? audioSource;
  bool _cancelRequested = false;
  bool _stopSent = false;

  @override
  bool get isConfigured => true;

  @override
  Future<void> prepare() async {
    await audioSource?.prepare();
  }

  @override
  Future<String> listenForTranscript() async {
    _cancelRequested = false;
    var latestTranscript = '';
    await for (final update in listenWithUpdates()) {
      if (update.transcript case final text?) {
        latestTranscript = text;
      }
      if (update.isFinal) {
        return latestTranscript;
      }
    }

    return latestTranscript;
  }

  @override
  Stream<VoiceInputUpdate> listenWithUpdates() async* {
    final source = audioSource;
    String? latestTranscript;
    Future<void>? audioSendFuture;
    _cancelRequested = false;
    _stopSent = false;
    if (source != null) {
      final granted = await source.requestPermission();
      if (!granted) {
        throw const VoiceInputException('Microphone permission denied');
      }
    }

    yield const VoiceInputUpdate(stage: VoiceInputStage.connecting);
    try {
      await for (final rawMessage in transport.connect(credentials)) {
        final message = _decodeMessage(rawMessage);
        final type = message['type'];
        if (type == 'ready') {
          if (_cancelRequested) {
            await _sendStopOnce();
            continue;
          }
          yield const VoiceInputUpdate(stage: VoiceInputStage.listening);
          audioSendFuture ??= _sendAudioStream(source);
          continue;
        }
        if (type == 'transcript') {
          final text = message['text'];
          if (text is String) {
            latestTranscript = text;
            yield VoiceInputUpdate(
              stage: _cancelRequested
                  ? VoiceInputStage.stopping
                  : VoiceInputStage.listening,
              transcript: text,
              isFinal: false,
            );
          }
          continue;
        }
        if (type == 'error') {
          final messageText = message['message'];
          throw VoiceInputException(
            messageText is String && messageText.isNotEmpty
                ? _voiceErrorMessage(messageText)
                : 'Voice input failed',
          );
        }
        if (type == 'stopped') {
          if (audioSendFuture != null) {
            await audioSendFuture;
          }
          yield VoiceInputUpdate(
            stage: VoiceInputStage.stopping,
            transcript: latestTranscript,
            isFinal: true,
          );
          return;
        }
      }
    } finally {
      if (source != null) {
        await source.stop();
      }
    }
  }

  Future<void> _sendAudioStream(DoubaoAudioSource? source) async {
    if (source != null) {
      await for (final chunk in source.startPcmStream()) {
        if (_cancelRequested) {
          break;
        }
        await transport.sendAudioChunk(chunk, isFinal: false);
      }
    }
    await _sendStopOnce();
  }

  Map<String, Object?> _decodeMessage(String rawMessage) {
    final decoded = jsonDecode(rawMessage);
    if (decoded is Map<String, Object?>) {
      return decoded;
    }
    throw const VoiceInputException('Voice input returned an invalid message');
  }

  @override
  Future<void> cancel() async {
    _cancelRequested = true;
    await audioSource?.stop();
    await _sendStopOnce();
  }

  Future<void> _sendStopOnce() async {
    if (_stopSent) {
      return;
    }
    _stopSent = true;
    await transport.send(jsonEncode({'type': 'stop'}));
  }

  String _voiceErrorMessage(String message) {
    if (message.startsWith('Voice input failed:')) {
      return 'Voice input failed';
    }
    return message;
  }
}

class UnimplementedDoubaoVoiceTransport implements DoubaoVoiceTransport {
  const UnimplementedDoubaoVoiceTransport();

  @override
  Stream<String> connect(DoubaoVoiceCredentials credentials) {
    return Stream<String>.error(
      const VoiceInputException(
        'Direct Doubao voice transport is not wired yet',
      ),
    );
  }

  @override
  Future<void> send(String message) {
    return Future<void>.value();
  }

  @override
  Future<void> sendAudioChunk(List<int> bytes, {required bool isFinal}) {
    return Future<void>.value();
  }
}

class RecordDoubaoAudioSource implements DoubaoAudioSource {
  RecordDoubaoAudioSource({DoubaoRecorder? recorder})
    : _recorder = recorder ?? AudioRecorderAdapter();

  final DoubaoRecorder _recorder;

  @override
  Future<void> prepare() async {
    await _recorder.hasPermission(request: false);
  }

  @override
  Future<bool> requestPermission() {
    return _recorder.hasPermission(request: true);
  }

  @override
  Stream<Uint8List> startPcmStream() async* {
    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ),
    );
    yield* stream;
  }

  @override
  Future<void> stop() async {
    await _recorder.stop();
  }
}

class IoDoubaoVoiceTransport implements DoubaoVoiceTransport {
  IoDoubaoVoiceTransport({DoubaoSocketClient? socketClient})
    : _socketClient = socketClient ?? IoDoubaoSocketClient();

  final DoubaoSocketClient _socketClient;
  _IoDoubaoVoiceSession? _activeSession;
  bool _pendingStopRequest = false;

  @override
  Stream<String> connect(DoubaoVoiceCredentials credentials) {
    if (_activeSession != null) {
      return Stream<String>.error(
        const VoiceInputException('Voice input is already active'),
      );
    }
    final session = _IoDoubaoVoiceSession();
    session.stopRequested = _pendingStopRequest;
    _pendingStopRequest = false;
    _activeSession = session;
    unawaited(_open(credentials, session));
    return session.messages.stream;
  }

  @override
  Future<void> send(String message) {
    final decoded = jsonDecode(message);
    if (decoded is Map<String, Object?> && decoded['type'] == 'stop') {
      final session = _activeSession;
      if (session == null) {
        _pendingStopRequest = true;
        return Future<void>.value();
      }
      session.stopRequested = true;
      return _sendFinalPacket(session);
    }
    return Future<void>.value();
  }

  @override
  Future<void> sendAudioChunk(List<int> bytes, {required bool isFinal}) {
    final session = _activeSession;
    if (session == null) {
      return Future<void>.value();
    }
    return session.connection?.send(
          buildAudioRequestFrame(bytes, finalPacket: isFinal),
        ) ??
        Future<void>.value();
  }

  Future<void> _open(
    DoubaoVoiceCredentials credentials,
    _IoDoubaoVoiceSession session,
  ) async {
    try {
      final connection = await _socketClient.connect(
        buildProviderConnectRequest(credentials),
      );
      session.connection = connection;
      await connection.send(buildInitialRequestFrame());
      if (session.stopRequested) {
        await _sendFinalPacket(session);
      }
      session.messages.add(jsonEncode({'type': 'ready'}));
      await for (final rawMessage in connection.messages) {
        final bytes = switch (rawMessage) {
          final Uint8List data => data,
          final List<int> data => Uint8List.fromList(data),
          _ => null,
        };
        if (bytes == null) {
          continue;
        }

        final frame = decodeProviderFrame(bytes);
        switch (frame.type) {
          case 'transcript':
            if (frame.text case final text?) {
              session.messages.add(jsonEncode({'type': 'transcript', 'text': text}));
            }
            if (session.stopRequested && frame.isFinal) {
              if (identical(_activeSession, session)) {
                _activeSession = null;
              }
              session.messages.add(jsonEncode({'type': 'stopped'}));
              await connection.close();
              await session.messages.close();
              return;
            }
          case 'error':
            if (identical(_activeSession, session)) {
              _activeSession = null;
            }
            session.messages.add(
              jsonEncode({
                'type': 'error',
                'message': frame.message ?? 'Voice input failed',
              }),
            );
            await connection.close();
            await session.messages.close();
            return;
        }
      }

      if (identical(_activeSession, session)) {
        _activeSession = null;
      }
      if (session.stopRequested && !session.messages.isClosed) {
        session.messages.add(jsonEncode({'type': 'stopped'}));
      }
      if (!session.messages.isClosed) {
        await session.messages.close();
      }
    } on Object catch (error) {
      if (identical(_activeSession, session)) {
        _activeSession = null;
      }
      if (!session.messages.isClosed) {
        session.messages.add(
          jsonEncode({
            'type': 'error',
            'message': 'Voice input failed: $error',
          }),
        );
        await session.messages.close();
      }
    } finally {
      if (identical(_activeSession, session)) {
        _activeSession = null;
      }
      session.connection = null;
      _pendingStopRequest = false;
    }
  }

  Future<void> _sendFinalPacket(_IoDoubaoVoiceSession session) async {
    if (session.finalPacketSent) {
      return;
    }
    final connection = session.connection;
    if (connection == null) {
      return;
    }
    session.finalPacketSent = true;
    await connection.send(
      buildAudioRequestFrame(const <int>[], finalPacket: true),
    );
  }
}

class DaemonProxyVoiceTransport implements DoubaoVoiceTransport {
  DaemonProxyVoiceTransport({
    required this.daemonUrl,
    required this.token,
    DoubaoSocketClient? socketClient,
  }) : _socketClient = socketClient ?? IoDoubaoSocketClient();

  final Uri daemonUrl;
  final String token;
  final DoubaoSocketClient _socketClient;
  _DaemonProxyVoiceSession? _activeSession;
  bool _pendingStopRequest = false;

  @override
  Stream<String> connect(DoubaoVoiceCredentials credentials) {
    if (_activeSession != null) {
      return Stream<String>.error(
        const VoiceInputException('Voice input is already active'),
      );
    }
    final session = _DaemonProxyVoiceSession();
    session.stopRequested = _pendingStopRequest;
    _pendingStopRequest = false;
    _activeSession = session;
    unawaited(_open(session));
    return session.messages.stream;
  }

  @override
  Future<void> send(String message) {
    if (!_isStopMessage(message)) {
      return Future<void>.value();
    }
    final session = _activeSession;
    if (session == null) {
      _pendingStopRequest = true;
      return Future<void>.value();
    }
    session.stopRequested = true;
    return session.connection?.sendText(message) ?? Future<void>.value();
  }

  @override
  Future<void> sendAudioChunk(List<int> bytes, {required bool isFinal}) {
    final session = _activeSession;
    if (session == null || bytes.isEmpty) {
      return Future<void>.value();
    }
    return session.connection?.send(bytes) ?? Future<void>.value();
  }

  Future<void> _open(_DaemonProxyVoiceSession session) async {
    try {
      final connection = await _socketClient.connect(
        DoubaoConnectRequest(
          url: _daemonVoiceWebSocketUrl(daemonUrl).toString(),
          headers: {'authorization': 'Bearer $token'},
        ),
      );
      session.connection = connection;
      if (session.stopRequested) {
        await connection.sendText(jsonEncode({'type': 'stop'}));
      }
      await for (final rawMessage in connection.messages) {
        if (rawMessage is! String) {
          continue;
        }
        session.messages.add(rawMessage);
        switch (_messageType(rawMessage)) {
          case 'error':
          case 'stopped':
            await connection.close();
            await session.messages.close();
            return;
        }
      }
      if (session.stopRequested && !session.messages.isClosed) {
        session.messages.add(jsonEncode({'type': 'stopped'}));
      }
      if (!session.messages.isClosed) {
        await session.messages.close();
      }
    } on Object catch (error) {
      if (!session.messages.isClosed) {
        session.messages.add(
          jsonEncode({
            'type': 'error',
            'message': 'Voice input failed: $error',
          }),
        );
        await session.messages.close();
      }
    } finally {
      if (identical(_activeSession, session)) {
        _activeSession = null;
      }
      session.connection = null;
      _pendingStopRequest = false;
    }
  }
}

class _DaemonProxyVoiceSession {
  final StreamController<String> messages = StreamController<String>();
  DoubaoSocketConnection? connection;
  bool stopRequested = false;
}

class _IoDoubaoVoiceSession {
  final StreamController<String> messages = StreamController<String>();
  DoubaoSocketConnection? connection;
  bool stopRequested = false;
  bool finalPacketSent = false;
}

class IoDoubaoSocketClient implements DoubaoSocketClient {
  @override
  Future<DoubaoSocketConnection> connect(DoubaoConnectRequest request) async {
    final socket = await WebSocket.connect(
      request.url,
      headers: request.headers,
    );
    return IoDoubaoSocketConnection(socket);
  }
}

class AudioRecorderAdapter implements DoubaoRecorder {
  AudioRecorderAdapter({AudioRecorder? recorder})
    : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;

  @override
  Future<bool> hasPermission({bool request = true}) {
    return _recorder.hasPermission(request: request);
  }

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) {
    return _recorder.startStream(config);
  }

  @override
  Future<String?> stop() {
    return _recorder.stop();
  }
}

class IoDoubaoSocketConnection implements DoubaoSocketConnection {
  IoDoubaoSocketConnection(this._socket);

  final WebSocket _socket;

  @override
  Stream<Object?> get messages => _socket;

  @override
  Future<void> send(List<int> bytes) async {
    _socket.add(bytes);
  }

  @override
  Future<void> sendText(String message) async {
    _socket.add(message);
  }

  @override
  Future<void> close() async {
    await _socket.close();
  }
}

bool _isStopMessage(String message) {
  final decoded = jsonDecode(message);
  return decoded is Map<String, Object?> && decoded['type'] == 'stop';
}

String? _messageType(String message) {
  final decoded = jsonDecode(message);
  if (decoded is Map<String, Object?>) {
    return decoded['type'] as String?;
  }
  return null;
}

Uri _daemonVoiceWebSocketUrl(Uri daemonUrl) {
  final scheme = switch (daemonUrl.scheme) {
    'https' => 'wss',
    'http' => 'ws',
    _ => daemonUrl.scheme,
  };
  return daemonUrl.replace(
    scheme: scheme,
    path: '/ws/voice-input',
    query: null,
    queryParameters: null,
  );
}

DoubaoConnectRequest buildProviderConnectRequest(
  DoubaoVoiceCredentials credentials,
) {
  final requestId = DateTime.now().microsecondsSinceEpoch.toString();
  return DoubaoConnectRequest(
    url: credentials.websocketUrl,
    headers: {
      'X-Api-App-Key': credentials.appId,
      'X-Api-Access-Key': credentials.accessToken,
      'X-Api-Resource-Id': credentials.resourceId,
      'X-Api-Connect-Id': requestId,
      'X-Api-Request-Id': requestId,
      'X-Api-Sequence': '-1',
    },
  );
}

List<int> buildInitialRequestFrame() {
  return _buildClientMessage(
    messageType: _messageTypeFullClientRequest,
    flags: _messageFlagNone,
    serialization: _serializationJson,
    compression: _compressionGzip,
    payload: utf8.encode(
      jsonEncode({
        'user': {'uid': 'agent-dock'},
        'audio': {
          'format': 'pcm',
          'rate': 16000,
          'bits': 16,
          'channel': 1,
          'language': 'zh-CN',
        },
        'request': {
          'model_name': 'bigmodel',
          'enable_itn': true,
          'enable_punc': true,
        },
      }),
    ),
  );
}

List<int> buildAudioRequestFrame(List<int> chunk, {required bool finalPacket}) {
  return _buildClientMessage(
    messageType: _messageTypeAudioOnlyRequest,
    flags: finalPacket ? _messageFlagFinalPacket : _messageFlagNone,
    serialization: _serializationNone,
    compression: _compressionGzip,
    payload: chunk,
  );
}

DoubaoProviderFrame decodeProviderFrame(List<int> frame) {
  if (frame.length < 8) {
    throw const VoiceInputException('Provider response frame too short');
  }

  final messageType = frame[1] >> 4;
  final flags = frame[1] & 0x0f;
  final serialization = frame[2] >> 4;
  final compression = frame[2] & 0x0f;
  var cursor = 4;

  if (flags == _messageFlagSequence || flags == _messageFlagFinalResponse) {
    cursor += 4;
  }
  if (frame.length < cursor + 4) {
    throw const VoiceInputException(
      'Provider response frame missing payload size',
    );
  }

  final payloadSize = _readUint32(frame, cursor);
  cursor += 4;
  final payloadBytes = frame.sublist(cursor, cursor + payloadSize);
  final payload = switch (compression) {
    _compressionGzip => gzip.decode(payloadBytes),
    _compressionNone => payloadBytes,
    _ => throw const VoiceInputException(
      'Unsupported provider compression format',
    ),
  };

  switch (messageType) {
    case _messageTypeFullServerResponse:
      String? text;
      if (serialization == _serializationJson) {
        final decoded =
            jsonDecode(utf8.decode(payload)) as Map<String, Object?>;
        final result = decoded['result'];
        if (result is Map<String, Object?>) {
          final transcript = result['text'];
          if (transcript is String) {
            text = transcript;
          }
        }
      }
      return DoubaoProviderFrame(
        type: 'transcript',
        text: text,
        isFinal: flags == _messageFlagFinalResponse,
      );
    case _messageTypeErrorResponse:
      return DoubaoProviderFrame(
        type: 'error',
        message: _decodeErrorPayload(serialization, payload),
        isFinal: true,
      );
    default:
      return const DoubaoProviderFrame(type: 'unknown', isFinal: false);
  }
}

List<int> buildTranscriptResponseFrame(String text, {bool isFinal = false}) {
  final payload = utf8.encode(
    jsonEncode({
      'result': {'text': text},
    }),
  );
  return _buildServerMessage(
    messageType: _messageTypeFullServerResponse,
    flags: isFinal ? _messageFlagFinalResponse : _messageFlagSequence,
    serialization: _serializationJson,
    compression: _compressionGzip,
    payload: payload,
  );
}

List<int> buildErrorResponseFrame(String message) {
  return _buildServerMessage(
    messageType: _messageTypeErrorResponse,
    flags: _messageFlagFinalResponse,
    serialization: _serializationJson,
    compression: _compressionGzip,
    payload: utf8.encode(jsonEncode({'message': message})),
  );
}

List<int> _buildClientMessage({
  required int messageType,
  required int flags,
  required int serialization,
  required int compression,
  required List<int> payload,
}) {
  final encodedPayload = compression == _compressionGzip
      ? gzip.encode(payload)
      : payload;
  return <int>[
    0x11,
    (messageType << 4) | flags,
    (serialization << 4) | compression,
    0x00,
    ..._uint32Bytes(encodedPayload.length),
    ...encodedPayload,
  ];
}

List<int> _buildServerMessage({
  required int messageType,
  required int flags,
  required int serialization,
  required int compression,
  required List<int> payload,
}) {
  final encodedPayload = compression == _compressionGzip
      ? gzip.encode(payload)
      : payload;
  return <int>[
    0x11,
    (messageType << 4) | flags,
    (serialization << 4) | compression,
    0x00,
    ..._int32Bytes(flags == _messageFlagFinalResponse ? -1 : 1),
    ..._uint32Bytes(encodedPayload.length),
    ...encodedPayload,
  ];
}

List<int> _uint32Bytes(int value) {
  final data = ByteData(4)..setUint32(0, value);
  return data.buffer.asUint8List();
}

List<int> _int32Bytes(int value) {
  final data = ByteData(4)..setInt32(0, value);
  return data.buffer.asUint8List();
}

int _readUint32(List<int> bytes, int offset) {
  final data = ByteData.sublistView(
    Uint8List.fromList(bytes),
    offset,
    offset + 4,
  );
  return data.getUint32(0);
}

String _decodeErrorPayload(int serialization, List<int> payload) {
  if (serialization == _serializationJson) {
    final decoded = jsonDecode(utf8.decode(payload));
    if (decoded is Map<String, Object?>) {
      final message = decoded['message'] ?? decoded['error'];
      if (message is String) {
        return message;
      }
    }
  }
  return utf8.decode(payload, allowMalformed: true);
}
