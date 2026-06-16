import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../shared/api/daemon_client.dart';
import '../../shared/external_links/external_link_opener.dart';
import '../../shared/media/image_attachment_picker.dart';
import '../../shared/media/share_attachments.dart';
import '../../shared/storage/session_composer_draft_store.dart';
import '../../shared/storage/session_detail_cache_store.dart';
import '../../shared/voice/voice_input_controller.dart';
import 'timeline_projection.dart';

const _monospaceTextMaxScaleFactor = 1.25;
const _streamForbiddenText = 'You no longer have access to this session.';
const _streamReconnectingText = 'Reconnecting to event stream...';
const _streamStillReconnectingText = 'Still reconnecting...';
const _streamOfflineText = 'Offline. Waiting for network...';
const _streamBannerCollapseDuration = Duration(milliseconds: 160);

enum _ComposerVoiceStatusIndicatorState { none, listening, stopping }

class SessionDetailPage extends StatefulWidget {
  const SessionDetailPage({
    super.key,
    this.api,
    this.daemonUrl,
    this.attachmentPicker,
    this.openExternalLink,
    this.shareAttachments,
    this.voiceInputController,
    this.showDebugTimelineItems,
    this.voice,
    this.token,
    this.session,
    this.currentUserId,
    this.composerDraftStore,
    this.sessionDetailCacheStore,
    this.onDeleteSession,
    this.onUnauthorized,
  });

  final DaemonApi? api;
  final Uri? daemonUrl;
  final ImageAttachmentPicker? attachmentPicker;
  final ExternalLinkOpener? openExternalLink;
  final ShareAttachments? shareAttachments;
  final VoiceInputController? voiceInputController;
  final bool? showDebugTimelineItems;
  final VoiceConfig? voice;
  final String? token;
  final SessionSummary? session;
  final String? currentUserId;
  final SessionComposerDraftStore? composerDraftStore;
  final SessionDetailCacheStore? sessionDetailCacheStore;
  final Future<bool> Function(SessionSummary session)? onDeleteSession;
  final Future<void> Function()? onUnauthorized;

  @override
  State<SessionDetailPage> createState() => _SessionDetailPageState();
}

class _SessionDetailPageState extends State<SessionDetailPage> {
  static const _slashCommands = <String>['/resume', '/model', '\$skills'];
  static const _bottomProximityThreshold = 120.0;
  static const _topHistoryLoadThreshold = 400.0;
  static const _attachmentUploadSuccessStateDuration = Duration(
    milliseconds: 600,
  );
  static const _attachmentRemovalAnimationDuration = Duration(
    milliseconds: 180,
  );
  static const _voiceCancelFadeDuration = Duration(milliseconds: 180);
  static const _eventStreamRetryBaseDelay = Duration(seconds: 1);

  late final Future<SessionSnapshot?> _snapshotFuture;
  final ScrollController _timelineScrollController = ScrollController();
  final TextEditingController _messageController = TextEditingController();
  List<SessionEvent>? _events;
  SessionSnapshot? _cachedSnapshot;
  SessionSummary? _resolvedSessionSummary;
  StreamSubscription<SessionEvent>? _eventSubscription;
  final List<_UploadedAttachment> _attachments = <_UploadedAttachment>[];
  final Map<int, Timer> _attachmentSuccessTimers = <int, Timer>{};
  final Set<int> _removingAttachmentIds = <int>{};
  var _nextAttachmentId = 0;
  final Set<String> _expandedTimelineItemKeys = <String>{};
  final Set<String> _handledAutoExpandedFailedToolItemKeys = <String>{};
  String? _attachmentError;
  String? _sendFailureText;
  String? _voiceStatusText;
  String? _cancelFadingVoiceStatusText;
  String? _streamError;
  String? _collapsingStreamBannerText;
  bool _isEventStreamConnected = false;
  int _eventStreamFailureCount = 0;
  bool _hasMoreHistory = false;
  bool _isSending = false;
  bool _isUploading = false;
  bool _isLoadingOlderEvents = false;
  bool _isConnectingVoice = false;
  bool _isListeningForVoice = false;
  bool _isHandlingUnauthorized = false;
  bool _hasStartedEventStream = false;
  bool _hasAutoScrolledToLatest = false;
  bool _hasRestoredScrollOffset = false;
  bool _isForbiddenSnapshot = false;
  int _pendingNewEventCount = 0;
  bool _hasPendingAssistantStreamUpdate = false;
  int _streamBannerCollapseCount = 0;
  int _sendFailureShakeCount = 0;
  int _composerClearFadeCount = 0;
  int _voiceCancelFadeCount = 0;
  Set<String> _prependedTimelineItemKeys = <String>{};
  bool _voiceRetryAvailable = false;
  _ComposerVoiceStatusIndicatorState _voiceStatusIndicatorState =
      _ComposerVoiceStatusIndicatorState.none;
  _ComposerVoiceStatusIndicatorState _cancelFadingVoiceStatusIndicatorState =
      _ComposerVoiceStatusIndicatorState.none;
  Timer? _eventStreamRetryTimer;
  Timer? _composerClearTimer;
  Timer? _voiceCancelFadeTimer;

  Future<void> _emitSendStartedHaptic() async {
    await HapticFeedback.lightImpact();
  }

  Future<void> _emitSuccessHaptic() async {
    await HapticFeedback.successNotification();
  }

  Future<void> _emitWarningHaptic() async {
    await HapticFeedback.warningNotification();
  }

  Future<void> _emitCopyConfirmedHaptic() async {
    await HapticFeedback.selectionClick();
  }

  SessionSummary? get _sessionSummary => _resolvedSessionSummary ?? widget.session;

  SessionComposerDraftScope? get _draftScope {
    final daemonUrl = widget.daemonUrl;
    final userId = widget.currentUserId;
    final session = widget.session;
    if (daemonUrl == null || userId == null || session == null) {
      return null;
    }
    return SessionComposerDraftScope(
      daemonUrl: daemonUrl,
      userId: userId,
      sessionId: session.id,
    );
  }

  SessionDetailCacheScope? get _detailCacheScope {
    final daemonUrl = widget.daemonUrl;
    final userId = widget.currentUserId;
    final session = widget.session;
    if (daemonUrl == null || userId == null || session == null) {
      return null;
    }
    return SessionDetailCacheScope(
      daemonUrl: daemonUrl,
      userId: userId,
      sessionId: session.id,
    );
  }

  void _toggleTimelineItemExpanded(String key) {
    setState(() {
      if (!_expandedTimelineItemKeys.add(key)) {
        _expandedTimelineItemKeys.remove(key);
      }
      _syncSessionDetailCache();
    });
  }

  Future<void> _copyToClipboard(String text, String label) async {
    await Clipboard.setData(ClipboardData(text: text));
    await _emitCopyConfirmedHaptic();
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$label copied')));
  }

  Future<void> _showSessionDetailsSheet() {
    final session = _sessionSummary;
    if (session == null) {
      return Future<void>.value();
    }
    final daemonUrlHost = widget.daemonUrl?.host;
    final daemonHost = switch ((daemonUrlHost, widget.api)) {
      (final host?, _) when host.isNotEmpty => host,
      (_, DaemonClient(:final baseUrl)) when baseUrl.host.isNotEmpty =>
        baseUrl.host,
      _ => null,
    };
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => _SessionDetailsSheet(
        title: _sessionDisplayTitle(session),
        agentKind: session.agentKind,
        sourceKind: session.sourceKind,
        status: session.status,
        workspacePath: session.workspacePath,
        runtimeSessionId: session.runtimeSessionId,
        daemonHost: daemonHost,
      ),
    );
  }

  Future<void> _handleSessionMenuAction(_SessionDetailMenuAction action) async {
    final session = _sessionSummary;
    if (session == null) {
      return;
    }
    switch (action) {
      case _SessionDetailMenuAction.details:
        await _showSessionDetailsSheet();
      case _SessionDetailMenuAction.copySessionId:
        await _copyToClipboard(session.id, 'Session ID');
      case _SessionDetailMenuAction.copyRuntimeSessionId:
        final runtimeSessionId = session.runtimeSessionId;
        if (runtimeSessionId != null && runtimeSessionId.isNotEmpty) {
          await _copyToClipboard(runtimeSessionId, 'Runtime session ID');
        }
      case _SessionDetailMenuAction.copyWorkspacePath:
        await _copyToClipboard(session.workspacePath, 'Workspace path');
      case _SessionDetailMenuAction.deleteSession:
        await _deleteSessionFromDetail();
    }
  }

  Future<void> _deleteSessionFromDetail() async {
    final session = _sessionSummary;
    final onDeleteSession = widget.onDeleteSession;
    if (session == null || onDeleteSession == null) {
      return;
    }
    final displayTitle = _sessionDisplayTitle(session);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete session'),
        content: Text('Delete $displayTitle?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete session'),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      return;
    }

    var didDelete = false;
    try {
      didDelete = await onDeleteSession(session);
    } on Object catch (error) {
      if (await _handleUnauthorizedRequest(error)) {
        return;
      }
      rethrow;
    }
    if (!mounted || !didDelete) {
      return;
    }
    Navigator.of(context).pop(true);
  }

  bool get _showDebugTimelineItems =>
      widget.showDebugTimelineItems ?? kDebugMode;

  @override
  void initState() {
    super.initState();
    final draftScope = _draftScope;
    final composerDraftStore = widget.composerDraftStore;
    if (draftScope != null && composerDraftStore != null) {
      final savedDraft = composerDraftStore.readDraft(scope: draftScope);
      if (savedDraft != null) {
        if (savedDraft.text.isNotEmpty) {
          _messageController.text = savedDraft.text;
        }
        if (savedDraft.attachments.isNotEmpty) {
          _attachments.addAll(
            savedDraft.attachments.map(
              (attachment) => _UploadedAttachment(
                id: _nextAttachmentId++,
                filename: attachment.filename,
                contentType: attachment.contentType,
                bytes: attachment.bytes,
                status: _AttachmentUploadState.uploaded,
                path: attachment.path,
              ),
            ),
          );
        }
      }
    }
    _messageController.addListener(_handleDraftChanged);
    _timelineScrollController.addListener(_handleTimelineScrollChanged);
    _timelineScrollController.addListener(_maybeLoadOlderEventsFromController);
    final api = widget.api;
    final token = widget.token;
    final session = widget.session;
    final detailCacheStore = widget.sessionDetailCacheStore;
    final detailCacheScope = _detailCacheScope;
    final cachedSession = detailCacheStore != null && detailCacheScope != null
        ? detailCacheStore.readCache(scope: detailCacheScope)
        : null;
    if (cachedSession != null) {
      _events = List<SessionEvent>.from(cachedSession.events);
      _hasMoreHistory = cachedSession.hasMoreHistory;
      _expandedTimelineItemKeys.addAll(cachedSession.expandedItemKeys);
      _handledAutoExpandedFailedToolItemKeys.addAll(
        cachedSession.autoExpandedFailedToolItemKeys,
      );
      _cachedSnapshot = SessionSnapshot(
        id: session!.id,
        title: session.title,
        agentKind: session.agentKind,
        sourceKind: session.sourceKind,
        runtimeSessionId: session.runtimeSessionId,
        workspacePath: session.workspacePath,
        status: session.status,
        hasMoreHistory: cachedSession.hasMoreHistory,
        events: cachedSession.events,
      );
      _resolvedSessionSummary = _cachedSnapshot?.toSummary();
      _hasAutoScrolledToLatest = true;
    }
    if (api == null || token == null || session == null) {
      _snapshotFuture = Future<SessionSnapshot?>.value(null);
    } else if (cachedSession != null) {
      _snapshotFuture = SynchronousFuture<SessionSnapshot?>(_cachedSnapshot);
    } else {
      _snapshotFuture = api
          .sessionSnapshot(sessionId: session.id, token: token)
          .then((snapshot) {
            if (!mounted) {
              return snapshot;
            }
            setState(() {
              _resolvedSessionSummary = snapshot.toSummary();
            });
            return snapshot;
          });
    }
  }

  @override
  void dispose() {
    if (_isListeningForVoice) {
      unawaited(widget.voiceInputController?.cancel());
    }
    for (final timer in _attachmentSuccessTimers.values) {
      timer.cancel();
    }
    _attachmentSuccessTimers.clear();
    _composerClearTimer?.cancel();
    _voiceCancelFadeTimer?.cancel();
    _eventStreamRetryTimer?.cancel();
    _eventSubscription?.cancel();
    _timelineScrollController.removeListener(_handleTimelineScrollChanged);
    _timelineScrollController.removeListener(
      _maybeLoadOlderEventsFromController,
    );
    _timelineScrollController.dispose();
    _messageController.removeListener(_handleDraftChanged);
    _messageController.dispose();
    super.dispose();
  }

  void _syncComposerDraft() {
    final draftScope = _draftScope;
    final composerDraftStore = widget.composerDraftStore;
    if (draftScope != null && composerDraftStore != null) {
      final text = _messageController.text;
      final draftAttachments = _attachments
          .where((attachment) => attachment.isUploaded)
          .map(
            (attachment) => SessionComposerDraftAttachment(
              filename: attachment.filename,
              contentType: attachment.contentType,
              bytes: List<int>.from(attachment.bytes),
              path: attachment.path!,
            ),
          )
          .toList();
      if (text.trim().isEmpty && draftAttachments.isEmpty) {
        composerDraftStore.clearDraft(scope: draftScope);
      } else {
        composerDraftStore.saveDraft(
          scope: draftScope,
          draft: SessionComposerDraft(
            text: text,
            attachments: draftAttachments,
          ),
        );
      }
    }
  }

  void _handleDraftChanged() {
    _syncComposerDraft();
    if (mounted) {
      setState(() {});
    }
  }

  void _handleTimelineScrollChanged() {
    if (_isNearBottom && _hasPendingAssistantStreamUpdate && mounted) {
      setState(() {
        _hasPendingAssistantStreamUpdate = false;
      });
    }
    _syncSessionDetailCache();
  }

  void _syncSessionDetailCache() {
    final cacheScope = _detailCacheScope;
    final cacheStore = widget.sessionDetailCacheStore;
    final events = _events;
    if (cacheScope == null || cacheStore == null || events == null) {
      return;
    }
    final scrollOffset = _timelineScrollController.hasClients
        ? _timelineScrollController.offset
        : 0.0;
    cacheStore.saveCache(
      scope: cacheScope,
      entry: SessionDetailCacheEntry(
        events: events,
        hasMoreHistory: _hasMoreHistory,
        expandedItemKeys: _expandedTimelineItemKeys,
        autoExpandedFailedToolItemKeys:
            _handledAutoExpandedFailedToolItemKeys,
        scrollOffset: scrollOffset,
      ),
    );
  }

  void _restoreScrollOffsetFromCache() {
    final cachedSnapshot = _cachedSnapshot;
    if (_hasRestoredScrollOffset ||
        cachedSnapshot == null ||
        !_timelineScrollController.hasClients) {
      return;
    }
    final cacheScope = _detailCacheScope;
    final cacheStore = widget.sessionDetailCacheStore;
    if (cacheScope == null || cacheStore == null) {
      return;
    }
    final cachedOffset = cacheStore.readCache(scope: cacheScope)?.scrollOffset;
    if (cachedOffset == null) {
      return;
    }
    final maxScrollExtent = _timelineScrollController.position.maxScrollExtent;
    _timelineScrollController.jumpTo(
      cachedOffset.clamp(0.0, maxScrollExtent),
    );
    _hasRestoredScrollOffset = true;
  }

  List<String> get _slashSuggestions {
    final text = _messageController.text.trimLeft();
    if (!text.startsWith('/') && !text.startsWith('\$')) {
      return const <String>[];
    }

    return _slashCommands.where((command) => command.startsWith(text)).toList();
  }

  void _selectSlashCommand(String command) {
    _messageController.value = TextEditingValue(
      text: '$command ',
      selection: TextSelection.collapsed(offset: command.length + 1),
    );
  }

  String _voiceErrorText(Object error) {
    final text = error.toString();
    if (text == 'Microphone permission denied') {
      return 'Microphone permission denied. Enable it in settings.';
    }
    if (text.startsWith('Bad state:') || text.startsWith('Exception:')) {
      return 'Voice input failed. Retry.';
    }
    return text;
  }

  String _attachmentPickerErrorText(Object error) {
    return 'Could not pick image';
  }

  bool get _isNearBottom {
    if (!_timelineScrollController.hasClients) {
      return true;
    }
    final position = _timelineScrollController.position;
    return (position.maxScrollExtent - position.pixels) <=
        _bottomProximityThreshold;
  }

  void _scrollToBottomAndClearNewUpdates() {
    if (_timelineScrollController.hasClients) {
      _timelineScrollController.jumpTo(
        _timelineScrollController.position.maxScrollExtent,
      );
    }
    if ((_pendingNewEventCount > 0 || _hasPendingAssistantStreamUpdate) &&
        mounted) {
      setState(() {
        _pendingNewEventCount = 0;
        _hasPendingAssistantStreamUpdate = false;
      });
    }
  }

  int get _latestEventId {
    final events = _events;
    if (events == null || events.isEmpty) {
      return 0;
    }
    return events.last.id;
  }

  bool get _isForbiddenStream => _streamError == _streamForbiddenText;

  bool _isReconnectBannerError(String? error) {
    return error != null &&
        error != _streamForbiddenText &&
        error != _streamOfflineText;
  }

  String? get _statusPillText {
    if (_streamError == _streamOfflineText) {
      return 'offline';
    }
    if (_streamError != null && _streamError != _streamForbiddenText) {
      return 'reconnecting';
    }
    final events = _events;
    return events == null
        ? widget.session?.status
        : _latestMeaningfulSessionStatus(
            events,
            fallbackStatus: widget.session?.status,
          );
  }

  void _maybeLoadOlderEventsFromController() {
    if (!_timelineScrollController.hasClients || !_hasMoreHistory) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_timelineScrollController.hasClients ||
          !_hasMoreHistory) {
        return;
      }
      _maybeLoadOlderEventsOnScroll(_timelineScrollController.position.pixels);
    });
  }

  void _maybeLoadOlderEventsOnScroll(double pixelsFromTop) {
    if (!_hasAutoScrolledToLatest || !_timelineScrollController.hasClients) {
      return;
    }
    if (pixelsFromTop <= _topHistoryLoadThreshold) {
      unawaited(_loadOlderEvents());
    }
  }

  void _syncAutoExpandedFailedToolWithCurrentEvents() {
    final events = _events;
    if (events == null || events.isEmpty) {
      return;
    }
    final items = _visibleTimelineItems(
      events,
      showDebugTimelineItems: _showDebugTimelineItems,
    );
    if (items.isEmpty) {
      return;
    }
    final latestItem = items.last;
    if (latestItem case ToolCallItem(:final key, :final exitCode?)
        when exitCode != 0 &&
            !_handledAutoExpandedFailedToolItemKeys.contains(key)) {
      _handledAutoExpandedFailedToolItemKeys.add(key);
      _expandedTimelineItemKeys.add(key);
    }
  }

  Future<void> _pickAndUploadAttachment() async {
    final source = await _chooseAttachmentSource();
    if (source == null) {
      return;
    }
    await _pickAndUploadAttachmentFromSource(source);
  }

  Future<ImageAttachmentSource?> _chooseAttachmentSource() {
    return showModalBottomSheet<ImageAttachmentSource>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Add image', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Photo library'),
                onTap: () =>
                    Navigator.of(context).pop(ImageAttachmentSource.gallery),
              ),
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text('Camera'),
                onTap: () =>
                    Navigator.of(context).pop(ImageAttachmentSource.camera),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickAndUploadAttachmentFromSource(
    ImageAttachmentSource source,
  ) async {
    final api = widget.api;
    final picker = widget.attachmentPicker;
    final token = widget.token;
    final session = widget.session;
    if (api == null || picker == null || token == null || session == null) {
      return;
    }

    setState(() {
      _attachmentError = null;
      _sendFailureText = null;
    });
    try {
      final picked = await picker.pickImage(source: source);
      if (picked == null) {
        return;
      }

      if (!mounted) {
        return;
      }
      final attachment = _UploadedAttachment.pending(
        id: _nextAttachmentId++,
        filename: picked.filename,
        contentType: picked.contentType,
        bytes: picked.bytes,
      );
      setState(() {
        _attachments.add(attachment);
        _isUploading = true;
      });
      await _uploadAttachment(attachment.id);
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _attachmentError = _attachmentPickerErrorText(error);
        _isUploading = false;
      });
    }
  }

  Future<void> _uploadAttachment(int attachmentId) async {
    final api = widget.api;
    final token = widget.token;
    final session = widget.session;
    if (api == null || token == null || session == null) {
      return;
    }

    final index = _attachments.indexWhere(
      (attachment) => attachment.id == attachmentId,
    );
    if (index == -1) {
      return;
    }
    final attachment = _attachments[index];
    if (mounted) {
      setState(() {
        _attachments[index] = attachment.copyWith(
          status: _AttachmentUploadState.uploading,
        );
        _attachmentError = null;
        _sendFailureText = null;
        _isUploading = true;
      });
    }

    try {
      final path = await api.uploadAttachment(
        sessionId: session.id,
        token: token,
        filename: attachment.filename,
        contentType: attachment.contentType,
        bytes: attachment.bytes,
      );
      if (!mounted) {
        return;
      }
      final refreshedIndex = _attachments.indexWhere(
        (candidate) => candidate.id == attachmentId,
      );
      if (refreshedIndex == -1) {
        return;
      }
      setState(() {
        _attachments[refreshedIndex] = _attachments[refreshedIndex].copyWith(
          path: path,
          status: _AttachmentUploadState.uploadedSuccess,
        );
        _isUploading = false;
      });
      unawaited(_emitSuccessHaptic());
      _syncComposerDraft();
      _scheduleUploadedAttachmentSteadyState(attachmentId);
    } on Object catch (error) {
      if (await _handleUnauthorizedRequest(error)) {
        return;
      }
      if (!mounted) {
        return;
      }
      final refreshedIndex = _attachments.indexWhere(
        (candidate) => candidate.id == attachmentId,
      );
      if (refreshedIndex == -1) {
        return;
      }
      setState(() {
        _attachments[refreshedIndex] = _attachments[refreshedIndex].copyWith(
          status: _AttachmentUploadState.failed,
        );
        _isUploading = false;
      });
      unawaited(_emitWarningHaptic());
    }
  }

  void _scheduleUploadedAttachmentSteadyState(int attachmentId) {
    _attachmentSuccessTimers.remove(attachmentId)?.cancel();
    _attachmentSuccessTimers[attachmentId] = Timer(
      _attachmentUploadSuccessStateDuration,
      () {
        if (!mounted) {
          return;
        }
        final refreshedIndex = _attachments.indexWhere(
          (candidate) => candidate.id == attachmentId,
        );
        if (refreshedIndex == -1) {
          _attachmentSuccessTimers.remove(attachmentId);
          return;
        }
        if (_attachments[refreshedIndex].status !=
            _AttachmentUploadState.uploadedSuccess) {
          _attachmentSuccessTimers.remove(attachmentId);
          return;
        }
        setState(() {
          _attachments[refreshedIndex] = _attachments[refreshedIndex].copyWith(
            status: _AttachmentUploadState.uploaded,
          );
        });
        _syncComposerDraft();
        _attachmentSuccessTimers.remove(attachmentId);
      },
    );
  }

  void _removeAttachment(_UploadedAttachment attachment) {
    if (_removingAttachmentIds.contains(attachment.id)) {
      return;
    }
    if (MediaQuery.disableAnimationsOf(context)) {
      setState(() {
        _attachments.removeWhere((candidate) => candidate.id == attachment.id);
        _attachmentError = null;
        _sendFailureText = null;
        _syncComposerDraft();
      });
      return;
    }
    setState(() {
      _removingAttachmentIds.add(attachment.id);
      _attachmentError = null;
      _sendFailureText = null;
    });
    Timer(_attachmentRemovalAnimationDuration, () {
      if (!mounted) {
        return;
      }
      setState(() {
        _removingAttachmentIds.remove(attachment.id);
        _attachments.removeWhere((candidate) => candidate.id == attachment.id);
        _syncComposerDraft();
      });
    });
  }

  Future<void> _sendMessage() async {
    final api = widget.api;
    final token = widget.token;
    final session = widget.session;
    final message = _messageController.text.trim();
    final uploadedAttachmentPaths = _attachments
        .where((attachment) => attachment.isUploaded)
        .map((attachment) => attachment.path!)
        .toList();
    if (api == null ||
        token == null ||
        session == null ||
        (message.isEmpty && uploadedAttachmentPaths.isEmpty)) {
      return;
    }

    setState(() {
      _isSending = true;
      _sendFailureText = null;
    });
    unawaited(_emitSendStartedHaptic());
    try {
      await api.sendMessage(
        sessionId: session.id,
        token: token,
        message: message,
        imagePaths: uploadedAttachmentPaths,
      );
      if (!mounted) {
        return;
      }
      _composerClearTimer?.cancel();
      if (MediaQuery.disableAnimationsOf(context)) {
        setState(() {
          _messageController.clear();
        });
      } else {
        setState(() {
          _composerClearFadeCount += 1;
        });
        _composerClearTimer = Timer(const Duration(milliseconds: 160), () {
          if (!mounted) {
            return;
          }
          setState(() {
            _messageController.clear();
          });
        });
      }
      final draftScope = _draftScope;
      final composerDraftStore = widget.composerDraftStore;
      if (draftScope != null && composerDraftStore != null) {
        composerDraftStore.clearDraft(scope: draftScope);
      }
      _attachments.removeWhere((attachment) => attachment.isUploaded);
      _attachmentError = null;
      _sendFailureText = null;
      unawaited(_emitSuccessHaptic());
    } on Object catch (error) {
      if (await _handleUnauthorizedRequest(error)) {
        return;
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _sendFailureText = 'Send failed. Retry';
        _sendFailureShakeCount += 1;
      });
      unawaited(_emitWarningHaptic());
    } finally {
      if (mounted) {
        setState(() {
          _isSending = false;
        });
      }
    }
  }

  Future<void> _startVoiceInput() async {
    final controller = widget.voiceInputController;
    if (controller == null || !controller.isConfigured) {
      setState(() {
        _isConnectingVoice = false;
        _voiceStatusText = 'Voice input is not configured';
        _voiceRetryAvailable = false;
        _voiceStatusIndicatorState = _ComposerVoiceStatusIndicatorState.none;
      });
      return;
    }

    if (_isListeningForVoice) {
      await controller.cancel();
      if (!mounted) {
        return;
      }
      final disableAnimations = MediaQuery.disableAnimationsOf(context);
      _voiceCancelFadeTimer?.cancel();
      final fadingStatusText = _voiceStatusText;
      final fadingStatusIndicatorState = _voiceStatusIndicatorState;
      setState(() {
        _isConnectingVoice = false;
        _isListeningForVoice = false;
        _cancelFadingVoiceStatusText = disableAnimations ? null : fadingStatusText;
        _cancelFadingVoiceStatusIndicatorState = disableAnimations
            ? _ComposerVoiceStatusIndicatorState.none
            : fadingStatusIndicatorState;
        _voiceStatusText = null;
        _voiceRetryAvailable = false;
        _voiceStatusIndicatorState = _ComposerVoiceStatusIndicatorState.none;
        if (!disableAnimations) {
          _voiceCancelFadeCount += 1;
        }
      });
      if (!disableAnimations) {
        _voiceCancelFadeTimer = Timer(_voiceCancelFadeDuration, () {
          if (!mounted) {
            return;
          }
          setState(() {
            _cancelFadingVoiceStatusText = null;
            _cancelFadingVoiceStatusIndicatorState =
                _ComposerVoiceStatusIndicatorState.none;
          });
        });
      }
      return;
    }

    setState(() {
      _isConnectingVoice = true;
      _isListeningForVoice = true;
      _voiceStatusText = 'Connecting Doubao voice...';
      _voiceRetryAvailable = false;
      _voiceStatusIndicatorState = _ComposerVoiceStatusIndicatorState.none;
    });
    try {
      await for (final update in controller.listenWithUpdates()) {
        if (!mounted) {
          return;
        }
        switch (update.stage) {
          case VoiceInputStage.connecting:
            setState(() {
              _isConnectingVoice = true;
              _voiceStatusText = 'Connecting Doubao voice...';
              _cancelFadingVoiceStatusText = null;
              _voiceStatusIndicatorState = _ComposerVoiceStatusIndicatorState.none;
              _cancelFadingVoiceStatusIndicatorState =
                  _ComposerVoiceStatusIndicatorState.none;
            });
          case VoiceInputStage.listening:
            if (update.transcript != null) {
              _messageController.text = update.transcript!;
            }
            setState(() {
              _isConnectingVoice = false;
              _voiceStatusText = 'Listening...';
              _cancelFadingVoiceStatusText = null;
              _voiceStatusIndicatorState =
                  _ComposerVoiceStatusIndicatorState.listening;
              _cancelFadingVoiceStatusIndicatorState =
                  _ComposerVoiceStatusIndicatorState.none;
            });
          case VoiceInputStage.stopping:
            if (update.isFinal && update.transcript != null) {
              _messageController.text = update.transcript!;
              setState(() {
                _isConnectingVoice = false;
                _voiceStatusText = null;
                _cancelFadingVoiceStatusText = null;
                _isListeningForVoice = false;
                _voiceRetryAvailable = false;
                _voiceStatusIndicatorState =
                    _ComposerVoiceStatusIndicatorState.none;
                _cancelFadingVoiceStatusIndicatorState =
                    _ComposerVoiceStatusIndicatorState.none;
              });
            } else {
              if (update.transcript != null) {
                _messageController.text = update.transcript!;
              }
              setState(() {
                _isConnectingVoice = false;
                _voiceStatusText = 'Finishing transcript...';
                _cancelFadingVoiceStatusText = null;
                _voiceStatusIndicatorState =
                    _ComposerVoiceStatusIndicatorState.stopping;
                _cancelFadingVoiceStatusIndicatorState =
                    _ComposerVoiceStatusIndicatorState.none;
              });
            }
        }
      }
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isConnectingVoice = false;
        _voiceStatusText = _voiceErrorText(error);
        _cancelFadingVoiceStatusText = null;
        _isListeningForVoice = false;
        _voiceRetryAvailable = true;
        _voiceStatusIndicatorState = _ComposerVoiceStatusIndicatorState.none;
        _cancelFadingVoiceStatusIndicatorState =
            _ComposerVoiceStatusIndicatorState.none;
      });
    }
  }

  Future<void> _loadOlderEvents() async {
    final api = widget.api;
    final token = widget.token;
    final session = widget.session;
    final events = _events;
    if (api == null ||
        token == null ||
        session == null ||
        events == null ||
        events.isEmpty ||
        _isLoadingOlderEvents ||
        !_hasMoreHistory) {
      return;
    }

    setState(() {
      _isLoadingOlderEvents = true;
    });
    final previousMaxScrollExtent = _timelineScrollController.hasClients
        ? _timelineScrollController.position.maxScrollExtent
        : 0.0;
    final previousOffset = _timelineScrollController.hasClients
        ? _timelineScrollController.offset
        : 0.0;
    try {
      final older = await api.sessionSnapshot(
        sessionId: session.id,
        token: token,
        beforeEventId: events.first.id,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        final currentEvents = _events ?? <SessionEvent>[];
        final currentIds = currentEvents.map((event) => event.id).toSet();
        final prependedEvents = older.events
            .where((event) => !currentIds.contains(event.id))
            .toList();
        _events = <SessionEvent>[
          ...prependedEvents,
          ...currentEvents,
        ];
        _prependedTimelineItemKeys = _visibleTimelineItems(
          prependedEvents,
          showDebugTimelineItems: _showDebugTimelineItems,
        ).map(_timelineItemKey).toSet();
        _syncAutoExpandedFailedToolWithCurrentEvents();
        _hasMoreHistory = older.hasMoreHistory;
        _isLoadingOlderEvents = false;
        _syncSessionDetailCache();
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_timelineScrollController.hasClients) {
          return;
        }
        final newMaxScrollExtent =
            _timelineScrollController.position.maxScrollExtent;
        final delta = newMaxScrollExtent - previousMaxScrollExtent;
        if (delta <= 0) {
          return;
        }
        _timelineScrollController.jumpTo(previousOffset + delta);
      });
    } on Object catch (error) {
      if (await _handleUnauthorizedRequest(error)) {
        return;
      }
      if (error is DaemonApiException && error.statusCode == 403) {
        _eventStreamRetryTimer?.cancel();
        _eventStreamRetryTimer = null;
        unawaited(_eventSubscription?.cancel());
        _eventSubscription = null;
        if (!mounted) {
          return;
        }
        setState(() {
          _streamError = _streamForbiddenText;
          _isEventStreamConnected = false;
          _hasMoreHistory = false;
          _syncSessionDetailCache();
        });
        return;
      }
      rethrow;
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingOlderEvents = false;
        });
      }
    }
  }

  void _connectEventStream() {
    _eventStreamRetryTimer?.cancel();
    _eventStreamRetryTimer = null;
    _connectEventStreamWithStateUpdate(
      updateState: true,
      preserveReconnectBanner: true,
    );
  }

  void _scheduleEventStreamReconnect() {
    _eventStreamRetryTimer?.cancel();
    final retryDelay = _eventStreamRetryDelayForAttempt(
      _eventStreamFailureCount,
    );
    _eventStreamRetryTimer = Timer(retryDelay, () {
      _eventStreamRetryTimer = null;
      if (!mounted || _isHandlingUnauthorized) {
        return;
      }
      _connectEventStreamWithStateUpdate(
        updateState: true,
        preserveReconnectBanner: true,
      );
    });
  }

  Duration _eventStreamRetryDelayForAttempt(int failureCount) {
    final exponent = switch (failureCount) {
      <= 1 => 0,
      2 => 1,
      _ => 2,
    };
    return _eventStreamRetryBaseDelay * (1 << exponent);
  }

  Future<void> _handleUnauthorizedStream() async {
    if (_isHandlingUnauthorized) {
      return;
    }
    final onUnauthorized = widget.onUnauthorized;
    if (onUnauthorized == null) {
      return;
    }
    _isHandlingUnauthorized = true;
    unawaited(_eventSubscription?.cancel());
    _eventSubscription = null;
    unawaited(widget.voiceInputController?.cancel());
    await onUnauthorized();
    if (!mounted) {
      return;
    }
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Future<bool> _handleUnauthorizedRequest(Object error) async {
    if (!_isUnauthorizedEventStreamError(error)) {
      return false;
    }
    await _handleUnauthorizedStream();
    return true;
  }

  void _connectEventStreamWithStateUpdate({
    required bool updateState,
    bool preserveReconnectBanner = false,
  }) {
    final api = widget.api;
    final token = widget.token;
    final session = widget.session;
    if (api == null || token == null || session == null) {
      return;
    }

    _eventSubscription?.cancel();
    void markConnecting() {
      if (!preserveReconnectBanner) {
        _streamError = null;
      }
      _isEventStreamConnected = !preserveReconnectBanner;
    }

    if (updateState) {
      setState(markConnecting);
    } else {
      markConnecting();
    }
    _eventSubscription = api
        .sessionEvents(
          sessionId: session.id,
          token: token,
          afterEventId: _latestEventId,
        )
        .listen(
          (event) {
            if (!mounted) {
              return;
            }
            setState(() {
              final reconnectingError = _streamError;
              final events = _events ?? <SessionEvent>[];
              if (!events.any((item) => item.id == event.id)) {
                final insertionIndex = events.indexWhere(
                  (item) => item.id > event.id,
                );
                if (insertionIndex == -1) {
                  _events = <SessionEvent>[...events, event];
                } else {
                  _events = <SessionEvent>[
                    ...events.take(insertionIndex),
                    event,
                    ...events.skip(insertionIndex),
                  ];
                }
                _syncAutoExpandedFailedToolWithCurrentEvents();
                if (!_isNearBottom) {
                  if (event.eventType == 'assistant.message') {
                    if (!_hasPendingAssistantStreamUpdate) {
                      _pendingNewEventCount += 1;
                      _hasPendingAssistantStreamUpdate = true;
                    }
                  } else {
                    _pendingNewEventCount += 1;
                    _hasPendingAssistantStreamUpdate = false;
                  }
                } else if (event.eventType != 'assistant.message') {
                  _hasPendingAssistantStreamUpdate = false;
                }
              }
              if (_isReconnectBannerError(reconnectingError)) {
                _collapsingStreamBannerText = reconnectingError;
                _streamBannerCollapseCount += 1;
                Timer(_streamBannerCollapseDuration, () {
                  if (!mounted) {
                    return;
                  }
                  setState(() {
                    _collapsingStreamBannerText = null;
                  });
                });
              }
              _streamError = null;
              _eventStreamFailureCount = 0;
              _isEventStreamConnected = true;
              _syncSessionDetailCache();
            });
            if (_isNearBottom) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) {
                  return;
                }
                _scrollToBottomAndClearNewUpdates();
              });
            }
          },
          onError: (Object error) {
            if (error is DaemonApiException && error.statusCode == 403) {
              unawaited(_eventSubscription?.cancel());
              _eventSubscription = null;
            }
            if (_isUnauthorizedEventStreamError(error)) {
              unawaited(_handleUnauthorizedStream());
              return;
            }
            if (!mounted) {
              return;
            }
            setState(() {
              _streamError = _eventStreamErrorText(error);
              if (_streamError != _streamForbiddenText &&
                  _streamError != _streamOfflineText) {
                _eventStreamFailureCount += 1;
                if (_eventStreamFailureCount >= 3) {
                  _streamError = _streamStillReconnectingText;
                }
              }
              _isEventStreamConnected = false;
            });
            if (_streamError != _streamForbiddenText &&
                _streamError != _streamOfflineText &&
                _eventStreamFailureCount < 3) {
              _scheduleEventStreamReconnect();
            }
          },
          onDone: () {
            if (_isHandlingUnauthorized) {
              return;
            }
            if (!mounted) {
              return;
            }
            setState(() {
              if (_streamError != null &&
                  _streamError != _streamForbiddenText &&
                  _streamError != _streamOfflineText) {
                _streamError = _eventStreamFailureCount >= 3
                    ? _streamStillReconnectingText
                    : _streamReconnectingText;
              }
              _isEventStreamConnected = false;
            });
            if (_streamError != null &&
                _streamError != _streamForbiddenText &&
                _streamError != _streamOfflineText &&
                _eventStreamFailureCount < 3) {
              _scheduleEventStreamReconnect();
            }
          },
        );
  }

  void _startEventStream(SessionSnapshot snapshot) {
    if (_hasStartedEventStream) {
      return;
    }
    _hasStartedEventStream = true;

    if (_events == null) {
      _events = List<SessionEvent>.from(snapshot.events);
      _syncAutoExpandedFailedToolWithCurrentEvents();
      _hasMoreHistory = snapshot.hasMoreHistory;
      _syncSessionDetailCache();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _hasAutoScrolledToLatest) {
          return;
        }
        if (!_timelineScrollController.hasClients) {
          return;
        }
        _timelineScrollController.jumpTo(
          _timelineScrollController.position.maxScrollExtent,
        );
        _hasAutoScrolledToLatest = true;
        _maybeLoadOlderEventsFromController();
      });
    }
    final api = widget.api;
    final token = widget.token;
    final session = widget.session;
    if (api == null || token == null || session == null) {
      return;
    }

    _connectEventStreamWithStateUpdate(updateState: false);
  }

  @override
  Widget build(BuildContext context) {
    final title = switch (widget.session) {
      final session? => _sessionDisplayTitle(session),
      null => 'Chat',
    };
    final voiceAvailable = widget.voiceInputController?.isConfigured == true;
    final statusPillText = _statusPillText;
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          if (statusPillText != null && statusPillText.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: _SessionStatusPill(
                key: const ValueKey('session-status-pill'),
                label: statusPillText,
              ),
            ),
          const SizedBox(width: 8),
          PopupMenuButton<_SessionDetailMenuAction>(
            tooltip: 'Session details',
            enabled: _sessionSummary != null,
            onSelected: (value) {
              unawaited(_handleSessionMenuAction(value));
            },
            itemBuilder: (context) {
              final session = _sessionSummary;
              if (session == null) {
                return const <PopupMenuEntry<_SessionDetailMenuAction>>[];
              }
              return <PopupMenuEntry<_SessionDetailMenuAction>>[
                const PopupMenuItem(
                  value: _SessionDetailMenuAction.details,
                  child: Text('Session details'),
                ),
                const PopupMenuItem(
                  value: _SessionDetailMenuAction.copySessionId,
                  child: Text('Copy session ID'),
                ),
                if (session.runtimeSessionId != null &&
                    session.runtimeSessionId!.isNotEmpty)
                  const PopupMenuItem(
                    value: _SessionDetailMenuAction.copyRuntimeSessionId,
                    child: Text('Copy runtime session ID'),
                  ),
                const PopupMenuItem(
                  value: _SessionDetailMenuAction.copyWorkspacePath,
                  child: Text('Copy workspace path'),
                ),
                if (widget.onDeleteSession != null)
                  const PopupMenuItem(
                    value: _SessionDetailMenuAction.deleteSession,
                    child: Text('Delete session'),
                  ),
              ];
            },
            icon: const Icon(Icons.more_horiz_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: FutureBuilder<SessionSnapshot?>(
          future: _snapshotFuture,
          builder: (context, snapshot) {
            final cachedSnapshot = _cachedSnapshot;
            final useInitialTimelineFade =
                snapshot.connectionState == ConnectionState.done &&
                cachedSnapshot == null;
            var canUseComposer =
                widget.api != null &&
                widget.token != null &&
                widget.session != null &&
                !_isForbiddenStream &&
                !_isForbiddenSnapshot;

            Widget timeline;
            if (snapshot.connectionState != ConnectionState.done &&
                cachedSnapshot == null) {
              timeline = const _ChatTimelineSkeleton();
            } else if (snapshot.hasError) {
              final error = snapshot.error!;
              if (_isUnauthorizedEventStreamError(error)) {
                unawaited(_handleUnauthorizedStream());
                timeline = const SizedBox.shrink();
              } else if (error is DaemonApiException && error.statusCode == 403) {
                _isForbiddenSnapshot = true;
                _streamError = _streamForbiddenText;
                _isEventStreamConnected = false;
                canUseComposer = false;
                timeline = Column(
                  children: [
                    _StreamStatusBanner(
                      errorText: _streamError,
                      collapsingText: _collapsingStreamBannerText,
                      collapseCount: _streamBannerCollapseCount,
                      isConnected: _isEventStreamConnected,
                      onRetry: _connectEventStream,
                      onBackToSessions: () => Navigator.of(context).maybePop(),
                    ),
                    const Expanded(child: SizedBox.shrink()),
                  ],
                );
              } else {
                _isForbiddenSnapshot = false;
                _streamError = _eventStreamErrorText(error);
                _isEventStreamConnected = false;
                timeline = Column(
                  children: [
                    _StreamStatusBanner(
                      errorText: _streamError,
                      collapsingText: _collapsingStreamBannerText,
                      collapseCount: _streamBannerCollapseCount,
                      isConnected: _isEventStreamConnected,
                      onRetry: _connectEventStream,
                      onBackToSessions: () => Navigator.of(context).maybePop(),
                    ),
                    const Expanded(child: SizedBox.shrink()),
                  ],
                );
              }
            } else {
              final session = snapshot.data ?? cachedSnapshot;
              if (session == null) {
                _isForbiddenSnapshot = false;
                timeline = const _PreviewTimeline();
              } else {
                _isForbiddenSnapshot = false;
                canUseComposer =
                    widget.api != null &&
                    widget.token != null &&
                    widget.session != null &&
                    !_isForbiddenStream;
                _startEventStream(session);
                final timelineChild = _SessionTimeline(
                  scrollController: _timelineScrollController,
                  events: _events ?? session.events,
                  expandedItemKeys: _expandedTimelineItemKeys,
                  daemonUrl: widget.daemonUrl,
                  sessionId: session.id,
                  sessionStatus: statusPillText,
                  openExternalLink: widget.openExternalLink,
                  shareAttachments: widget.shareAttachments,
                  showDebugTimelineItems: _showDebugTimelineItems,
                  token: widget.token,
                  hasMoreHistory: _hasMoreHistory,
                  isLoadingOlderEvents: _isLoadingOlderEvents,
                  prependedItemKeys: _prependedTimelineItemKeys,
                  onLoadOlderEvents: _loadOlderEvents,
                  onToggleExpanded: _toggleTimelineItemExpanded,
                  onNearTop: _maybeLoadOlderEventsOnScroll,
                );
                final timelineBody = Expanded(
                  key: const ValueKey('session-timeline-expanded'),
                  child: useInitialTimelineFade
                      ? _InitialTimelineFade(child: timelineChild)
                      : timelineChild,
                );
                timeline = Column(
                  children: [
                    _StreamStatusBanner(
                      errorText: _streamError,
                      collapsingText: _collapsingStreamBannerText,
                      collapseCount: _streamBannerCollapseCount,
                      isConnected: _isEventStreamConnected,
                      onRetry: _connectEventStream,
                      onBackToSessions: () =>
                          Navigator.of(context).maybePop(),
                    ),
                    if (_isLoadingOlderEvents)
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
                        child: _OlderHistoryLoader(),
                      ),
                    timelineBody,
                    if (_pendingNewEventCount > 0)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        child: Align(
                          alignment: Alignment.center,
                          child: _NewUpdatesChip(
                            count: _pendingNewEventCount,
                            onPressed: _scrollToBottomAndClearNewUpdates,
                          ),
                        ),
                      ),
                  ],
                );
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) {
                    return;
                  }
                  _restoreScrollOffsetFromCache();
                });
              }
            }

            final canSubmit =
                canUseComposer &&
                !_isSending &&
                !_isUploading &&
                !_isListeningForVoice;
            return Column(
              children: [
                Expanded(child: timeline),
                _ComposerPreview(
                  controller: _messageController,
                  attachments: _attachments,
                  attachmentError: _attachmentError,
                  sendFailureText: _sendFailureText,
                  sendFailureShakeCount: _sendFailureShakeCount,
                  voiceCancelFadeCount: _voiceCancelFadeCount,
                  composerClearFadeCount: _composerClearFadeCount,
                  slashSuggestions: _slashSuggestions,
                  voiceAvailable: voiceAvailable,
                  voiceStatusText: _voiceStatusText,
                  cancelFadingVoiceStatusText: _cancelFadingVoiceStatusText,
                  voiceStatusIndicatorState: _voiceStatusIndicatorState,
                  cancelFadingVoiceStatusIndicatorState:
                      _cancelFadingVoiceStatusIndicatorState,
                  voiceRetryAvailable: _voiceRetryAvailable,
                  enabled: canUseComposer,
                  canSubmit: canSubmit,
                  isUploading: _isUploading,
                  isSending: _isSending,
                  isConnectingVoice: _isConnectingVoice,
                  isListeningForVoice: _isListeningForVoice,
                  onAttachImage: _pickAndUploadAttachment,
                  onRetryAttachmentUpload: (attachment) =>
                      _uploadAttachment(attachment.id),
                  onSelectSlashCommand: _selectSlashCommand,
                  onRetryVoiceInput: _startVoiceInput,
                  onVoiceInput: _startVoiceInput,
                  onKeepEditing: () => setState(() {
                    _sendFailureText = null;
                  }),
                  removingAttachmentIds: _removingAttachmentIds,
                  onRemoveAttachment: _removeAttachment,
                  onRetrySend: _sendMessage,
                  onSend: _sendMessage,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

String _eventStreamErrorText(Object error) {
  if (error is DaemonApiException && error.statusCode == 403) {
    return _streamForbiddenText;
  }
  if (error is SocketException) {
    return _streamOfflineText;
  }
  return _streamReconnectingText;
}

bool _isUnauthorizedEventStreamError(Object error) {
  return error is DaemonApiException && error.statusCode == 401;
}

class _PreviewTimeline extends StatelessWidget {
  const _PreviewTimeline();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: const [
        _AssistantPreviewCard(),
        SizedBox(height: 14),
        _ActivityPreviewCard(),
        SizedBox(height: 14),
        _UserPreviewBubble(),
      ],
    );
  }
}

class _NewUpdatesChip extends StatelessWidget {
  const _NewUpdatesChip({required this.count, required this.onPressed});

  final int count;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final label = count == 1 ? '1 new update' : '$count new updates';
    final button = FilledButton.tonal(
      onPressed: onPressed,
      child: Text(label),
    );
    if (MediaQuery.disableAnimationsOf(context)) {
      return button;
    }
    return TweenAnimationBuilder<double>(
      key: ValueKey('new-updates-chip-scale-$count'),
      tween: Tween<double>(begin: 0.96, end: 1),
      duration: const Duration(milliseconds: 180),
      builder: (context, value, child) {
        return Transform.scale(
          key: const ValueKey('new-updates-chip-scale'),
          scale: value,
          child: child,
        );
      },
      child: button,
    );
  }
}

enum _SessionDetailMenuAction {
  details,
  copySessionId,
  copyRuntimeSessionId,
  copyWorkspacePath,
  deleteSession,
}

class _SessionDetailsSheet extends StatelessWidget {
  const _SessionDetailsSheet({
    required this.title,
    required this.agentKind,
    required this.sourceKind,
    required this.status,
    required this.workspacePath,
    required this.runtimeSessionId,
    required this.daemonHost,
  });

  final String title;
  final String agentKind;
  final String sourceKind;
  final String status;
  final String workspacePath;
  final String? runtimeSessionId;
  final String? daemonHost;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Session details',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              _SessionDetailRow(label: 'Title', value: title),
              _SessionDetailRow(label: 'Agent kind', value: agentKind),
              _SessionDetailRow(label: 'Source kind', value: sourceKind),
              _SessionDetailRow(label: 'Status', value: status),
              _SessionDetailRow(label: 'Workspace path', value: workspacePath),
              if (runtimeSessionId != null)
                _SessionDetailRow(
                  label: 'Runtime session ID',
                  value: runtimeSessionId!,
                ),
              if (daemonHost != null)
                _SessionDetailRow(
                  label: 'Daemon URL host',
                  value: daemonHost!,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SessionDetailRow extends StatelessWidget {
  const _SessionDetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 4),
          Text(value),
        ],
      ),
    );
  }
}

class _ChatTimelineSkeleton extends StatelessWidget {
  const _ChatTimelineSkeleton();

  @override
  Widget build(BuildContext context) {
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    return ListView(
      key: const ValueKey('chat-timeline-skeleton'),
      padding: const EdgeInsets.all(20),
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: _ChatSkeletonBlock(
            key: const ValueKey('chat-skeleton-user-bubble'),
            widthFactor: 0.72,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(22),
              topRight: Radius.circular(22),
              bottomLeft: Radius.circular(22),
              bottomRight: Radius.circular(8),
            ),
            child: _ChatSkeletonShimmer(
              enabled: !disableAnimations,
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _ChatSkeletonLine(width: 180, height: 14),
                  SizedBox(height: 10),
                  _ChatSkeletonLine(width: 120, height: 14),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        _ChatSkeletonBlock(
          key: const ValueKey('chat-skeleton-assistant-card'),
          widthFactor: 1,
          borderRadius: BorderRadius.circular(28),
          child: _ChatSkeletonShimmer(
            enabled: !disableAnimations,
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ChatSkeletonLine(width: 96, height: 12),
                SizedBox(height: 18),
                _ChatSkeletonLine(width: double.infinity, height: 16),
                SizedBox(height: 12),
                _ChatSkeletonLine(width: double.infinity, height: 16),
                SizedBox(height: 12),
                _ChatSkeletonLine(width: 220, height: 16),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        _ChatSkeletonBlock(
          key: const ValueKey('chat-skeleton-activity-card'),
          widthFactor: 0.86,
          borderRadius: BorderRadius.circular(22),
          child: _ChatSkeletonShimmer(
            enabled: !disableAnimations,
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ChatSkeletonLine(width: 88, height: 13),
                SizedBox(height: 12),
                _ChatSkeletonLine(width: 180, height: 12),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ChatSkeletonBlock extends StatelessWidget {
  const _ChatSkeletonBlock({
    super.key,
    required this.widthFactor,
    required this.borderRadius,
    required this.child,
  });

  final double widthFactor;
  final BorderRadius borderRadius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      widthFactor: widthFactor,
      alignment: widthFactor < 0.8 ? Alignment.centerRight : Alignment.centerLeft,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF101820),
          borderRadius: borderRadius,
          border: Border.all(color: const Color(0xFF22313D)),
        ),
        child: Padding(padding: const EdgeInsets.all(18), child: child),
      ),
    );
  }
}

class _ChatSkeletonShimmer extends StatefulWidget {
  const _ChatSkeletonShimmer({required this.enabled, required this.child});

  final bool enabled;
  final Widget child;

  @override
  State<_ChatSkeletonShimmer> createState() => _ChatSkeletonShimmerState();
}

class _ChatSkeletonShimmerState extends State<_ChatSkeletonShimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void initState() {
    super.initState();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant _ChatSkeletonShimmer oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAnimation();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _syncAnimation() {
    if (!widget.enabled) {
      _controller.stop();
      return;
    }
    if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) {
      return widget.child;
    }
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final alignment = Alignment(-1 + (_controller.value * 2), 0);
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (bounds) => LinearGradient(
            begin: alignment,
            end: Alignment(alignment.x + 1.2, 0),
            colors: const [
              Color(0xFF17232D),
              Color(0xFF253542),
              Color(0xFF17232D),
            ],
            stops: const [0.1, 0.45, 0.9],
          ).createShader(bounds),
          child: child!,
        );
      },
      child: widget.child,
    );
  }
}

class _ChatSkeletonLine extends StatelessWidget {
  const _ChatSkeletonLine({required this.width, required this.height});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: const Color(0xFF22313D),
        borderRadius: BorderRadius.circular(999),
      ),
    );
  }
}

class _StreamStatusBanner extends StatelessWidget {
  const _StreamStatusBanner({
    required this.errorText,
    required this.collapsingText,
    required this.collapseCount,
    required this.isConnected,
    required this.onRetry,
    required this.onBackToSessions,
  });

  final String? errorText;
  final String? collapsingText;
  final int collapseCount;
  final bool isConnected;
  final VoidCallback onRetry;
  final VoidCallback onBackToSessions;

  @override
  Widget build(BuildContext context) {
    final error = errorText;
    final bannerText = error ?? collapsingText;
    if (bannerText == null && isConnected) {
      return const SizedBox.shrink();
    }

    final label = bannerText ?? 'Connecting to event stream...';
    final actionLabel = switch (error ?? collapsingText) {
      _streamForbiddenText => 'Back to Sessions',
      _streamStillReconnectingText => 'Reconnect',
      _ => null,
    };
    final action = switch (error ?? collapsingText) {
      _streamForbiddenText => onBackToSessions,
      _streamStillReconnectingText => onRetry,
      _ => null,
    };
    final showProgressSweep =
        bannerText != null &&
        bannerText != _streamForbiddenText &&
        bannerText != _streamOfflineText &&
        !MediaQuery.disableAnimationsOf(context);
    final banner = Material(
      color: const Color(0xFF17232D),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Expanded(child: Text(label)),
                if (action case final callback?)
                  TextButton(onPressed: callback, child: Text(actionLabel!)),
              ],
            ),
          ),
          if (showProgressSweep) const _ReconnectingProgressSweep(),
        ],
      ),
    );
    final isCollapsing = collapsingText != null && error == null;
    if (MediaQuery.disableAnimationsOf(context)) {
      return banner;
    }
    return AnimatedAlign(
      key: ValueKey('stream-status-banner-collapse-$collapseCount'),
      duration: _streamBannerCollapseDuration,
      curve: Curves.easeOut,
      alignment: Alignment.topCenter,
      heightFactor: isCollapsing ? 0 : 1,
      child: KeyedSubtree(
        key: const ValueKey('stream-status-banner-collapse'),
        child: banner,
      ),
    );
  }
}

class _SessionStatusPill extends StatefulWidget {
  const _SessionStatusPill({super.key, required this.label});

  final String label;

  @override
  State<_SessionStatusPill> createState() => _SessionStatusPillState();
}

class _SessionStatusPillState extends State<_SessionStatusPill> {
  static const _pulseInterval = Duration(milliseconds: 650);

  Timer? _pulseTimer;
  var _pulseVisible = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPulseTimer();
  }

  @override
  void didUpdateWidget(covariant _SessionStatusPill oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.label != widget.label) {
      _syncPulseTimer(reset: true);
    }
  }

  @override
  void dispose() {
    _pulseTimer?.cancel();
    super.dispose();
  }

  void _syncPulseTimer({bool reset = false}) {
    final shouldPulse = switch (widget.label) {
      'running' || 'active' || 'reconnecting' => true,
      _ => false,
    };
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    if (!shouldPulse || disableAnimations) {
      _pulseTimer?.cancel();
      _pulseTimer = null;
      _pulseVisible = true;
      return;
    }
    if (reset) {
      _pulseTimer?.cancel();
      _pulseTimer = null;
      _pulseVisible = true;
    }
    _pulseTimer ??= Timer.periodic(_pulseInterval, (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _pulseVisible = !_pulseVisible;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    _syncPulseTimer();
    final dotColor = _sessionStatusDotColor(widget.label);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF17232D),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFF29404D)),
      ),
      alignment: Alignment.center,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Opacity(
            key: const ValueKey('session-status-pill-dot-opacity'),
            opacity: _pulseVisible ? 1 : 0.24,
            child: Container(
              key: const ValueKey('session-status-pill-dot'),
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: dotColor,
                shape: BoxShape.circle,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(widget.label),
        ],
      ),
    );
  }
}

class _ReconnectingProgressSweep extends StatelessWidget {
  const _ReconnectingProgressSweep();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF2A3540),
      child: SizedBox(
        key: const ValueKey('stream-reconnecting-progress-sweep'),
        height: 2,
        child: ClipRect(
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: -1, end: 1),
            duration: const Duration(milliseconds: 1400),
            curve: Curves.easeInOut,
            builder: (context, value, child) {
              return FractionalTranslation(
                translation: Offset(value, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: 0.45,
                    alignment: Alignment.centerLeft,
                    child: child,
                  ),
                ),
              );
            },
            child: const ColoredBox(color: Color(0xFFE2A84D)),
          ),
        ),
      ),
    );
  }
}

class _SessionTimeline extends StatefulWidget {
  const _SessionTimeline({
    required this.scrollController,
    required this.events,
    required this.expandedItemKeys,
    required this.daemonUrl,
    required this.sessionId,
    required this.sessionStatus,
    required this.openExternalLink,
    required this.shareAttachments,
    required this.showDebugTimelineItems,
    required this.token,
    required this.hasMoreHistory,
    required this.isLoadingOlderEvents,
    required this.prependedItemKeys,
    required this.onLoadOlderEvents,
    required this.onToggleExpanded,
    required this.onNearTop,
  });

  final ScrollController scrollController;
  final List<SessionEvent> events;
  final Set<String> expandedItemKeys;
  final Uri? daemonUrl;
  final String sessionId;
  final String? sessionStatus;
  final ExternalLinkOpener? openExternalLink;
  final ShareAttachments? shareAttachments;
  final bool showDebugTimelineItems;
  final String? token;
  final bool hasMoreHistory;
  final bool isLoadingOlderEvents;
  final Set<String> prependedItemKeys;
  final VoidCallback onLoadOlderEvents;
  final ValueChanged<String> onToggleExpanded;
  final ValueChanged<double> onNearTop;

  @override
  State<_SessionTimeline> createState() => _SessionTimelineState();
}

class _SessionTimelineState extends State<_SessionTimeline> {
  final Set<String> _seenItemKeys = <String>{};
  final Set<String> _appendingItemKeys = <String>{};
  final Set<String> _prependingItemKeys = <String>{};
  final Map<String, Timer> _entryAnimationTimers = <String, Timer>{};
  String? _leadingRenderedKey;

  @override
  void initState() {
    super.initState();
    final initialItems = _visibleTimelineItems(
      widget.events,
      showDebugTimelineItems: widget.showDebugTimelineItems,
    );
    _seenItemKeys.addAll(initialItems.map(_timelineItemKey));
    if (initialItems.isNotEmpty) {
      _leadingRenderedKey = _timelineItemKey(initialItems.first);
    }
  }

  @override
  void dispose() {
    for (final timer in _entryAnimationTimers.values) {
      timer.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final events = widget.events;
    if (events.isEmpty) {
      return Center(
        child: Text(
          'No session events yet',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );
    }
    final projectedItems = _projectedItems;
    final previousLeadingKey = _leadingRenderedKey;
    _primeEntryAnimations(projectedItems, previousLeadingKey: previousLeadingKey);
    final activeReasoningIndex =
        projectedItems.isNotEmpty && projectedItems.last is ThinkingItem
        ? projectedItems.length - 1
        : -1;
    final activeAssistantIndex =
        projectedItems.isNotEmpty &&
            projectedItems.last is AssistantMessageItem &&
            _sessionAllowsActiveIndicators(widget.sessionStatus)
        ? projectedItems.length - 1
        : -1;

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.metrics.axis == Axis.vertical &&
            (notification is ScrollUpdateNotification ||
                notification is OverscrollNotification)) {
          widget.onNearTop(notification.metrics.pixels);
        }
        return false;
      },
      child: ListView.separated(
        controller: widget.scrollController,
        padding: const EdgeInsets.all(20),
        itemCount: projectedItems.length + 1,
        separatorBuilder: (_, _) => const SizedBox(height: 14),
        itemBuilder: (context, index) {
          if (index == 0) {
            if (widget.hasMoreHistory) {
              return const SizedBox.shrink();
            }
            return Center(
              child: Text(
                'Beginning of session',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: const Color(0xFF8FA1AE)),
              ),
            );
          }
          final itemIndex = index - 1;
          final item = projectedItems[itemIndex];
          final itemKey = _timelineItemKey(item);
          final shouldAnimateAppend =
              _appendingItemKeys.contains(itemKey) &&
              !MediaQuery.disableAnimationsOf(context);
          final shouldAnimatePrepend =
              (widget.prependedItemKeys.contains(itemKey) ||
                  _prependingItemKeys.contains(itemKey)) &&
              !MediaQuery.disableAnimationsOf(context);
          return _TimelineEntryAppearance(
            key: ValueKey('timeline-item-entry-$itemKey'),
            itemKey: itemKey,
            animateAppend: shouldAnimateAppend,
            animatePrepend: shouldAnimatePrepend,
            child: KeyedSubtree(
              key: ValueKey('timeline-item-$itemKey'),
              child: _TimelineItemCard(
                daemonUrl: widget.daemonUrl,
                expandedItemKeys: widget.expandedItemKeys,
                item: item,
                isActiveAssistant: itemIndex == activeAssistantIndex,
                isActiveReasoning: itemIndex == activeReasoningIndex,
                itemKey: itemKey,
                sessionId: widget.sessionId,
                openExternalLink: widget.openExternalLink,
                onToggleExpanded: widget.onToggleExpanded,
                shareAttachments: widget.shareAttachments,
                token: widget.token,
              ),
            ),
          );
        },
      ),
    );
  }

  List<TimelineItem> get _projectedItems => _visibleTimelineItems(
    widget.events,
    showDebugTimelineItems: widget.showDebugTimelineItems,
  );

  void _primeEntryAnimations(
    List<TimelineItem> projectedItems, {
    required String? previousLeadingKey,
  }) {
    final currentKeys = projectedItems.map(_timelineItemKey).toList();
    final newKeys = currentKeys.where((key) => !_seenItemKeys.contains(key)).toSet();
    final prependBoundaryIndex = previousLeadingKey == null
        ? -1
        : currentKeys.indexOf(previousLeadingKey);
    for (final key in newKeys) {
      _entryAnimationTimers.remove(key)?.cancel();
      final isPrepended =
          prependBoundaryIndex > 0 &&
          currentKeys.indexOf(key) < prependBoundaryIndex;
      if (isPrepended) {
        _prependingItemKeys.add(key);
      } else {
        _appendingItemKeys.add(key);
      }
      _entryAnimationTimers[key] = Timer(const Duration(milliseconds: 180), () {
        _entryAnimationTimers.remove(key);
        if (!mounted) {
          return;
        }
        setState(() {
          _appendingItemKeys.remove(key);
          _prependingItemKeys.remove(key);
        });
      });
    }
    _seenItemKeys.addAll(currentKeys);
    _leadingRenderedKey = currentKeys.isEmpty ? null : currentKeys.first;
  }
}

class _OlderHistoryLoader extends StatelessWidget {
  const _OlderHistoryLoader();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const ValueKey('older-history-loader'),
      height: 36,
      child: Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              key: ValueKey('older-history-loader-spinner'),
              strokeWidth: 2,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            'Loading earlier events...',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}

class _TimelineEntryAppearance extends StatelessWidget {
  const _TimelineEntryAppearance({
    super.key,
    required this.itemKey,
    required this.animateAppend,
    required this.animatePrepend,
    required this.child,
  });

  final String itemKey;
  final bool animateAppend;
  final bool animatePrepend;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (animatePrepend) {
      return TweenAnimationBuilder<double>(
        key: ValueKey('timeline-item-prepend-appear-$itemKey'),
        tween: Tween<double>(begin: 0, end: 1),
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        builder: (context, value, child) {
          return Opacity(opacity: value, child: child);
        },
        child: child,
      );
    }
    if (!animateAppend) {
      return child;
    }
    return TweenAnimationBuilder<double>(
      key: ValueKey('timeline-item-entry-appear-$itemKey'),
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      builder: (context, value, child) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, (1 - value) * 6),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}

class _InitialTimelineFade extends StatelessWidget {
  const _InitialTimelineFade({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return child;
    }
    return TweenAnimationBuilder<double>(
      key: const ValueKey('chat-timeline-initial-fade'),
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
      builder: (context, value, child) {
        return FadeTransition(
          opacity: AlwaysStoppedAnimation<double>(value),
          child: child,
        );
      },
      child: child,
    );
  }
}

List<TimelineItem> _visibleTimelineItems(
  List<SessionEvent> events, {
  required bool showDebugTimelineItems,
}) {
  return projectTimelineItems(events).where((item) {
    if (item is UnknownEventItem) {
      return showDebugTimelineItems;
    }
    return true;
  }).toList();
}

String? _latestMeaningfulSessionStatus(
  List<SessionEvent> events, {
  String? fallbackStatus,
}) {
  for (final event in events.reversed) {
    if (event.eventType != 'session.status.changed') {
      continue;
    }
    if (_sessionStatusFromPayload(event.payload) case final status?) {
      return status;
    }
  }
  return _normalizedStatus(fallbackStatus);
}

String? _sessionStatusFromPayload(Map<String, Object?> payload) {
  return switch (payload['status']) {
    final String value => _normalizedStatus(value),
    final Map<String, Object?> value when value['type'] is String =>
      _normalizedStatus(value['type'] as String),
    _ => null,
  };
}

String? _normalizedStatus(String? value) {
  final normalized = value?.trim();
  if (normalized == null || normalized.isEmpty) {
    return null;
  }
  return normalized;
}

bool _sessionAllowsActiveIndicators(String? status) {
  return switch (status?.trim()) {
    'running' || 'active' => true,
    _ => false,
  };
}

String _sessionDisplayTitle(SessionSummary session) {
  final title = session.title?.trim();
  if (title != null && title.isNotEmpty) {
    return title;
  }
  final segments = session.workspacePath
      .split('/')
      .where((segment) => segment.isNotEmpty)
      .toList();
  if (segments.isNotEmpty) {
    return segments.last;
  }
  final agentKind = session.agentKind.trim();
  if (agentKind.isNotEmpty) {
    return agentKind;
  }
  return session.workspacePath;
}

String _timelineItemKey(TimelineItem item) {
  return switch (item) {
    UserMessageItem(:final text, :final imagePaths) =>
      'user:${Object.hash(text, Object.hashAll(imagePaths))}',
    AssistantMessageItem(:final key) => key,
    ThinkingItem(:final key) => key,
    ToolCallItem(:final key) => key,
    FileChangeItem(:final key) => key,
    ActivitySummaryItem(:final key) => key,
    AttachedSessionItem(:final runtimeSessionId) =>
      'attached-runtime:${runtimeSessionId ?? 'unknown'}',
    StatusSummaryItem(:final status) => 'status:$status',
    UnknownEventItem(:final eventType, :final details) =>
      'unknown:${Object.hash(eventType, details)}',
  };
}

class _TimelineItemCard extends StatelessWidget {
  const _TimelineItemCard({
    required this.item,
    required this.daemonUrl,
    required this.expandedItemKeys,
    required this.itemKey,
    required this.sessionId,
    required this.openExternalLink,
    required this.onToggleExpanded,
    required this.shareAttachments,
    required this.token,
    this.isActiveAssistant = false,
    this.isActiveReasoning = false,
  });

  final Uri? daemonUrl;
  final Set<String> expandedItemKeys;
  final TimelineItem item;
  final bool isActiveAssistant;
  final bool isActiveReasoning;
  final String itemKey;
  final String sessionId;
  final ExternalLinkOpener? openExternalLink;
  final ValueChanged<String> onToggleExpanded;
  final ShareAttachments? shareAttachments;
  final String? token;

  @override
  Widget build(BuildContext context) {
    return switch (item) {
      UserMessageItem(:final text, :final imagePaths) => _UserMessageBubble(
        daemonUrl: daemonUrl,
        imagePaths: imagePaths,
        sessionId: sessionId,
        shareAttachments: shareAttachments,
        text: text,
        token: token,
      ),
      AssistantMessageItem(:final text) => _AssistantMessageCard(
        openExternalLink: openExternalLink,
        showTypingIndicator: isActiveAssistant,
        text: text,
      ),
      ThinkingItem(:final text) => _CollapsibleReasoningCard(
        expanded: expandedItemKeys.contains(itemKey),
        text: text,
        isActive: isActiveReasoning,
        onToggleExpanded: () => onToggleExpanded(itemKey),
      ),
      ToolCallItem(
        :final toolName,
        :final label,
        :final output,
        :final status,
        :final cwd,
        :final exitCode,
        :final durationMs,
      ) =>
        _CollapsibleToolCallCard(
          expanded: expandedItemKeys.contains(itemKey),
          toolName: toolName,
          label: label,
          onToggleExpanded: () => onToggleExpanded(itemKey),
          output: output,
          status: status,
          cwd: cwd,
          exitCode: exitCode,
          durationMs: durationMs,
        ),
      FileChangeItem(
        :final files,
        :final fileKinds,
        :final summary,
        :final diffs,
        :final status,
      ) =>
        _CollapsibleFileChangeCard(
          expanded: expandedItemKeys.contains(itemKey),
          files: files,
          fileKinds: fileKinds,
          onToggleExpanded: () => onToggleExpanded(itemKey),
          summary: summary,
          diffs: diffs,
          status: status,
        ),
      ActivitySummaryItem(:final groups) => Semantics(
        container: true,
        explicitChildNodes: true,
        label: 'Activity summary',
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'Activity',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    if (_activitySummaryHasStartedGroup(groups)) ...[
                      const SizedBox(width: 8),
                      const _ActivitySummaryActiveIndicator(),
                    ],
                  ],
                ),
                const SizedBox(height: 10),
                for (final group in groups) ...[
                  _ActivitySummaryGroupRow(group: group),
                ],
              ],
            ),
          ),
        ),
      ),
      AttachedSessionItem(:final runtimeSessionId) => _CollapsibleAttachedRuntimeCard(
        expanded: expandedItemKeys.contains(itemKey),
        runtimeSessionId: runtimeSessionId,
        onCopyRuntimeSessionId: runtimeSessionId == null || runtimeSessionId.isEmpty
            ? null
            : () => _copyToClipboard(
                context,
                runtimeSessionId,
                'Runtime session ID',
              ),
        onToggleExpanded: () => onToggleExpanded(itemKey),
      ),
      StatusSummaryItem(:final status) => Semantics(
        container: true,
        explicitChildNodes: true,
        label: _sessionStatusLabel(status),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0x1417232D),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0x3329404D)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.info_outline, size: 18),
              const SizedBox(width: 8),
              Text(_sessionStatusLabel(status)),
            ],
          ),
        ),
      ),
      UnknownEventItem(:final eventType, :final details) => _CollapsibleUnknownEventCard(
        eventType: eventType,
        details: details,
        expanded: expandedItemKeys.contains(itemKey),
        onToggleExpanded: () => onToggleExpanded(itemKey),
      ),
    };
  }

  Future<void> _copyToClipboard(
    BuildContext context,
    String text,
    String label,
  ) async {
    await Clipboard.setData(ClipboardData(text: text));
    await HapticFeedback.selectionClick();
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$label copied')));
  }
}

class _CollapsibleUnknownEventCard extends StatelessWidget {
  const _CollapsibleUnknownEventCard({
    required this.eventType,
    required this.details,
    required this.expanded,
    required this.onToggleExpanded,
  });

  final String eventType;
  final String details;
  final bool expanded;
  final VoidCallback onToggleExpanded;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: 'Unknown event: $eventType',
      child: Card(
        child: InkWell(
          onTap: onToggleExpanded,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(eventType, style: Theme.of(context).textTheme.titleLarge),
                if (expanded) ...[
                  const SizedBox(height: 10),
                  Text(details),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CollapsibleAttachedRuntimeCard extends StatelessWidget {
  const _CollapsibleAttachedRuntimeCard({
    required this.expanded,
    required this.runtimeSessionId,
    required this.onToggleExpanded,
    this.onCopyRuntimeSessionId,
  });

  final bool expanded;
  final String? runtimeSessionId;
  final VoidCallback onToggleExpanded;
  final VoidCallback? onCopyRuntimeSessionId;

  @override
  Widget build(BuildContext context) {
    final runtimeSessionId = this.runtimeSessionId;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: 'Attached runtime',
      child: Card(
        child: InkWell(
          onTap: onToggleExpanded,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Attached runtime',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 10),
                const Text('Connected to an existing runtime session.'),
                if (expanded && runtimeSessionId != null && runtimeSessionId.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  _SessionDetailRow(
                    label: 'Runtime session ID',
                    value: runtimeSessionId,
                  ),
                  FilledButton.tonal(
                    onPressed: onCopyRuntimeSessionId,
                    child: const Text('Copy runtime session ID'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _UserMessageBubble extends StatelessWidget {
  const _UserMessageBubble({
    required this.daemonUrl,
    required this.imagePaths,
    required this.sessionId,
    required this.shareAttachments,
    required this.text,
    required this.token,
  });

  final Uri? daemonUrl;
  final List<String> imagePaths;
  final String sessionId;
  final ShareAttachments? shareAttachments;
  final String text;
  final String? token;

  Future<void> _copyText(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: text));
    await HapticFeedback.selectionClick();
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Message text copied')));
  }

  Future<void> _shareImages(BuildContext context) async {
    final paths = imagePaths.where((path) => path.trim().isNotEmpty).toList();
    if (paths.isEmpty) {
      return;
    }
    final shareAttachments = this.shareAttachments;
    if (shareAttachments != null) {
      await shareAttachments(paths, text.isEmpty ? null : text);
    }
    await HapticFeedback.selectionClick();
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Image shared')));
  }

  Future<void> _showActions(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy_all_outlined),
              title: const Text('Copy message text'),
              onTap: () async {
                Navigator.of(sheetContext).pop();
                await _copyText(context);
              },
            ),
            if (imagePaths.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.ios_share_outlined),
                title: const Text('Share image'),
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  await _shareImages(context);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _showImagePreview(BuildContext context, String imagePath) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog.fullscreen(
        child: Scaffold(
          backgroundColor: const Color(0xFF020617),
          appBar: AppBar(
            title: const Text('Image preview'),
            leading: IconButton(
              tooltip: 'Close preview',
              onPressed: () => Navigator.of(dialogContext).pop(),
              icon: const Icon(Icons.close_rounded),
            ),
          ),
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: _SessionAttachmentImage(
                fit: BoxFit.contain,
                imagePath: imagePath,
                imageUri: _sessionAttachmentUri(
                  daemonUrl,
                  sessionId,
                  imagePath,
                ),
                previewKey: ValueKey('image-preview-$imagePath'),
                token: token,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: 'User message',
      child: Align(
        alignment: Alignment.centerRight,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 320),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF1E3B2B),
            borderRadius: BorderRadius.circular(22),
          ),
          child: InkWell(
            onLongPress: () {
              unawaited(_showActions(context));
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (imagePaths.isNotEmpty)
                  LayoutBuilder(
                    builder: (context, constraints) {
                      const spacing = 8.0;
                      final itemWidth = imagePaths.length == 1
                          ? constraints.maxWidth
                          : (constraints.maxWidth - spacing) / 2;
                      return Wrap(
                        spacing: spacing,
                        runSpacing: spacing,
                        children: [
                          for (final imagePath in imagePaths)
                            SizedBox(
                              width: itemWidth,
                              child: _UserMessageImageThumbnail(
                                imagePath: imagePath,
                                imageUri: _sessionAttachmentUri(
                                  daemonUrl,
                                  sessionId,
                                  imagePath,
                                ),
                                onTap: () {
                                  unawaited(
                                    _showImagePreview(context, imagePath),
                                  );
                                },
                                token: token,
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                if (imagePaths.isNotEmpty && text.isNotEmpty)
                  const SizedBox(height: 12),
                if (text.isNotEmpty) Text(text),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _UserMessageImageThumbnail extends StatelessWidget {
  const _UserMessageImageThumbnail({
    required this.imagePath,
    required this.imageUri,
    required this.onTap,
    required this.token,
  });

  final String imagePath;
  final Uri? imageUri;
  final VoidCallback onTap;
  final String? token;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: ValueKey('user-message-image-$imagePath'),
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: AspectRatio(
          aspectRatio: 1.2,
          child: _SessionAttachmentImage(
            fit: BoxFit.cover,
            imagePath: imagePath,
            imageUri: imageUri,
            token: token,
          ),
        ),
      ),
    );
  }
}

class _SessionAttachmentImage extends StatelessWidget {
  const _SessionAttachmentImage({
    required this.fit,
    required this.imagePath,
    required this.imageUri,
    required this.token,
    this.previewKey,
  });

  final BoxFit fit;
  final String imagePath;
  final Uri? imageUri;
  final Key? previewKey;
  final String? token;

  @override
  Widget build(BuildContext context) {
    final uri = imageUri;
    final authToken = token;
    if (uri == null || authToken == null) {
      return _AttachmentImageFallback(
        imagePath: imagePath,
        fallbackKey: previewKey,
      );
    }

    return Image.network(
      key: previewKey,
      uri.toString(),
      fit: fit,
      headers: {'authorization': 'Bearer $authToken'},
      errorBuilder: (_, _, _) => _AttachmentImageFallback(
        imagePath: imagePath,
        fallbackKey: previewKey,
      ),
    );
  }
}

class _AttachmentImageFallback extends StatelessWidget {
  const _AttachmentImageFallback({required this.imagePath, this.fallbackKey});

  final Key? fallbackKey;
  final String imagePath;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      key: fallbackKey,
      color: const Color(0xFF17232D),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.image_outlined, color: Colors.white70),
              const SizedBox(height: 8),
              Text(
                _attachmentName(imagePath),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AssistantMessageCard extends StatelessWidget {
  const _AssistantMessageCard({
    required this.openExternalLink,
    this.showTypingIndicator = false,
    required this.text,
  });

  final ExternalLinkOpener? openExternalLink;
  final bool showTypingIndicator;
  final String text;

  Future<void> _showActions(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListTile(
          leading: const Icon(Icons.copy_all_outlined),
          title: const Text('Copy assistant message'),
          onTap: () async {
            Navigator.of(sheetContext).pop();
            await Clipboard.setData(ClipboardData(text: text));
            await HapticFeedback.selectionClick();
            if (!context.mounted) {
              return;
            }
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Assistant message copied')),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: 'Assistant message',
      child: Card(
        child: InkWell(
          onLongPress: () {
            unawaited(_showActions(context));
          },
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Assistant',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 10),
                _AssistantMarkdownView(
                  markdown: text,
                  openExternalLink: openExternalLink,
                ),
                if (showTypingIndicator) ...[
                  const SizedBox(height: 12),
                  const _AssistantTypingIndicator(),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CardCopyAction {
  const _CardCopyAction({
    required this.label,
    required this.text,
    required this.snackLabel,
  });

  final String label;
  final String text;
  final String snackLabel;
}

Future<void> _showCardCopyActions(
  BuildContext context,
  List<_CardCopyAction> actions,
) {
  if (actions.isEmpty) {
    return Future<void>.value();
  }

  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final action in actions)
            ListTile(
              leading: const Icon(Icons.copy_all_outlined),
              title: Text(action.label),
              onTap: () async {
                Navigator.of(sheetContext).pop();
                await Clipboard.setData(ClipboardData(text: action.text));
                await HapticFeedback.selectionClick();
                if (!context.mounted) {
                  return;
                }
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('${action.snackLabel} copied')),
                );
              },
            ),
        ],
      ),
    ),
  );
}

class _AssistantMarkdownView extends StatelessWidget {
  const _AssistantMarkdownView({
    required this.markdown,
    required this.openExternalLink,
  });

  final String markdown;
  final ExternalLinkOpener? openExternalLink;

  @override
  Widget build(BuildContext context) {
    final blocks = _parseAssistantMarkdown(markdown);
    if (blocks.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var index = 0; index < blocks.length; index += 1) ...[
          _AnimatedAssistantMarkdownBlock(
            block: blocks[index],
            blockIndex: index,
            openExternalLink: openExternalLink,
          ),
          if (index < blocks.length - 1) const SizedBox(height: 12),
        ],
      ],
    );
  }
}

class _AnimatedAssistantMarkdownBlock extends StatelessWidget {
  const _AnimatedAssistantMarkdownBlock({
    required this.block,
    required this.blockIndex,
    required this.openExternalLink,
  });

  final _AssistantMarkdownBlock block;
  final int blockIndex;
  final ExternalLinkOpener? openExternalLink;

  @override
  Widget build(BuildContext context) {
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    final blockIdentity = _assistantMarkdownBlockIdentity(block);
    return AnimatedSwitcher(
      duration: disableAnimations
          ? Duration.zero
          : const Duration(milliseconds: 180),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeOut,
      transitionBuilder: (child, animation) {
        final childKey = switch (child.key) {
          final ValueKey<Object?> key => key.value,
          _ => blockIdentity,
        };
        return FadeTransition(
          key: ValueKey('assistant-markdown-block-fade-$blockIndex-$childKey'),
          opacity: animation,
          child: child,
        );
      },
      child: _AssistantMarkdownBlockView(
        key: ValueKey('assistant-markdown-block-$blockIndex-$blockIdentity'),
        block: block,
        openExternalLink: openExternalLink,
      ),
    );
  }
}

class _AssistantMarkdownBlockView extends StatelessWidget {
  const _AssistantMarkdownBlockView({
    super.key,
    required this.block,
    required this.openExternalLink,
  });

  final _AssistantMarkdownBlock block;
  final ExternalLinkOpener? openExternalLink;

  @override
  Widget build(BuildContext context) {
    return switch (block) {
      _AssistantHeadingBlock(:final level, :final text) => Text(
        text,
        style: _assistantHeadingStyle(context, level),
      ),
      _AssistantParagraphBlock(:final text) => _AssistantInlineContent(
        openExternalLink: openExternalLink,
        text: text,
      ),
      _AssistantListBlock(:final items) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var index = 0; index < items.length; index += 1) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 8, right: 10),
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      color: Color(0xFF9FE870),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                Expanded(
                  child: _AssistantInlineContent(
                    openExternalLink: openExternalLink,
                    text: items[index],
                  ),
                ),
              ],
            ),
            if (index < items.length - 1) const SizedBox(height: 8),
          ],
        ],
      ),
      _AssistantCodeBlock(:final code, :final language) =>
        _AssistantCodeBlockView(code: code, language: language),
    };
  }
}

class _AssistantInlineContent extends StatelessWidget {
  const _AssistantInlineContent({
    required this.openExternalLink,
    required this.text,
  });

  final ExternalLinkOpener? openExternalLink;
  final String text;

  Future<void> _openLink(BuildContext context, String url) async {
    final uri = Uri.tryParse(url);
    final openExternalLink = this.openExternalLink;
    final opened = uri != null && openExternalLink != null
        ? await openExternalLink(uri)
        : false;
    if (!context.mounted) {
      return;
    }
    if (!opened) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not open link')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final fragments = _parseAssistantInlineFragments(text);
    final hasDecoratedFragment = fragments.any(
      (fragment) => fragment is! _AssistantTextFragment,
    );
    if (!hasDecoratedFragment) {
      return Text(text, style: Theme.of(context).textTheme.bodyLarge);
    }

    return Wrap(
      spacing: 0,
      runSpacing: 6,
      children: [
        for (final fragment in fragments)
          switch (fragment) {
            _AssistantTextFragment(:final text) => Text(
              text,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            _AssistantInlineCodeFragment(:final text) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xFF13212C),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF29404D)),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Text(
                    text,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontFamily: 'monospace',
                      color: const Color(0xFFF8FAFC),
                    ),
                  ),
                ),
              ),
            ),
            _AssistantLinkFragment(:final label, :final url) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () {
                  unawaited(_openLink(context, url));
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 2,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: const Color(0xFF7DD3FC),
                          decoration: TextDecoration.underline,
                          decorationColor: const Color(0xFF7DD3FC),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.open_in_new_rounded,
                        key: ValueKey('assistant-link-icon-$url'),
                        size: 14,
                        color: const Color(0xFF7DD3FC),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          },
      ],
    );
  }
}

class _AssistantCodeBlockView extends StatefulWidget {
  const _AssistantCodeBlockView({required this.code, required this.language});

  final String code;
  final String? language;

  @override
  State<_AssistantCodeBlockView> createState() =>
      _AssistantCodeBlockViewState();
}

class _AssistantCodeBlockViewState extends State<_AssistantCodeBlockView> {
  static const _collapsedLineLimit = 12;

  var _expanded = false;

  @override
  Widget build(BuildContext context) {
    final lines = const LineSplitter().convert(widget.code);
    final isCollapsible = lines.length > _collapsedLineLimit;
    final visibleLines = _expanded || !isCollapsible
        ? lines
        : lines.take(_collapsedLineLimit).toList();
    final codeTextScaler = _cappedMonospaceTextScaler(context);

    return Container(
      key: const ValueKey('assistant-code-block'),
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF09131D),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF223341)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.language != null && widget.language!.isNotEmpty) ...[
              Text(
                widget.language!,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: const Color(0xFF9FB3C8),
                  letterSpacing: 0.6,
                ),
              ),
              const SizedBox(height: 10),
            ],
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final line in visibleLines)
                    Text(
                      line,
                      textScaler: codeTextScaler,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontFamily: 'monospace',
                        color: const Color(0xFFF8FAFC),
                        height: 1.45,
                      ),
                    ),
                ],
              ),
            ),
            if (isCollapsible) ...[
              const SizedBox(height: 10),
              TextButton(
                onPressed: () {
                  setState(() {
                    _expanded = !_expanded;
                  });
                },
                child: Text(_expanded ? 'Collapse code' : 'Show full code'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AssistantTypingIndicator extends StatefulWidget {
  const _AssistantTypingIndicator();

  @override
  State<_AssistantTypingIndicator> createState() =>
      _AssistantTypingIndicatorState();
}

class _AssistantTypingIndicatorState extends State<_AssistantTypingIndicator>
    with WidgetsBindingObserver {
  static const _blinkInterval = Duration(milliseconds: 650);

  Timer? _blinkTimer;
  var _visible = true;
  var _isAppActive = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncBlinkTimer();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _blinkTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final isAppActive = switch (state) {
      AppLifecycleState.resumed => true,
      AppLifecycleState.inactive ||
      AppLifecycleState.hidden ||
      AppLifecycleState.paused ||
      AppLifecycleState.detached => false,
    };
    if (_isAppActive == isAppActive) {
      return;
    }
    _isAppActive = isAppActive;
    if (!mounted) {
      return;
    }
    setState(() {
      if (!_isAppActive) {
        _visible = true;
      }
    });
  }

  void _syncBlinkTimer() {
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    if (disableAnimations || !_isAppActive) {
      _blinkTimer?.cancel();
      _blinkTimer = null;
      _visible = true;
      return;
    }
    _blinkTimer ??= Timer.periodic(_blinkInterval, (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _visible = !_visible;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    _syncBlinkTimer();
    return Align(
      alignment: Alignment.centerLeft,
      child: Opacity(
        opacity: _visible ? 1 : 0.24,
        child: Container(
          key: const ValueKey('assistant-typing-indicator'),
          width: 10,
          height: 18,
          decoration: BoxDecoration(
            color: const Color(0xFF9FE870),
            borderRadius: BorderRadius.circular(999),
          ),
        ),
      ),
    );
  }
}

sealed class _AssistantMarkdownBlock {
  const _AssistantMarkdownBlock();
}

class _AssistantHeadingBlock extends _AssistantMarkdownBlock {
  const _AssistantHeadingBlock({required this.level, required this.text});

  final int level;
  final String text;
}

class _AssistantParagraphBlock extends _AssistantMarkdownBlock {
  const _AssistantParagraphBlock({required this.text});

  final String text;
}

class _AssistantListBlock extends _AssistantMarkdownBlock {
  const _AssistantListBlock({required this.items});

  final List<String> items;
}

class _AssistantCodeBlock extends _AssistantMarkdownBlock {
  const _AssistantCodeBlock({required this.code, required this.language});

  final String code;
  final String? language;
}

sealed class _AssistantInlineFragment {
  const _AssistantInlineFragment();
}

class _AssistantTextFragment extends _AssistantInlineFragment {
  const _AssistantTextFragment(this.text);

  final String text;
}

class _AssistantInlineCodeFragment extends _AssistantInlineFragment {
  const _AssistantInlineCodeFragment(this.text);

  final String text;
}

class _AssistantLinkFragment extends _AssistantInlineFragment {
  const _AssistantLinkFragment({required this.label, required this.url});

  final String label;
  final String url;
}

String _assistantMarkdownBlockIdentity(_AssistantMarkdownBlock block) {
  return switch (block) {
    _AssistantHeadingBlock(:final level, :final text) => 'heading:$level:$text',
    _AssistantParagraphBlock(:final text) => 'paragraph:$text',
    _AssistantListBlock(:final items) => 'list:${items.join('|')}',
    _AssistantCodeBlock(:final language) => 'code:${language ?? ''}',
  };
}

List<_AssistantMarkdownBlock> _parseAssistantMarkdown(String markdown) {
  final lines = const LineSplitter().convert(markdown);
  final blocks = <_AssistantMarkdownBlock>[];
  var index = 0;

  while (index < lines.length) {
    final line = lines[index].trimRight();
    if (line.trim().isEmpty) {
      index += 1;
      continue;
    }

    final headingMatch = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(line);
    if (headingMatch != null) {
      blocks.add(
        _AssistantHeadingBlock(
          level: headingMatch.group(1)!.length,
          text: headingMatch.group(2)!.trim(),
        ),
      );
      index += 1;
      continue;
    }

    if (line.startsWith('```')) {
      final language = line.substring(3).trim();
      index += 1;
      final codeLines = <String>[];
      while (index < lines.length &&
          !lines[index].trimRight().startsWith('```')) {
        codeLines.add(lines[index].trimRight());
        index += 1;
      }
      if (index < lines.length) {
        index += 1;
      }
      blocks.add(
        _AssistantCodeBlock(
          code: codeLines.join('\n'),
          language: language.isEmpty ? null : language,
        ),
      );
      continue;
    }

    if (_assistantListItemMatch(line) != null) {
      final items = <String>[];
      while (index < lines.length) {
        final match = _assistantListItemMatch(lines[index].trimRight());
        if (match == null) {
          break;
        }
        items.add(match.group(1)!.trim());
        index += 1;
      }
      blocks.add(_AssistantListBlock(items: items));
      continue;
    }

    final paragraphLines = <String>[];
    while (index < lines.length) {
      final candidate = lines[index].trimRight();
      if (candidate.trim().isEmpty ||
          RegExp(r'^(#{1,6})\s+').hasMatch(candidate) ||
          candidate.startsWith('```') ||
          _assistantListItemMatch(candidate) != null) {
        break;
      }
      paragraphLines.add(candidate.trim());
      index += 1;
    }
    blocks.add(_AssistantParagraphBlock(text: paragraphLines.join(' ')));
  }

  return blocks;
}

Match? _assistantListItemMatch(String line) {
  return RegExp(r'^\s*-\s+(.*)$').firstMatch(line);
}

List<_AssistantInlineFragment> _parseAssistantInlineFragments(String text) {
  final fragments = <_AssistantInlineFragment>[];
  final pattern = RegExp(r'`([^`]+)`|\[([^\]]+)\]\(([^)]+)\)');
  var lastEnd = 0;

  for (final match in pattern.allMatches(text)) {
    if (match.start > lastEnd) {
      fragments.add(
        _AssistantTextFragment(text.substring(lastEnd, match.start)),
      );
    }

    final inlineCode = match.group(1);
    final linkLabel = match.group(2);
    final linkUrl = match.group(3);
    if (inlineCode != null) {
      fragments.add(_AssistantInlineCodeFragment(inlineCode));
    } else if (linkLabel != null && linkUrl != null) {
      fragments.add(_AssistantLinkFragment(label: linkLabel, url: linkUrl));
    }
    lastEnd = match.end;
  }

  if (lastEnd < text.length) {
    fragments.add(_AssistantTextFragment(text.substring(lastEnd)));
  }

  if (fragments.isEmpty) {
    fragments.add(_AssistantTextFragment(text));
  }

  return fragments;
}

TextStyle _assistantHeadingStyle(BuildContext context, int level) {
  final base = Theme.of(context).textTheme.titleLarge ?? const TextStyle();
  return switch (level) {
    1 => base.copyWith(fontSize: 24, fontWeight: FontWeight.w700),
    2 => base.copyWith(fontSize: 20, fontWeight: FontWeight.w700),
    3 => base.copyWith(fontSize: 18, fontWeight: FontWeight.w600),
    _ => base.copyWith(fontSize: 16, fontWeight: FontWeight.w600),
  };
}

class _CollapsibleReasoningCard extends StatefulWidget {
  const _CollapsibleReasoningCard({
    required this.expanded,
    required this.onToggleExpanded,
    required this.text,
    this.isActive = false,
  });

  final bool expanded;
  final String text;
  final bool isActive;
  final VoidCallback onToggleExpanded;

  @override
  State<_CollapsibleReasoningCard> createState() =>
      _CollapsibleReasoningCardState();
}

class _CollapsibleReasoningCardState extends State<_CollapsibleReasoningCard> {
  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: 'Reasoning card',
      child: Card(
        child: InkWell(
          onTap: widget.onToggleExpanded,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'Reasoning',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    if (widget.isActive) ...[
                      const SizedBox(width: 8),
                      const _ReasoningActiveIndicator(),
                    ],
                  ],
                ),
                const SizedBox(height: 10),
                if (widget.expanded)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 220),
                    child: SingleChildScrollView(child: Text(widget.text)),
                  )
                else
                  _ReasoningPreviewText(text: widget.text),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ReasoningPreviewText extends StatefulWidget {
  const _ReasoningPreviewText({required this.text});

  final String text;

  @override
  State<_ReasoningPreviewText> createState() => _ReasoningPreviewTextState();
}

class _ReasoningPreviewTextState extends State<_ReasoningPreviewText> {
  late String _previewAnimationKey = _reasoningPreview(widget.text);

  @override
  void didUpdateWidget(covariant _ReasoningPreviewText oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previousPreview = _reasoningPreview(oldWidget.text);
    final nextPreview = _reasoningPreview(widget.text);
    if (_isSubstantialReasoningPreviewChange(previousPreview, nextPreview)) {
      setState(() {
        _previewAnimationKey = nextPreview;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = _reasoningPreview(widget.text);
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    return AnimatedSwitcher(
      duration: disableAnimations
          ? Duration.zero
          : const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeOut,
      transitionBuilder: (child, animation) {
        final childKey = switch (child.key) {
          final ValueKey<Object?> key => key.value,
          _ => preview,
        };
        return FadeTransition(
          key: ValueKey('reasoning-preview-fade-$childKey'),
          opacity: animation,
          child: child,
        );
      },
      child: Text(key: ValueKey(_previewAnimationKey), preview),
    );
  }
}

class _ReasoningActiveIndicator extends StatefulWidget {
  const _ReasoningActiveIndicator();

  @override
  State<_ReasoningActiveIndicator> createState() =>
      _ReasoningActiveIndicatorState();
}

class _ReasoningActiveIndicatorState extends State<_ReasoningActiveIndicator> {
  static const _pulseInterval = Duration(milliseconds: 650);

  Timer? _pulseTimer;
  var _pulseVisible = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPulseTimer();
  }

  @override
  void dispose() {
    _pulseTimer?.cancel();
    super.dispose();
  }

  void _syncPulseTimer() {
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    if (disableAnimations) {
      _pulseTimer?.cancel();
      _pulseTimer = null;
      _pulseVisible = true;
      return;
    }
    _pulseTimer ??= Timer.periodic(_pulseInterval, (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _pulseVisible = !_pulseVisible;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    _syncPulseTimer();
    return Opacity(
      key: const ValueKey('reasoning-active-indicator-opacity'),
      opacity: _pulseVisible ? 1 : 0.24,
      child: Container(
        key: const ValueKey('reasoning-active-indicator'),
        width: 8,
        height: 8,
        decoration: const BoxDecoration(
          color: Color(0xFF4DAA7F),
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

String _reasoningPreview(String text) {
  const maxLength = 72;
  final normalized = text.trim();
  if (normalized.length <= maxLength) {
    return normalized;
  }
  return '${normalized.substring(0, maxLength).trimRight()}...';
}

bool _isSubstantialReasoningPreviewChange(
  String previousPreview,
  String nextPreview,
) {
  if (previousPreview == nextPreview) {
    return false;
  }
  final previousLine = _normalizedReasoningPreviewLine(previousPreview);
  final nextLine = _normalizedReasoningPreviewLine(nextPreview);
  if (previousLine == nextLine) {
    return false;
  }
  if (nextLine.startsWith(previousLine) &&
      nextLine.length - previousLine.length <= 8) {
    return false;
  }
  return true;
}

String _normalizedReasoningPreviewLine(String preview) {
  final trimmedLine = preview.split('\n').last.trim();
  final singleSpaced = trimmedLine.replaceAll(RegExp(r'\s+'), ' ');
  return singleSpaced.replaceFirst(RegExp(r'[.!?,;:]+$'), '');
}

bool _activitySummaryHasStartedGroup(List<ActivitySummaryGroup> groups) {
  for (final group in groups) {
    if (group.status == 'started') {
      return true;
    }
  }
  return false;
}

class _ActivitySummaryActiveIndicator extends StatefulWidget {
  const _ActivitySummaryActiveIndicator();

  @override
  State<_ActivitySummaryActiveIndicator> createState() =>
      _ActivitySummaryActiveIndicatorState();
}

class _ActivitySummaryActiveIndicatorState
    extends State<_ActivitySummaryActiveIndicator> {
  static const _pulseInterval = Duration(milliseconds: 650);

  Timer? _pulseTimer;
  var _pulseVisible = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPulseTimer();
  }

  @override
  void dispose() {
    _pulseTimer?.cancel();
    super.dispose();
  }

  void _syncPulseTimer() {
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    if (disableAnimations) {
      _pulseTimer?.cancel();
      _pulseTimer = null;
      _pulseVisible = true;
      return;
    }
    _pulseTimer ??= Timer.periodic(_pulseInterval, (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _pulseVisible = !_pulseVisible;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    _syncPulseTimer();
    return Opacity(
      key: const ValueKey('activity-summary-active-indicator-opacity'),
      opacity: _pulseVisible ? 1 : 0.24,
      child: Container(
        key: const ValueKey('activity-summary-active-indicator'),
        width: 8,
        height: 8,
        decoration: const BoxDecoration(
          color: Color(0xFF4DAA7F),
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

class _ActivitySummaryGroupRow extends StatelessWidget {
  const _ActivitySummaryGroupRow({required this.group});

  final ActivitySummaryGroup group;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 0,
      runSpacing: 4,
      children: [
        Text('${group.itemType} ${group.status} '),
        _ActivitySummaryCount(group: group),
      ],
    );
  }
}

class _ActivitySummaryCount extends StatelessWidget {
  const _ActivitySummaryCount({required this.group});

  final ActivitySummaryGroup group;

  @override
  Widget build(BuildContext context) {
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    final keySuffix = '${group.itemType}-${group.status}';
    return AnimatedSwitcher(
      duration: disableAnimations
          ? Duration.zero
          : const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeOut,
      transitionBuilder: (child, animation) => FadeTransition(
        key: ValueKey('activity-summary-count-fade-$keySuffix'),
        opacity: animation,
        child: child,
      ),
      child: Text(
        'x${group.count}',
        key: ValueKey('activity-summary-count-value-$keySuffix-${group.count}'),
      ),
    );
  }
}

String _attachmentName(String imagePath) {
  final segments = imagePath
      .split('/')
      .where((segment) => segment.isNotEmpty)
      .toList();
  if (segments.isEmpty) {
    return 'attachment.png';
  }
  return segments.last;
}

Uri? _sessionAttachmentUri(Uri? daemonUrl, String sessionId, String imagePath) {
  if (daemonUrl == null) {
    return null;
  }

  final basePath = switch (daemonUrl.path) {
    '/' || '' => '',
    final value when value.endsWith('/') => value.substring(
      0,
      value.length - 1,
    ),
    final value => value,
  };
  return daemonUrl.replace(
    path:
        '${basePath.isEmpty ? '' : basePath}/api/sessions/${Uri.encodeComponent(sessionId)}/attachments/${Uri.encodeComponent(_attachmentName(imagePath))}',
  );
}

String _sessionStatusLabel(String status) {
  return 'Session $status';
}

String _toolSemanticLabel(String label, String? status) {
  final trimmed = label.trim();
  final command = trimmed.isEmpty ? 'shell' : trimmed;
  if (status == null || status.isEmpty) {
    return 'Tool call: $command';
  }
  return 'Tool call: $command, $status';
}

String _fileChangeSemanticLabel(String summary, String? status) {
  if (status == null || status.isEmpty) {
    return 'File change: $summary';
  }
  return 'File change: $summary, $status';
}

String _fileChangeCountLabel(List<String> files) {
  if (files.isEmpty) {
    return 'Files changed';
  }
  return files.length == 1 ? '1 file' : '${files.length} files';
}

class _CollapsibleToolCallCard extends StatefulWidget {
  const _CollapsibleToolCallCard({
    required this.expanded,
    required this.toolName,
    required this.label,
    required this.onToggleExpanded,
    this.output,
    this.status,
    this.cwd,
    this.exitCode,
    this.durationMs,
  });

  final bool expanded;
  final String toolName;
  final String label;
  final VoidCallback onToggleExpanded;
  final String? output;
  final String? status;
  final String? cwd;
  final int? exitCode;
  final int? durationMs;

  @override
  State<_CollapsibleToolCallCard> createState() =>
      _CollapsibleToolCallCardState();
}

class _CollapsibleToolCallCardState extends State<_CollapsibleToolCallCard> {
  Future<void> _showActions() {
    final commandText = widget.label.trim();
    final actions = <_CardCopyAction>[
      if (commandText.isNotEmpty && commandText != widget.toolName)
        _CardCopyAction(
          label: 'Copy command',
          text: commandText,
          snackLabel: 'Command',
        ),
      if (widget.output != null && widget.output!.trim().isNotEmpty)
        _CardCopyAction(
          label: 'Copy output',
          text: widget.output!,
          snackLabel: 'Output',
        ),
    ];
    return _showCardCopyActions(context, actions);
  }

  @override
  Widget build(BuildContext context) {
    final isInProgress =
        widget.status == 'inProgress' || widget.status == 'started';
    final outputText =
        widget.output ??
        (widget.status == 'inProgress' ? 'Waiting for output...' : 'No output');
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: _toolSemanticLabel(widget.label, widget.status),
      child: Card(
        child: InkWell(
          onTap: widget.onToggleExpanded,
          onLongPress: () {
            unawaited(_showActions());
          },
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _ToolStatusIndicator(
                      isInProgress: isInProgress,
                      status: widget.status,
                      exitCode: widget.exitCode,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      widget.toolName,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(widget.label),
                if (widget.status != null) ...[
                  const SizedBox(height: 8),
                  _StatusPill(
                    label: widget.status!,
                    tone: _toolStatusPillTone(widget.status, widget.exitCode),
                    pulse: isInProgress,
                    pulseKeySuffix: 'tool.call.started',
                  ),
                ],
                if (widget.expanded) ...[
                  if (widget.cwd != null) ...[
                    const SizedBox(height: 10),
                    Text(widget.cwd!),
                  ],
                  const SizedBox(height: 10),
                  _ToolOutputBlock(text: outputText),
                  if (widget.exitCode != null || widget.durationMs != null) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 10,
                      runSpacing: 6,
                      children: [
                        if (widget.exitCode != null)
                          Text('exit ${widget.exitCode}'),
                        if (widget.durationMs != null)
                          Text('${widget.durationMs}ms'),
                      ],
                    ),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ToolOutputBlock extends StatefulWidget {
  const _ToolOutputBlock({required this.text});

  final String text;

  @override
  State<_ToolOutputBlock> createState() => _ToolOutputBlockState();
}

class _ToolOutputBlockState extends State<_ToolOutputBlock> {
  static const _collapsedLineLimit = 12;
  static const _placeholderOutputs = <String>{
    'Waiting for output...',
    'No output',
  };

  var _expanded = false;
  late String _outputAnimationKey = widget.text;

  @override
  void didUpdateWidget(covariant _ToolOutputBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    final wasPlaceholder = _placeholderOutputs.contains(oldWidget.text);
    final isRealOutput = !_placeholderOutputs.contains(widget.text);
    if (oldWidget.text != widget.text && wasPlaceholder && isRealOutput) {
      setState(() {
        _outputAnimationKey = widget.text;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    final lines = const LineSplitter().convert(widget.text);
    final isCollapsible = lines.length > _collapsedLineLimit;
    final visibleLines = _expanded || !isCollapsible
        ? lines
        : lines.take(_collapsedLineLimit).toList();

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF09131D),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF223341)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedSwitcher(
              duration: disableAnimations
                  ? Duration.zero
                  : const Duration(milliseconds: 220),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeOut,
              transitionBuilder: (child, animation) {
                final childKey = switch (child.key) {
                  final ValueKey<Object?> key => key.value,
                  _ => widget.text,
                };
                return FadeTransition(
                  key: ValueKey('tool-output-fade-$childKey'),
                  opacity: animation,
                  child: child,
                );
              },
              child: SingleChildScrollView(
                key: ValueKey(_outputAnimationKey),
                scrollDirection: Axis.horizontal,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final line in visibleLines)
                      Text(
                        line,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontFamily: 'monospace',
                          color: const Color(0xFFF8FAFC),
                          height: 1.45,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (isCollapsible) ...[
              const SizedBox(height: 10),
              TextButton(
                onPressed: () {
                  setState(() {
                    _expanded = !_expanded;
                  });
                },
                child: Text(_expanded ? 'Collapse output' : 'Show full output'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ToolInProgressIndicator extends StatefulWidget {
  const _ToolInProgressIndicator({super.key});

  @override
  State<_ToolInProgressIndicator> createState() =>
      _ToolInProgressIndicatorState();
}

class _ToolInProgressIndicatorState extends State<_ToolInProgressIndicator> {
  static const _pulseInterval = Duration(milliseconds: 650);

  Timer? _pulseTimer;
  var _pulseVisible = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPulseTimer();
  }

  @override
  void dispose() {
    _pulseTimer?.cancel();
    super.dispose();
  }

  void _syncPulseTimer() {
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    if (disableAnimations) {
      _pulseTimer?.cancel();
      _pulseTimer = null;
      _pulseVisible = true;
      return;
    }
    _pulseTimer ??= Timer.periodic(_pulseInterval, (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _pulseVisible = !_pulseVisible;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    _syncPulseTimer();
    return Opacity(
      opacity: _pulseVisible ? 1 : 0.24,
      child: Container(
        key: const ValueKey('tool-call-in-progress-spinner'),
        width: 10,
        height: 16,
        decoration: BoxDecoration(
          color: const Color(0xFF9FE870),
          borderRadius: BorderRadius.circular(999),
        ),
      ),
    );
  }
}

class _ToolStatusIndicator extends StatelessWidget {
  const _ToolStatusIndicator({
    required this.isInProgress,
    required this.status,
    required this.exitCode,
  });

  final bool isInProgress;
  final String? status;
  final int? exitCode;

  @override
  Widget build(BuildContext context) {
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    return AnimatedSwitcher(
      duration: disableAnimations
          ? Duration.zero
          : const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeOut,
      transitionBuilder: (child, animation) =>
          FadeTransition(opacity: animation, child: child),
      child: isInProgress
          ? const _ToolInProgressIndicator(key: ValueKey('tool-status-active'))
          : Icon(
              _toolStatusIcon(status, exitCode),
              key: const ValueKey('tool-status-complete'),
              size: 18,
            ),
    );
  }
}

IconData _toolStatusIcon(String? status, int? exitCode) {
  if (exitCode != null) {
    return exitCode == 0 ? Icons.check_circle_outline : Icons.error_outline;
  }
  if (status == 'inProgress' || status == 'started') {
    return Icons.more_horiz;
  }
  return Icons.terminal_rounded;
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.label,
    required this.tone,
    this.pulse = false,
    this.pulseKeySuffix,
  });

  final String label;
  final bool pulse;
  final String? pulseKeySuffix;
  final _StatusPillTone tone;

  @override
  Widget build(BuildContext context) {
    return _AnimatedStatusPill(
      label: label,
      tone: tone,
      pulse: pulse,
      pulseKeySuffix: pulseKeySuffix,
    );
  }
}

class _AnimatedStatusPill extends StatefulWidget {
  const _AnimatedStatusPill({
    required this.label,
    required this.tone,
    required this.pulse,
    this.pulseKeySuffix,
  });

  final String label;
  final _StatusPillTone tone;
  final bool pulse;
  final String? pulseKeySuffix;

  @override
  State<_AnimatedStatusPill> createState() => _AnimatedStatusPillState();
}

class _AnimatedStatusPillState extends State<_AnimatedStatusPill> {
  static const _pulseInterval = Duration(milliseconds: 650);

  Timer? _pulseTimer;
  var _pulseVisible = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPulseTimer();
  }

  @override
  void didUpdateWidget(covariant _AnimatedStatusPill oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pulse != widget.pulse ||
        oldWidget.label != widget.label ||
        oldWidget.pulseKeySuffix != widget.pulseKeySuffix) {
      _syncPulseTimer();
    }
  }

  @override
  void dispose() {
    _pulseTimer?.cancel();
    super.dispose();
  }

  void _syncPulseTimer() {
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    if (disableAnimations || !widget.pulse) {
      _pulseTimer?.cancel();
      _pulseTimer = null;
      _pulseVisible = true;
      return;
    }
    _pulseTimer ??= Timer.periodic(_pulseInterval, (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _pulseVisible = !_pulseVisible;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    _syncPulseTimer();
    final keySuffix = widget.pulseKeySuffix;
    return Opacity(
      key: keySuffix == null
          ? null
          : ValueKey('status-pill-opacity-${widget.label}-$keySuffix'),
      opacity: _pulseVisible ? 1 : 0.24,
      child: Chip(
        backgroundColor: _statusPillColor(widget.tone),
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: EdgeInsets.zero,
        label: Text(widget.label, style: const TextStyle(color: Colors.white)),
      ),
    );
  }
}

enum _StatusPillTone { success, inProgress, failure, neutral }

_StatusPillTone _toolStatusPillTone(String? status, int? exitCode) {
  if (exitCode != null && exitCode != 0) {
    return _StatusPillTone.failure;
  }
  return _statusPillToneForStatus(status);
}

_StatusPillTone _statusPillToneForStatus(String? status) {
  return switch (status) {
    'inProgress' || 'started' => _StatusPillTone.inProgress,
    'failed' || 'cancelled' => _StatusPillTone.failure,
    'completed' => _StatusPillTone.success,
    _ => _StatusPillTone.neutral,
  };
}

Color _statusPillColor(_StatusPillTone tone) {
  return switch (tone) {
    _StatusPillTone.success => const Color(0xFF1E3B2B),
    _StatusPillTone.inProgress => const Color(0xFF5C4318),
    _StatusPillTone.failure => const Color(0xFF5B2222),
    _StatusPillTone.neutral => const Color(0xFF29404D),
  };
}

Color _sessionStatusDotColor(String status) {
  return switch (status) {
    'running' || 'active' => const Color(0xFF43D17A),
    'reconnecting' || 'offline' => const Color(0xFFF0B84A),
    _ => const Color(0xFF9FB3C8),
  };
}

class _CollapsibleFileChangeCard extends StatefulWidget {
  const _CollapsibleFileChangeCard({
    required this.expanded,
    required this.files,
    this.fileKinds = const <String?>[],
    required this.onToggleExpanded,
    required this.summary,
    this.diffs,
    this.status,
  });

  final bool expanded;
  final List<String> files;
  final List<String?> fileKinds;
  final VoidCallback onToggleExpanded;
  final String summary;
  final List<String>? diffs;
  final String? status;

  @override
  State<_CollapsibleFileChangeCard> createState() =>
      _CollapsibleFileChangeCardState();
}

class _CollapsibleFileChangeCardState
    extends State<_CollapsibleFileChangeCard> {
  static const _completionIconDuration = Duration(milliseconds: 600);

  Timer? _completionIconTimer;
  var _showCompletionIcon = false;

  @override
  void didUpdateWidget(covariant _CollapsibleFileChangeCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final wasInProgress =
        oldWidget.status == 'inProgress' || oldWidget.status == 'started';
    final isCompleted = widget.status == 'completed';
    if (wasInProgress && isCompleted) {
      _completionIconTimer?.cancel();
      _showCompletionIcon = true;
      _completionIconTimer = Timer(_completionIconDuration, () {
        if (!mounted) {
          return;
        }
        setState(() {
          _showCompletionIcon = false;
        });
      });
      setState(() {});
    }
    if (!isCompleted && _showCompletionIcon) {
      _completionIconTimer?.cancel();
      _completionIconTimer = null;
      _showCompletionIcon = false;
    }
  }

  @override
  void dispose() {
    _completionIconTimer?.cancel();
    super.dispose();
  }

  Future<void> _showActions() {
    final paths = widget.files.where((file) => file.trim().isNotEmpty).toList();
    final diffs = widget.diffs
        ?.where((diff) => diff.trim().isNotEmpty)
        .toList();
    final actions = <_CardCopyAction>[
      if (paths.isNotEmpty)
        _CardCopyAction(
          label: 'Copy path',
          text: paths.join('\n'),
          snackLabel: 'Path',
        ),
      if (diffs != null && diffs.isNotEmpty)
        _CardCopyAction(
          label: 'Copy diff',
          text: diffs.join('\n\n'),
          snackLabel: 'Diff',
        ),
    ];
    return _showCardCopyActions(context, actions);
  }

  @override
  Widget build(BuildContext context) {
    final accentStatus = widget.status;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: _fileChangeSemanticLabel(widget.summary, widget.status),
      child: Card(
        child: InkWell(
          onTap: widget.onToggleExpanded,
          onLongPress: () {
            unawaited(_showActions());
          },
          child: Stack(
            children: [
              if (accentStatus != null)
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: _FileChangeAccent(status: accentStatus),
                ),
              Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          'Files changed',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        if (_showCompletionIcon) ...[
                          const SizedBox(width: 8),
                          const Icon(
                            Icons.check_circle_outline,
                            key: ValueKey('file-change-completion-icon'),
                            size: 18,
                            color: Color(0xFF43D17A),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 8),
                    _FileChangeCountText(files: widget.files),
                    if (widget.status != null) ...[
                      const SizedBox(height: 8),
                      _StatusPill(
                        label: widget.status!,
                        tone: _statusPillToneForStatus(widget.status),
                      ),
                    ],
                    if (widget.expanded) ...[
                      for (
                        var index = 0;
                        index < widget.files.length;
                        index++
                      ) ...[
                        const SizedBox(height: 8),
                        if (index < widget.fileKinds.length)
                          () {
                            final kind = widget.fileKinds[index];
                            return Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Text(widget.files[index]),
                                if (kind != null)
                                  Text(
                                    kind,
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: const Color(0xFF9FB3C8),
                                        ),
                                  ),
                              ],
                            );
                          }()
                        else
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [Text(widget.files[index])],
                          ),
                      ],
                      _FileChangeDiffSection(
                        diffs: widget.diffs,
                        files: widget.files,
                        status: widget.status,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FileChangeCountText extends StatelessWidget {
  const _FileChangeCountText({required this.files});

  final List<String> files;

  @override
  Widget build(BuildContext context) {
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    final countLabel = _fileChangeCountLabel(files);
    return AnimatedSwitcher(
      duration: disableAnimations
          ? Duration.zero
          : const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeOut,
      transitionBuilder: (child, animation) {
        final childKey = switch (child.key) {
          final ValueKey<Object?> key => key.value,
          _ => countLabel,
        };
        return FadeTransition(
          key: ValueKey('file-change-count-fade-$childKey'),
          opacity: animation,
          child: child,
        );
      },
      child: Text(countLabel, key: ValueKey(countLabel)),
    );
  }
}

class _FileChangeDiffSection extends StatelessWidget {
  const _FileChangeDiffSection({
    required this.diffs,
    required this.files,
    required this.status,
  });

  final List<String>? diffs;
  final List<String> files;
  final String? status;

  @override
  Widget build(BuildContext context) {
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    return AnimatedSwitcher(
      duration: disableAnimations
          ? Duration.zero
          : const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeOut,
      transitionBuilder: (child, animation) {
        final isDiffGroup =
            child.key == const ValueKey('file-change-diff-group-child');
        return FadeTransition(
          key: isDiffGroup
              ? const ValueKey('file-change-diff-group-fade')
              : null,
          opacity: animation,
          child: child,
        );
      },
      child: switch ((diffs, status)) {
        (final diffList?, _) when diffList.isNotEmpty => Padding(
          key: const ValueKey('file-change-diff-group-child'),
          padding: const EdgeInsets.only(top: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var index = 0; index < diffList.length; index++) ...[
                if (index > 0) const SizedBox(height: 10),
                _FileDiffBlock(
                  diff: diffList[index],
                  fileLabel: index < files.length ? files[index] : null,
                ),
              ],
            ],
          ),
        ),
        (_, 'inProgress') => const Padding(
          key: ValueKey('file-change-preparing'),
          padding: EdgeInsets.only(top: 10),
          child: Text('Preparing changes...'),
        ),
        _ => const SizedBox.shrink(
          key: ValueKey('file-change-diff-group-empty'),
        ),
      },
    );
  }
}

class _FileDiffBlock extends StatelessWidget {
  const _FileDiffBlock({required this.diff, this.fileLabel});

  final String diff;
  final String? fileLabel;

  @override
  Widget build(BuildContext context) {
    final lines = const LineSplitter().convert(diff);
    final diffTextScaler = _cappedMonospaceTextScaler(context);
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF09131D),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF223341)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (fileLabel case final label?) ...[
              Text(
                label,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: const Color(0xFF9FB3C8),
                  letterSpacing: 0.4,
                ),
              ),
              const SizedBox(height: 8),
            ],
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final line in lines)
                    Text(
                      line,
                      textScaler: diffTextScaler,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontFamily: 'monospace',
                        color: _diffLineColor(line),
                        height: 1.45,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FileChangeAccent extends StatefulWidget {
  const _FileChangeAccent({required this.status});

  final String status;

  @override
  State<_FileChangeAccent> createState() => _FileChangeAccentState();
}

class _FileChangeAccentState extends State<_FileChangeAccent> {
  static const _scanInterval = Duration(milliseconds: 650);
  static const _scanAnimationDuration = Duration(milliseconds: 180);
  static const _scanLineHeight = 16.0;

  Timer? _scanTimer;
  var _scanLineAtTop = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncScanTimer();
  }

  @override
  void didUpdateWidget(covariant _FileChangeAccent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.status != widget.status) {
      _syncScanTimer();
    }
  }

  @override
  void dispose() {
    _scanTimer?.cancel();
    super.dispose();
  }

  void _syncScanTimer() {
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    final shouldAnimate = switch (widget.status) {
      'inProgress' || 'started' => true,
      _ => false,
    };
    if (disableAnimations || !shouldAnimate) {
      _scanTimer?.cancel();
      _scanTimer = null;
      _scanLineAtTop = true;
      return;
    }
    _scanTimer ??= Timer.periodic(_scanInterval, (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _scanLineAtTop = !_scanLineAtTop;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    _syncScanTimer();
    final borderRadius = const BorderRadius.horizontal(
      left: Radius.circular(12),
      right: Radius.circular(4),
    );
    final accentColor = _fileChangeAccentColor(widget.status);
    final shouldShowScanLine =
        !MediaQuery.disableAnimationsOf(context) &&
        (widget.status == 'inProgress' || widget.status == 'started');
    return SizedBox(
      key: const ValueKey('file-change-in-progress-accent'),
      width: 4,
      child: ClipRRect(
        borderRadius: borderRadius,
        child: Stack(
          children: [
            Positioned.fill(
              child: ColoredBox(color: accentColor),
            ),
            if (shouldShowScanLine)
              AnimatedAlign(
                duration: _scanAnimationDuration,
                curve: Curves.easeInOut,
                alignment: Alignment(0, _scanLineAtTop ? -1 : 1),
                child: Container(
                  key: const ValueKey('file-change-in-progress-scan-line'),
                  width: 4,
                  height: _scanLineHeight,
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color(0x00F8FAFC),
                        Color(0xFFF8FAFC),
                        Color(0x00F8FAFC),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

TextScaler _cappedMonospaceTextScaler(BuildContext context) {
  return MediaQuery.textScalerOf(
    context,
  ).clamp(maxScaleFactor: _monospaceTextMaxScaleFactor);
}

Color _diffLineColor(String line) {
  if (line.startsWith('+')) {
    return const Color(0xFF86EFAC);
  }
  if (line.startsWith('-')) {
    return const Color(0xFFFCA5A5);
  }
  return const Color(0xFF9FB3C8);
}

Color _fileChangeAccentColor(String status) {
  return switch (status) {
    'inProgress' || 'started' || 'completed' => const Color(0xFF43D17A),
    'failed' || 'cancelled' => const Color(0xFFE07A7A),
    _ => const Color(0xFF9FB3C8),
  };
}

class _AssistantPreviewCard extends StatelessWidget {
  const _AssistantPreviewCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Assistant output',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 10),
            Text(
              'Timeline projection will render assistant, reasoning, tool, file, status, and unknown events here.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _ActivityPreviewCard extends StatelessWidget {
  const _ActivityPreviewCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.terminal_rounded),
        title: const Text('shell'),
        subtitle: const Text('Waiting for daemon events'),
        trailing: Text('idle', style: Theme.of(context).textTheme.labelLarge),
      ),
    );
  }
}

class _UserPreviewBubble extends StatelessWidget {
  const _UserPreviewBubble();

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 280),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF1E3B2B),
          borderRadius: BorderRadius.circular(22),
        ),
        child: const Text('User messages will appear here.'),
      ),
    );
  }
}

class _ComposerPreview extends StatelessWidget {
  const _ComposerPreview({
    this.controller,
    this.attachments = const <_UploadedAttachment>[],
    this.removingAttachmentIds = const <int>{},
    this.attachmentError,
    this.sendFailureText,
    this.sendFailureShakeCount = 0,
    this.voiceCancelFadeCount = 0,
    this.composerClearFadeCount = 0,
    this.slashSuggestions = const <String>[],
    this.voiceAvailable = false,
    this.voiceStatusText,
    this.cancelFadingVoiceStatusText,
    this.voiceStatusIndicatorState = _ComposerVoiceStatusIndicatorState.none,
    this.cancelFadingVoiceStatusIndicatorState =
        _ComposerVoiceStatusIndicatorState.none,
    this.voiceRetryAvailable = false,
    this.enabled = false,
    this.canSubmit = false,
    this.isUploading = false,
    this.isSending = false,
    this.isConnectingVoice = false,
    this.isListeningForVoice = false,
    this.onAttachImage,
    this.onKeepEditing,
    this.onRetryAttachmentUpload,
    this.onSelectSlashCommand,
    this.onRetrySend,
    this.onRetryVoiceInput,
    this.onVoiceInput,
    this.onRemoveAttachment,
    this.onSend,
  });

  final TextEditingController? controller;
  final List<_UploadedAttachment> attachments;
  final Set<int> removingAttachmentIds;
  final String? attachmentError;
  final String? sendFailureText;
  final int sendFailureShakeCount;
  final int voiceCancelFadeCount;
  final int composerClearFadeCount;
  final List<String> slashSuggestions;
  final bool voiceAvailable;
  final String? voiceStatusText;
  final String? cancelFadingVoiceStatusText;
  final _ComposerVoiceStatusIndicatorState voiceStatusIndicatorState;
  final _ComposerVoiceStatusIndicatorState cancelFadingVoiceStatusIndicatorState;
  final bool voiceRetryAvailable;
  final bool enabled;
  final bool canSubmit;
  final bool isUploading;
  final bool isSending;
  final bool isConnectingVoice;
  final bool isListeningForVoice;
  final VoidCallback? onAttachImage;
  final VoidCallback? onKeepEditing;
  final ValueChanged<_UploadedAttachment>? onRetryAttachmentUpload;
  final ValueChanged<String>? onSelectSlashCommand;
  final VoidCallback? onRetrySend;
  final VoidCallback? onRetryVoiceInput;
  final VoidCallback? onVoiceInput;
  final ValueChanged<_UploadedAttachment>? onRemoveAttachment;
  final VoidCallback? onSend;

  @override
  Widget build(BuildContext context) {
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    final resolvedVoiceStatusText =
        voiceStatusText ?? cancelFadingVoiceStatusText;
    final defaultUnavailableVoiceStatusText =
        !voiceAvailable && resolvedVoiceStatusText == null
        ? 'Voice input is not configured'
        : null;
    final statusText =
        sendFailureText ??
        resolvedVoiceStatusText ??
        attachmentError ??
        defaultUnavailableVoiceStatusText;
    final showAttachmentChips = attachments.isNotEmpty;
    final showStatusRow = statusText != null;
    final hasUploadedAttachment = attachments.any(
      (attachment) => attachment.isUploaded,
    );
    final sendIcon = isSending
        ? disableAnimations
              ? const Icon(
                  Icons.hourglass_top_rounded,
                  key: ValueKey('composer-send-static-progress-icon'),
                )
              : const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
        : const Icon(Icons.arrow_upward_rounded);
    final voiceIcon = switch ((isConnectingVoice, isListeningForVoice, disableAnimations)) {
      (true, _, true) => const Icon(
        Icons.mic_rounded,
        key: ValueKey('composer-voice-active-static-icon'),
      ),
      (true, _, false) => const SizedBox.square(
        key: ValueKey('composer-voice-connecting-spinner'),
        dimension: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      (false, true, true) => const Icon(
        Icons.mic_rounded,
        key: ValueKey('composer-voice-active-static-icon'),
      ),
      (false, true, false) => const _ListeningVoiceButtonIcon(),
      _ => const Icon(Icons.mic_none_rounded),
    };
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Color(0xFF081018),
        border: Border(top: BorderSide(color: Color(0xFF182631))),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showAttachmentChips || showStatusRow)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (showAttachmentChips)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final attachment in attachments)
                              _AttachmentChip(
                                attachment: attachment,
                                isRemoving: removingAttachmentIds.contains(
                                  attachment.id,
                                ),
                                onRemoveAttachment: onRemoveAttachment,
                                onRetryAttachmentUpload:
                                    onRetryAttachmentUpload,
                              ),
                          ],
                        ),
                      ),
                    if (showAttachmentChips && showStatusRow)
                      const SizedBox(height: 8),
                    if (showStatusRow)
                      _ComposerStatusRow(
                        statusText: statusText,
                        sendFailureText: sendFailureText,
                        sendFailureShakeCount: sendFailureShakeCount,
                        voiceCancelFadeCount: voiceCancelFadeCount,
                        disableAnimations: disableAnimations,
                        voiceStatusIndicatorState: sendFailureText == null
                            ? (voiceStatusText != null
                                  ? voiceStatusIndicatorState
                                  : cancelFadingVoiceStatusIndicatorState)
                            : _ComposerVoiceStatusIndicatorState.none,
                        onRetrySend: onRetrySend,
                        onKeepEditing: onKeepEditing,
                        voiceRetryAvailable: voiceRetryAvailable,
                        onRetryVoiceInput: onRetryVoiceInput,
                      ),
                  ],
                ),
              ),
            if (slashSuggestions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final command in slashSuggestions)
                        ActionChip(
                          label: Text(command),
                          onPressed: () => onSelectSlashCommand?.call(command),
                        ),
                    ],
                  ),
                ),
              ),
            Row(
              children: [
                IconButton(
                  tooltip: 'Attach image',
                  onPressed: enabled && !isUploading ? onAttachImage : null,
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                ),
                Expanded(
                  child: _ComposerInputField(
                    controller: controller,
                    enabled: enabled && !isUploading,
                    composerClearFadeCount: composerClearFadeCount,
                    disableAnimations: disableAnimations,
                    onSubmitted: onSend,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: voiceAvailable
                      ? 'Voice input'
                      : 'Voice input unavailable',
                  onPressed: enabled && !isUploading && voiceAvailable
                      ? onVoiceInput
                      : null,
                  icon: voiceIcon,
                ),
                if (controller case final draftController?)
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: draftController,
                    builder: (context, value, _) {
                      final hasSendableContent =
                          value.text.trim().isNotEmpty || hasUploadedAttachment;
                      return IconButton(
                        tooltip: 'Send',
                        onPressed: canSubmit && hasSendableContent
                            ? onSend
                            : null,
                        icon: sendIcon,
                      );
                    },
                  )
                else
                  IconButton(
                    tooltip: 'Send',
                    onPressed: canSubmit && hasUploadedAttachment
                        ? onSend
                        : null,
                    icon: sendIcon,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ComposerStatusRow extends StatelessWidget {
  const _ComposerStatusRow({
    required this.statusText,
    required this.sendFailureShakeCount,
    required this.disableAnimations,
    this.voiceCancelFadeCount = 0,
    this.voiceStatusIndicatorState = _ComposerVoiceStatusIndicatorState.none,
    this.sendFailureText,
    this.onRetrySend,
    this.onKeepEditing,
    this.voiceRetryAvailable = false,
    this.onRetryVoiceInput,
  });

  final String statusText;
  final String? sendFailureText;
  final int sendFailureShakeCount;
  final bool disableAnimations;
  final int voiceCancelFadeCount;
  final _ComposerVoiceStatusIndicatorState voiceStatusIndicatorState;
  final VoidCallback? onRetrySend;
  final VoidCallback? onKeepEditing;
  final bool voiceRetryAvailable;
  final VoidCallback? onRetryVoiceInput;

  @override
  Widget build(BuildContext context) {
    final isPermissionDeniedStatus =
        statusText == 'Microphone permission denied. Enable it in settings.';
    final row = Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (isPermissionDeniedStatus)
          const Icon(
            Icons.warning_amber_rounded,
            key: ValueKey('composer-voice-permission-warning-icon'),
            size: 16,
          ),
        if (voiceStatusIndicatorState != _ComposerVoiceStatusIndicatorState.none)
          _ComposerVoiceStatusIndicator(
            state: voiceStatusIndicatorState,
            disableAnimations: disableAnimations,
          ),
        Text(statusText, style: Theme.of(context).textTheme.bodyMedium),
        if (sendFailureText != null) ...[
          TextButton(
            key: const ValueKey('composer-retry-send'),
            onPressed: onRetrySend,
            child: const Text('Retry'),
          ),
          TextButton(
            key: const ValueKey('composer-keep-editing'),
            onPressed: onKeepEditing,
            child: const Text('Keep editing'),
          ),
        ] else if (voiceRetryAvailable) ...[
          TextButton(
            onPressed: onRetryVoiceInput,
            child: const Text('Retry voice'),
          ),
        ],
      ],
    );
    if (sendFailureText != null && !disableAnimations) {
      return TweenAnimationBuilder<double>(
        key: ValueKey('composer-status-row-shake-$sendFailureShakeCount'),
        tween: Tween<double>(begin: 1, end: 0),
        duration: const Duration(milliseconds: 320),
        builder: (context, value, child) {
          final offset = math.sin((1 - value) * math.pi * 6) * 6 * value;
          return Transform.translate(
            key: const ValueKey('composer-status-row-shake'),
            offset: Offset(offset, 0),
            child: child,
          );
        },
        child: row,
      );
    }
    if (voiceCancelFadeCount == 0 || disableAnimations) {
      return row;
    }
    return TweenAnimationBuilder<double>(
      key: ValueKey('composer-voice-cancel-fade-$voiceCancelFadeCount'),
      tween: Tween<double>(begin: 1, end: 0),
      duration: const Duration(milliseconds: 180),
      builder: (context, value, child) {
        return FadeTransition(
          key: const ValueKey('composer-voice-cancel-fade'),
          opacity: AlwaysStoppedAnimation<double>(value),
          child: child,
        );
      },
      child: row,
    );
  }
}

class _ComposerVoiceStatusIndicator extends StatelessWidget {
  const _ComposerVoiceStatusIndicator({
    required this.state,
    required this.disableAnimations,
  });

  final _ComposerVoiceStatusIndicatorState state;
  final bool disableAnimations;

  @override
  Widget build(BuildContext context) {
    final showStoppingSpinner =
        state == _ComposerVoiceStatusIndicatorState.stopping;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _VoiceStatusWaveform(
          animate:
              state == _ComposerVoiceStatusIndicatorState.listening &&
              !disableAnimations,
        ),
        if (showStoppingSpinner) ...[
          const SizedBox(width: 6),
          disableAnimations
              ? const Icon(
                  Icons.hourglass_top_rounded,
                  key: ValueKey('composer-voice-status-static-spinner'),
                  size: 14,
                )
              : const SizedBox.square(
                  key: ValueKey('composer-voice-status-spinner'),
                  dimension: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
        ],
      ],
    );
  }
}

class _ComposerInputField extends StatelessWidget {
  const _ComposerInputField({
    required this.controller,
    required this.enabled,
    required this.composerClearFadeCount,
    required this.disableAnimations,
    this.onSubmitted,
  });

  final TextEditingController? controller;
  final bool enabled;
  final int composerClearFadeCount;
  final bool disableAnimations;
  final VoidCallback? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final textField = TextField(
      controller: controller,
      enabled: enabled,
      decoration: InputDecoration(
        hintText: enabled ? 'Message the agent' : 'Connect daemon to send',
      ),
      minLines: 1,
      maxLines: 5,
      onSubmitted: (_) => onSubmitted?.call(),
    );
    if (disableAnimations || composerClearFadeCount == 0) {
      return textField;
    }
    return TweenAnimationBuilder<double>(
      key: ValueKey('composer-clear-fade-$composerClearFadeCount'),
      tween: Tween<double>(begin: 1, end: 0),
      duration: const Duration(milliseconds: 160),
      builder: (context, value, child) {
        return Opacity(
          key: const ValueKey('composer-clear-fade'),
          opacity: value,
          child: child,
        );
      },
      child: textField,
    );
  }
}

class _VoiceStatusWaveform extends StatefulWidget {
  const _VoiceStatusWaveform({required this.animate});

  final bool animate;

  @override
  State<_VoiceStatusWaveform> createState() => _VoiceStatusWaveformState();
}

class _VoiceStatusWaveformState extends State<_VoiceStatusWaveform>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    if (widget.animate) {
      _controller.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant _VoiceStatusWaveform oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animate == oldWidget.animate) {
      return;
    }
    if (widget.animate) {
      _controller.repeat();
    } else {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        const phases = <double>[0.0, 0.2, 0.4, 0.6];
        const baseHeights = <double>[7, 11, 9, 13];
        final progress = widget.animate ? _controller.value : 0.0;
        return SizedBox(
          key: const ValueKey('composer-voice-status-waveform'),
          width: 22,
          height: 14,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var index = 0; index < phases.length; index += 1)
                _VoiceStatusWaveformBar(
                  height:
                      baseHeights[index] *
                      (widget.animate
                          ? 0.72 +
                              (0.28 *
                                  (0.5 +
                                      (0.5 *
                                          math.sin(
                                            (progress + phases[index]) *
                                                math.pi *
                                                2,
                                          ))))
                          : 1),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _VoiceStatusWaveformBar extends StatelessWidget {
  const _VoiceStatusWaveformBar({required this.height});

  final double height;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF9AE6B4),
        borderRadius: BorderRadius.circular(999),
      ),
      child: SizedBox(width: 3, height: height),
    );
  }
}

class _ListeningVoiceButtonIcon extends StatefulWidget {
  const _ListeningVoiceButtonIcon();

  @override
  State<_ListeningVoiceButtonIcon> createState() =>
      _ListeningVoiceButtonIconState();
}

class _ListeningVoiceButtonIconState extends State<_ListeningVoiceButtonIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final progress = _controller.value;
        final scale = 1 + (0.12 * progress);
        final opacity = 0.22 + (0.22 * (1 - progress));
        return SizedBox.square(
          dimension: 24,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Opacity(
                opacity: opacity,
                child: Transform.scale(
                  scale: scale,
                  child: Container(
                    key: const ValueKey('composer-voice-listening-ring'),
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: const Color(0xFF9AE6B4),
                        width: 1.5,
                      ),
                    ),
                  ),
                ),
              ),
              const Icon(Icons.mic_rounded, size: 18),
            ],
          ),
        );
      },
    );
  }
}

class _AttachmentChip extends StatelessWidget {
  const _AttachmentChip({
    required this.attachment,
    this.isRemoving = false,
    this.onRemoveAttachment,
    this.onRetryAttachmentUpload,
  });

  final _UploadedAttachment attachment;
  final bool isRemoving;
  final ValueChanged<_UploadedAttachment>? onRemoveAttachment;
  final ValueChanged<_UploadedAttachment>? onRetryAttachmentUpload;

  @override
  Widget build(BuildContext context) {
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    final chip = switch (attachment.status) {
      _AttachmentUploadState.uploading => Chip(
        avatar: _AttachmentThumbnail(
          attachment: attachment,
          showUploadProgress: !disableAnimations,
        ),
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(attachment.filename),
            const SizedBox(width: 8),
            const Text('Uploading...'),
            const SizedBox(width: 8),
            disableAnimations
                ? Icon(
                    Icons.hourglass_top_rounded,
                    key: ValueKey(
                      'attachment-chip-upload-static-icon-${attachment.filename}',
                    ),
                    size: 14,
                  )
                : const SizedBox.shrink(),
          ],
        ),
      ),
      _AttachmentUploadState.uploaded => InputChip(
        key: ValueKey('attachment-chip-${attachment.filename}'),
        avatar: _AttachmentThumbnail(attachment: attachment),
        deleteIcon: Icon(
          Icons.close_rounded,
          key: ValueKey('attachment-chip-delete-${attachment.filename}'),
          size: 18,
        ),
        label: Text(attachment.filename),
        onDeleted: onRemoveAttachment == null
            ? null
            : () => onRemoveAttachment!(attachment),
      ),
      _AttachmentUploadState.uploadedSuccess => InputChip(
        key: ValueKey('attachment-chip-${attachment.filename}'),
        avatar: _AttachmentThumbnail(attachment: attachment),
        deleteIcon: Icon(
          Icons.close_rounded,
          key: ValueKey('attachment-chip-delete-${attachment.filename}'),
          size: 18,
        ),
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(attachment.filename),
            const SizedBox(width: 8),
            const Icon(
              Icons.check_circle_outline,
              key: ValueKey('attachment-chip-success-icon'),
              size: 16,
              color: Color(0xFF86EFAC),
            ),
          ],
        ),
        onDeleted: onRemoveAttachment == null
            ? null
            : () => onRemoveAttachment!(attachment),
      ),
      _AttachmentUploadState.failed => Container(
        decoration: BoxDecoration(
          color: const Color(0xFF2A1416),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: const Color(0xFF8B3434)),
        ),
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _AttachmentThumbnail(attachment: attachment),
            const SizedBox(width: 6),
            Text(attachment.filename),
            const SizedBox(width: 6),
            const Icon(
              Icons.error_outline_rounded,
              size: 16,
              color: Color(0xFFE7A3A3),
            ),
            const SizedBox(width: 4),
            TextButton(
              key: ValueKey('attachment-chip-retry-${attachment.filename}'),
              onPressed: onRetryAttachmentUpload == null
                  ? null
                  : () => onRetryAttachmentUpload!(attachment),
              child: const Text('Retry'),
            ),
            IconButton(
              key: ValueKey('attachment-chip-delete-${attachment.filename}'),
              onPressed: onRemoveAttachment == null
                  ? null
                  : () => onRemoveAttachment!(attachment),
              icon: const Icon(Icons.close_rounded, size: 18),
              visualDensity: VisualDensity.compact,
              tooltip: 'Remove attachment',
            ),
          ],
        ),
      ),
    };
    if (disableAnimations) {
      return chip;
    }
    if (isRemoving) {
      return TweenAnimationBuilder<double>(
        key: ValueKey('attachment-chip-remove-${attachment.filename}'),
        tween: Tween<double>(begin: 1, end: 0),
        duration: _SessionDetailPageState._attachmentRemovalAnimationDuration,
        builder: (context, value, child) {
          final scale = 0.96 + (0.04 * value);
          return Opacity(
            opacity: value,
            child: Transform.scale(scale: scale, child: child),
          );
        },
        child: chip,
      );
    }
    return TweenAnimationBuilder<double>(
      key: ValueKey('attachment-chip-appear-${attachment.filename}'),
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 180),
      builder: (context, value, child) {
        final scale = 0.96 + (0.04 * value);
        return Opacity(
          opacity: value,
          child: Transform.scale(scale: scale, child: child),
        );
      },
      child: chip,
    );
  }
}

class _AttachmentThumbnail extends StatelessWidget {
  const _AttachmentThumbnail({
    required this.attachment,
    this.showUploadProgress = false,
  });

  final _UploadedAttachment attachment;
  final bool showUploadProgress;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox.square(
        key: ValueKey('attachment-chip-thumbnail-${attachment.filename}'),
        dimension: 28,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.memory(
              Uint8List.fromList(attachment.bytes),
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) {
                return Container(
                  color: const Color(0xFF17232D),
                  alignment: Alignment.center,
                  child: const Icon(Icons.image_outlined, size: 16),
                );
              },
            ),
            if (showUploadProgress)
              ColoredBox(
                color: const Color(0x9905100A),
                child: Center(
                  child: SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(
                      key: ValueKey(
                        'attachment-chip-upload-progress-${attachment.filename}',
                      ),
                      strokeWidth: 2,
                      color: const Color(0xFF86EFAC),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

enum _AttachmentUploadState { uploading, uploadedSuccess, uploaded, failed }

class _UploadedAttachment {
  const _UploadedAttachment({
    required this.id,
    required this.filename,
    required this.contentType,
    required this.bytes,
    required this.status,
    this.path,
  });

  factory _UploadedAttachment.pending({
    required int id,
    required String filename,
    required String contentType,
    required List<int> bytes,
  }) {
    return _UploadedAttachment(
      id: id,
      filename: filename,
      contentType: contentType,
      bytes: List<int>.from(bytes),
      status: _AttachmentUploadState.uploading,
    );
  }

  final int id;
  final String filename;
  final String contentType;
  final List<int> bytes;
  final _AttachmentUploadState status;
  final String? path;

  bool get isUploaded =>
      (status == _AttachmentUploadState.uploaded ||
          status == _AttachmentUploadState.uploadedSuccess) &&
      path != null;

  _UploadedAttachment copyWith({String? path, _AttachmentUploadState? status}) {
    return _UploadedAttachment(
      id: id,
      filename: filename,
      contentType: contentType,
      bytes: bytes,
      status: status ?? this.status,
      path: path ?? this.path,
    );
  }
}
