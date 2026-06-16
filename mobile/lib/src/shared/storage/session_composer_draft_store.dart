class SessionComposerDraft {
  const SessionComposerDraft({
    required this.text,
    this.attachments = const <SessionComposerDraftAttachment>[],
  });

  final String text;
  final List<SessionComposerDraftAttachment> attachments;
}

class SessionComposerDraftAttachment {
  const SessionComposerDraftAttachment({
    required this.filename,
    required this.contentType,
    required this.bytes,
    required this.path,
  });

  final String filename;
  final String contentType;
  final List<int> bytes;
  final String path;
}

class SessionComposerDraftScope {
  const SessionComposerDraftScope({
    required this.daemonUrl,
    required this.userId,
    required this.sessionId,
  });

  final Uri daemonUrl;
  final String userId;
  final String sessionId;
}

abstract class SessionComposerDraftStore {
  SessionComposerDraft? readDraft({required SessionComposerDraftScope scope});

  void saveDraft({
    required SessionComposerDraftScope scope,
    required SessionComposerDraft draft,
  });

  void clearDraft({required SessionComposerDraftScope scope});

  void clearUserDrafts({required Uri daemonUrl, required String userId});
}

class MemorySessionComposerDraftStore implements SessionComposerDraftStore {
  final _drafts = <_SessionComposerDraftKey, SessionComposerDraft>{};

  @override
  SessionComposerDraft? readDraft({required SessionComposerDraftScope scope}) {
    return _drafts[_SessionComposerDraftKey.fromScope(scope)];
  }

  @override
  void saveDraft({
    required SessionComposerDraftScope scope,
    required SessionComposerDraft draft,
  }) {
    _drafts[_SessionComposerDraftKey.fromScope(scope)] = draft;
  }

  @override
  void clearDraft({required SessionComposerDraftScope scope}) {
    _drafts.remove(_SessionComposerDraftKey.fromScope(scope));
  }

  @override
  void clearUserDrafts({required Uri daemonUrl, required String userId}) {
    _drafts.removeWhere((key, _) {
      return key.daemonUrl == daemonUrl && key.userId == userId;
    });
  }
}

class _SessionComposerDraftKey {
  const _SessionComposerDraftKey({
    required this.daemonUrl,
    required this.userId,
    required this.sessionId,
  });

  factory _SessionComposerDraftKey.fromScope(SessionComposerDraftScope scope) {
    return _SessionComposerDraftKey(
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
    return other is _SessionComposerDraftKey &&
        other.daemonUrl == daemonUrl &&
        other.userId == userId &&
        other.sessionId == sessionId;
  }

  @override
  int get hashCode => Object.hash(daemonUrl, userId, sessionId);
}
