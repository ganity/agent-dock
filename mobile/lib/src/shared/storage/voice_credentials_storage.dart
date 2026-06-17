import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class VoiceCredentialScope {
  const VoiceCredentialScope({required this.daemonUrl, required this.userId});

  final Uri daemonUrl;
  final String userId;
}

class DoubaoVoiceCredentials {
  const DoubaoVoiceCredentials({
    required this.appId,
    required this.accessToken,
    required this.resourceId,
    required this.websocketUrl,
  });

  factory DoubaoVoiceCredentials.fromJson(Map<String, Object?> json) {
    return DoubaoVoiceCredentials(
      appId: json['appId'] as String,
      accessToken: json['accessToken'] as String,
      resourceId: json['resourceId'] as String,
      websocketUrl: json['websocketUrl'] as String,
    );
  }

  final String appId;
  final String accessToken;
  final String resourceId;
  final String websocketUrl;

  bool get isUsable {
    final normalizedAppId = appId.trim().toLowerCase();
    final normalizedAccessToken = accessToken.trim().toLowerCase();
    final normalizedResourceId = resourceId.trim();
    final normalizedWebsocketUrl = websocketUrl.trim();
    if (normalizedAppId.isEmpty ||
        normalizedAccessToken.isEmpty ||
        normalizedResourceId.isEmpty ||
        normalizedWebsocketUrl.isEmpty) {
      return false;
    }
    if (normalizedAppId == 'your-app-id' ||
        normalizedAccessToken == 'your-access-token') {
      return false;
    }
    return true;
  }

  Map<String, Object?> toJson() {
    return {
      'appId': appId,
      'accessToken': accessToken,
      'resourceId': resourceId,
      'websocketUrl': websocketUrl,
    };
  }
}

abstract class VoiceCredentialsStorage {
  Future<DoubaoVoiceCredentials?> readCredentials({
    required VoiceCredentialScope scope,
  });

  Future<void> saveCredentials({
    required VoiceCredentialScope scope,
    required DoubaoVoiceCredentials credentials,
  });

  Future<void> clearCredentials({required VoiceCredentialScope scope});
}

abstract class VoiceCredentialSecretStore {
  Future<String?> read({required String key});

  Future<void> write({required String key, required String value});

  Future<void> delete({required String key});
}

class FlutterSecureVoiceCredentialSecretStore
    implements VoiceCredentialSecretStore {
  FlutterSecureVoiceCredentialSecretStore({FlutterSecureStorage? storage})
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

class SecureVoiceCredentialsStorage implements VoiceCredentialsStorage {
  SecureVoiceCredentialsStorage({VoiceCredentialSecretStore? secretStore})
    : _secretStore = secretStore ?? FlutterSecureVoiceCredentialSecretStore();

  final VoiceCredentialSecretStore _secretStore;

  @override
  Future<DoubaoVoiceCredentials?> readCredentials({
    required VoiceCredentialScope scope,
  }) async {
    final value = await _readFirstAvailable([
      _key(scope),
      _legacyKey(scope),
    ]);
    if (value == null) {
      return null;
    }

    return DoubaoVoiceCredentials.fromJson(_decodeObject(value));
  }

  @override
  Future<void> saveCredentials({
    required VoiceCredentialScope scope,
    required DoubaoVoiceCredentials credentials,
  }) {
    return _secretStore.write(
      key: _key(scope),
      value: jsonEncode(credentials.toJson()),
    );
  }

  @override
  Future<void> clearCredentials({required VoiceCredentialScope scope}) {
    return _secretStore.delete(key: _key(scope));
  }

  String _key(VoiceCredentialScope scope) {
    final daemon = base64Url.encode(utf8.encode(scope.daemonUrl.toString()));
    final user = base64Url.encode(utf8.encode(scope.userId));
    return 'agent_dock.voice.doubao.$daemon.$user';
  }

  String _legacyKey(VoiceCredentialScope scope) {
    final daemon = base64Url.encode(utf8.encode(scope.daemonUrl.toString()));
    final user = base64Url.encode(utf8.encode(scope.userId));
    return 'agent_workspace.voice.doubao.$daemon.$user';
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

Map<String, Object?> _decodeObject(String value) {
  final decoded = jsonDecode(value);
  if (decoded is Map<String, Object?>) {
    return decoded;
  }
  throw const FormatException('Expected JSON object');
}
