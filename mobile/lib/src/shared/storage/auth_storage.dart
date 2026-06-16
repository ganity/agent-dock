import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class AuthProfile {
  const AuthProfile({
    required this.daemonUrl,
    required this.token,
    required this.userId,
  });

  final Uri daemonUrl;
  final String token;
  final String userId;
}

class SessionStorageScope {
  const SessionStorageScope({required this.daemonUrl, required this.userId});

  final Uri daemonUrl;
  final String userId;
}

abstract class AuthStorage {
  Future<AuthProfile?> readProfile();

  Future<Uri?> readDaemonUrl();

  Future<void> saveDaemonUrl(Uri daemonUrl);

  Future<void> saveProfile(AuthProfile profile);

  Future<String?> readLastSelectedSessionId({
    required SessionStorageScope scope,
  });

  Future<void> saveLastSelectedSessionId({
    required SessionStorageScope scope,
    required String sessionId,
  });

  Future<void> clearLastSelectedSessionId({required SessionStorageScope scope});

  Future<void> clearProfile();
}

abstract class AuthSecretStore {
  Future<String?> read({required String key});

  Future<void> write({required String key, required String value});

  Future<void> delete({required String key});
}

class FlutterSecureAuthSecretStore implements AuthSecretStore {
  FlutterSecureAuthSecretStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read({required String key}) {
    return _storage.read(key: key);
  }

  @override
  Future<void> write({required String key, required String value}) {
    return _storage.write(key: key, value: value);
  }

  @override
  Future<void> delete({required String key}) {
    return _storage.delete(key: key);
  }
}

class SecureAuthStorage implements AuthStorage {
  SecureAuthStorage({AuthSecretStore? secretStore})
    : _secretStore = secretStore ?? FlutterSecureAuthSecretStore();

  static const _daemonUrlKey = 'agent_dock.daemon_url';
  static const _legacyDaemonUrlKey = 'agent_workspace.daemon_url';
  static const _tokenKey = 'agent_dock.auth_token';
  static const _legacyTokenKey = 'agent_workspace.auth_token';
  static const _userIdKey = 'agent_dock.user_id';
  static const _legacyUserIdKey = 'agent_workspace.user_id';

  final AuthSecretStore _secretStore;

  @override
  Future<AuthProfile?> readProfile() async {
    final token = await _readFirstAvailable([_tokenKey, _legacyTokenKey]);
    final userId = await _readFirstAvailable([_userIdKey, _legacyUserIdKey]);
    final daemonUrl = await readDaemonUrl();
    if (daemonUrl == null || token == null || userId == null) {
      return null;
    }

    return AuthProfile(
      daemonUrl: daemonUrl,
      token: token,
      userId: userId,
    );
  }

  @override
  Future<Uri?> readDaemonUrl() async {
    final daemonUrl = await _readFirstAvailable([_daemonUrlKey, _legacyDaemonUrlKey]);
    if (daemonUrl == null) {
      return null;
    }
    return Uri.parse(daemonUrl);
  }

  @override
  Future<void> saveDaemonUrl(Uri daemonUrl) async {
    await _secretStore.write(key: _daemonUrlKey, value: daemonUrl.toString());
  }

  @override
  Future<void> saveProfile(AuthProfile profile) async {
    await saveDaemonUrl(profile.daemonUrl);
    await _secretStore.write(key: _tokenKey, value: profile.token);
    await _secretStore.write(key: _userIdKey, value: profile.userId);
  }

  @override
  Future<String?> readLastSelectedSessionId({
    required SessionStorageScope scope,
  }) async {
    return _readFirstAvailable([
      _lastSelectedSessionKey(scope),
      _legacyLastSelectedSessionKey(scope),
    ]);
  }

  @override
  Future<void> saveLastSelectedSessionId({
    required SessionStorageScope scope,
    required String sessionId,
  }) {
    return _secretStore.write(
      key: _lastSelectedSessionKey(scope),
      value: sessionId,
    );
  }

  @override
  Future<void> clearLastSelectedSessionId({required SessionStorageScope scope}) {
    return _secretStore.delete(key: _lastSelectedSessionKey(scope));
  }

  @override
  Future<void> clearProfile() async {
    await _secretStore.delete(key: _tokenKey);
    await _secretStore.delete(key: _userIdKey);
  }

  String _lastSelectedSessionKey(SessionStorageScope scope) {
    final daemon = base64Url.encode(utf8.encode(scope.daemonUrl.toString()));
    final user = base64Url.encode(utf8.encode(scope.userId));
    return 'agent_dock.last_session.$daemon.$user';
  }

  String _legacyLastSelectedSessionKey(SessionStorageScope scope) {
    final daemon = base64Url.encode(utf8.encode(scope.daemonUrl.toString()));
    final user = base64Url.encode(utf8.encode(scope.userId));
    return 'agent_workspace.last_session.$daemon.$user';
  }

  Future<String?> _readFirstAvailable(List<String> keys) async {
    for (final key in keys) {
      final value = await _secretStore.read(key: key);
      if (value != null) {
        return value;
      }
    }
    return null;
  }
}
