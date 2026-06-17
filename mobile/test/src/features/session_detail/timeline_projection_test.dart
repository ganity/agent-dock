import 'package:agent_dock_mobile/src/features/session_detail/timeline_projection.dart';
import 'package:agent_dock_mobile/src/shared/api/daemon_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('projects user assistant attached and useful status events', () {
    final items = projectTimelineItems([
      const SessionEvent(
        id: 1,
        eventType: 'user.message',
        payload: {'text': 'user prompt'},
      ),
      const SessionEvent(
        id: 2,
        eventType: 'assistant.message',
        payload: {'text': 'assistant reply'},
      ),
      const SessionEvent(
        id: 3,
        eventType: 'session.attached',
        payload: {'runtimeSessionId': 'thread-abc'},
      ),
      const SessionEvent(
        id: 4,
        eventType: 'session.status.changed',
        payload: {'status': 'running'},
      ),
      const SessionEvent(
        id: 5,
        eventType: 'session.status.changed',
        payload: {'status': 'idle'},
      ),
    ]);

    expect(items, hasLength(4));
    expect(items[0], isA<UserMessageItem>());
    expect((items[0] as UserMessageItem).text, 'user prompt');
    expect(items[1], isA<AssistantMessageItem>());
    expect((items[1] as AssistantMessageItem).text, 'assistant reply');
    expect(items[2], isA<AttachedSessionItem>());
    expect(items[3], isA<StatusSummaryItem>());
    expect((items[3] as StatusSummaryItem).status, 'idle');
  });

  test('projects active and idle session status summaries', () {
    final items = projectTimelineItems([
      const SessionEvent(
        id: 1,
        eventType: 'session.status.changed',
        payload: {'status': 'active'},
      ),
      const SessionEvent(
        id: 2,
        eventType: 'user.message',
        payload: {'text': 'continue'},
      ),
      const SessionEvent(
        id: 3,
        eventType: 'session.status.changed',
        payload: {'status': 'idle'},
      ),
    ]);

    expect(items, hasLength(3));
    expect(items[0], isA<StatusSummaryItem>());
    expect((items[0] as StatusSummaryItem).status, 'active');
    expect(items[1], isA<UserMessageItem>());
    expect(items[2], isA<StatusSummaryItem>());
    expect((items[2] as StatusSummaryItem).status, 'idle');
  });

  test('projects turn error messages instead of opaque system error statuses', () {
    final items = projectTimelineItems([
      const SessionEvent(
        id: 1,
        eventType: 'session.status.changed',
        payload: {
          'status': {'type': 'systemError'},
        },
      ),
      const SessionEvent(
        id: 2,
        eventType: 'session.status.changed',
        payload: {
          'turn': {
            'status': 'failed',
            'error': {
              'message':
                  'Selected model is at capacity. Please try a different model.',
              'codexErrorInfo': 'serverOverloaded',
            },
          },
        },
      ),
    ]);

    expect(items, hasLength(1));
    expect(items.single, isA<StatusSummaryItem>());
    expect(
      (items.single as StatusSummaryItem).status,
      'Selected model is at capacity. Please try a different model.',
    );
  });

  test('keeps image-only user messages in the projected timeline', () {
    final items = projectTimelineItems([
      const SessionEvent(
        id: 1,
        eventType: 'user.message',
        payload: {
          'text': '',
          'imagePaths': ['/tmp/attachments/sess-1/screenshot.png'],
        },
      ),
    ]);

    expect(items, hasLength(1));
    expect(items.single, isA<UserMessageItem>());
    final item = items.single as UserMessageItem;
    expect(item.text, isEmpty);
    expect(item.imagePaths, ['/tmp/attachments/sess-1/screenshot.png']);
  });

  test('projects unknown events only when payload is useful', () {
    final items = projectTimelineItems([
      const SessionEvent(
        id: 1,
        eventType: 'tool.unknown',
        payload: {'text': 'debug payload'},
      ),
      const SessionEvent(id: 2, eventType: 'tool.empty', payload: {}),
    ]);

    expect(items, hasLength(1));
    expect(items.single, isA<UnknownEventItem>());
    expect((items.single as UnknownEventItem).eventType, 'tool.unknown');
  });

  test('coalesces adjacent assistant messages into one item', () {
    final items = projectTimelineItems([
      const SessionEvent(
        id: 1,
        eventType: 'assistant.message',
        payload: {'text': 'line one'},
      ),
      const SessionEvent(
        id: 2,
        eventType: 'assistant.message',
        payload: {'text': 'line two'},
      ),
    ]);

    expect(items, hasLength(1));
    expect(items.single, isA<AssistantMessageItem>());
    final item = items.single as AssistantMessageItem;
    expect(item.key, 'assistant:1');
    expect(item.text, 'line oneline two');
  });

  test('filters known internal assistant system messages', () {
    final items = projectTimelineItems([
      const SessionEvent(
        id: 1,
        eventType: 'assistant.message',
        payload: {'text': 'You are Codex, a coding agent based on GPT-5.'},
      ),
      const SessionEvent(
        id: 2,
        eventType: 'assistant.message',
        payload: {'text': 'visible answer'},
      ),
    ]);

    expect(items, hasLength(1));
    expect(items.single, isA<AssistantMessageItem>());
    expect((items.single as AssistantMessageItem).text, 'visible answer');
  });

  test('coalesces adjacent thinking deltas into one reasoning item', () {
    final items = projectTimelineItems([
      const SessionEvent(
        id: 1,
        eventType: 'assistant.thinking.delta',
        payload: {'text': 'plan first'},
      ),
      const SessionEvent(
        id: 2,
        eventType: 'assistant.thinking.delta',
        payload: {'text': 'then execute'},
      ),
    ]);

    expect(items, hasLength(1));
    expect(items.single, isA<ThinkingItem>());
    expect((items.single as ThinkingItem).text, 'plan first\nthen execute');
  });

  test('projects completed command execution tool calls', () {
    final items = projectTimelineItems([
      const SessionEvent(
        id: 1,
        eventType: 'tool.call.completed',
        payload: {
          'item': {
            'id': 'cmd-1',
            'type': 'commandExecution',
            'command': '/bin/zsh -lc npm test',
            'cwd': '/tmp/workspace',
            'status': 'completed',
            'commandActions': [
              {'type': 'runCommand', 'command': 'npm test', 'path': null},
            ],
            'aggregatedOutput': 'PASS src/app.test.ts\n',
            'exitCode': 0,
            'durationMs': 42,
          },
        },
      ),
    ]);

    expect(items, hasLength(1));
    expect(items.single, isA<ToolCallItem>());
    final item = items.single as ToolCallItem;
    expect(item.toolName, 'shell');
    expect(item.label, 'npm test');
    expect(item.output, 'PASS src/app.test.ts');
    expect(item.status, 'completed');
  });

  test('merges started and completed command execution lifecycle events', () {
    final items = projectTimelineItems([
      const SessionEvent(
        id: 1,
        eventType: 'tool.call.started',
        payload: {
          'item': {
            'id': 'cmd-1',
            'type': 'commandExecution',
            'command': '/bin/zsh -lc npm test',
            'status': 'inProgress',
          },
        },
      ),
      const SessionEvent(
        id: 2,
        eventType: 'tool.call.completed',
        payload: {
          'item': {
            'id': 'cmd-1',
            'type': 'commandExecution',
            'command': '/bin/zsh -lc npm test',
            'status': 'completed',
            'aggregatedOutput': 'PASS\n',
            'exitCode': 0,
          },
        },
      ),
    ]);

    expect(items, hasLength(1));
    expect(items.single, isA<ToolCallItem>());
    final item = items.single as ToolCallItem;
    expect(item.key, 'commandExecution:cmd-1');
    expect(item.label, 'npm test');
    expect(item.status, 'completed');
    expect(item.output, 'PASS');
  });

  test('projects completed file changes with patch diffs', () {
    final items = projectTimelineItems([
      const SessionEvent(
        id: 1,
        eventType: 'tool.call.completed',
        payload: {
          'item': {
            'id': 'patch-1',
            'type': 'fileChange',
            'status': 'completed',
            'changes': [
              {
                'path': 'src/app.ts',
                'kind': {'type': 'update', 'move_path': null},
                'diff': '@@\n-old\n+new\n',
              },
            ],
          },
        },
      ),
    ]);

    expect(items, hasLength(1));
    expect(items.single, isA<FileChangeItem>());
    final item = items.single as FileChangeItem;
    expect(item.key, 'fileChange:patch-1');
    expect(item.files, ['src/app.ts']);
    expect(item.summary, 'Edited src/app.ts');
    expect(item.fileKinds, ['updated']);
    expect(item.diffs, ['@@\n-old\n+new']);
    expect(item.status, 'completed');
  });

  test(
    'projects rename file changes as explicit source to destination paths',
    () {
      final items = projectTimelineItems([
        const SessionEvent(
          id: 1,
          eventType: 'tool.call.completed',
          payload: {
            'item': {
              'id': 'patch-1',
              'type': 'fileChange',
              'status': 'completed',
              'changes': [
                {
                  'path': 'src/old_name.dart',
                  'kind': {'type': 'rename', 'move_path': 'src/new_name.dart'},
                  'diff': '',
                },
              ],
            },
          },
        ),
      ]);

      expect(items, hasLength(1));
      expect(items.single, isA<FileChangeItem>());
      final item = items.single as FileChangeItem;
      expect(item.files, ['src/old_name.dart -> src/new_name.dart']);
      expect(item.fileKinds, ['renamed']);
      expect(item.summary, 'Edited src/old_name.dart -> src/new_name.dart');
    },
  );

  test('projects file.change.reported as a metadata-only file change item', () {
    final items = projectTimelineItems([
      const SessionEvent(
        id: 1,
        eventType: 'file.change.reported',
        payload: {
          'files': ['src/app.ts', 'src/lib.rs'],
        },
      ),
    ]);

    expect(items, hasLength(1));
    expect(items.single, isA<FileChangeItem>());
    final item = items.single as FileChangeItem;
    expect(item.files, ['src/app.ts', 'src/lib.rs']);
    expect(item.summary, 'Edited 2 files');
    expect(item.diffs, isNull);
    expect(item.status, isNull);
  });

  test('merges started and completed file change lifecycle events', () {
    final items = projectTimelineItems([
      const SessionEvent(
        id: 1,
        eventType: 'tool.call.started',
        payload: {
          'item': {
            'id': 'patch-1',
            'type': 'fileChange',
            'status': 'inProgress',
            'changes': [
              {
                'path': 'src/app.ts',
                'kind': {'type': 'update', 'move_path': null},
                'diff': '',
              },
            ],
          },
        },
      ),
      const SessionEvent(
        id: 2,
        eventType: 'tool.call.completed',
        payload: {
          'item': {
            'id': 'patch-1',
            'type': 'fileChange',
            'status': 'completed',
            'changes': [
              {
                'path': 'src/app.ts',
                'kind': {'type': 'update', 'move_path': null},
                'diff': '@@\n-old\n+new\n',
              },
            ],
          },
        },
      ),
    ]);

    expect(items, hasLength(1));
    expect(items.single, isA<FileChangeItem>());
    final item = items.single as FileChangeItem;
    expect(item.files, ['src/app.ts']);
    expect(item.summary, 'Edited src/app.ts');
    expect(item.fileKinds, ['updated']);
    expect(item.diffs, ['@@\n-old\n+new']);
    expect(item.status, 'completed');
  });

  test(
    'aggregates adjacent undetailed tool lifecycle events into activity',
    () {
      final items = projectTimelineItems([
        const SessionEvent(
          id: 1,
          eventType: 'tool.call.completed',
          payload: {
            'item': {'id': 'tool-1', 'type': 'commandExecution'},
          },
        ),
        const SessionEvent(
          id: 2,
          eventType: 'tool.call.completed',
          payload: {
            'item': {'id': 'tool-2', 'type': 'commandExecution'},
          },
        ),
      ]);

      expect(items, hasLength(1));
      expect(items.single, isA<ActivitySummaryItem>());
      final item = items.single as ActivitySummaryItem;
      expect(item.groups, hasLength(1));
      expect(item.groups.single.itemType, 'commandExecution');
      expect(item.groups.single.status, 'completed');
      expect(item.groups.single.count, 2);
    },
  );

  test('flushes activity summaries before following visible items', () {
    final items = projectTimelineItems([
      const SessionEvent(
        id: 1,
        eventType: 'tool.call.started',
        payload: {
          'item': {'id': 'tool-1', 'type': 'commandExecution'},
        },
      ),
      const SessionEvent(
        id: 2,
        eventType: 'assistant.message',
        payload: {'text': 'done'},
      ),
    ]);

    expect(items, hasLength(2));
    expect(items.first, isA<ActivitySummaryItem>());
    expect(items.last, isA<AssistantMessageItem>());
  });
}
