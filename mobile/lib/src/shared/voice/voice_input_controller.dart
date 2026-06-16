import 'dart:async';

enum VoiceInputStage { connecting, listening, stopping }

class VoiceInputUpdate {
  const VoiceInputUpdate({
    required this.stage,
    this.transcript,
    this.isFinal = false,
  });

  final VoiceInputStage stage;
  final String? transcript;
  final bool isFinal;
}

abstract class VoiceInputController {
  bool get isConfigured;

  Future<String> listenForTranscript();

  Future<void> cancel() async {}

  Stream<VoiceInputUpdate> listenWithUpdates() async* {
    yield const VoiceInputUpdate(stage: VoiceInputStage.connecting);
    yield const VoiceInputUpdate(stage: VoiceInputStage.listening);
    final transcript = await listenForTranscript();
    yield VoiceInputUpdate(
      stage: VoiceInputStage.stopping,
      transcript: transcript,
      isFinal: true,
    );
  }
}

class DisabledVoiceInputController implements VoiceInputController {
  const DisabledVoiceInputController();

  @override
  bool get isConfigured => false;

  @override
  Future<String> listenForTranscript() {
    throw UnsupportedError('Voice input is not configured');
  }

  @override
  Stream<VoiceInputUpdate> listenWithUpdates() {
    return const Stream<VoiceInputUpdate>.empty();
  }

  @override
  Future<void> cancel() async {}
}
