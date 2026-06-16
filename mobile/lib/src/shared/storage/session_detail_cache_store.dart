import '../api/daemon_client.dart';

class SessionDetailCacheScope {
  const SessionDetailCacheScope({
    required this.daemonUrl,
    required this.userId,
    required this.sessionId,
  });

  final Uri daemonUrl;
  final String userId;
  final String sessionId;
}

class SessionDetailCacheEntry {
  const SessionDetailCacheEntry({
    required this.events,
    required this.hasMoreHistory,
    required this.expandedItemKeys,
    required this.autoExpandedFailedToolItemKeys,
    required this.scrollOffset,
  });

  final List<SessionEvent> events;
  final bool hasMoreHistory;
  final Set<String> expandedItemKeys;
  final Set<String> autoExpandedFailedToolItemKeys;
  final double scrollOffset;
}

abstract class SessionDetailCacheStore {
  SessionDetailCacheEntry? readCache({required SessionDetailCacheScope scope});

  void saveCache({
    required SessionDetailCacheScope scope,
    required SessionDetailCacheEntry entry,
  });

  void clearCache({required SessionDetailCacheScope scope});

  void clearUserCaches({required Uri daemonUrl, required String userId});
}

class MemorySessionDetailCacheStore implements SessionDetailCacheStore {
  final _entries = <_SessionDetailCacheKey, SessionDetailCacheEntry>{};

  @override
  SessionDetailCacheEntry? readCache({required SessionDetailCacheScope scope}) {
    return _entries[_SessionDetailCacheKey.fromScope(scope)];
  }

  @override
  void saveCache({
    required SessionDetailCacheScope scope,
    required SessionDetailCacheEntry entry,
  }) {
    _entries[_SessionDetailCacheKey.fromScope(scope)] = SessionDetailCacheEntry(
      events: List<SessionEvent>.from(entry.events),
      hasMoreHistory: entry.hasMoreHistory,
      expandedItemKeys: Set<String>.from(entry.expandedItemKeys),
      autoExpandedFailedToolItemKeys: Set<String>.from(
        entry.autoExpandedFailedToolItemKeys,
      ),
      scrollOffset: entry.scrollOffset,
    );
  }

  @override
  void clearCache({required SessionDetailCacheScope scope}) {
    _entries.remove(_SessionDetailCacheKey.fromScope(scope));
  }

  @override
  void clearUserCaches({required Uri daemonUrl, required String userId}) {
    _entries.removeWhere((key, _) {
      return key.daemonUrl == daemonUrl && key.userId == userId;
    });
  }
}

class _SessionDetailCacheKey {
  const _SessionDetailCacheKey({
    required this.daemonUrl,
    required this.userId,
    required this.sessionId,
  });

  factory _SessionDetailCacheKey.fromScope(SessionDetailCacheScope scope) {
    return _SessionDetailCacheKey(
      daemonUrl: scope.daemonUrl,
      userId: scope.userId,
      sessionId: scope.sessionId,
    );
  }

  final Uri daemonUrl;
  final String userId;
  final String sessionId;

  @override
  bool operator ==(Object other) {
    return other is _SessionDetailCacheKey &&
        other.daemonUrl == daemonUrl &&
        other.userId == userId &&
        other.sessionId == sessionId;
  }

  @override
  int get hashCode => Object.hash(daemonUrl, userId, sessionId);
}
