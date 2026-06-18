class SessionOutboxScope {
  const SessionOutboxScope({
    required this.daemonUrl,
    required this.userId,
    required this.sessionId,
  });

  final Uri daemonUrl;
  final String userId;
  final String sessionId;
}

enum SessionOutboxStatus { sending, retrying, failedRetryable, sent }

class SessionOutboxEntry {
  const SessionOutboxEntry({
    required this.clientMessageId,
    required this.text,
    required this.imagePaths,
    required this.createdAtMillis,
    required this.status,
  });

  final String clientMessageId;
  final String text;
  final List<String> imagePaths;
  final int createdAtMillis;
  final SessionOutboxStatus status;

  SessionOutboxEntry copyWith({SessionOutboxStatus? status}) {
    return SessionOutboxEntry(
      clientMessageId: clientMessageId,
      text: text,
      imagePaths: List<String>.from(imagePaths),
      createdAtMillis: createdAtMillis,
      status: status ?? this.status,
    );
  }
}

abstract class SessionOutboxStore {
  List<SessionOutboxEntry> listEntries({required SessionOutboxScope scope});

  void saveEntry({
    required SessionOutboxScope scope,
    required SessionOutboxEntry entry,
  });

  void removeEntry({
    required SessionOutboxScope scope,
    required String clientMessageId,
  });
}

class MemorySessionOutboxStore implements SessionOutboxStore {
  final Map<String, List<SessionOutboxEntry>> _entries =
      <String, List<SessionOutboxEntry>>{};

  @override
  List<SessionOutboxEntry> listEntries({required SessionOutboxScope scope}) {
    return List<SessionOutboxEntry>.from(
      _entries[_key(scope)] ?? const <SessionOutboxEntry>[],
    );
  }

  @override
  void saveEntry({
    required SessionOutboxScope scope,
    required SessionOutboxEntry entry,
  }) {
    final key = _key(scope);
    final current = List<SessionOutboxEntry>.from(
      _entries[key] ?? const <SessionOutboxEntry>[],
    );
    current.removeWhere(
      (candidate) => candidate.clientMessageId == entry.clientMessageId,
    );
    current.add(entry);
    current.sort(
      (left, right) => left.createdAtMillis.compareTo(right.createdAtMillis),
    );
    _entries[key] = current;
  }

  @override
  void removeEntry({
    required SessionOutboxScope scope,
    required String clientMessageId,
  }) {
    final key = _key(scope);
    final current = List<SessionOutboxEntry>.from(
      _entries[key] ?? const <SessionOutboxEntry>[],
    );
    current.removeWhere(
      (candidate) => candidate.clientMessageId == clientMessageId,
    );
    _entries[key] = current;
  }

  String _key(SessionOutboxScope scope) {
    return '${scope.daemonUrl}|${scope.userId}|${scope.sessionId}';
  }
}
