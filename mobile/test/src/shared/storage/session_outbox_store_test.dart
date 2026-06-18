import 'package:agent_dock_mobile/src/shared/storage/session_outbox_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MemorySessionOutboxStore', () {
    test('saves and lists queued outgoing messages per session scope', () {
      final store = MemorySessionOutboxStore();
      final scope = SessionOutboxScope(
        daemonUrl: Uri.parse('https://daemon.example.com'),
        userId: 'usr_workspace',
        sessionId: 'sess_1',
      );

      store.saveEntry(
        scope: scope,
        entry: const SessionOutboxEntry(
          clientMessageId: 'cli_1',
          text: 'hello',
          imagePaths: <String>[],
          createdAtMillis: 1,
          status: SessionOutboxStatus.sending,
        ),
      );

      final entries = store.listEntries(scope: scope);
      expect(entries, hasLength(1));
      expect(entries.single.clientMessageId, 'cli_1');
      expect(entries.single.status, SessionOutboxStatus.sending);
    });
  });
}
