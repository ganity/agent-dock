import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/agent_dock_app.dart' show agentDockAppVersion;
import '../session_detail/session_detail_page.dart';
import '../../shared/api/daemon_client.dart';
import '../../shared/external_links/external_link_opener.dart';
import '../../shared/media/image_attachment_picker.dart';
import '../../shared/media/share_attachments.dart';
import '../../shared/delayed_inline_spinner.dart';
import '../../shared/storage/session_composer_draft_store.dart';
import '../../shared/storage/session_detail_cache_store.dart';
import '../../shared/storage/session_outbox_store.dart';
import '../../shared/storage/voice_credentials_storage.dart';
import '../../shared/voice/voice_input_controller.dart';

const _sessionsOfflineText = 'Offline. Waiting for network...';
const _minimumSupportedDaemonVersion = '0.1.0';

String _userFacingSheetErrorText(Object error, {required String fallbackText}) {
  if (error is SocketException) {
    return _sessionsOfflineText;
  }
  return switch (error) {
    DaemonApiException(:final message) => message,
    _ => fallbackText,
  };
}

class _ResolvedOpenSession {
  const _ResolvedOpenSession({
    required this.summary,
    required this.initialSnapshot,
    required this.resumeInBackground,
  });

  final SessionSummary summary;
  final SessionSnapshot? initialSnapshot;
  final bool resumeInBackground;
}

_ResolvedOpenSession _resolveSessionForOpen({required SessionSummary session}) {
  final runtimeHealth = session.runtimeHealth.toLowerCase();
  final runtimeErrorKind = session.runtimeErrorKind?.toLowerCase();
  final shouldResumeForRuntimeHealth =
      runtimeHealth == 'offline' ||
      (runtimeHealth == 'unknown' &&
          (session.runtimeSessionId?.isNotEmpty ?? false)) ||
      (runtimeHealth == 'recoverable_error' &&
          (runtimeErrorKind == null ||
              runtimeErrorKind == 'runtime' ||
              runtimeErrorKind == 'stale_thread'));

  if (session.status.toLowerCase() != 'suspended' &&
      !shouldResumeForRuntimeHealth) {
    return _ResolvedOpenSession(
      summary: session,
      initialSnapshot: null,
      resumeInBackground: false,
    );
  }

  return _ResolvedOpenSession(
    summary: session,
    initialSnapshot: null,
    resumeInBackground: true,
  );
}

class SessionsPage extends StatefulWidget {
  const SessionsPage({
    super.key,
    required this.api,
    required this.attachmentPicker,
    required this.openExternalLink,
    required this.shareAttachments,
    required this.voiceInputController,
    required this.showDebugTimelineItems,
    required this.token,
    required this.bootstrap,
    required this.loadBootstrapOnInit,
    required this.daemonUrl,
    required this.currentUserId,
    required this.composerDraftStore,
    required this.sessionDetailCacheStore,
    required this.outboxStore,
    required this.voiceCredentialsStorage,
    required this.onVoiceSettingsChanged,
    required this.onBootstrapLoaded,
    required this.onChangeDaemon,
    required this.onSelectSession,
    required this.onSessionExpired,
    required this.onSignOut,
  });

  final DaemonApi api;
  final ImageAttachmentPicker attachmentPicker;
  final ExternalLinkOpener openExternalLink;
  final ShareAttachments shareAttachments;
  final VoiceInputController voiceInputController;
  final bool? showDebugTimelineItems;
  final String token;
  final MobileBootstrap bootstrap;
  final bool loadBootstrapOnInit;
  final Uri daemonUrl;
  final String currentUserId;
  final SessionComposerDraftStore composerDraftStore;
  final SessionDetailCacheStore sessionDetailCacheStore;
  final SessionOutboxStore outboxStore;
  final VoiceCredentialsStorage voiceCredentialsStorage;
  final Future<void> Function() onVoiceSettingsChanged;
  final Future<void> Function(MobileBootstrap bootstrap) onBootstrapLoaded;
  final Future<void> Function() onChangeDaemon;
  final Future<void> Function(String sessionId) onSelectSession;
  final Future<void> Function() onSessionExpired;
  final Future<void> Function() onSignOut;

  @override
  State<SessionsPage> createState() => _SessionsPageState();
}

class _SessionsPageState extends State<SessionsPage>
    with WidgetsBindingObserver {
  late MobileBootstrap _bootstrap;
  late VoiceInputController _effectiveVoiceInputController;
  late final List<SessionSummary> _sessions;
  final Set<String> _deletingSessionIds = <String>{};
  final Set<String> _removingSessionIds = <String>{};
  final Set<String> _enteringSessionIds = <String>{};
  late bool _isBootstrapLoading;
  String? _statusBannerText;

  bool get _isUnsupportedDaemonVersion =>
      !_isDaemonVersionSupported(_bootstrap.daemonVersion);

  bool get _isVoiceConfigured =>
      (_bootstrap.voice.providerCredentials?.isUsable ?? false) ||
      _effectiveVoiceInputController.isConfigured;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bootstrap = widget.bootstrap;
    _effectiveVoiceInputController = widget.voiceInputController;
    _sessions = List<SessionSummary>.from(widget.bootstrap.sessions);
    _isBootstrapLoading = widget.loadBootstrapOnInit;
    if (_isBootstrapLoading) {
      unawaited(_loadBootstrap());
    }
  }

  @override
  void didUpdateWidget(covariant SessionsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bootstrap != widget.bootstrap) {
      _bootstrap = widget.bootstrap;
      _sessions
        ..clear()
        ..addAll(widget.bootstrap.sessions);
    }
    if (oldWidget.voiceInputController != widget.voiceInputController) {
      _effectiveVoiceInputController = widget.voiceInputController;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshSessions());
    }
  }

  List<SessionSummary> get _sortedSessions {
    final sessions = List<SessionSummary>.from(_sessions);
    sessions.sort((left, right) {
      final order = _statusPriority(
        left.status,
      ).compareTo(_statusPriority(right.status));
      if (order != 0) {
        return order;
      }
      return (left.title ?? left.workspacePath).compareTo(
        right.title ?? right.workspacePath,
      );
    });
    return sessions;
  }

  int _statusPriority(String status) {
    final normalized = status.toLowerCase();
    return switch (normalized) {
      'running' || 'active' => 0,
      'idle' => 1,
      'completed' => 2,
      _ => 3,
    };
  }

  Future<void> _refreshSessions() async {
    try {
      final bootstrap = await widget.api.bootstrap(token: widget.token);
      if (!mounted) {
        return;
      }
      setState(() {
        _bootstrap = bootstrap;
        _sessions
          ..clear()
          ..addAll(bootstrap.sessions);
        _isBootstrapLoading = false;
        _statusBannerText = null;
      });
    } on DaemonApiException catch (error) {
      if (error.statusCode == 401) {
        await widget.onSessionExpired();
        return;
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _statusBannerText = _sessionsStatusBannerText(error);
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _statusBannerText = _sessionsStatusBannerText(error);
      });
    }
  }

  Future<void> _loadBootstrap() async {
    try {
      final bootstrap = await widget.api.bootstrap(token: widget.token);
      if (!mounted) {
        return;
      }
      setState(() {
        _bootstrap = bootstrap;
        _sessions
          ..clear()
          ..addAll(bootstrap.sessions);
        _isBootstrapLoading = false;
        _statusBannerText = null;
      });
      unawaited(widget.onBootstrapLoaded(bootstrap));
    } on DaemonApiException catch (error) {
      if (error.statusCode == 401) {
        await widget.onSessionExpired();
        return;
      }
      if (!mounted) {
        return;
      }
      setState(() {
        if (_sessions.isNotEmpty) {
          _isBootstrapLoading = false;
        }
        _statusBannerText = _sessionsStatusBannerText(error);
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        if (_sessions.isNotEmpty) {
          _isBootstrapLoading = false;
        }
        _statusBannerText = _sessionsStatusBannerText(error);
      });
    }
  }

  String _sessionsStatusBannerText(Object error) {
    if (error is SocketException) {
      return _sessionsOfflineText;
    }
    return switch (error) {
      DaemonApiException(:final message) => message,
      _ => 'Could not refresh sessions',
    };
  }

  @override
  Widget build(BuildContext context) {
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    final isUnsupportedDaemonVersion = _isUnsupportedDaemonVersion;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text('Sessions'),
            const SizedBox(width: 10),
            Flexible(
              child: _AppBarConnectionStatus(
                host: widget.daemonUrl.host,
                isOffline: _statusBannerText == _sessionsOfflineText,
              ),
            ),
          ],
        ),
        actions: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 96),
              child: Text(
                _bootstrap.user.displayName,
                key: const ValueKey('sessions-appbar-user'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Settings',
            onPressed: () => _openSettings(context),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _refreshSessions,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(20),
            children: [
              if (_statusBannerText case final bannerText?) ...[
                _SessionsStatusBanner(text: bannerText),
                const SizedBox(height: 12),
              ],
              if (isUnsupportedDaemonVersion) ...[
                _DaemonVersionWarningCard(
                  daemonVersion: _bootstrap.daemonVersion,
                  requiredVersion: _minimumSupportedDaemonVersion,
                  onChangeDaemon: widget.onChangeDaemon,
                ),
              ],
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed:
                          _bootstrap.roots.isEmpty || isUnsupportedDaemonVersion
                          ? null
                          : () => _openCreateSessionDialog(context),
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('New session'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed:
                          _bootstrap.roots.isEmpty || isUnsupportedDaemonVersion
                          ? null
                          : () => _openAttachSessionDialog(context),
                      icon: const Icon(Icons.link_rounded),
                      label: const Text('Attach'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              AnimatedSwitcher(
                duration: disableAnimations
                    ? Duration.zero
                    : const Duration(milliseconds: 160),
                child: _isBootstrapLoading
                    ? const _SessionsSkeletonList()
                    : _sessions.isEmpty
                    ? _EmptySessionsCard(
                        onCreateSession:
                            _bootstrap.roots.isEmpty ||
                                isUnsupportedDaemonVersion
                            ? null
                            : () => _openCreateSessionDialog(context),
                        onAttachRuntime:
                            _bootstrap.roots.isEmpty ||
                                isUnsupportedDaemonVersion
                            ? null
                            : () => _openAttachSessionDialog(context),
                      )
                    : _SessionList(
                        key: const ValueKey('sessions-loaded-list'),
                        api: widget.api,
                        attachmentPicker: widget.attachmentPicker,
                        openExternalLink: widget.openExternalLink,
                        shareAttachments: widget.shareAttachments,
                        daemonUrl: widget.daemonUrl,
                        currentUserId: widget.currentUserId,
                        composerDraftStore: widget.composerDraftStore,
                        sessionDetailCacheStore: widget.sessionDetailCacheStore,
                        outboxStore: widget.outboxStore,
                        voiceInputController: _effectiveVoiceInputController,
                        showDebugTimelineItems: widget.showDebugTimelineItems,
                        voice: _bootstrap.voice,
                        token: widget.token,
                        sessions: _sortedSessions,
                        canOpenSessions: !isUnsupportedDaemonVersion,
                        deletingSessionIds: _deletingSessionIds,
                        removingSessionIds: _removingSessionIds,
                        enteringSessionIds: _enteringSessionIds,
                        onDeleteFromActions: _deleteSessionFromActions,
                        onDeleteImmediately:
                            _deleteSessionImmediatelyFromDetail,
                        onRefreshAfterReturn: _refreshSessions,
                        onSelectSession: widget.onSelectSession,
                        onSessionExpired: widget.onSessionExpired,
                        onSignOut: widget.onSignOut,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openSettings(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: FractionallySizedBox(
          heightFactor: 0.8,
          child: _SettingsSheet(
            userDisplayName: _bootstrap.user.displayName,
            daemonHost: widget.daemonUrl.host,
            daemonUrl: widget.daemonUrl.toString(),
            appVersion: agentDockAppVersion,
            daemonVersion: _bootstrap.daemonVersion,
            isOffline: _statusBannerText == _sessionsOfflineText,
            voiceConfigured: _isVoiceConfigured,
            onTestConnection: () => _testConnection(),
            onConfigureVoice: () async {
              Navigator.of(context).pop();
              await _openVoiceSettings(context);
            },
            onChangeDaemon: () async {
              Navigator.of(context).pop();
              await _openChangeDaemon(context);
            },
            onSignOut: () async {
              Navigator.of(context).pop();
              await widget.onSignOut();
            },
          ),
        ),
      ),
    );
  }

  Future<String> _testConnection() async {
    try {
      await widget.api.bootstrap(token: widget.token);
      return 'Connection looks good';
    } on Object catch (error) {
      return _sessionsStatusBannerText(error);
    }
  }

  Future<void> _openVoiceSettings(BuildContext context) async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: FractionallySizedBox(
          heightFactor: 0.8,
          child: _VoiceSettingsDialog(
            storage: widget.voiceCredentialsStorage,
            scope: VoiceCredentialScope(
              daemonUrl: widget.daemonUrl,
              userId: _bootstrap.user.id,
            ),
            daemonManagedVoiceAvailable:
                _bootstrap.voice.providerCredentials?.isUsable ?? false,
            onTestConnection: _testConnection,
          ),
        ),
      ),
    );
    if (result == true) {
      await widget.onVoiceSettingsChanged();
    }
  }

  Future<void> _openChangeDaemon(BuildContext context) async {
    final hasRunningSession = _sessions.any((session) {
      final normalized = session.status.toLowerCase();
      return normalized == 'running';
    });
    if (hasRunningSession) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Change daemon?'),
          content: const Text('A running session may disconnect. Continue?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Stay'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Change daemon'),
            ),
          ],
        ),
      );
      if (confirmed != true) {
        return;
      }
    }

    await widget.onChangeDaemon();
  }

  Future<void> _openCreateSessionDialog(BuildContext context) async {
    final navigator = Navigator.of(context);
    final created = await showModalBottomSheet<SessionSummary>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: FractionallySizedBox(
          heightFactor: 0.96,
          child: _CreateSessionDialog(
            api: widget.api,
            token: widget.token,
            roots: _bootstrap.roots,
            onSessionExpired: widget.onSessionExpired,
          ),
        ),
      ),
    );

    if (created == null || !mounted) {
      return;
    }
    setState(() {
      _sessions.insert(0, created);
      _enteringSessionIds.add(created.id);
    });
    unawaited(widget.onSelectSession(created.id));
    unawaited(_clearEnteringSession(created.id));
    if (!mounted) {
      return;
    }
    await navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => SessionDetailPage(
          api: widget.api,
          daemonUrl: widget.daemonUrl,
          attachmentPicker: widget.attachmentPicker,
          openExternalLink: widget.openExternalLink,
          shareAttachments: widget.shareAttachments,
          voiceInputController: _effectiveVoiceInputController,
          showDebugTimelineItems: widget.showDebugTimelineItems,
          currentUserId: widget.currentUserId,
          composerDraftStore: widget.composerDraftStore,
          sessionDetailCacheStore: widget.sessionDetailCacheStore,
          outboxStore: widget.outboxStore,
          voice: _bootstrap.voice,
          token: widget.token,
          session: created,
          resumeInBackground: false,
          onDeleteSession: _deleteSessionImmediatelyFromDetail,
          onUnauthorized: widget.onSessionExpired,
        ),
      ),
    );
    if (!mounted) {
      return;
    }
    unawaited(_refreshSessions());
  }

  Future<void> _openAttachSessionDialog(BuildContext context) async {
    final navigator = Navigator.of(context);
    final attached = await showModalBottomSheet<SessionSummary>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: FractionallySizedBox(
          heightFactor: 0.96,
          child: _AttachSessionDialog(
            api: widget.api,
            token: widget.token,
            roots: _bootstrap.roots,
            recentSessions: _bootstrap.sessions,
            onSessionExpired: widget.onSessionExpired,
          ),
        ),
      ),
    );

    if (attached == null || !mounted) {
      return;
    }
    setState(() {
      _sessions.insert(0, attached);
    });
    unawaited(widget.onSelectSession(attached.id));
    if (!mounted) {
      return;
    }
    await navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => SessionDetailPage(
          api: widget.api,
          daemonUrl: widget.daemonUrl,
          attachmentPicker: widget.attachmentPicker,
          openExternalLink: widget.openExternalLink,
          shareAttachments: widget.shareAttachments,
          voiceInputController: _effectiveVoiceInputController,
          showDebugTimelineItems: widget.showDebugTimelineItems,
          currentUserId: widget.currentUserId,
          composerDraftStore: widget.composerDraftStore,
          sessionDetailCacheStore: widget.sessionDetailCacheStore,
          outboxStore: widget.outboxStore,
          voice: _bootstrap.voice,
          token: widget.token,
          session: attached,
          resumeInBackground: false,
          onDeleteSession: _deleteSessionImmediatelyFromDetail,
          onUnauthorized: widget.onSessionExpired,
        ),
      ),
    );
    if (!mounted) {
      return;
    }
    unawaited(_refreshSessions());
  }

  Future<bool> _confirmDeleteSession(SessionSummary session) async {
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

    return confirmed == true;
  }

  Future<String?> _deleteSessionFromActions(SessionSummary session) async {
    if (!await _confirmDeleteSession(session)) {
      return null;
    }
    return _deleteSessionImmediately(session);
  }

  Future<String?> _deleteSessionImmediately(SessionSummary session) async {
    final disableAnimations =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    setState(() {
      _deletingSessionIds.add(session.id);
    });
    try {
      await widget.api.deleteSession(
        sessionId: session.id,
        token: widget.token,
      );
      if (!mounted) {
        return null;
      }
      setState(() {
        _deletingSessionIds.remove(session.id);
        _removingSessionIds.add(session.id);
      });
      await Future<void>.delayed(
        disableAnimations ? Duration.zero : const Duration(milliseconds: 180),
      );
      if (!mounted) {
        return null;
      }
      setState(() {
        _sessions.removeWhere((item) => item.id == session.id);
        _removingSessionIds.remove(session.id);
      });
      return null;
    } on Object catch (error) {
      if (error is DaemonApiException && error.statusCode == 401) {
        await widget.onSessionExpired();
        return 'Unauthorized';
      }
      if (!mounted) {
        return 'Unavailable';
      }
      return switch (error) {
        DaemonApiException(:final message) => message,
        _ => 'Could not delete session',
      };
    } finally {
      if (mounted) {
        setState(() {
          _deletingSessionIds.remove(session.id);
          _removingSessionIds.remove(session.id);
        });
      }
    }
  }

  Future<bool> _deleteSessionImmediatelyFromDetail(
    SessionSummary session,
  ) async {
    final errorMessage = await _deleteSessionImmediately(session);
    if (!mounted) {
      return false;
    }
    if (errorMessage == null) {
      return true;
    }
    if (errorMessage == 'Unauthorized') {
      return false;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(errorMessage)));
    return false;
  }

  Future<void> _clearEnteringSession(String sessionId) async {
    final disableAnimations =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    await Future<void>.delayed(
      disableAnimations ? Duration.zero : const Duration(milliseconds: 40),
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _enteringSessionIds.remove(sessionId);
    });
  }
}

class _DaemonVersionWarningCard extends StatelessWidget {
  const _DaemonVersionWarningCard({
    required this.daemonVersion,
    required this.requiredVersion,
    required this.onChangeDaemon,
  });

  final String daemonVersion;
  final String requiredVersion;
  final Future<void> Function() onChangeDaemon;

  @override
  Widget build(BuildContext context) {
    return Card(
      key: const ValueKey('daemon-version-warning'),
      color: const Color(0xFF3B2A12),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.warning_amber_rounded),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Unsupported daemon version',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text('Daemon version $daemonVersion'),
            const SizedBox(height: 4),
            Text('Requires daemon version $requiredVersion or newer'),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                onPressed: onChangeDaemon,
                child: const Text('Change daemon'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SessionsStatusBanner extends StatelessWidget {
  const _SessionsStatusBanner({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('sessions-status-banner'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF3B2A12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFF0B84A)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.wifi_off_rounded,
            size: 18,
            color: Color(0xFFF0B84A),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

class _AppBarConnectionStatus extends StatelessWidget {
  const _AppBarConnectionStatus({required this.host, required this.isOffline});

  final String host;
  final bool isOffline;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('sessions-appbar-connection'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFF101820),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFF29404D)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            key: const ValueKey('sessions-appbar-status-dot'),
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: isOffline
                  ? const Color(0xFFF0B84A)
                  : const Color(0xFF43D17A),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              host,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

class _SessionsSkeletonList extends StatelessWidget {
  const _SessionsSkeletonList();

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const ValueKey('sessions-skeleton-list'),
      children: const [
        _SessionSkeletonRow(index: 0),
        SizedBox(height: 12),
        _SessionSkeletonRow(index: 1),
        SizedBox(height: 12),
        _SessionSkeletonRow(index: 2),
      ],
    );
  }
}

class _SessionSkeletonRow extends StatelessWidget {
  const _SessionSkeletonRow({required this.index});

  final int index;

  @override
  Widget build(BuildContext context) {
    return Card(
      key: ValueKey('sessions-skeleton-row-$index'),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: _SkeletonShimmer(
          shimmerKey: ValueKey('sessions-skeleton-shimmer-$index'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              _SkeletonLine(width: 168, height: 18),
              SizedBox(height: 12),
              Row(
                children: [
                  _SkeletonLine(width: 64, height: 12),
                  SizedBox(width: 8),
                  _SkeletonLine(width: 72, height: 12),
                ],
              ),
              SizedBox(height: 12),
              _SkeletonLine(width: double.infinity, height: 12),
              SizedBox(height: 8),
              _SkeletonLine(width: 220, height: 12),
            ],
          ),
        ),
      ),
    );
  }
}

class _SkeletonShimmer extends StatefulWidget {
  const _SkeletonShimmer({required this.child, required this.shimmerKey});

  final Widget child;
  final Key shimmerKey;

  @override
  State<_SkeletonShimmer> createState() => _SkeletonShimmerState();
}

class _SkeletonShimmerState extends State<_SkeletonShimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final disableAnimations =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (disableAnimations) {
      _controller.stop();
      return;
    }
    if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return widget.child;
    }
    return AnimatedBuilder(
      key: widget.shimmerKey,
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
              Color(0xFF223241),
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

class _SkeletonLine extends StatelessWidget {
  const _SkeletonLine({required this.width, required this.height});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: const Color(0xFF17232D),
        borderRadius: BorderRadius.circular(999),
      ),
    );
  }
}

class _SessionList extends StatelessWidget {
  const _SessionList({
    super.key,
    required this.api,
    required this.attachmentPicker,
    required this.openExternalLink,
    required this.shareAttachments,
    required this.daemonUrl,
    required this.currentUserId,
    required this.composerDraftStore,
    required this.sessionDetailCacheStore,
    required this.outboxStore,
    required this.voiceInputController,
    required this.showDebugTimelineItems,
    required this.voice,
    required this.token,
    required this.sessions,
    required this.canOpenSessions,
    required this.deletingSessionIds,
    required this.removingSessionIds,
    required this.enteringSessionIds,
    required this.onDeleteFromActions,
    required this.onDeleteImmediately,
    required this.onRefreshAfterReturn,
    required this.onSelectSession,
    required this.onSessionExpired,
    required this.onSignOut,
  });

  final DaemonApi api;
  final ImageAttachmentPicker attachmentPicker;
  final ExternalLinkOpener openExternalLink;
  final ShareAttachments shareAttachments;
  final Uri daemonUrl;
  final String currentUserId;
  final SessionComposerDraftStore composerDraftStore;
  final SessionDetailCacheStore sessionDetailCacheStore;
  final SessionOutboxStore outboxStore;
  final VoiceInputController voiceInputController;
  final bool? showDebugTimelineItems;
  final VoiceConfig voice;
  final String token;
  final List<SessionSummary> sessions;
  final bool canOpenSessions;
  final Set<String> deletingSessionIds;
  final Set<String> removingSessionIds;
  final Set<String> enteringSessionIds;
  final Future<String?> Function(SessionSummary session) onDeleteFromActions;
  final Future<bool> Function(SessionSummary session) onDeleteImmediately;
  final Future<void> Function() onRefreshAfterReturn;
  final Future<void> Function(String sessionId) onSelectSession;
  final Future<void> Function() onSessionExpired;
  final Future<void> Function() onSignOut;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: sessions.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        return _SessionRow(
          api: api,
          attachmentPicker: attachmentPicker,
          openExternalLink: openExternalLink,
          shareAttachments: shareAttachments,
          daemonUrl: daemonUrl,
          currentUserId: currentUserId,
          composerDraftStore: composerDraftStore,
          sessionDetailCacheStore: sessionDetailCacheStore,
          outboxStore: outboxStore,
          voiceInputController: voiceInputController,
          showDebugTimelineItems: showDebugTimelineItems,
          voice: voice,
          token: token,
          session: sessions[index],
          canOpenSession: canOpenSessions,
          isDeleting: deletingSessionIds.contains(sessions[index].id),
          isRemoving: removingSessionIds.contains(sessions[index].id),
          isEntering: enteringSessionIds.contains(sessions[index].id),
          onDeleteFromActions: onDeleteFromActions,
          onDeleteImmediately: onDeleteImmediately,
          onRefreshAfterReturn: onRefreshAfterReturn,
          onSelectSession: onSelectSession,
          onSessionExpired: onSessionExpired,
          onSignOut: onSignOut,
        );
      },
    );
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.api,
    required this.attachmentPicker,
    required this.openExternalLink,
    required this.shareAttachments,
    required this.daemonUrl,
    required this.currentUserId,
    required this.composerDraftStore,
    required this.sessionDetailCacheStore,
    required this.outboxStore,
    required this.voiceInputController,
    required this.showDebugTimelineItems,
    required this.voice,
    required this.token,
    required this.session,
    required this.canOpenSession,
    required this.isDeleting,
    required this.isRemoving,
    required this.isEntering,
    required this.onDeleteFromActions,
    required this.onDeleteImmediately,
    required this.onRefreshAfterReturn,
    required this.onSelectSession,
    required this.onSessionExpired,
    required this.onSignOut,
  });

  final DaemonApi api;
  final ImageAttachmentPicker attachmentPicker;
  final ExternalLinkOpener openExternalLink;
  final ShareAttachments shareAttachments;
  final Uri daemonUrl;
  final String currentUserId;
  final SessionComposerDraftStore composerDraftStore;
  final SessionDetailCacheStore sessionDetailCacheStore;
  final SessionOutboxStore outboxStore;
  final VoiceInputController voiceInputController;
  final bool? showDebugTimelineItems;
  final VoiceConfig voice;
  final String token;
  final SessionSummary session;
  final bool canOpenSession;
  final bool isDeleting;
  final bool isRemoving;
  final bool isEntering;
  final Future<String?> Function(SessionSummary session) onDeleteFromActions;
  final Future<bool> Function(SessionSummary session) onDeleteImmediately;
  final Future<void> Function() onRefreshAfterReturn;
  final Future<void> Function(String sessionId) onSelectSession;
  final Future<void> Function() onSessionExpired;
  final Future<void> Function() onSignOut;

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

  Future<void> _openSession(BuildContext context) async {
    final navigator = Navigator.of(context);
    final resolved = _resolveSessionForOpen(session: session);
    final resolvedSession = resolved.summary;
    unawaited(onSelectSession(resolvedSession.id));
    await navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => SessionDetailPage(
          api: api,
          daemonUrl: daemonUrl,
          attachmentPicker: attachmentPicker,
          openExternalLink: openExternalLink,
          shareAttachments: shareAttachments,
          voiceInputController: voiceInputController,
          showDebugTimelineItems: showDebugTimelineItems,
          currentUserId: currentUserId,
          composerDraftStore: composerDraftStore,
          sessionDetailCacheStore: sessionDetailCacheStore,
          outboxStore: outboxStore,
          voice: voice,
          token: token,
          session: resolvedSession,
          initialSnapshot: resolved.initialSnapshot,
          resumeInBackground: resolved.resumeInBackground,
          onDeleteSession: onDeleteImmediately,
          onUnauthorized: onSessionExpired,
        ),
      ),
    );
    if (!navigator.mounted) {
      return;
    }
    unawaited(onRefreshAfterReturn());
  }

  Future<void> _openSessionActions(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => _SessionActionsSheet(
        session: session,
        onOpenDetails: () => _showSessionDetailsSheet(context),
        onOpenSession: () => _openSession(context),
        onCopyWorkspacePath: () =>
            _copyToClipboard(context, session.workspacePath, 'Workspace path'),
        onCopyRuntimeSessionId:
            session.runtimeSessionId == null ||
                session.runtimeSessionId!.isEmpty
            ? null
            : () => _copyToClipboard(
                context,
                session.runtimeSessionId!,
                'Runtime session ID',
              ),
        onDeleteSession: () async {
          final errorMessage = await onDeleteFromActions(session);
          if (!sheetContext.mounted) {
            return errorMessage;
          }
          if (errorMessage == null) {
            Navigator.of(sheetContext).pop();
          }
          return errorMessage;
        },
      ),
    );
  }

  Future<void> _showSessionDetailsSheet(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => _SessionRowDetailsSheet(
        title: _sessionDisplayTitle(session),
        daemonUrlHost: daemonUrl.host,
        agentKind: session.agentKind,
        sourceKind: session.sourceKind,
        status: session.status,
        workspacePath: session.workspacePath,
        runtimeSessionId: session.runtimeSessionId,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    final duration = disableAnimations
        ? Duration.zero
        : const Duration(milliseconds: 180);
    final title = _sessionDisplayTitle(session);
    final workspacePath = _formatSessionWorkspacePath(session.workspacePath);
    return AnimatedAlign(
      key: ValueKey('session-row-collapse-${session.id}'),
      duration: duration,
      alignment: Alignment.topCenter,
      heightFactor: isRemoving ? 0 : 1,
      child: AnimatedSlide(
        key: ValueKey('session-row-slide-${session.id}'),
        offset: disableAnimations
            ? Offset.zero
            : (isEntering ? const Offset(0, 0.08) : Offset.zero),
        duration: duration,
        child: AnimatedOpacity(
          key: ValueKey('session-row-opacity-${session.id}'),
          opacity: disableAnimations
              ? (isRemoving ? 0 : (isDeleting ? 0.56 : 1))
              : (isRemoving ? 0 : (isDeleting ? 0.56 : (isEntering ? 0.0 : 1))),
          duration: duration,
          child: Card(
            child: InkWell(
              key: ValueKey('session-row-inkwell-${session.id}'),
              borderRadius: BorderRadius.circular(24),
              onTap: !canOpenSession || isDeleting || isRemoving
                  ? null
                  : () => _openSession(context),
              onLongPress: !canOpenSession || isDeleting || isRemoving
                  ? null
                  : () => _openSessionActions(context),
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        const SizedBox(width: 12),
                        _MetaChip(label: session.agentKind),
                        const SizedBox(width: 8),
                        _StatusPill(label: session.status),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (isDeleting) ...[
                      Text(
                        'Deleting...',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 12),
                    ],
                    Text(
                      workspacePath,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
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

String _formatSessionWorkspacePath(String workspacePath) {
  if (workspacePath.length <= 36) {
    return workspacePath;
  }
  final hasLeadingSlash = workspacePath.startsWith('/');
  final segments = workspacePath
      .split('/')
      .where((segment) => segment.isNotEmpty)
      .toList();
  if (segments.length <= 4) {
    return workspacePath;
  }
  final leading = segments.take(2).join('/');
  final trailing = segments.skip(segments.length - 2).join('/');
  return '${hasLeadingSlash ? '/' : ''}$leading/.../$trailing';
}

WorkspaceRoot? _matchingRootForWorkspacePath(
  String workspacePath,
  List<WorkspaceRoot> roots,
) {
  WorkspaceRoot? bestMatch;
  for (final root in roots) {
    final rootPath = root.path;
    final matchesRoot =
        workspacePath == rootPath || workspacePath.startsWith('$rootPath/');
    if (!matchesRoot) {
      continue;
    }
    if (bestMatch == null || rootPath.length > bestMatch.path.length) {
      bestMatch = root;
    }
  }
  return bestMatch;
}

bool _isDaemonVersionSupported(String version) {
  final current = _parseVersion(version);
  final required = _parseVersion(_minimumSupportedDaemonVersion);
  if (current == null || required == null) {
    return false;
  }
  for (var index = 0; index < required.length; index++) {
    if (current[index] > required[index]) {
      return true;
    }
    if (current[index] < required[index]) {
      return false;
    }
  }
  return true;
}

List<int>? _parseVersion(String version) {
  final core = version.split('+').first.split('-').first;
  final parts = core.split('.');
  if (parts.length != 3) {
    return null;
  }
  final parsed = <int>[];
  for (final part in parts) {
    final value = int.tryParse(part);
    if (value == null) {
      return null;
    }
    parsed.add(value);
  }
  return parsed;
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF173623),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFF245F38)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(label, style: Theme.of(context).textTheme.labelLarge),
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF17232D),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(label),
      ),
    );
  }
}

class _CreateSessionDialog extends StatefulWidget {
  const _CreateSessionDialog({
    required this.api,
    required this.token,
    required this.roots,
    required this.onSessionExpired,
  });

  final DaemonApi api;
  final String token;
  final List<WorkspaceRoot> roots;
  final Future<void> Function() onSessionExpired;

  @override
  State<_CreateSessionDialog> createState() => _CreateSessionDialogState();
}

class _CreateSessionDialogState extends State<_CreateSessionDialog> {
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _pathController = TextEditingController();
  late WorkspaceRoot _selectedRoot;
  String _agentKind = 'codex';
  bool _isEditingPath = false;
  bool _isCreating = false;
  bool _isBrowsingPath = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _selectedRoot = widget.roots.first;
    _pathController.text = _selectedRoot.path;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _pathController.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final title = _titleController.text.trim();
    final path = _pathController.text.trim();
    if (title.isEmpty) {
      setState(() {
        _errorText = 'Session name is required';
      });
      return;
    }
    if (path.isEmpty) {
      setState(() {
        _errorText = 'Path is required';
      });
      return;
    }

    setState(() {
      _isCreating = true;
      _errorText = null;
    });
    try {
      final snapshot = await widget.api.createSession(
        token: widget.token,
        rootId: _selectedRoot.id,
        path: path,
        agentKind: _agentKind,
        title: title,
      );
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(snapshot.toSummary());
    } on Object catch (error) {
      if (error is DaemonApiException && error.statusCode == 401) {
        Navigator.of(context).pop();
        await widget.onSessionExpired();
        return;
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _isCreating = false;
        _errorText = _userFacingSheetErrorText(
          error,
          fallbackText: 'Could not create session',
        );
      });
    }
  }

  Future<void> _browseForPath() async {
    setState(() {
      _isBrowsingPath = true;
    });
    try {
      final selectedPath = await showDialog<String>(
        context: context,
        builder: (_) => _DirectoryPickerDialog(
          api: widget.api,
          token: widget.token,
          initialPath: _selectedRoot.path,
          onSessionExpired: widget.onSessionExpired,
        ),
      );
      if (selectedPath == null || !mounted) {
        return;
      }
      setState(() {
        _pathController.text = selectedPath;
        _errorText = null;
      });
    } finally {
      if (mounted) {
        setState(() {
          _isBrowsingPath = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final multipleRoots = widget.roots.length > 1;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('New session', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            'Create a new managed session in a workspace root.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (multipleRoots)
                    DropdownButtonFormField<String>(
                      key: const ValueKey('create-session-root'),
                      initialValue: _selectedRoot.id,
                      decoration: const InputDecoration(
                        labelText: 'Workspace root',
                      ),
                      items: [
                        for (final root in widget.roots)
                          DropdownMenuItem<String>(
                            value: root.id,
                            child: Text(root.label),
                          ),
                      ],
                      onChanged: _isCreating
                          ? null
                          : (value) {
                              if (value == null) {
                                return;
                              }
                              setState(() {
                                _selectedRoot = widget.roots.firstWhere(
                                  (root) => root.id == value,
                                );
                                _pathController.text = _selectedRoot.path;
                                _isEditingPath = false;
                                _errorText = null;
                              });
                            },
                    )
                  else
                    _ReadonlyRootContext(
                      key: const ValueKey('create-session-root-context'),
                      root: _selectedRoot,
                    ),
                  const SizedBox(height: 16),
                  _AgentKindSelector(
                    selectedAgentKind: _agentKind,
                    onSelected: _isCreating
                        ? null
                        : (agentKind) {
                            setState(() {
                              _agentKind = agentKind;
                            });
                          },
                    keyPrefix: 'create-session-agent',
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _titleController,
                    enabled: !_isCreating,
                    decoration: const InputDecoration(
                      labelText: 'Session name',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _pathController,
                    enabled: !_isCreating,
                    readOnly: !_isEditingPath,
                    decoration: const InputDecoration(labelText: 'Path'),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Wrap(
                      spacing: 8,
                      children: [
                        TextButton(
                          onPressed: _isCreating || _isBrowsingPath
                              ? null
                              : _browseForPath,
                          child: Text(
                            _isBrowsingPath ? 'Loading...' : 'Browse',
                          ),
                        ),
                        TextButton(
                          onPressed: _isCreating
                              ? null
                              : () {
                                  setState(() {
                                    _isEditingPath = true;
                                  });
                                },
                          child: const Text('Edit path'),
                        ),
                      ],
                    ),
                  ),
                  if (_errorText != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _errorText!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: _isCreating
                      ? null
                      : () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _isCreating ? null : _create,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      DelayedInlineSpinner(
                        active: _isCreating,
                        spinnerKey: const ValueKey('create-session-spinner'),
                      ),
                      Text(_isCreating ? 'Creating...' : 'Create'),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DirectoryPickerDialog extends StatefulWidget {
  const _DirectoryPickerDialog({
    required this.api,
    required this.token,
    required this.initialPath,
    required this.onSessionExpired,
  });

  final DaemonApi api;
  final String token;
  final String initialPath;
  final Future<void> Function() onSessionExpired;

  @override
  State<_DirectoryPickerDialog> createState() => _DirectoryPickerDialogState();
}

class _DirectoryPickerDialogState extends State<_DirectoryPickerDialog> {
  late Future<WorkspaceDirectoryListing> _listingFuture;
  late String _currentPath;
  bool _handledUnauthorized = false;

  @override
  void initState() {
    super.initState();
    _currentPath = widget.initialPath;
    _listingFuture = _loadListing(_currentPath);
  }

  Future<WorkspaceDirectoryListing> _loadListing(String path) {
    return widget.api.workspaceDirectories(token: widget.token, path: path);
  }

  void _openPath(String path) {
    setState(() {
      _currentPath = path;
      _listingFuture = _loadListing(path);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Choose directory'),
      content: SizedBox(
        width: 420,
        child: FutureBuilder<WorkspaceDirectoryListing>(
          future: _listingFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const SizedBox(
                height: 180,
                child: Center(child: CircularProgressIndicator()),
              );
            }

            if (snapshot.hasError) {
              final error = snapshot.error;
              if (!_handledUnauthorized &&
                  error is DaemonApiException &&
                  error.statusCode == 401) {
                _handledUnauthorized = true;
                WidgetsBinding.instance.addPostFrameCallback((_) async {
                  if (!mounted) {
                    return;
                  }
                  Navigator.of(context).pop();
                  await widget.onSessionExpired();
                });
                return const SizedBox(
                  height: 180,
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final errorText = switch (snapshot.error) {
                DaemonApiException(:final message) =>
                  'Could not load directories: $message',
                _ => 'Could not load directories',
              };
              return SizedBox(
                height: 180,
                child: Center(child: Text(errorText)),
              );
            }

            final listing = snapshot.requireData;
            return SizedBox(
              height: 260,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    listing.currentPath,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  if (listing.parentPath != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: () => _openPath(listing.parentPath!),
                        child: const Text('Up'),
                      ),
                    ),
                  Expanded(
                    child: listing.directories.isEmpty
                        ? const Center(child: Text('No subdirectories'))
                        : ListView.separated(
                            itemCount: listing.directories.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 8),
                            itemBuilder: (context, index) {
                              final directory = listing.directories[index];
                              return ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: const Icon(Icons.folder_outlined),
                                title: Text(directory.name),
                                subtitle: Text(directory.path),
                                onTap: () => _openPath(directory.path),
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_currentPath),
          child: const Text('Use this folder'),
        ),
      ],
    );
  }
}

class _AttachSessionDialog extends StatefulWidget {
  const _AttachSessionDialog({
    required this.api,
    required this.token,
    required this.roots,
    required this.recentSessions,
    required this.onSessionExpired,
  });

  final DaemonApi api;
  final String token;
  final List<WorkspaceRoot> roots;
  final List<SessionSummary> recentSessions;
  final Future<void> Function() onSessionExpired;

  @override
  State<_AttachSessionDialog> createState() => _AttachSessionDialogState();
}

class _AttachSessionDialogState extends State<_AttachSessionDialog> {
  final TextEditingController _pathController = TextEditingController();
  final TextEditingController _runtimeSessionIdController =
      TextEditingController();
  late WorkspaceRoot _selectedRoot;
  List<ResumeCandidate> _resumeCandidates = const <ResumeCandidate>[];
  bool _isEditingPath = false;
  bool _isAttaching = false;
  bool _isBrowsingPath = false;
  bool _isLoadingResumeCandidates = false;
  String? _errorText;
  String _agentKind = 'claude';

  List<SessionSummary> get _recentAttachableSessions {
    return widget.recentSessions
        .where((session) => session.runtimeSessionId != null)
        .toList();
  }

  @override
  void initState() {
    super.initState();
    _selectedRoot = widget.roots.first;
    _pathController.text = _selectedRoot.path;
  }

  @override
  void dispose() {
    _pathController.dispose();
    _runtimeSessionIdController.dispose();
    super.dispose();
  }

  Future<void> _attach() async {
    final path = _pathController.text.trim();
    final runtimeSessionId = _runtimeSessionIdController.text.trim();
    if (runtimeSessionId.isEmpty) {
      setState(() {
        _errorText = 'Runtime session ID is required';
      });
      return;
    }
    if (path.isEmpty) {
      setState(() {
        _errorText = 'Path is required';
      });
      return;
    }

    setState(() {
      _isAttaching = true;
      _errorText = null;
    });
    try {
      final snapshot = await widget.api.attachSession(
        token: widget.token,
        rootId: _selectedRoot.id,
        path: path,
        agentKind: _agentKind,
        runtimeSessionId: runtimeSessionId,
      );
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(snapshot.toSummary());
    } on Object catch (error) {
      if (error is DaemonApiException && error.statusCode == 401) {
        Navigator.of(context).pop();
        await widget.onSessionExpired();
        return;
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _isAttaching = false;
        _errorText = _userFacingSheetErrorText(
          error,
          fallbackText: 'Could not attach session',
        );
      });
    }
  }

  Future<void> _browseForPath() async {
    setState(() {
      _isBrowsingPath = true;
    });
    try {
      final selectedPath = await showDialog<String>(
        context: context,
        builder: (_) => _DirectoryPickerDialog(
          api: widget.api,
          token: widget.token,
          initialPath: _selectedRoot.path,
          onSessionExpired: widget.onSessionExpired,
        ),
      );
      if (selectedPath == null || !mounted) {
        return;
      }
      setState(() {
        _pathController.text = selectedPath;
        _resumeCandidates = const <ResumeCandidate>[];
        _errorText = null;
      });
    } finally {
      if (mounted) {
        setState(() {
          _isBrowsingPath = false;
        });
      }
    }
  }

  Future<void> _loadResumeCandidates() async {
    final path = _pathController.text.trim();
    if (path.isEmpty) {
      setState(() {
        _resumeCandidates = const <ResumeCandidate>[];
        _errorText = 'Path is required';
      });
      return;
    }

    setState(() {
      _isLoadingResumeCandidates = true;
      _resumeCandidates = const <ResumeCandidate>[];
      _errorText = null;
    });
    try {
      final candidates = await widget.api.listResumeCandidates(
        token: widget.token,
        rootId: _selectedRoot.id,
        agentKind: _agentKind,
        path: path,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _resumeCandidates = candidates;
      });
    } on Object catch (error) {
      if (error is DaemonApiException && error.statusCode == 401) {
        Navigator.of(context).pop();
        await widget.onSessionExpired();
        return;
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _errorText = _userFacingSheetErrorText(
          error,
          fallbackText: 'Could not load resume candidates',
        );
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingResumeCandidates = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final recentSessions = _recentAttachableSessions;
    final multipleRoots = widget.roots.length > 1;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Attach runtime', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            'Attach an existing runtime to a workspace root.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (multipleRoots)
                    DropdownButtonFormField<String>(
                      key: const ValueKey('attach-session-root'),
                      initialValue: _selectedRoot.id,
                      decoration: const InputDecoration(
                        labelText: 'Workspace root',
                      ),
                      items: [
                        for (final root in widget.roots)
                          DropdownMenuItem<String>(
                            value: root.id,
                            child: Text(root.label),
                          ),
                      ],
                      onChanged: _isAttaching || _isBrowsingPath
                          ? null
                          : (value) {
                              if (value == null) {
                                return;
                              }
                              setState(() {
                                _selectedRoot = widget.roots.firstWhere(
                                  (root) => root.id == value,
                                );
                                _pathController.text = _selectedRoot.path;
                                _resumeCandidates = const <ResumeCandidate>[];
                                _isEditingPath = false;
                                _errorText = null;
                              });
                            },
                    )
                  else
                    _ReadonlyRootContext(
                      key: const ValueKey('attach-session-root-context'),
                      root: _selectedRoot,
                    ),
                  const SizedBox(height: 16),
                  _AgentKindSelector(
                    selectedAgentKind: _agentKind,
                    onSelected: _isAttaching
                        ? null
                        : (agentKind) {
                            setState(() {
                              _agentKind = agentKind;
                              _resumeCandidates = const <ResumeCandidate>[];
                              _errorText = null;
                            });
                          },
                    keyPrefix: 'attach-session-agent',
                  ),
                  if (recentSessions.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text(
                      'Recent sessions',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Column(
                      children: [
                        for (
                          var index = 0;
                          index < recentSessions.length;
                          index++
                        ) ...[
                          if (index > 0) const SizedBox(height: 8),
                          Builder(
                            builder: (context) {
                              final session = recentSessions[index];
                              final title =
                                  session.title ?? session.workspacePath;
                              return OutlinedButton(
                                onPressed: _isAttaching
                                    ? null
                                    : () {
                                        final matchingRoot =
                                            _matchingRootForWorkspacePath(
                                              session.workspacePath,
                                              widget.roots,
                                            );
                                        setState(() {
                                          if (matchingRoot != null) {
                                            _selectedRoot = matchingRoot;
                                          }
                                          _pathController.text =
                                              session.workspacePath;
                                          _runtimeSessionIdController.text =
                                              session.runtimeSessionId!;
                                          _isEditingPath = false;
                                          _agentKind = session.agentKind;
                                          _errorText = null;
                                        });
                                      },
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(title),
                                    Text(
                                      session.runtimeSessionId!,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ],
                      ],
                    ),
                  ],
                  const SizedBox(height: 16),
                  TextField(
                    controller: _pathController,
                    enabled: !_isAttaching,
                    readOnly: !_isEditingPath,
                    decoration: const InputDecoration(labelText: 'Path'),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Wrap(
                      spacing: 8,
                      children: [
                        TextButton(
                          onPressed: _isAttaching || _isBrowsingPath
                              ? null
                              : _browseForPath,
                          child: Text(
                            _isBrowsingPath ? 'Loading...' : 'Browse',
                          ),
                        ),
                        TextButton(
                          onPressed: _isAttaching
                              ? null
                              : () {
                                  setState(() {
                                    _isEditingPath = true;
                                  });
                                },
                          child: const Text('Edit path'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: _isAttaching || _isLoadingResumeCandidates
                          ? null
                          : _loadResumeCandidates,
                      child: Text(
                        _isLoadingResumeCandidates
                            ? 'Loading resume sessions...'
                            : 'Load resume sessions',
                      ),
                    ),
                  ),
                  if (_resumeCandidates.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Resume sessions from $_agentKind',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Column(
                      children: [
                        for (
                          var index = 0;
                          index < _resumeCandidates.length;
                          index++
                        ) ...[
                          if (index > 0) const SizedBox(height: 8),
                          Builder(
                            builder: (context) {
                              final candidate = _resumeCandidates[index];
                              final title =
                                  candidate.title ?? candidate.workspacePath;
                              return OutlinedButton(
                                onPressed: _isAttaching
                                    ? null
                                    : () {
                                        final matchingRoot =
                                            _matchingRootForWorkspacePath(
                                              candidate.workspacePath,
                                              widget.roots,
                                            );
                                        setState(() {
                                          if (matchingRoot != null) {
                                            _selectedRoot = matchingRoot;
                                          }
                                          _pathController.text =
                                              candidate.workspacePath;
                                          _runtimeSessionIdController.text =
                                              candidate.runtimeSessionId;
                                          _isEditingPath = false;
                                          _agentKind = candidate.agentKind;
                                          _errorText = null;
                                        });
                                      },
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(title),
                                    Text(
                                      candidate.runtimeSessionId,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ],
                      ],
                    ),
                  ],
                  const SizedBox(height: 12),
                  TextField(
                    controller: _runtimeSessionIdController,
                    enabled: !_isAttaching,
                    decoration: const InputDecoration(
                      labelText: 'Runtime session ID',
                    ),
                  ),
                  if (_errorText != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _errorText!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: _isAttaching
                      ? null
                      : () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _isAttaching ? null : _attach,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      DelayedInlineSpinner(
                        active: _isAttaching,
                        spinnerKey: const ValueKey('attach-session-spinner'),
                      ),
                      Text(_isAttaching ? 'Attaching...' : 'Attach'),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _VoiceSettingsDialog extends StatefulWidget {
  const _VoiceSettingsDialog({
    required this.storage,
    required this.scope,
    required this.daemonManagedVoiceAvailable,
    required this.onTestConnection,
  });

  final VoiceCredentialsStorage storage;
  final VoiceCredentialScope scope;
  final bool daemonManagedVoiceAvailable;
  final Future<String> Function() onTestConnection;

  @override
  State<_VoiceSettingsDialog> createState() => _VoiceSettingsDialogState();
}

class _VoiceSettingsDialogState extends State<_VoiceSettingsDialog> {
  final TextEditingController _appIdController = TextEditingController();
  final TextEditingController _accessTokenController = TextEditingController();
  final TextEditingController _resourceIdController = TextEditingController();
  final TextEditingController _websocketUrlController = TextEditingController();
  bool _isLoading = true;
  bool _isSaving = false;
  bool _isTestingConnection = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _appIdController.dispose();
    _accessTokenController.dispose();
    _resourceIdController.dispose();
    _websocketUrlController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final credentials = await widget.storage.readCredentials(
      scope: widget.scope,
    );
    if (!mounted) {
      return;
    }
    if (credentials != null) {
      _appIdController.text = credentials.appId;
      _accessTokenController.text = credentials.accessToken;
      _resourceIdController.text = credentials.resourceId;
      _websocketUrlController.text = credentials.websocketUrl;
    }
    setState(() {
      _isLoading = false;
    });
  }

  Future<void> _save() async {
    final appId = _appIdController.text.trim();
    final accessToken = _accessTokenController.text.trim();
    final resourceId = _resourceIdController.text.trim();
    final websocketUrl = _websocketUrlController.text.trim();
    if (appId.isEmpty ||
        accessToken.isEmpty ||
        resourceId.isEmpty ||
        websocketUrl.isEmpty) {
      setState(() {
        _errorText = 'All voice settings are required';
      });
      return;
    }

    setState(() {
      _isSaving = true;
      _errorText = null;
    });
    await widget.storage.saveCredentials(
      scope: widget.scope,
      credentials: DoubaoVoiceCredentials(
        appId: appId,
        accessToken: accessToken,
        resourceId: resourceId,
        websocketUrl: websocketUrl,
      ),
    );
    if (!mounted) {
      return;
    }
    Navigator.of(context).pop(true);
  }

  Future<void> _clear() async {
    await widget.storage.clearCredentials(scope: widget.scope);
    if (!mounted) {
      return;
    }
    Navigator.of(context).pop(true);
  }

  Future<void> _refreshProviderVoice() async {
    Navigator.of(context).pop(true);
  }

  Future<void> _testConnection() async {
    setState(() {
      _isTestingConnection = true;
      _errorText = null;
    });
    final status = await widget.onTestConnection();
    if (!mounted) {
      return;
    }
    setState(() {
      _errorText = status;
      _isTestingConnection = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final showProviderManagedState = widget.daemonManagedVoiceAvailable;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Configure Doubao voice',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (showProviderManagedState) ...[
                          const Text('Daemon-managed voice input is active.'),
                          const SizedBox(height: 12),
                          Text(
                            'This daemon currently provides voice input for your account. Local Doubao credentials are not required.',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ] else ...[
                          TextField(
                            controller: _appIdController,
                            enabled: !_isSaving,
                            decoration: const InputDecoration(
                              labelText: 'App ID',
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _accessTokenController,
                            enabled: !_isSaving,
                            decoration: const InputDecoration(
                              labelText: 'Access Token',
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _resourceIdController,
                            enabled: !_isSaving,
                            decoration: const InputDecoration(
                              labelText: 'Resource ID',
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _websocketUrlController,
                            enabled: !_isSaving,
                            decoration: const InputDecoration(
                              labelText: 'WebSocket URL',
                            ),
                          ),
                        ],
                        if (_errorText != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            _errorText!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: _isSaving
                      ? null
                      : () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextButton(
                  onPressed: showProviderManagedState
                      ? (_isTestingConnection ? null : _refreshProviderVoice)
                      : (_isLoading || _isSaving ? null : _clear),
                  child: Text(
                    showProviderManagedState
                        ? 'Refresh'
                        : 'Clear voice settings',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (showProviderManagedState)
            FilledButton.tonal(
              onPressed: _isTestingConnection ? null : _testConnection,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DelayedInlineSpinner(
                    active: _isTestingConnection,
                    spinnerKey: const ValueKey(
                      'voice-settings-test-connection-spinner',
                    ),
                  ),
                  Text(
                    _isTestingConnection
                        ? 'Testing connection...'
                        : 'Test connection',
                  ),
                ],
              ),
            )
          else
            FilledButton(
              onPressed: _isLoading || _isSaving ? null : _save,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DelayedInlineSpinner(
                    active: _isSaving,
                    spinnerKey: const ValueKey('voice-settings-save-spinner'),
                  ),
                  Text(_isSaving ? 'Saving...' : 'Save voice settings'),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet({
    required this.userDisplayName,
    required this.daemonHost,
    required this.daemonUrl,
    required this.appVersion,
    required this.daemonVersion,
    required this.isOffline,
    required this.voiceConfigured,
    required this.onTestConnection,
    required this.onConfigureVoice,
    required this.onChangeDaemon,
    required this.onSignOut,
  });

  final String userDisplayName;
  final String daemonHost;
  final String daemonUrl;
  final String appVersion;
  final String daemonVersion;
  final bool isOffline;
  final bool voiceConfigured;
  final Future<String> Function() onTestConnection;
  final Future<void> Function() onConfigureVoice;
  final Future<void> Function() onChangeDaemon;
  final Future<void> Function() onSignOut;

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  String? _statusText;
  bool _isTestingConnection = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Settings',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text('Signed in as ${widget.userDisplayName}'),
                  const SizedBox(height: 4),
                  Text('Connected to ${widget.daemonHost}'),
                  const SizedBox(height: 4),
                  Text('Connection status'),
                  const SizedBox(height: 4),
                  Text(widget.isOffline ? 'Offline' : 'Connected'),
                  const SizedBox(height: 4),
                  const Text('Daemon URL'),
                  const SizedBox(height: 4),
                  Text(widget.daemonUrl),
                  const SizedBox(height: 4),
                  const Text('App version'),
                  const SizedBox(height: 4),
                  Text(widget.appVersion),
                  if (widget.daemonVersion.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text('Daemon version ${widget.daemonVersion}'),
                  ],
                  const SizedBox(height: 4),
                  Text(
                    widget.voiceConfigured
                        ? 'Voice input configured'
                        : 'Voice input is not configured',
                  ),
                  if (_statusText != null) ...[
                    const SizedBox(height: 8),
                    Text(_statusText!),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.tonal(
            onPressed: _isTestingConnection
                ? null
                : () async {
                    setState(() {
                      _isTestingConnection = true;
                    });
                    final status = await widget.onTestConnection();
                    if (!mounted) {
                      return;
                    }
                    setState(() {
                      _statusText = status;
                      _isTestingConnection = false;
                    });
                  },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                DelayedInlineSpinner(
                  active: _isTestingConnection,
                  spinnerKey: const ValueKey(
                    'settings-test-connection-spinner',
                  ),
                ),
                Text(
                  _isTestingConnection
                      ? 'Testing connection...'
                      : 'Test connection',
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.tonal(
            onPressed: widget.onConfigureVoice,
            child: const Text('Configure Doubao voice'),
          ),
          const SizedBox(height: 16),
          FilledButton.tonal(
            onPressed: widget.onChangeDaemon,
            child: const Text('Change daemon'),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: widget.onSignOut,
            child: const Text('Logout'),
          ),
        ],
      ),
    );
  }
}

class _EmptySessionsCard extends StatelessWidget {
  const _EmptySessionsCard({
    required this.onCreateSession,
    required this.onAttachRuntime,
  });

  final VoidCallback? onCreateSession;
  final VoidCallback? onAttachRuntime;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.forum_outlined, size: 48),
            const SizedBox(height: 18),
            Text(
              'No sessions yet',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              'Start a managed session or attach an existing runtime.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: onCreateSession,
              child: const Text('New session'),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: onAttachRuntime,
              child: const Text('Attach runtime'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SessionRowDetailsSheet extends StatelessWidget {
  const _SessionRowDetailsSheet({
    required this.title,
    required this.daemonUrlHost,
    required this.agentKind,
    required this.sourceKind,
    required this.status,
    required this.workspacePath,
    required this.runtimeSessionId,
  });

  final String title;
  final String daemonUrlHost;
  final String agentKind;
  final String sourceKind;
  final String status;
  final String workspacePath;
  final String? runtimeSessionId;

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
              _SessionRowDetail(label: 'Title', value: title),
              _SessionRowDetail(label: 'Agent kind', value: agentKind),
              _SessionRowDetail(label: 'Source kind', value: sourceKind),
              _SessionRowDetail(label: 'Status', value: status),
              _SessionRowDetail(label: 'Workspace path', value: workspacePath),
              if (runtimeSessionId case final id?)
                _SessionRowDetail(label: 'Runtime session ID', value: id),
              _SessionRowDetail(label: 'Daemon URL host', value: daemonUrlHost),
            ],
          ),
        ),
      ),
    );
  }
}

class _SessionActionsSheet extends StatefulWidget {
  const _SessionActionsSheet({
    required this.session,
    required this.onOpenDetails,
    required this.onOpenSession,
    required this.onCopyWorkspacePath,
    required this.onDeleteSession,
    required this.onCopyRuntimeSessionId,
  });

  final SessionSummary session;
  final Future<void> Function() onOpenDetails;
  final Future<void> Function() onOpenSession;
  final Future<void> Function() onCopyWorkspacePath;
  final Future<String?> Function() onDeleteSession;
  final Future<void> Function()? onCopyRuntimeSessionId;

  @override
  State<_SessionActionsSheet> createState() => _SessionActionsSheetState();
}

class _SessionActionsSheetState extends State<_SessionActionsSheet> {
  bool _isDeleting = false;
  String? _errorText;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Wrap(
        children: [
          if (_errorText case final errorText?)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                errorText,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ListTile(
            leading: const Icon(Icons.chat_bubble_outline_rounded),
            title: const Text('Open'),
            onTap: _isDeleting
                ? null
                : () async {
                    Navigator.of(context).pop();
                    await widget.onOpenSession();
                  },
          ),
          ListTile(
            leading: const Icon(Icons.info_outline_rounded),
            title: const Text('Session details'),
            onTap: _isDeleting
                ? null
                : () async {
                    Navigator.of(context).pop();
                    await widget.onOpenDetails();
                  },
          ),
          if (widget.onCopyRuntimeSessionId case final onCopyRuntimeSessionId?)
            ListTile(
              leading: const Icon(Icons.tag_outlined),
              title: const Text('Copy runtime session ID'),
              onTap: _isDeleting
                  ? null
                  : () async {
                      Navigator.of(context).pop();
                      await onCopyRuntimeSessionId();
                    },
            ),
          ListTile(
            leading: const Icon(Icons.copy_all_outlined),
            title: const Text('Copy workspace path'),
            onTap: _isDeleting
                ? null
                : () async {
                    Navigator.of(context).pop();
                    await widget.onCopyWorkspacePath();
                  },
          ),
          ListTile(
            leading: _isDeleting
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.delete_outline_rounded),
            title: Text(_isDeleting ? 'Deleting...' : 'Delete session'),
            onTap: _isDeleting
                ? null
                : () async {
                    setState(() {
                      _isDeleting = true;
                      _errorText = null;
                    });
                    final errorMessage = await widget.onDeleteSession();
                    if (!mounted) {
                      return;
                    }
                    setState(() {
                      _isDeleting = false;
                      _errorText = errorMessage;
                    });
                  },
          ),
        ],
      ),
    );
  }
}

class _SessionRowDetail extends StatelessWidget {
  const _SessionRowDetail({required this.label, required this.value});

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

class _AgentKindSelector extends StatelessWidget {
  const _AgentKindSelector({
    required this.selectedAgentKind,
    required this.onSelected,
    required this.keyPrefix,
  });

  final String selectedAgentKind;
  final ValueChanged<String>? onSelected;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Agent', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final agentKind in const ['codex', 'claude'])
              ChoiceChip(
                key: ValueKey('$keyPrefix-$agentKind'),
                label: Text(agentKind),
                selected: selectedAgentKind == agentKind,
                onSelected: onSelected == null
                    ? null
                    : (_) => onSelected!(agentKind),
              ),
          ],
        ),
      ],
    );
  }
}

class _ReadonlyRootContext extends StatelessWidget {
  const _ReadonlyRootContext({super.key, required this.root});

  final WorkspaceRoot root;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.35,
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.45),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Workspace root',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 6),
            Text(root.label, style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              root.path,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
