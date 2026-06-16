import 'dart:convert';

import 'package:agent_dock_mobile/src/shared/storage/auth_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AuthStorage session scope', () {
    test('saves and reads last selected session scoped by daemon and user', () async {
      final store = MemoryAuthSecretStore();
      final storage = SecureAuthStorage(secretStore: store);
      final profile = AuthProfile(
        daemonUrl: Uri.parse('https://daemon.example.com'),
        token: 'tok_workspace',
        userId: 'usr_workspace',
      );

      await storage.saveProfile(profile);
      await storage.saveLastSelectedSessionId(
        scope: SessionStorageScope(
          daemonUrl: profile.daemonUrl,
          userId: profile.userId,
        ),
        sessionId: 'sess_123',
      );

      final restored = await storage.readLastSelectedSessionId(
        scope: SessionStorageScope(
          daemonUrl: profile.daemonUrl,
          userId: profile.userId,
        ),
      );

      expect(restored, 'sess_123');
    });

    test('writes profile and last selected session under agent_dock key names', () async {
      final store = MemoryAuthSecretStore();
      final storage = SecureAuthStorage(secretStore: store);
      final profile = AuthProfile(
        daemonUrl: Uri.parse('https://daemon.example.com'),
        token: 'tok_workspace',
        userId: 'usr_workspace',
      );
      final daemonKey = base64Url.encode(
        utf8.encode(profile.daemonUrl.toString()),
      );
      final userKey = base64Url.encode(utf8.encode(profile.userId));

      await storage.saveProfile(profile);
      await storage.saveLastSelectedSessionId(
        scope: SessionStorageScope(
          daemonUrl: profile.daemonUrl,
          userId: profile.userId,
        ),
        sessionId: 'sess_123',
      );

      expect(
        await store.read(key: 'agent_dock.daemon_url'),
        'https://daemon.example.com',
      );
      expect(await store.read(key: 'agent_dock.auth_token'), 'tok_workspace');
      expect(await store.read(key: 'agent_dock.user_id'), 'usr_workspace');
      expect(
        await store.read(
          key: 'agent_dock.last_session.$daemonKey.$userKey',
        ),
        'sess_123',
      );
    });

    test('does not return another user session id on the same daemon', () async {
      final store = MemoryAuthSecretStore();
      final storage = SecureAuthStorage(secretStore: store);

      await storage.saveLastSelectedSessionId(
        scope: SessionStorageScope(
          daemonUrl: Uri.parse('https://daemon.example.com'),
          userId: 'usr_workspace',
        ),
        sessionId: 'sess_123',
      );

      final restored = await storage.readLastSelectedSessionId(
        scope: SessionStorageScope(
          daemonUrl: Uri.parse('https://daemon.example.com'),
          userId: 'usr_other',
        ),
      );

      expect(restored, isNull);
    });

    test(
      'clearProfile keeps daemon url and preserves scoped last selected session',
      () async {
      final store = MemoryAuthSecretStore();
      final storage = SecureAuthStorage(secretStore: store);
      final firstProfile = AuthProfile(
        daemonUrl: Uri.parse('https://daemon.example.com'),
        token: 'tok_workspace',
        userId: 'usr_workspace',
      );
      final secondScope = SessionStorageScope(
        daemonUrl: Uri.parse('https://saved.example.com'),
        userId: 'usr_workspace',
      );

      await storage.saveProfile(firstProfile);
      await storage.saveLastSelectedSessionId(
        scope: SessionStorageScope(
          daemonUrl: firstProfile.daemonUrl,
          userId: firstProfile.userId,
        ),
        sessionId: 'sess_123',
      );
      await storage.saveLastSelectedSessionId(
        scope: secondScope,
        sessionId: 'sess_other',
      );

      await storage.clearProfile();

      expect(await storage.readDaemonUrl(), firstProfile.daemonUrl);
      expect(await storage.readProfile(), isNull);
      expect(
        await storage.readLastSelectedSessionId(
          scope: SessionStorageScope(
            daemonUrl: firstProfile.daemonUrl,
            userId: firstProfile.userId,
          ),
        ),
        'sess_123',
      );
      expect(
        await storage.readLastSelectedSessionId(scope: secondScope),
        'sess_other',
      );
    });

    test('reads profile and last selected session from legacy key names', () async {
      final store = MemoryAuthSecretStore();
      final storage = SecureAuthStorage(secretStore: store);
      const daemon = 'https://daemon.example.com';
      const userId = 'usr_workspace';
      final daemonKey = base64Url.encode(utf8.encode(daemon));
      final userKey = base64Url.encode(utf8.encode(userId));

      await store.write(
        key: 'agent_workspace.daemon_url',
        value: daemon,
      );
      await store.write(
        key: 'agent_workspace.auth_token',
        value: 'tok_workspace',
      );
      await store.write(
        key: 'agent_workspace.user_id',
        value: userId,
      );
      await store.write(
        key: 'agent_workspace.last_session.$daemonKey.$userKey',
        value: 'sess_legacy',
      );

      final profile = await storage.readProfile();
      final sessionId = await storage.readLastSelectedSessionId(
        scope: SessionStorageScope(
          daemonUrl: Uri.parse(daemon),
          userId: userId,
        ),
      );

      expect(profile, isNotNull);
      expect(profile!.daemonUrl, Uri.parse(daemon));
      expect(profile.token, 'tok_workspace');
      expect(profile.userId, userId);
      expect(sessionId, 'sess_legacy');
    });
  });
}

class MemoryAuthSecretStore implements AuthSecretStore {
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
