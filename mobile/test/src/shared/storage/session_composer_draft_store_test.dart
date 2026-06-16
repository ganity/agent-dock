import 'package:agent_dock_mobile/src/shared/storage/session_composer_draft_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MemorySessionComposerDraftStore', () {
    test('saves and restores text and uploaded attachments per session scope', () {
      final store = MemorySessionComposerDraftStore();
      final scope = SessionComposerDraftScope(
        daemonUrl: Uri.parse('https://daemon.example.com'),
        userId: 'usr_workspace',
        sessionId: 'sess_1',
      );

      store.saveDraft(
        scope: scope,
        draft: const SessionComposerDraft(
          text: 'keep this draft',
          attachments: [
            SessionComposerDraftAttachment(
              filename: 'screenshot.png',
              contentType: 'image/png',
              bytes: [1, 2, 3, 4],
              path: '/tmp/attachments/sess_1/screenshot.png',
            ),
          ],
        ),
      );

      final restored = store.readDraft(scope: scope);
      expect(restored, isNotNull);
      expect(restored!.text, 'keep this draft');
      expect(restored.attachments, hasLength(1));
      expect(restored.attachments.single.filename, 'screenshot.png');
      expect(
        restored.attachments.single.path,
        '/tmp/attachments/sess_1/screenshot.png',
      );
    });
  });
}
