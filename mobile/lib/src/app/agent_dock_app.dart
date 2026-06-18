import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../features/launch/launch_page.dart';
import '../features/sessions/sessions_page.dart';
import '../shared/api/daemon_client.dart';
import '../shared/external_links/external_link_opener.dart';
import '../shared/media/image_attachment_picker.dart';
import '../shared/media/share_attachments.dart';
import '../shared/storage/auth_storage.dart';
import '../shared/storage/session_composer_draft_store.dart';
import '../shared/storage/session_detail_cache_store.dart';
import '../shared/storage/session_outbox_store.dart';
import '../shared/storage/voice_credentials_storage.dart';
import '../shared/voice/doubao_voice_input_controller.dart';
import '../shared/voice/voice_input_controller.dart';
import 'app_theme.dart';

typedef DaemonApiFactory = DaemonApi Function(Uri daemonUrl);
Future<void> _defaultShareAttachments(List<String> paths, String? text) {
  return SharePlus.instance.share(
    ShareParams(files: paths.map(XFile.new).toList(), text: text),
  );
}

Future<bool> _defaultOpenExternalLink(Uri uri) async {
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}

const agentDockAppVersion = '1.0.0+1';
const _launchOfflineText = 'Offline. Waiting for network...';
const _invalidDaemonText = 'Daemon responded but does not look like Agent Dock';
const _loginFailureText = 'Could not sign in';
const _restoreFailureText = 'Could not restore session';
const _sessionExpiredText = 'Session expired. Sign in again.';

class AgentDockApp extends StatelessWidget {
  AgentDockApp({
    super.key,
    DaemonApi? api,
    DaemonApiFactory? apiFactory,
    ImageAttachmentPicker? attachmentPicker,
    ExternalLinkOpener? openExternalLink,
    VoiceInputController? voiceInputController,
    ShareAttachments? shareAttachments,
    AuthStorage? authStorage,
    SessionComposerDraftStore? composerDraftStore,
    SessionDetailCacheStore? sessionDetailCacheStore,
    SessionOutboxStore? outboxStore,
    VoiceCredentialsStorage? voiceCredentialsStorage,
    this.showDebugTimelineItems,
    this.doubaoSocketClient,
    this.doubaoRecorder,
    required this.daemonUrl,
  }) : apiFactory =
           apiFactory ??
           ((daemonUrl) => api ?? DaemonClient(baseUrl: daemonUrl)),
       attachmentPicker = attachmentPicker ?? GalleryImageAttachmentPicker(),
       openExternalLink = openExternalLink ?? _defaultOpenExternalLink,
       voiceInputController =
           voiceInputController ?? const DisabledVoiceInputController(),
       shareAttachments = shareAttachments ?? _defaultShareAttachments,
       authStorage = authStorage ?? SecureAuthStorage(),
       composerDraftStore =
           composerDraftStore ?? MemorySessionComposerDraftStore(),
       sessionDetailCacheStore =
           sessionDetailCacheStore ?? MemorySessionDetailCacheStore(),
       outboxStore = outboxStore ?? MemorySessionOutboxStore(),
       voiceCredentialsStorage =
           voiceCredentialsStorage ?? SecureVoiceCredentialsStorage();

  final DaemonApiFactory apiFactory;
  final ImageAttachmentPicker attachmentPicker;
  final ExternalLinkOpener openExternalLink;
  final VoiceInputController voiceInputController;
  final ShareAttachments shareAttachments;
  final AuthStorage authStorage;
  final SessionComposerDraftStore composerDraftStore;
  final SessionDetailCacheStore sessionDetailCacheStore;
  final SessionOutboxStore outboxStore;
  final VoiceCredentialsStorage voiceCredentialsStorage;
  final bool? showDebugTimelineItems;
  final DoubaoSocketClient? doubaoSocketClient;
  final DoubaoRecorder? doubaoRecorder;
  final Uri daemonUrl;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Agent Dock',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: _AgentDockShell(
        apiFactory: apiFactory,
        attachmentPicker: attachmentPicker,
        openExternalLink: openExternalLink,
        voiceInputController: voiceInputController,
        shareAttachments: shareAttachments,
        authStorage: authStorage,
        composerDraftStore: composerDraftStore,
        sessionDetailCacheStore: sessionDetailCacheStore,
        outboxStore: outboxStore,
        voiceCredentialsStorage: voiceCredentialsStorage,
        showDebugTimelineItems: showDebugTimelineItems,
        doubaoSocketClient: doubaoSocketClient,
        doubaoRecorder: doubaoRecorder,
        daemonUrl: daemonUrl,
      ),
    );
  }
}

class _AgentDockShell extends StatefulWidget {
  const _AgentDockShell({
    required this.apiFactory,
    required this.attachmentPicker,
    required this.openExternalLink,
    required this.voiceInputController,
    required this.shareAttachments,
    required this.authStorage,
    required this.composerDraftStore,
    required this.sessionDetailCacheStore,
    required this.outboxStore,
    required this.voiceCredentialsStorage,
    required this.showDebugTimelineItems,
    required this.doubaoSocketClient,
    required this.doubaoRecorder,
    required this.daemonUrl,
  });

  final DaemonApiFactory apiFactory;
  final ImageAttachmentPicker attachmentPicker;
  final ExternalLinkOpener openExternalLink;
  final VoiceInputController voiceInputController;
  final ShareAttachments shareAttachments;
  final AuthStorage authStorage;
  final SessionComposerDraftStore composerDraftStore;
  final SessionDetailCacheStore sessionDetailCacheStore;
  final SessionOutboxStore outboxStore;
  final VoiceCredentialsStorage voiceCredentialsStorage;
  final bool? showDebugTimelineItems;
  final DoubaoSocketClient? doubaoSocketClient;
  final DoubaoRecorder? doubaoRecorder;
  final Uri daemonUrl;

  @override
  State<_AgentDockShell> createState() => _AgentDockShellState();
}

class _AgentDockShellState extends State<_AgentDockShell> {
  DaemonApi? _api;
  late Uri _daemonUrl;
  MobileBootstrap? _bootstrap;
  bool _bootstrapNeedsRefresh = false;
  String? _token;
  String? _loginError;
  bool _hasConfiguredDaemonUrl = false;
  bool _showDaemonSetup = false;
  bool _isTestingDaemon = false;
  late VoiceInputController _voiceInputController;
  bool _isRestoring = true;
  bool _restoreFailed = false;
  bool _isSigningIn = false;
  String _restoreStatusText = 'Checking daemon...';
  String? _restoreDaemonHost;
  int _clearPasswordSignal = 0;

  bool get _usesInjectedVoiceController =>
      widget.voiceInputController is! DisabledVoiceInputController;

  @override
  void initState() {
    super.initState();
    _daemonUrl = widget.daemonUrl;
    _voiceInputController = widget.voiceInputController;
    _restoreProfile();
  }

  String _restoreErrorText(Object error) {
    if (error is SocketException) {
      return _launchOfflineText;
    }
    return _restoreFailureText;
  }

  String _loginErrorText(Object error) {
    if (error is SocketException) {
      return _launchOfflineText;
    }
    return _loginFailureText;
  }

  String _daemonHealthErrorText(Object error) {
    if (error is FormatException) {
      return _invalidDaemonText;
    }
    if (error is SocketException) {
      return _launchOfflineText;
    }
    return _invalidDaemonText;
  }

  void _clearComposerDrafts({required Uri daemonUrl, required String userId}) {
    widget.composerDraftStore.clearUserDrafts(
      daemonUrl: daemonUrl,
      userId: userId,
    );
  }

  void _clearSessionDetailCaches({
    required Uri daemonUrl,
    required String userId,
  }) {
    widget.sessionDetailCacheStore.clearUserCaches(
      daemonUrl: daemonUrl,
      userId: userId,
    );
  }

  Future<void> _cancelActiveVoiceInput() async {
    try {
      await _voiceInputController.cancel();
    } on Object {
      // Best-effort cleanup when leaving the current authenticated shell.
    }
  }

  void _prepareVoiceInputController(VoiceInputController controller) {
    if (!controller.isConfigured) {
      return;
    }
    unawaited(
      controller.prepare().catchError((Object _) {
        // Voice preparation is opportunistic; real errors are surfaced on use.
      }),
    );
  }

  Future<void> _restoreProfile() async {
    final savedDaemonUrl = await widget.authStorage.readDaemonUrl();
    _daemonUrl = savedDaemonUrl ?? _daemonUrl;
    _restoreDaemonHost = savedDaemonUrl?.host;
    _hasConfiguredDaemonUrl = savedDaemonUrl != null;
    _showDaemonSetup = !_hasConfiguredDaemonUrl;
    _restoreFailed = false;
    DaemonApi? api;
    if (savedDaemonUrl != null) {
      api = widget.apiFactory(_daemonUrl);
      try {
        await api.healthCheck();
      } on DaemonApiException catch (error) {
        if (!mounted) {
          return;
        }
        setState(() {
          _api = null;
          _loginError = error.message;
          _showDaemonSetup = true;
          _isRestoring = false;
        });
        return;
      } on Object catch (error) {
        if (!mounted) {
          return;
        }
        setState(() {
          _api = null;
          _loginError = _daemonHealthErrorText(error);
          _showDaemonSetup = true;
          _isRestoring = false;
        });
        return;
      }
    }
    final profile = await widget.authStorage.readProfile();
    if (profile == null) {
      if (!mounted) {
        return;
      }
      setState(() {
        _api = _hasConfiguredDaemonUrl ? api : null;
        _isRestoring = false;
      });
      return;
    }

    if (!mounted) {
      return;
    }
    setState(() {
      _restoreStatusText = 'Restoring session...';
      _restoreFailed = false;
    });

    try {
      api ??= widget.apiFactory(_daemonUrl);
      final bootstrap = await api.bootstrap(token: profile.token);
      if (!mounted) {
        return;
      }
      setState(() {
        _api = api;
        _token = profile.token;
        _bootstrap = bootstrap;
        _bootstrapNeedsRefresh = false;
        _showDaemonSetup = false;
        _voiceInputController = _initialVoiceInputController(bootstrap.voice);
        _isRestoring = false;
        _restoreFailed = false;
      });
      _prepareVoiceInputController(_voiceInputController);
      unawaited(
        _refreshVoiceInputController(
          daemonUrl: profile.daemonUrl,
          userId: profile.userId,
          token: profile.token,
          voice: bootstrap.voice,
        ),
      );
    } on DaemonApiException catch (error) {
      if (error.statusCode == 401) {
        _clearComposerDrafts(
          daemonUrl: profile.daemonUrl,
          userId: profile.userId,
        );
        _clearSessionDetailCaches(
          daemonUrl: profile.daemonUrl,
          userId: profile.userId,
        );
        await widget.authStorage.clearProfile();
        if (!mounted) {
          return;
        }
        setState(() {
          _api = widget.apiFactory(_daemonUrl);
          _loginError = _sessionExpiredText;
          _showDaemonSetup = false;
          _isRestoring = false;
          _restoreFailed = false;
        });
        return;
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _api = api;
        _loginError = error.message;
        _showDaemonSetup = false;
        _isRestoring = false;
        _restoreFailed = true;
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _api = api;
        _loginError = _restoreErrorText(error);
        _showDaemonSetup = _hasConfiguredDaemonUrl ? false : true;
        _isRestoring = false;
        _restoreFailed = _hasConfiguredDaemonUrl;
      });
    }
  }

  void _openManualSignInFromRestoreFailure() {
    setState(() {
      _restoreFailed = false;
      _loginError = null;
      _showDaemonSetup = false;
    });
  }

  Future<void> _signIn({
    required String username,
    required String password,
  }) async {
    setState(() {
      _isSigningIn = true;
      _loginError = null;
    });

    try {
      final api = _api ?? widget.apiFactory(_daemonUrl);
      final previousProfile = await widget.authStorage.readProfile();
      final login = await api.login(username: username, password: password);
      if (previousProfile != null &&
          previousProfile.daemonUrl == _daemonUrl &&
          previousProfile.userId != login.user.id) {
        _clearComposerDrafts(
          daemonUrl: previousProfile.daemonUrl,
          userId: previousProfile.userId,
        );
        _clearSessionDetailCaches(
          daemonUrl: previousProfile.daemonUrl,
          userId: previousProfile.userId,
        );
      }
      await widget.authStorage.saveDaemonUrl(_daemonUrl);
      await widget.authStorage.saveProfile(
        AuthProfile(
          daemonUrl: _daemonUrl,
          token: login.token,
          userId: login.user.id,
        ),
      );
      if (!mounted) {
        return;
      }
      const bootstrap = MobileBootstrap(
        daemonVersion: '0.1.0',
        user: CurrentUser(id: 'usr_workspace', displayName: 'Agent Dock'),
        roots: <WorkspaceRoot>[],
        sessions: <SessionSummary>[],
        voice: VoiceConfig(doubaoDirectAvailable: false),
      );
      setState(() {
        _api = api;
        _token = login.token;
        _bootstrap = MobileBootstrap(
          daemonVersion: bootstrap.daemonVersion,
          user: login.user,
          roots: bootstrap.roots,
          sessions: bootstrap.sessions,
          voice: bootstrap.voice,
        );
        _bootstrapNeedsRefresh = true;
        _showDaemonSetup = false;
        _voiceInputController = _initialVoiceInputController(bootstrap.voice);
        _isSigningIn = false;
      });
    } on DaemonApiException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loginError = error.message;
        if (error.statusCode == 401) {
          _clearPasswordSignal++;
        }
        _isSigningIn = false;
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loginError = _loginErrorText(error);
        _isSigningIn = false;
      });
    }
  }

  Future<void> _signOut() async {
    await _cancelActiveVoiceInput();
    final bootstrap = _bootstrap;
    if (bootstrap != null) {
      _clearComposerDrafts(daemonUrl: _daemonUrl, userId: bootstrap.user.id);
      _clearSessionDetailCaches(
        daemonUrl: _daemonUrl,
        userId: bootstrap.user.id,
      );
    }
    await widget.authStorage.clearProfile();
    if (!mounted) {
      return;
    }
    setState(() {
      _token = null;
      _bootstrap = null;
      _bootstrapNeedsRefresh = false;
      _loginError = null;
      _api = widget.apiFactory(_daemonUrl);
      _showDaemonSetup = false;
      _voiceInputController = widget.voiceInputController;
    });
  }

  Future<void> _expireSession() async {
    await _cancelActiveVoiceInput();
    final bootstrap = _bootstrap;
    if (bootstrap != null) {
      _clearComposerDrafts(daemonUrl: _daemonUrl, userId: bootstrap.user.id);
      _clearSessionDetailCaches(
        daemonUrl: _daemonUrl,
        userId: bootstrap.user.id,
      );
    }
    await widget.authStorage.clearProfile();
    if (!mounted) {
      return;
    }
    setState(() {
      _token = null;
      _bootstrap = null;
      _bootstrapNeedsRefresh = false;
      _loginError = _sessionExpiredText;
      _api = widget.apiFactory(_daemonUrl);
      _showDaemonSetup = false;
      _voiceInputController = widget.voiceInputController;
      _isSigningIn = false;
      _isRestoring = false;
    });
  }

  Future<void> _saveLastSelectedSession(String sessionId) async {
    final bootstrap = _bootstrap;
    if (bootstrap == null) {
      return;
    }
    await widget.authStorage.saveLastSelectedSessionId(
      scope: SessionStorageScope(
        daemonUrl: _daemonUrl,
        userId: bootstrap.user.id,
      ),
      sessionId: sessionId,
    );
  }

  Future<void> _openDaemonSetup() async {
    await _cancelActiveVoiceInput();
    final bootstrap = _bootstrap;
    if (bootstrap != null) {
      _clearComposerDrafts(daemonUrl: _daemonUrl, userId: bootstrap.user.id);
      _clearSessionDetailCaches(
        daemonUrl: _daemonUrl,
        userId: bootstrap.user.id,
      );
    }
    await widget.authStorage.clearProfile();
    if (!mounted) {
      return;
    }
    setState(() {
      _token = null;
      _bootstrap = null;
      _bootstrapNeedsRefresh = false;
      _loginError = null;
      _hasConfiguredDaemonUrl = false;
      _showDaemonSetup = true;
      _api = null;
      _voiceInputController = widget.voiceInputController;
      _isSigningIn = false;
      _isRestoring = false;
      _restoreFailed = false;
    });
  }

  Future<void> _testDaemonConnection(Uri daemonUrl) async {
    setState(() {
      _isTestingDaemon = true;
      _loginError = null;
    });
    try {
      final api = widget.apiFactory(daemonUrl);
      await api.healthCheck();
      await widget.authStorage.saveDaemonUrl(daemonUrl);
      if (!mounted) {
        return;
      }
      setState(() {
        _daemonUrl = daemonUrl;
        _hasConfiguredDaemonUrl = true;
        _showDaemonSetup = false;
        _api = api;
        _isTestingDaemon = false;
      });
    } on DaemonApiException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loginError = error.message;
        _isTestingDaemon = false;
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loginError = _daemonHealthErrorText(error);
        _isTestingDaemon = false;
      });
    }
  }

  Future<VoiceInputController> _loadVoiceInputController({
    required Uri daemonUrl,
    required String userId,
    required String token,
    required VoiceConfig? voice,
  }) async {
    if (_usesInjectedVoiceController) {
      return widget.voiceInputController;
    }

    if (voice?.doubaoDirectAvailable == true) {
      final providerCredentials = voice?.providerCredentials;
      if (providerCredentials != null && providerCredentials.isUsable) {
        return DoubaoVoiceInputController(
          credentials: providerCredentials,
          transport: IoDoubaoVoiceTransport(
            socketClient: widget.doubaoSocketClient,
          ),
          audioSource: RecordDoubaoAudioSource(recorder: widget.doubaoRecorder),
        );
      }
    }

    try {
      final credentials = await widget.voiceCredentialsStorage.readCredentials(
        scope: VoiceCredentialScope(daemonUrl: daemonUrl, userId: userId),
      );
      if (credentials != null) {
        return DoubaoVoiceInputController(
          credentials: credentials,
          transport: IoDoubaoVoiceTransport(
            socketClient: widget.doubaoSocketClient,
          ),
          audioSource: RecordDoubaoAudioSource(recorder: widget.doubaoRecorder),
        );
      }
    } on Object {
      if (voice?.providerCredentials?.isUsable != true) {
        return const DisabledVoiceInputController();
      }
    }

    return const DisabledVoiceInputController();
  }

  VoiceInputController _initialVoiceInputController(VoiceConfig? voice) {
    if (_usesInjectedVoiceController) {
      return widget.voiceInputController;
    }
    final providerCredentials = voice?.providerCredentials;
    if (providerCredentials == null || !providerCredentials.isUsable) {
      return const DisabledVoiceInputController();
    }
    return DoubaoVoiceInputController(
      credentials: providerCredentials,
      transport: IoDoubaoVoiceTransport(
        socketClient: widget.doubaoSocketClient,
      ),
      audioSource: RecordDoubaoAudioSource(recorder: widget.doubaoRecorder),
    );
  }

  Future<VoiceInputController> _safeLoadVoiceInputController({
    required Uri daemonUrl,
    required String userId,
    required String token,
    required VoiceConfig? voice,
  }) async {
    try {
      return await _loadVoiceInputController(
        daemonUrl: daemonUrl,
        userId: userId,
        token: token,
        voice: voice,
      );
    } on Object {
      return const DisabledVoiceInputController();
    }
  }

  Future<void> _refreshVoiceInputController({
    required Uri daemonUrl,
    required String userId,
    required String token,
    required VoiceConfig? voice,
  }) async {
    final controller = await _safeLoadVoiceInputController(
      daemonUrl: daemonUrl,
      userId: userId,
      token: token,
      voice: voice,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _voiceInputController = controller;
    });
    _prepareVoiceInputController(controller);
  }

  Future<void> _refreshVoiceSettingsState() async {
    final api = _api;
    final token = _token;
    final bootstrap = _bootstrap;
    if (api == null || token == null || bootstrap == null) {
      return;
    }

    var voice = bootstrap.voice;
    var userId = bootstrap.user.id;
    try {
      final refreshedBootstrap = await api.bootstrap(token: token);
      if (!mounted) {
        return;
      }
      setState(() {
        _bootstrap = refreshedBootstrap;
        _bootstrapNeedsRefresh = false;
      });
      voice = refreshedBootstrap.voice;
      userId = refreshedBootstrap.user.id;
    } on DaemonApiException catch (error) {
      if (error.statusCode == 401) {
        await _expireSession();
        return;
      }
    } on Object {
      // Keep the current bootstrap when refresh fails; local credential changes
      // can still update the voice controller from secure storage.
    }

    await _refreshVoiceInputController(
      daemonUrl: _daemonUrl,
      userId: userId,
      token: token,
      voice: voice,
    );
  }

  Future<void> _handleInitialSessionsBootstrap(
    MobileBootstrap bootstrap,
  ) async {
    if (!mounted) {
      return;
    }
    final token = _token;
    setState(() {
      _bootstrap = bootstrap;
      _bootstrapNeedsRefresh = false;
    });
    if (token == null) {
      return;
    }
    await _refreshVoiceInputController(
      daemonUrl: _daemonUrl,
      userId: bootstrap.user.id,
      token: token,
      voice: bootstrap.voice,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isRestoring || _restoreFailed) {
      return RestorePage(
        statusText: _restoreStatusText,
        daemonHost: _restoreDaemonHost,
        errorText: _restoreFailed ? _loginError : null,
        onRetry: _restoreFailed ? _restoreProfile : null,
        onSignInManually: _restoreFailed
            ? _openManualSignInFromRestoreFailure
            : null,
        onChangeDaemon: _restoreFailed ? _openDaemonSetup : null,
      );
    }

    final bootstrap = _bootstrap;
    final token = _token;
    final api = _api;
    if (bootstrap != null && token != null && api != null) {
      return SessionsPage(
        api: api,
        attachmentPicker: widget.attachmentPicker,
        openExternalLink: widget.openExternalLink,
        shareAttachments: widget.shareAttachments,
        voiceInputController: _voiceInputController,
        token: token,
        bootstrap: bootstrap,
        loadBootstrapOnInit: _bootstrapNeedsRefresh,
        daemonUrl: _daemonUrl,
        currentUserId: bootstrap.user.id,
        composerDraftStore: widget.composerDraftStore,
        sessionDetailCacheStore: widget.sessionDetailCacheStore,
        outboxStore: widget.outboxStore,
        voiceCredentialsStorage: widget.voiceCredentialsStorage,
        showDebugTimelineItems: widget.showDebugTimelineItems,
        onVoiceSettingsChanged: _refreshVoiceSettingsState,
        onBootstrapLoaded: _handleInitialSessionsBootstrap,
        onChangeDaemon: _openDaemonSetup,
        onSelectSession: _saveLastSelectedSession,
        onSessionExpired: _expireSession,
        onSignOut: _signOut,
      );
    }

    return LaunchPage(
      daemonUrl: _daemonUrl,
      isDaemonConfigured: _hasConfiguredDaemonUrl && !_showDaemonSetup,
      errorText: _loginError,
      isSigningIn: _isSigningIn,
      isTestingConnection: _isTestingDaemon,
      clearPasswordSignal: _clearPasswordSignal,
      onOpenDaemonSetup: _openDaemonSetup,
      onTestConnection: _testDaemonConnection,
      onSignIn: _signIn,
    );
  }
}
