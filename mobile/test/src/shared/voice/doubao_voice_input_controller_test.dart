import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_dock_mobile/src/shared/storage/voice_credentials_storage.dart';
import 'package:agent_dock_mobile/src/shared/voice/doubao_voice_input_controller.dart';
import 'package:agent_dock_mobile/src/shared/voice/voice_input_controller.dart';
import 'package:record/record.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:async/async.dart';

void main() {
  group('DoubaoVoiceInputController', () {
    test('returns the final transcript from the voice transport', () async {
      final transport = FakeDoubaoVoiceTransport();
      final controller = DoubaoVoiceInputController(
        credentials: _credentials,
        transport: transport,
      );

      final transcriptFuture = controller.listenForTranscript();
      transport.emit('{"type":"ready"}');
      transport.emit('{"type":"transcript","text":"你好"}');
      transport.emit('{"type":"transcript","text":"你好，继续"}');
      transport.emit('{"type":"stopped"}');

      await expectLater(transcriptFuture, completion('你好，继续'));
      expect(transport.connectedCredentials, _credentials);
    });

    test('throws when the provider sends an error message', () async {
      final transport = FakeDoubaoVoiceTransport();
      final controller = DoubaoVoiceInputController(
        credentials: _credentials,
        transport: transport,
      );

      final transcriptFuture = controller.listenForTranscript();
      transport.emit('{"type":"ready"}');
      transport.emit('{"type":"error","message":"quota exceeded"}');

      await expectLater(
        transcriptFuture,
        throwsA(
          isA<VoiceInputException>().having(
            (error) => error.message,
            'message',
            'quota exceeded',
          ),
        ),
      );
    });

    test(
      'surfaces a user-facing fallback when the transport emits an unexpected internal error message',
      () async {
        final transport = FakeDoubaoVoiceTransport();
        final controller = DoubaoVoiceInputController(
          credentials: _credentials,
          transport: transport,
        );

        final transcriptFuture = controller.listenForTranscript();
        transport.emit('{"type":"ready"}');
        transport.emit(
          '{"type":"error","message":"Voice input failed: Bad state: provider handshake corrupted"}',
        );

        await expectLater(
          transcriptFuture,
          throwsA(
            isA<VoiceInputException>().having(
              (error) => error.message,
              'message',
              'Voice input failed',
            ),
          ),
        );
      },
    );

    test('sends a stop message after the transport is ready', () async {
      final transport = FakeDoubaoVoiceTransport();
      final controller = DoubaoVoiceInputController(
        credentials: _credentials,
        transport: transport,
      );

      final transcriptFuture = controller.listenForTranscript();
      transport.emit('{"type":"ready"}');

      await transport.waitForSentMessages(1);
      expect(transport.sentMessages.single, '{"type":"stop"}');

      transport.emit('{"type":"transcript","text":"final text"}');
      transport.emit('{"type":"stopped"}');
      await expectLater(transcriptFuture, completion('final text'));
    });

    test('encodes the initial provider request frame', () async {
      final frame = buildInitialRequestFrame();

      expect(frame[0], 0x11);
      expect(frame[1], 0x10);
      expect(frame[2], 0x11);

      final payloadSize = _readUint32(frame, 4);
      expect(payloadSize, greaterThan(0));
      expect(frame.length, greaterThan(8));
      final payload = _decodeJsonPayload(frame);
      expect(payload['user'], {'uid': 'agent-dock'});
    });

    test('encodes audio frames and final packet flag', () async {
      final frame = buildAudioRequestFrame(
        Uint8List.fromList(const [1, 2, 3, 4]),
        finalPacket: true,
      );

      expect(frame[0], 0x11);
      expect(frame[1], 0x22);
      expect(frame[2], 0x01);
      final payloadSize = _readUint32(frame, 4);
      expect(payloadSize, greaterThan(0));
    });

    test('decodes transcript response frames', () async {
      final frame = buildTranscriptResponseFrame('识别结果', isFinal: true);

      final message = decodeProviderFrame(frame);

      expect(message.type, 'transcript');
      expect(message.text, '识别结果');
      expect(message.isFinal, isTrue);
    });

    test('decodes provider error frames', () async {
      final frame = buildErrorResponseFrame('quota exceeded');

      final message = decodeProviderFrame(frame);

      expect(message.type, 'error');
      expect(message.message, 'quota exceeded');
      expect(message.isFinal, isTrue);
    });

    test('builds provider connect headers from Doubao credentials', () async {
      final request = buildProviderConnectRequest(_credentials);

      expect(request.url, _credentials.websocketUrl);
      expect(request.headers['X-Api-App-Key'], 'app-123');
      expect(request.headers['X-Api-Access-Key'], 'token-abc');
      expect(request.headers['X-Api-Resource-Id'], 'volc.bigasr.sauc.duration');
      expect(request.headers['X-Api-Sequence'], '-1');
      expect(request.headers['X-Api-Request-Id'], isNotEmpty);
      expect(request.headers['X-Api-Connect-Id'], isNotEmpty);
    });

    test(
      'transport emits ready transcript and stopped around upstream frames',
      () async {
        final socket = FakeDoubaoSocketConnection();
        final transport = IoDoubaoVoiceTransport(
          socketClient: FakeDoubaoSocketClient(socket),
        );

        final queue = StreamQueue<String>(transport.connect(_credentials));
        socket.emit(buildTranscriptResponseFrame('你好', isFinal: false));

        expect(await queue.next, '{"type":"ready"}');
        expect(await queue.next, '{"type":"transcript","text":"你好"}');

        await transport.send('{"type":"stop"}');
        socket.emit(buildTranscriptResponseFrame('你好，结束', isFinal: true));

        expect(await queue.next, '{"type":"transcript","text":"你好，结束"}');
        expect(await queue.next, '{"type":"stopped"}');
        expect(socket.sentFrames, hasLength(2));
        expect(socket.sentFrames.first[1], 0x10);
        expect(socket.sentFrames.last[1], 0x22);
      },
    );

    test('transport can be reused for a second connection after stopping', () async {
      final firstSocket = FakeDoubaoSocketConnection();
      final secondSocket = FakeDoubaoSocketConnection();
      final transport = IoDoubaoVoiceTransport(
        socketClient: SequentialFakeDoubaoSocketClient([
          firstSocket,
          secondSocket,
        ]),
      );

      var queue = StreamQueue<String>(transport.connect(_credentials));
      firstSocket.emit(buildTranscriptResponseFrame('first', isFinal: false));

      expect(await queue.next, '{"type":"ready"}');
      expect(await queue.next, '{"type":"transcript","text":"first"}');

      await transport.send('{"type":"stop"}');
      firstSocket.emit(buildTranscriptResponseFrame('first done', isFinal: true));

      expect(await queue.next, '{"type":"transcript","text":"first done"}');
      expect(await queue.next, '{"type":"stopped"}');
      expect(firstSocket.sentFrames, hasLength(2));
      expect(firstSocket.sentFrames.first[1], 0x10);
      expect(firstSocket.sentFrames.last[1], 0x22);
      unawaited(queue.cancel());

      queue = StreamQueue<String>(transport.connect(_credentials));
      secondSocket.emit(buildTranscriptResponseFrame('second', isFinal: false));

      expect(await queue.next, '{"type":"ready"}');
      expect(await queue.next, '{"type":"transcript","text":"second"}');

      await transport.send('{"type":"stop"}');
      secondSocket.emit(
        buildTranscriptResponseFrame('second done', isFinal: true),
      );

      expect(await queue.next, '{"type":"transcript","text":"second done"}');
      expect(await queue.next, '{"type":"stopped"}');
      expect(secondSocket.sentFrames, hasLength(2));
      expect(secondSocket.sentFrames.first[1], 0x10);
      expect(secondSocket.sentFrames.last[1], 0x22);
      unawaited(queue.cancel());
    });

    test('daemon proxy transport relays ready transcript and stop frames', () async {
      final socket = FakeDoubaoSocketConnection();
      final transport = DaemonProxyVoiceTransport(
        daemonUrl: Uri.parse('https://daemon.example.com'),
        token: 'tok_workspace',
        socketClient: FakeDoubaoSocketClient(socket),
      );

      final queue = StreamQueue<String>(transport.connect(_credentials));
      socket.emitText('{"type":"ready"}');
      socket.emitText('{"type":"transcript","text":"ni hao"}');

      expect(await queue.next, '{"type":"ready"}');
      expect(await queue.next, '{"type":"transcript","text":"ni hao"}');

      await transport.send('{"type":"stop"}');
      expect(socket.sentTexts.single, '{"type":"stop"}');

      socket.emitText('{"type":"stopped"}');
      expect(await queue.next, '{"type":"stopped"}');
      unawaited(queue.cancel());
    });

    test(
      'controller requests permission streams audio and returns final transcript',
      () async {
        final audioSource = FakeDoubaoAudioSource(
          chunks: [
            Uint8List.fromList(const [1, 2, 3, 4]),
            Uint8List.fromList(const [5, 6, 7, 8]),
          ],
        );
        final socket = FakeDoubaoSocketConnection();
        final transport = IoDoubaoVoiceTransport(
          socketClient: FakeDoubaoSocketClient(socket),
        );
        final controller = DoubaoVoiceInputController(
          credentials: _credentials,
          transport: transport,
          audioSource: audioSource,
        );

        final transcriptFuture = controller.listenForTranscript();
        scheduleMicrotask(() async {
          socket.emit(buildTranscriptResponseFrame('hello', isFinal: false));
          await socket.waitForSentFrames(4);
          socket.emit(
            buildTranscriptResponseFrame('hello world', isFinal: true),
          );
        });

        await expectLater(transcriptFuture, completion('hello world'));
        expect(audioSource.permissionRequested, isTrue);
        expect(audioSource.started, isTrue);
        expect(audioSource.stopped, isTrue);
        expect(socket.sentFrames, hasLength(4));
        expect(socket.sentFrames.first[1], 0x10);
        expect(socket.sentFrames[1][1], 0x20);
        expect(socket.sentFrames[2][1], 0x20);
        expect(socket.sentFrames.last[1], 0x22);
      },
    );

    test(
      'controller surfaces partial transcript updates before audio stream completes',
      () async {
        final audioSource = FakeDoubaoAudioSource(
          chunks: [
            Uint8List.fromList(const [1, 2, 3, 4]),
          ],
          chunkDelayMs: 30,
        );
        final socket = FakeDoubaoSocketConnection();
        final transport = IoDoubaoVoiceTransport(
          socketClient: FakeDoubaoSocketClient(socket),
        );
        final controller = DoubaoVoiceInputController(
          credentials: _credentials,
          transport: transport,
          audioSource: audioSource,
        );

        final queue = StreamQueue<VoiceInputUpdate>(
          controller.listenWithUpdates(),
        );
        expect((await queue.next).stage, VoiceInputStage.connecting);

        socket.emit(buildTranscriptResponseFrame('partial', isFinal: false));

        final listening = await queue.next;
        expect(listening.stage, VoiceInputStage.listening);
        final partial = await queue.next;
        expect(partial.transcript, 'partial');
        expect(partial.isFinal, isFalse);
      },
    );

    test('cancel during connecting still sends a final stop packet', () async {
      final audioSource = FakeDoubaoAudioSource(
        chunks: [
          Uint8List.fromList(const [1, 2, 3, 4]),
        ],
        chunkDelayMs: 50,
      );
      final socket = FakeDoubaoSocketConnection();
      final transport = IoDoubaoVoiceTransport(
        socketClient: FakeDoubaoSocketClient(socket),
      );
      final controller = DoubaoVoiceInputController(
        credentials: _credentials,
        transport: transport,
        audioSource: audioSource,
      );

      final updates = <VoiceInputUpdate>[];
      final done = Completer<void>();
      controller.listenWithUpdates().listen(updates.add, onDone: done.complete);

      await controller.cancel();
      await _waitUntil(
        () => socket.sentFrames.any((frame) => frame[1] == 0x22),
      );
      socket.emit(buildTranscriptResponseFrame('cancelled', isFinal: true));
      await done.future;

      final finalPackets = socket.sentFrames.where((frame) => frame[1] == 0x22);
      expect(finalPackets, hasLength(1));
      expect(updates.first.stage, VoiceInputStage.connecting);
    });

    test('cancel after ready only sends one final stop packet', () async {
      final audioSource = FakeDoubaoAudioSource(
        chunks: [
          Uint8List.fromList(const [1, 2, 3, 4]),
        ],
        chunkDelayMs: 50,
      );
      final socket = FakeDoubaoSocketConnection();
      final transport = IoDoubaoVoiceTransport(
        socketClient: FakeDoubaoSocketClient(socket),
      );
      final controller = DoubaoVoiceInputController(
        credentials: _credentials,
        transport: transport,
        audioSource: audioSource,
      );

      final updates = <VoiceInputUpdate>[];
      final done = Completer<void>();
      controller.listenWithUpdates().listen(updates.add, onDone: done.complete);
      await _waitUntil(
        () =>
            updates.any((update) => update.stage == VoiceInputStage.listening),
      );

      await controller.cancel();
      await _waitUntil(
        () => socket.sentFrames.any((frame) => frame[1] == 0x22),
      );
      socket.emit(buildTranscriptResponseFrame('cancelled', isFinal: true));
      await done.future;

      final finalPackets = socket.sentFrames.where((frame) => frame[1] == 0x22);
      expect(finalPackets, hasLength(1));
    });

    test(
      'record audio source requests permission and starts pcm16 stream',
      () async {
        final recorder = FakeAudioRecorder(
          stream: Stream<Uint8List>.value(Uint8List.fromList(const [1, 2, 3])),
        );
        final audioSource = RecordDoubaoAudioSource(recorder: recorder);

        expect(await audioSource.requestPermission(), isTrue);
        final stream = audioSource.startPcmStream();
        expect(await stream.first, [1, 2, 3]);
        await audioSource.stop();

        expect(recorder.permissionRequested, isTrue);
        expect(recorder.startedConfig?.encoder, AudioEncoder.pcm16bits);
        expect(recorder.startedConfig?.sampleRate, 16000);
        expect(recorder.startedConfig?.numChannels, 1);
        expect(recorder.stopped, isTrue);
      },
    );

    test(
      'prepare warms local audio permission without starting audio or transport',
      () async {
        final transport = FakeDoubaoVoiceTransport();
        final recorder = FakeAudioRecorder(
          stream: Stream<Uint8List>.value(Uint8List.fromList(const [1, 2, 3])),
        );
        final controller = DoubaoVoiceInputController(
          credentials: _credentials,
          transport: transport,
          audioSource: RecordDoubaoAudioSource(recorder: recorder),
        );

        await controller.prepare();

        expect(recorder.permissionChecks, [false]);
        expect(recorder.startedConfig, isNull);
        expect(recorder.stopped, isFalse);
        expect(transport.connectedCredentials, isNull);
      },
    );
  });
}

const _credentials = DoubaoVoiceCredentials(
  appId: 'app-123',
  accessToken: 'token-abc',
  resourceId: 'volc.bigasr.sauc.duration',
  websocketUrl: 'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel',
);

class FakeDoubaoVoiceTransport implements DoubaoVoiceTransport {
  final _messages = StreamController<String>();
  final sentMessages = <String>[];
  final sentAudioChunks = <({List<int> bytes, bool isFinal})>[];
  DoubaoVoiceCredentials? connectedCredentials;

  @override
  Stream<String> connect(DoubaoVoiceCredentials credentials) {
    connectedCredentials = credentials;
    return _messages.stream;
  }

  @override
  Future<void> send(String message) async {
    sentMessages.add(message);
  }

  @override
  Future<void> sendAudioChunk(List<int> bytes, {required bool isFinal}) async {
    sentAudioChunks.add((bytes: bytes, isFinal: isFinal));
  }

  void emit(String message) {
    _messages.add(message);
  }

  Future<void> waitForSentMessages(int count) async {
    await _waitUntil(() => sentMessages.length >= count);
  }
}

class FakeDoubaoSocketClient implements DoubaoSocketClient {
  FakeDoubaoSocketClient(this.connection);

  final FakeDoubaoSocketConnection connection;

  @override
  Future<DoubaoSocketConnection> connect(DoubaoConnectRequest request) async {
    return connection;
  }
}

class SequentialFakeDoubaoSocketClient implements DoubaoSocketClient {
  SequentialFakeDoubaoSocketClient(this.connections);

  final List<FakeDoubaoSocketConnection> connections;
  var _index = 0;

  @override
  Future<DoubaoSocketConnection> connect(DoubaoConnectRequest request) async {
    if (_index >= connections.length) {
      throw StateError('No fake socket connection left for test');
    }
    return connections[_index++];
  }
}

class FakeDoubaoSocketConnection implements DoubaoSocketConnection {
  final _controller = StreamController<Object?>();
  final sentFrames = <List<int>>[];
  final sentTexts = <String>[];

  @override
  Stream<Object?> get messages => _controller.stream;

  @override
  Future<void> send(List<int> bytes) async {
    sentFrames.add(bytes);
  }

  @override
  Future<void> sendText(String message) async {
    sentTexts.add(message);
  }

  @override
  Future<void> close() async {
    await _controller.close();
  }

  void emit(List<int> bytes) {
    _controller.add(Uint8List.fromList(bytes));
  }

  void emitText(String message) {
    _controller.add(message);
  }

  Future<void> waitForSentFrames(int count) async {
    await _waitUntil(() => sentFrames.length >= count);
  }
}

class FakeDoubaoAudioSource implements DoubaoAudioSource {
  FakeDoubaoAudioSource({required this.chunks, this.chunkDelayMs = 0});

  final List<Uint8List> chunks;
  final int chunkDelayMs;
  var permissionRequested = false;
  var prepareCount = 0;
  var started = false;
  var stopped = false;

  @override
  Future<void> prepare() async {
    prepareCount += 1;
  }

  @override
  Future<bool> requestPermission() async {
    permissionRequested = true;
    return true;
  }

  @override
  Stream<Uint8List> startPcmStream() async* {
    started = true;
    for (final chunk in chunks) {
      if (chunkDelayMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: chunkDelayMs));
      }
      yield chunk;
    }
  }

  @override
  Future<void> stop() async {
    stopped = true;
  }
}

class FakeAudioRecorder implements DoubaoRecorder {
  FakeAudioRecorder({required this.stream});

  final Stream<Uint8List> stream;
  var permissionRequested = false;
  final permissionChecks = <bool>[];
  var stopped = false;
  RecordConfig? startedConfig;

  @override
  Future<bool> hasPermission({bool request = true}) async {
    permissionChecks.add(request);
    permissionRequested = request;
    return true;
  }

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async {
    startedConfig = config;
    return stream;
  }

  @override
  Future<String?> stop() async {
    stopped = true;
    return null;
  }
}

int _readUint32(List<int> bytes, int offset) {
  final data = ByteData.sublistView(
    Uint8List.fromList(bytes),
    offset,
    offset + 4,
  );
  return data.getUint32(0);
}

Map<String, Object?> _decodeJsonPayload(List<int> frame) {
  final payloadSize = _readUint32(frame, 4);
  final payload = frame.sublist(8, 8 + payloadSize);
  final decoded = jsonDecode(utf8.decode(gzip.decode(payload)));
  return decoded as Map<String, Object?>;
}

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition was not met before timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
