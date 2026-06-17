import 'dart:convert';

import '../../shared/api/daemon_client.dart';

const _assistantSystemPrefixes = <String>[
  'You are Codex, a coding agent',
  'You are Claude Code',
  '<environment_context>',
  '<system-reminder>',
  '# AGENTS.md',
  '<INSTRUCTIONS>',
  '<claude-mem-context>',
];

sealed class TimelineItem {
  const TimelineItem();
}

class UserMessageItem extends TimelineItem {
  const UserMessageItem({
    required this.text,
    this.imagePaths = const <String>[],
  });

  final String text;
  final List<String> imagePaths;
}

class AssistantMessageItem extends TimelineItem {
  const AssistantMessageItem({required this.key, required this.text});

  final String key;
  final String text;
}

class ThinkingItem extends TimelineItem {
  const ThinkingItem({required this.key, required this.text});

  final String key;
  final String text;
}

class ToolCallItem extends TimelineItem {
  const ToolCallItem({
    required this.key,
    required this.toolName,
    required this.label,
    required this.summary,
    this.output,
    this.status,
    this.command,
    this.cwd,
    this.exitCode,
    this.durationMs,
  });

  final String key;
  final String toolName;
  final String label;
  final String summary;
  final String? output;
  final String? status;
  final String? command;
  final String? cwd;
  final int? exitCode;
  final int? durationMs;
}

class FileChangeItem extends TimelineItem {
  const FileChangeItem({
    required this.key,
    required this.files,
    required this.summary,
    this.fileKinds = const <String?>[],
    this.diffs,
    this.status,
  });

  final String key;
  final List<String> files;
  final String summary;
  final List<String?> fileKinds;
  final List<String>? diffs;
  final String? status;
}

class ActivitySummaryGroup {
  const ActivitySummaryGroup({
    required this.itemType,
    required this.status,
    required this.count,
  });

  final String itemType;
  final String status;
  final int count;
}

class ActivitySummaryItem extends TimelineItem {
  const ActivitySummaryItem({required this.key, required this.groups});

  final String key;
  final List<ActivitySummaryGroup> groups;
}

class AttachedSessionItem extends TimelineItem {
  const AttachedSessionItem({this.runtimeSessionId});

  final String? runtimeSessionId;
}

class StatusSummaryItem extends TimelineItem {
  const StatusSummaryItem({required this.status});

  final String status;
}

class UnknownEventItem extends TimelineItem {
  const UnknownEventItem({required this.eventType, required this.details});

  final String eventType;
  final String details;
}

List<TimelineItem> projectTimelineItems(List<SessionEvent> events) {
  final items = <TimelineItem>[];
  String? pendingStatus;
  final pendingActivityGroups = <ActivitySummaryGroup>[];
  final lifecycleItemIndexes = <String, int>{};

  void flushStatus() {
    if (pendingStatus case final status?) {
      items.add(StatusSummaryItem(status: status));
      pendingStatus = null;
    }
  }

  void flushActivity() {
    if (pendingActivityGroups.isEmpty) {
      return;
    }
    items.add(
      ActivitySummaryItem(
        key: _activitySummaryKey(pendingActivityGroups),
        groups: List<ActivitySummaryGroup>.unmodifiable(pendingActivityGroups),
      ),
    );
    pendingActivityGroups.clear();
  }

  for (final event in events) {
    final text = event.payload['text'] as String?;
    switch (event.eventType) {
      case 'user.message':
        flushStatus();
        flushActivity();
        final imagePaths = _imagePaths(event.payload);
        final userText = text ?? '';
        if (userText.isNotEmpty || imagePaths.isNotEmpty) {
          items.add(UserMessageItem(text: userText, imagePaths: imagePaths));
        }
      case 'assistant.message':
        flushStatus();
        flushActivity();
        if (text != null &&
            text.isNotEmpty &&
            !_isInternalAssistantText(text)) {
          final previous = items.isEmpty ? null : items.last;
          if (previous is AssistantMessageItem) {
            items[items.length - 1] = AssistantMessageItem(
              key: previous.key,
              text: '${previous.text}$text',
            );
          } else {
            items.add(
              AssistantMessageItem(key: 'assistant:${event.id}', text: text),
            );
          }
        }
      case 'assistant.thinking.delta':
        flushStatus();
        flushActivity();
        if (text != null && text.trim().isNotEmpty) {
          final previous = items.isEmpty ? null : items.last;
          if (previous is ThinkingItem) {
            items[items.length - 1] = ThinkingItem(
              key: previous.key,
              text: '${previous.text}\n$text',
            );
          } else {
            items.add(ThinkingItem(key: 'thinking:${event.id}', text: text));
          }
        }
      case 'file.change.reported':
        flushStatus();
        flushActivity();
        if (_projectReportedFileChangeItem(event.payload) case final item?) {
          items.add(item);
        }
      case 'session.attached':
        flushStatus();
        flushActivity();
        items.add(
          AttachedSessionItem(
            runtimeSessionId: event.payload['runtimeSessionId'] as String?,
          ),
        );
      case 'session.status.changed':
        flushActivity();
        pendingStatus = _usefulStatus(event.payload) ?? pendingStatus;
      case 'tool.call.started':
      case 'tool.call.completed':
        flushStatus();
        final lifecycleKey = _toolLifecycleKey(event);
        final detailedItem = _projectDetailedToolItem(event, lifecycleKey);
        if (detailedItem != null) {
          flushActivity();
          if (lifecycleKey != null &&
              lifecycleItemIndexes.containsKey(lifecycleKey)) {
            final existingIndex = lifecycleItemIndexes[lifecycleKey]!;
            items[existingIndex] = _mergeLifecycleItem(
              items[existingIndex],
              detailedItem,
            );
          } else {
            if (lifecycleKey != null) {
              lifecycleItemIndexes[lifecycleKey] = items.length;
            }
            items.add(detailedItem);
          }
        } else if (_projectActivityGroup(event) case final group?) {
          if (pendingActivityGroups case [..., final last]
              when last.itemType == group.itemType &&
                  last.status == group.status) {
            pendingActivityGroups[pendingActivityGroups.length -
                1] = ActivitySummaryGroup(
              itemType: last.itemType,
              status: last.status,
              count: last.count + group.count,
            );
          } else {
            pendingActivityGroups.add(group);
          }
        } else if (_hasUsefulPayload(event.payload)) {
          flushActivity();
          items.add(
            UnknownEventItem(
              eventType: event.eventType,
              details: _formatPayload(event.payload),
            ),
          );
        }
      default:
        flushStatus();
        flushActivity();
        if (_hasUsefulPayload(event.payload)) {
          items.add(
            UnknownEventItem(
              eventType: event.eventType,
              details: _formatPayload(event.payload),
            ),
          );
        }
    }
  }

  flushStatus();
  flushActivity();
  return items;
}

List<String> _imagePaths(Map<String, Object?> payload) {
  final raw = payload['imagePaths'];
  if (raw is! List<Object?>) {
    return const <String>[];
  }

  return raw.whereType<String>().where((value) => value.isNotEmpty).toList();
}

String? _usefulStatus(Map<String, Object?> payload) {
  if (_turnErrorMessage(payload) case final message?) {
    return message;
  }
  final raw = payload['status'];
  final status = switch (raw) {
    final String value => value,
    final Map<String, Object?> value when value['type'] is String =>
      value['type'] as String,
    _ => null,
  };
  if (status == null || status.isEmpty) {
    return null;
  }
  return switch (status) {
    'running' ||
    'active' ||
    'idle' ||
    'completed' ||
    'failed' ||
    'cancelled' => status,
    _ => null,
  };
}

String? _turnErrorMessage(Map<String, Object?> payload) {
  final turn = _asObject(payload['turn']);
  final error = _asObject(turn['error']);
  final message = error['message'] as String?;
  if (message == null) {
    return null;
  }
  final trimmed = message.trim();
  return trimmed.isEmpty ? null : trimmed;
}

bool _hasUsefulPayload(Map<String, Object?> payload) {
  return payload.isNotEmpty;
}

bool _isInternalAssistantText(String text) {
  final trimmed = text.trimLeft();
  return _assistantSystemPrefixes.any(trimmed.startsWith);
}

TimelineItem? _projectDetailedToolItem(
  SessionEvent event,
  String? lifecycleKey,
) {
  final item = _asObject(event.payload['item']);
  final itemType = item['type'];
  if (itemType == 'commandExecution') {
    final command = item['command'] as String?;
    final commandActions = item['commandActions'];
    final cwd = item['cwd'] as String?;
    final aggregatedOutput = item['aggregatedOutput'] as String?;
    final hasCommandDetails =
        (command != null && command.trim().isNotEmpty) ||
        (commandActions is List<Object?> && commandActions.isNotEmpty) ||
        (cwd != null && cwd.isNotEmpty) ||
        (aggregatedOutput != null && aggregatedOutput.trim().isNotEmpty);
    if (!hasCommandDetails) {
      return null;
    }
    final label = _commandLabel(commandActions, command);
    final output = _trimmed(aggregatedOutput);
    final status =
        (item['status'] as String?) ??
        (event.eventType == 'tool.call.started' ? 'started' : 'completed');
    return ToolCallItem(
      key: lifecycleKey ?? 'commandExecution:${event.id}',
      toolName: 'shell',
      label: label,
      summary: 'Ran $label',
      output: output,
      status: status,
      command: command,
      cwd: cwd,
      exitCode: item['exitCode'] as int?,
      durationMs: item['durationMs'] as int?,
    );
  }

  if (itemType == 'fileChange') {
    final changes = item['changes'];
    if (changes is! List<Object?>) {
      return null;
    }
    final files = <String>[];
    final fileKinds = <String?>[];
    final diffs = <String>[];
    for (final change in changes) {
      final object = _asObject(change);
      if (object['path'] case final String path) {
        files.add(_fileChangePathLabel(path, object['kind']));
        fileKinds.add(_fileChangeKindLabel(object['kind']));
      }
      if (_trimmed(object['diff'] as String?) case final diff?) {
        diffs.add(diff);
      }
    }
    if (files.isEmpty && diffs.isEmpty) {
      return null;
    }
    return FileChangeItem(
      key: lifecycleKey ?? 'fileChange:${event.id}',
      files: files,
      summary: _fileChangeSummary(files),
      fileKinds: fileKinds,
      diffs: diffs.isEmpty ? null : diffs,
      status:
          (item['status'] as String?) ??
          (event.eventType == 'tool.call.started' ? 'started' : 'completed'),
    );
  }

  return null;
}

FileChangeItem? _projectReportedFileChangeItem(Map<String, Object?> payload) {
  final rawFiles = payload['files'];
  if (rawFiles is! List<Object?>) {
    return null;
  }
  final files = rawFiles
      .whereType<String>()
      .where((file) => file.isNotEmpty)
      .toList();
  if (files.isEmpty) {
    return null;
  }
  return FileChangeItem(
    key: 'fileChange:${files.join('|')}',
    files: files,
    summary: _fileChangeSummary(files),
  );
}

ActivitySummaryGroup? _projectActivityGroup(SessionEvent event) {
  final item = _asObject(event.payload['item']);
  final itemType = item['type'] as String?;
  if (itemType == null || itemType.isEmpty) {
    return null;
  }
  return ActivitySummaryGroup(
    itemType: itemType,
    status:
        (item['status'] as String?) ??
        (event.eventType == 'tool.call.started' ? 'started' : 'completed'),
    count: 1,
  );
}

String _activitySummaryKey(List<ActivitySummaryGroup> groups) {
  return 'activity:${groups.map((group) => '${group.itemType}:${group.status}').join('|')}';
}

String? _toolLifecycleKey(SessionEvent event) {
  final item = _asObject(event.payload['item']);
  final itemType = item['type'] as String?;
  final itemId = item['id'] as String?;
  if (itemType == null || itemId == null) {
    return null;
  }
  return '$itemType:$itemId';
}

TimelineItem _mergeLifecycleItem(TimelineItem existing, TimelineItem next) {
  if (existing is ToolCallItem && next is ToolCallItem) {
    return ToolCallItem(
      key: existing.key,
      toolName: next.toolName,
      label: next.label,
      summary: next.summary,
      output: next.output ?? existing.output,
      status: next.status ?? existing.status,
      command: next.command ?? existing.command,
      cwd: next.cwd ?? existing.cwd,
      exitCode: next.exitCode ?? existing.exitCode,
      durationMs: next.durationMs ?? existing.durationMs,
    );
  }
  if (existing is FileChangeItem && next is FileChangeItem) {
    final files = next.files.isNotEmpty ? next.files : existing.files;
    return FileChangeItem(
      key: existing.key,
      files: files,
      summary: _fileChangeSummary(files),
      fileKinds: next.fileKinds.isNotEmpty
          ? next.fileKinds
          : existing.fileKinds,
      diffs: next.diffs ?? existing.diffs,
      status: next.status ?? existing.status,
    );
  }
  return next;
}

Map<String, Object?> _asObject(Object? value) {
  return value is Map<String, Object?> ? value : <String, Object?>{};
}

String _commandLabel(Object? commandActions, String? command) {
  if (commandActions is List<Object?> && commandActions.isNotEmpty) {
    final action = commandActions.first;
    if (action is Map<String, Object?> && action['command'] is String) {
      return action['command'] as String;
    }
  }
  if (command != null && command.isNotEmpty) {
    final trimmed = command.trim();
    return trimmed.startsWith('/bin/zsh -lc ')
        ? trimmed.substring('/bin/zsh -lc '.length)
        : trimmed;
  }
  return 'shell';
}

String? _trimmed(String? value) {
  if (value == null) {
    return null;
  }
  final trimmed = value.trimRight();
  return trimmed.isEmpty ? null : trimmed;
}

String _fileChangePathLabel(String path, Object? kind) {
  if (kind is! Map<String, Object?>) {
    return path;
  }
  final type = kind['type'] as String?;
  final movePath = kind['move_path'] as String?;
  if ((type == 'move' || type == 'rename') &&
      movePath != null &&
      movePath.isNotEmpty) {
    return '$path -> $movePath';
  }
  return path;
}

String? _fileChangeKindLabel(Object? value) {
  if (value is! Map<String, Object?>) {
    return null;
  }
  final type = value['type'] as String?;
  if (type == null || type.isEmpty) {
    return null;
  }
  return switch (type) {
    'update' => 'updated',
    'delete' => 'deleted',
    'create' || 'add' => 'created',
    'move' => 'moved',
    'rename' => 'renamed',
    _ => type,
  };
}

String _fileChangeSummary(List<String> files) {
  if (files.isEmpty) {
    return 'Files changed';
  }
  if (files.length == 1) {
    return 'Edited ${files.first}';
  }
  return 'Edited ${files.length} files';
}

String _formatPayload(Map<String, Object?> payload) {
  return const JsonEncoder.withIndent('  ').convert(payload);
}
