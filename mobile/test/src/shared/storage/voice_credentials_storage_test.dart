import 'dart:convert';

import 'package:agent_dock_mobile/src/shared/storage/voice_credentials_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('VoiceCredentialsStorage', () {
    test(
      'saves and reads Doubao credentials scoped by daemon and user',
      () async {
        final store = MemoryVoiceCredentialSecretStore();
        final storage = SecureVoiceCredentialsStorage(secretStore: store);
        final scope = VoiceCredentialScope(
          daemonUrl: Uri.parse('https://daemon.example.com'),
          userId: 'usr_workspace',
        );
        const credentials = DoubaoVoiceCredentials(
          appId: 'app-123',
          accessToken: 'token-abc',
          resourceId: 'volc.bigasr.sauc.duration',
          websocketUrl: 'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel',
        );

        await storage.saveCredentials(scope: scope, credentials: credentials);

        final restored = await storage.readCredentials(scope: scope);
        expect(restored, isNotNull);
        expect(restored!.appId, 'app-123');
        expect(restored.accessToken, 'token-abc');
        expect(restored.resourceId, 'volc.bigasr.sauc.duration');
        expect(
          restored.websocketUrl,
          'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel',
        );
      },
    );

    test('writes credentials under the agent_dock key name', () async {
      final store = MemoryVoiceCredentialSecretStore();
      final storage = SecureVoiceCredentialsStorage(secretStore: store);
      final scope = VoiceCredentialScope(
        daemonUrl: Uri.parse('https://daemon.example.com'),
        userId: 'usr_workspace',
      );
      const credentials = DoubaoVoiceCredentials(
        appId: 'app-123',
        accessToken: 'token-abc',
        resourceId: 'volc.bigasr.sauc.duration',
        websocketUrl: 'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel',
      );
      final daemonKey = base64Url.encode(utf8.encode(scope.daemonUrl.toString()));
      final userKey = base64Url.encode(utf8.encode(scope.userId));

      await storage.saveCredentials(scope: scope, credentials: credentials);

      expect(
        await store.read(
          key: 'agent_dock.voice.doubao.$daemonKey.$userKey',
        ),
        isNotNull,
      );
    });

    test('does not return credentials saved for a different user', () async {
      final store = MemoryVoiceCredentialSecretStore();
      final storage = SecureVoiceCredentialsStorage(secretStore: store);
      const credentials = DoubaoVoiceCredentials(
        appId: 'app-123',
        accessToken: 'token-abc',
        resourceId: 'volc.bigasr.sauc.duration',
        websocketUrl: 'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel',
      );

      await storage.saveCredentials(
        scope: VoiceCredentialScope(
          daemonUrl: Uri.parse('https://daemon.example.com'),
          userId: 'usr_workspace',
        ),
        credentials: credentials,
      );

      final restored = await storage.readCredentials(
        scope: VoiceCredentialScope(
          daemonUrl: Uri.parse('https://daemon.example.com'),
          userId: 'usr_other',
        ),
      );

      expect(restored, isNull);
    });

    test('clears only the credentials for the requested scope', () async {
      final store = MemoryVoiceCredentialSecretStore();
      final storage = SecureVoiceCredentialsStorage(secretStore: store);
      final firstScope = VoiceCredentialScope(
        daemonUrl: Uri.parse('https://daemon.example.com'),
        userId: 'usr_workspace',
      );
      final secondScope = VoiceCredentialScope(
        daemonUrl: Uri.parse('https://saved.example.com'),
        userId: 'usr_workspace',
      );
      const credentials = DoubaoVoiceCredentials(
        appId: 'app-123',
        accessToken: 'token-abc',
        resourceId: 'volc.bigasr.sauc.duration',
        websocketUrl: 'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel',
      );

      await storage.saveCredentials(
        scope: firstScope,
        credentials: credentials,
      );
      await storage.saveCredentials(
        scope: secondScope,
        credentials: credentials,
      );

      await storage.clearCredentials(scope: firstScope);

      expect(await storage.readCredentials(scope: firstScope), isNull);
      expect(await storage.readCredentials(scope: secondScope), isNotNull);
    });

    test('reads credentials from the legacy key name', () async {
      final store = MemoryVoiceCredentialSecretStore();
      final storage = SecureVoiceCredentialsStorage(secretStore: store);
      const daemon = 'https://daemon.example.com';
      const userId = 'usr_workspace';
      final daemonKey = base64Url.encode(utf8.encode(daemon));
      final userKey = base64Url.encode(utf8.encode(userId));

      await store.write(
        key: 'agent_workspace.voice.doubao.$daemonKey.$userKey',
        value:
            '{"appId":"app-123","accessToken":"token-abc","resourceId":"volc.bigasr.sauc.duration","websocketUrl":"wss://openspeech.bytedance.com/api/v3/sauc/bigmodel"}',
      );

      final restored = await storage.readCredentials(
        scope: VoiceCredentialScope(
          daemonUrl: Uri.parse(daemon),
          userId: userId,
        ),
      );

      expect(restored, isNotNull);
      expect(restored!.appId, 'app-123');
      expect(restored.accessToken, 'token-abc');
    });
  });
}

class MemoryVoiceCredentialSecretStore implements VoiceCredentialSecretStore {
  final _values = <String, String>{};

  @override
  Future<String?> read({required String key}) async => _values[key];

  @override
  Future<void> write({required String key, required String value}) async {
    _values[key] = value;
  }

  @override
  Future<void> delete({required String key}) async {
    _values.remove(key);
  }
}
