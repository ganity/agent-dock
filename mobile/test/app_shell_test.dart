import 'dart:async';
import 'dart:io';

import 'package:agent_dock_mobile/src/app/agent_dock_app.dart';
import 'package:agent_dock_mobile/src/features/session_detail/session_detail_page.dart';
import 'package:agent_dock_mobile/src/shared/api/daemon_client.dart';
import 'package:agent_dock_mobile/src/shared/media/image_attachment_picker.dart';
import 'package:agent_dock_mobile/src/shared/storage/auth_storage.dart';
import 'package:agent_dock_mobile/src/shared/storage/session_composer_draft_store.dart';
import 'package:agent_dock_mobile/src/shared/storage/session_detail_cache_store.dart';
import 'package:agent_dock_mobile/src/shared/storage/session_outbox_store.dart';
import 'package:agent_dock_mobile/src/shared/storage/voice_credentials_storage.dart';
import 'package:agent_dock_mobile/src/shared/voice/doubao_voice_input_controller.dart';
import 'package:agent_dock_mobile/src/shared/voice/voice_input_controller.dart';
import 'package:record/record.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _inProgressStatusPillColor = Color(0xFF5C4318);
const _providerVoiceCredentials = DoubaoVoiceCredentials(
  appId: 'provider-app-id',
  accessToken: 'provider-access-token',
  resourceId: 'volc.bigasr.sauc.duration',
  websocketUrl: 'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async',
);

void main() {
  testWidgets('shows daemon setup when no daemon URL has been saved', (
    tester,
  ) async {
    final storage = MemoryAuthStorage();
    await pumpApp(
      tester,
      api: FakeDaemonApi(),
      daemonUrl: Uri.parse('https://daemon.example.com'),
      storage: storage,
      seedDaemonUrlInStorage: false,
    );

    expect(find.text('Connect daemon'), findsOneWidget);
    expect(find.text('Test connection'), findsOneWidget);
    expect(find.text('Unlock workspace'), findsNothing);
  });

  testWidgets(
    'daemon setup shows examples and fills the local development address',
    (tester) async {
      final storage = MemoryAuthStorage();
      await pumpApp(
        tester,
        api: FakeDaemonApi(),
        daemonUrl: Uri.parse('https://daemon.example.com'),
        storage: storage,
        seedDaemonUrlInStorage: false,
      );

      expect(find.textContaining('https://agent.example.com'), findsOneWidget);
      expect(find.text('Use local development address'), findsOneWidget);

      await tester.tap(find.text('Use local development address'));
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(TextField, 'https://dockapi.lark.video/'),
        findsOneWidget,
      );

      await tester.tap(find.text('Test connection'));
      await tester.pumpAndSettle();

      expect(storage.savedDaemonUrl, Uri.parse('https://dockapi.lark.video'));
      expect(find.text('Unlock workspace'), findsOneWidget);
      expect(find.text('dockapi.lark.video'), findsOneWidget);
    },
  );

  testWidgets('stores daemon URL only after a successful health check', (
    tester,
  ) async {
    final storage = MemoryAuthStorage();
    await pumpApp(
      tester,
      api: FakeDaemonApi(),
      daemonUrl: Uri.parse('https://fallback.example.com'),
      storage: storage,
      seedDaemonUrlInStorage: false,
    );

    await tester.enterText(
      find.widgetWithText(TextField, 'Daemon URL'),
      'https://saved.example.com/',
    );
    await tester.tap(find.text('Test connection'));
    await tester.pumpAndSettle();

    expect(storage.savedDaemonUrl, Uri.parse('https://saved.example.com'));
    expect(find.text('Unlock workspace'), findsOneWidget);
    expect(find.text('saved.example.com'), findsOneWidget);
  });

  testWidgets(
    'daemon setup avoids spinner flicker for quick connection tests',
    (tester) async {
      final storage = MemoryAuthStorage();
      await pumpApp(
        tester,
        api: FakeDaemonApi(healthCheckDelay: const Duration(milliseconds: 200)),
        daemonUrl: Uri.parse('https://fallback.example.com'),
        storage: storage,
        seedDaemonUrlInStorage: false,
      );

      await tester.enterText(
        find.widgetWithText(TextField, 'Daemon URL'),
        'https://saved.example.com',
      );
      await tester.tap(find.text('Test connection'));
      await tester.pump();

      expect(
        find.byKey(const ValueKey('launch-test-connection-spinner')),
        findsNothing,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Testing connection...'),
            )
            .onPressed,
        isNull,
      );

      await tester.pump(const Duration(milliseconds: 220));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'daemon setup shows a spinner after longer connection tests cross 300 ms',
    (tester) async {
      final storage = MemoryAuthStorage();
      await pumpApp(
        tester,
        api: FakeDaemonApi(healthCheckDelay: const Duration(milliseconds: 450)),
        daemonUrl: Uri.parse('https://fallback.example.com'),
        storage: storage,
        seedDaemonUrlInStorage: false,
      );

      await tester.enterText(
        find.widgetWithText(TextField, 'Daemon URL'),
        'https://saved.example.com',
      );
      await tester.tap(find.text('Test connection'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 320));

      expect(
        find.byKey(const ValueKey('launch-test-connection-spinner')),
        findsOneWidget,
      );

      await tester.pump(const Duration(milliseconds: 180));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('shows daemon health errors and keeps setup active', (
    tester,
  ) async {
    final storage = MemoryAuthStorage();
    await pumpApp(
      tester,
      api: FakeDaemonApi(
        healthError: const DaemonApiException(
          statusCode: 503,
          code: 'UNAVAILABLE',
          message: 'Cannot reach daemon',
        ),
      ),
      daemonUrl: Uri.parse('https://fallback.example.com'),
      storage: storage,
      seedDaemonUrlInStorage: false,
    );

    await tester.enterText(
      find.widgetWithText(TextField, 'Daemon URL'),
      'https://saved.example.com/',
    );
    await tester.tap(find.text('Test connection'));
    await tester.pumpAndSettle();

    expect(find.text('Cannot reach daemon'), findsOneWidget);
    expect(find.text('Connect daemon'), findsOneWidget);
    expect(find.text('Unlock workspace'), findsNothing);
    expect(storage.savedDaemonUrl, isNull);
  });

  testWidgets(
    'shows a specific error when the daemon responds but is not Agent Dock',
    (tester) async {
      final storage = MemoryAuthStorage();
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          healthError: const FormatException(
            'Daemon responded but is not healthy',
          ),
        ),
        daemonUrl: Uri.parse('https://fallback.example.com'),
        storage: storage,
        seedDaemonUrlInStorage: false,
      );

      await tester.enterText(
        find.widgetWithText(TextField, 'Daemon URL'),
        'https://saved.example.com/',
      );
      await tester.tap(find.text('Test connection'));
      await tester.pumpAndSettle();

      expect(
        find.text('Daemon responded but does not look like Agent Dock'),
        findsOneWidget,
      );
      expect(find.text('Connect daemon'), findsOneWidget);
      expect(find.text('Unlock workspace'), findsNothing);
      expect(storage.savedDaemonUrl, isNull);
    },
  );

  testWidgets(
    'checks saved daemon health on launch and returns to setup on failure',
    (tester) async {
      final api = FakeDaemonApi(
        healthError: const DaemonApiException(
          statusCode: 503,
          code: 'UNAVAILABLE',
          message: 'Cannot reach saved daemon',
        ),
      );
      final storage = MemoryAuthStorage(
        daemonUrl: Uri.parse('https://saved.example.com'),
      );

      await pumpApp(
        tester,
        api: api,
        daemonUrl: Uri.parse('https://fallback.example.com'),
        storage: storage,
        seedDaemonUrlInStorage: false,
      );

      expect(api.healthChecks, hasLength(1));
      expect(find.text('Connect daemon'), findsOneWidget);
      expect(find.text('Cannot reach saved daemon'), findsOneWidget);
      expect(
        find.widgetWithText(TextField, 'https://saved.example.com'),
        findsOneWidget,
      );
      expect(find.text('Unlock workspace'), findsNothing);
    },
  );

  testWidgets('shows login form before daemon authentication', (tester) async {
    await pumpApp(tester, api: FakeDaemonApi());

    expect(find.text('Agent Dock'), findsOneWidget);
    expect(find.text('Unlock workspace'), findsOneWidget);
    expect(find.text('daemon.example.com'), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(2));
    expect(find.text('Sign in'), findsOneWidget);
  });

  testWidgets(
    'returns to login when the initial sessions bootstrap refresh is unauthorized',
    (tester) async {
      final storage = MemoryAuthStorage();
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrapErrors: <Object>[
            const DaemonApiException(
              statusCode: 401,
              code: 'UNAUTHORIZED',
              message: 'Session expired',
            ),
          ],
        ),
        storage: storage,
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      expect(storage.profile, isNull);
      expect(find.text('Unlock workspace'), findsOneWidget);
      expect(find.text('Sessions'), findsNothing);
      expect(find.text('Session expired. Sign in again.'), findsOneWidget);
    },
  );

  testWidgets(
    'shows an offline banner for login network failures and keeps the username',
    (tester) async {
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          loginError: const SocketException('Network is unreachable'),
        ),
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      expect(find.text('Unlock workspace'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('launch-status-banner')),
        findsOneWidget,
      );
      expect(find.text('Offline. Waiting for network...'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField).at(0)).controller!.text,
        'workspace',
      );
      expect(find.text('Sessions'), findsNothing);
    },
  );

  testWidgets('sign in avoids spinner flicker for quick logins', (
    tester,
  ) async {
    await pumpApp(
      tester,
      api: FakeDaemonApi(loginDelay: const Duration(milliseconds: 200)),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pump();

    expect(find.byKey(const ValueKey('launch-sign-in-spinner')), findsNothing);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Signing in...'),
          )
          .onPressed,
      isNull,
    );

    await tester.pump(const Duration(milliseconds: 220));
    await tester.pumpAndSettle();
  });

  testWidgets('sign in shows a spinner after longer logins cross 300 ms', (
    tester,
  ) async {
    await pumpApp(
      tester,
      api: FakeDaemonApi(loginDelay: const Duration(milliseconds: 450)),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 320));

    expect(
      find.byKey(const ValueKey('launch-sign-in-spinner')),
      findsOneWidget,
    );

    await tester.pump(const Duration(milliseconds: 180));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'routes to daemon setup from the login page and keeps the current URL',
    (tester) async {
      await pumpApp(
        tester,
        api: FakeDaemonApi(),
        daemonUrl: Uri.parse('https://daemon.example.com'),
      );

      await tester.tap(find.text('Change daemon'));
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(TextField, 'https://daemon.example.com'),
        findsOneWidget,
      );
      expect(find.text('Connect daemon'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'https://daemon.example.com'),
        'https://saved.example.com',
      );
      await tester.tap(find.text('Test connection'));
      await tester.pumpAndSettle();

      expect(find.text('saved.example.com'), findsOneWidget);
      expect(find.text('Unlock workspace'), findsOneWidget);
    },
  );

  testWidgets('rejects invalid daemon URLs on the login page', (tester) async {
    await pumpApp(
      tester,
      api: FakeDaemonApi(),
      daemonUrl: Uri.parse('https://daemon.example.com'),
    );

    await tester.tap(find.text('Change daemon'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'https://daemon.example.com'),
      'not-a-url',
    );
    await tester.tap(find.text('Test connection'));
    await tester.pumpAndSettle();

    expect(find.text('Enter a valid daemon URL'), findsOneWidget);
  });

  testWidgets('rejects non-local insecure daemon URLs on the login page', (
    tester,
  ) async {
    await pumpApp(
      tester,
      api: FakeDaemonApi(),
      daemonUrl: Uri.parse('https://daemon.example.com'),
    );

    await tester.tap(find.text('Change daemon'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'https://daemon.example.com'),
      'http://remote.example.com:4123',
    );
    await tester.tap(find.text('Test connection'));
    await tester.pumpAndSettle();

    expect(find.text('Use HTTPS for remote daemons'), findsOneWidget);
  });

  testWidgets('allows local development HTTP daemon URLs on the login page', (
    tester,
  ) async {
    await pumpApp(
      tester,
      api: FakeDaemonApi(),
      daemonUrl: Uri.parse('https://daemon.example.com'),
    );

    await tester.tap(find.text('Change daemon'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'https://daemon.example.com'),
      'http://10.0.2.2:4123',
    );
    await tester.tap(find.text('Test connection'));
    await tester.pumpAndSettle();

    expect(find.text('10.0.2.2'), findsOneWidget);
    expect(find.text('Unlock workspace'), findsOneWidget);
  });

  testWidgets('signs in and renders daemon bootstrap sessions', (tester) async {
    final api = FakeDaemonApi(
      bootstrap: MobileBootstrap(
        daemonVersion: '0.1.0',
        user: const CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: const [
          WorkspaceRoot(
            id: 'workspace',
            label: 'Workspace',
            path: '/home/jhz/projects',
          ),
        ],
        sessions: const [
          SessionSummary(
            id: 'sess_1',
            title: 'Mobile migration',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            status: 'running',
            workspacePath: '/home/jhz/projects/agent-dock',
          ),
        ],
        voice: const VoiceConfig(doubaoDirectAvailable: false),
      ),
    );
    await pumpApp(tester, api: api);

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    expect(api.bootstrappedTokens, ['tok_workspace']);
    expect(find.text('Unlock workspace'), findsNothing);
    expect(find.text('Sessions'), findsOneWidget);
    expect(find.text('Workspace'), findsOneWidget);
    expect(find.text('Mobile migration'), findsOneWidget);
    expect(find.text('running'), findsOneWidget);
    expect(find.text('codex'), findsOneWidget);
    expect(find.text('managed'), findsNothing);
    expect(find.text('/home/jhz/projects/agent-dock'), findsOneWidget);
    expect(find.text('Voice input is not configured'), findsNothing);
    expect(find.text('New session'), findsOneWidget);
    expect(find.text('Attach'), findsOneWidget);
  });

  testWidgets(
    'opening a session saves the last selected session scoped by daemon and user',
    (tester) async {
      final storage = MemoryAuthStorage();
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: const MobileBootstrap(
            daemonVersion: '0.1.0',
            user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
            roots: <WorkspaceRoot>[],
            sessions: [
              SessionSummary(
                id: 'sess_1',
                title: 'Mobile migration',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'running',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: VoiceConfig(doubaoDirectAvailable: true),
          ),
          snapshot: const SessionSnapshot(
            id: 'sess_1',
            title: 'Mobile migration',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            workspacePath: '/home/jhz/projects/agent-dock',
            status: 'running',
            hasMoreHistory: false,
            events: <SessionEvent>[],
          ),
        ),
        storage: storage,
        daemonUrl: Uri.parse('https://daemon.example.com'),
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mobile migration'));
      await tester.pumpAndSettle();

      expect(storage.lastSelectedSessionIds, {
        (Uri.parse('https://daemon.example.com'), 'usr_workspace'): 'sess_1',
      });
    },
  );

  testWidgets('unsupported daemon version blocks mutating session actions', (
    tester,
  ) async {
    await pumpApp(
      tester,
      api: FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.0.9',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: [
            WorkspaceRoot(
              id: 'workspace',
              label: 'Workspace',
              path: '/home/jhz/projects',
            ),
          ],
          sessions: [
            SessionSummary(
              id: 'sess_1',
              title: 'Mobile migration',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: VoiceConfig(doubaoDirectAvailable: true),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    expect(find.text('Unsupported daemon version'), findsOneWidget);
    expect(find.text('Daemon version 0.0.9'), findsOneWidget);
    expect(find.text('Requires daemon version 0.1.0 or newer'), findsOneWidget);
    expect(find.text('Mobile migration'), findsOneWidget);
    final newSessionButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'New session'),
    );
    expect(newSessionButton.onPressed, isNull);
    final attachButton = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Attach'),
    );
    expect(attachButton.onPressed, isNull);
    expect(find.byTooltip('Delete session'), findsNothing);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Change daemon'));
    await tester.pumpAndSettle();

    expect(find.text('Connect daemon'), findsOneWidget);
    expect(find.text('Unlock workspace'), findsNothing);
  });

  testWidgets(
    'shows daemon host and connection indicator in the sessions app bar',
    (tester) async {
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: const MobileBootstrap(
            daemonVersion: '0.1.0',
            user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
            roots: <WorkspaceRoot>[],
            sessions: <SessionSummary>[],
            voice: VoiceConfig(doubaoDirectAvailable: false),
          ),
        ),
        daemonUrl: Uri.parse('https://daemon.example.com'),
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      expect(find.text('Sessions'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('sessions-appbar-connection')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('sessions-appbar-connection')),
          matching: find.text('daemon.example.com'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('sessions-appbar-connection')),
          matching: find.byKey(const ValueKey('sessions-appbar-status-dot')),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('session rows middle-truncate long workspace paths', (
    tester,
  ) async {
    const fullPath =
        '/Users/alice/workspaces/product/mobile/app/agent-workspace';
    const truncatedPath = '/Users/alice/.../app/agent-workspace';
    await pumpApp(
      tester,
      api: FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: <WorkspaceRoot>[],
          sessions: [
            SessionSummary(
              id: 'sess_1',
              title: 'Long path session',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: fullPath,
            ),
          ],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    expect(find.text(truncatedPath), findsOneWidget);
    expect(find.text(fullPath), findsNothing);
    final pathText = tester.widget<Text>(find.text(truncatedPath));
    expect(pathText.maxLines, 1);
    expect(pathText.overflow, TextOverflow.ellipsis);
  });

  testWidgets('session rows place metadata after the title on the first line', (
    tester,
  ) async {
    await pumpApp(
      tester,
      api: FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: <WorkspaceRoot>[],
          sessions: [
            SessionSummary(
              id: 'sess_1',
              title: 'dock',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/tools/agent-workspace',
            ),
          ],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    final sessionCard = find.byKey(
      const ValueKey('session-row-inkwell-sess_1'),
    );
    final titleCenter = tester
        .getCenter(
          find.descendant(of: sessionCard, matching: find.text('dock')),
        )
        .dy;
    final agentCenter = tester
        .getCenter(
          find.descendant(of: sessionCard, matching: find.text('codex')),
        )
        .dy;
    final statusCenter = tester
        .getCenter(
          find.descendant(of: sessionCard, matching: find.text('running')),
        )
        .dy;
    final pathTop = tester
        .getTopLeft(
          find.descendant(
            of: sessionCard,
            matching: find.text('/home/jhz/tools/agent-workspace'),
          ),
        )
        .dy;

    expect(agentCenter, closeTo(titleCenter, 1));
    expect(statusCenter, closeTo(titleCenter, 1));
    expect(pathTop, greaterThan(titleCenter));

    final titleText = tester.widget<Text>(
      find.descendant(of: sessionCard, matching: find.text('dock')),
    );
    expect(titleText.maxLines, 1);
    expect(titleText.overflow, TextOverflow.ellipsis);
  });

  testWidgets('orders running sessions before completed sessions', (
    tester,
  ) async {
    await pumpApp(
      tester,
      api: FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: <WorkspaceRoot>[],
          sessions: [
            SessionSummary(
              id: 'sess_done',
              title: 'Completed session',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: null,
              status: 'completed',
              workspacePath: '/tmp/completed',
            ),
            SessionSummary(
              id: 'sess_running',
              title: 'Running session',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: null,
              status: 'running',
              workspacePath: '/tmp/running',
            ),
          ],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    final runningTopLeft = tester.getTopLeft(find.text('Running session'));
    final completedTopLeft = tester.getTopLeft(find.text('Completed session'));
    expect(runningTopLeft.dy, lessThan(completedTopLeft.dy));
  });

  testWidgets(
    'session rows fall back to the agent kind when title and workspace basename are unavailable',
    (tester) async {
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: const MobileBootstrap(
            daemonVersion: '0.1.0',
            user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
            roots: <WorkspaceRoot>[],
            sessions: [
              SessionSummary(
                id: 'sess_root',
                title: null,
                agentKind: 'claude',
                sourceKind: 'attached',
                runtimeSessionId: null,
                status: 'completed',
                workspacePath: '/',
              ),
            ],
            voice: VoiceConfig(doubaoDirectAvailable: false),
          ),
        ),
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      final sessionCard = find.byKey(
        const ValueKey('session-row-inkwell-sess_root'),
      );
      expect(
        find.descendant(of: sessionCard, matching: find.text('claude')),
        findsAtLeastNWidgets(1),
      );
      expect(
        find.descendant(of: sessionCard, matching: find.text('/')),
        findsOneWidget,
      );
    },
  );

  testWidgets('shows running sessions only in the main sessions list', (
    tester,
  ) async {
    await pumpApp(
      tester,
      api: FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: <WorkspaceRoot>[],
          sessions: [
            SessionSummary(
              id: 'sess_running',
              title: 'Running session',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_running',
              status: 'running',
              workspacePath: '/tmp/running',
            ),
            SessionSummary(
              id: 'sess_idle',
              title: 'Idle session',
              agentKind: 'claude',
              sourceKind: 'attached',
              runtimeSessionId: 'runtime_idle',
              status: 'idle',
              workspacePath: '/tmp/idle',
            ),
          ],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    expect(find.text('Running now'), findsNothing);
    expect(find.byKey(const ValueKey('running-session-strip')), findsNothing);
    expect(find.text('Resume Running session'), findsNothing);
    expect(find.text('Resume Idle session'), findsNothing);
    expect(find.text('Running session'), findsOneWidget);
    expect(find.text('Idle session'), findsOneWidget);
  });

  testWidgets('long session lists stay fully reachable in the sessions page', (
    tester,
  ) async {
    await pumpApp(
      tester,
      api: FakeDaemonApi(
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: List<SessionSummary>.generate(
            16,
            (index) => SessionSummary(
              id: 'sess_$index',
              title: 'Session ${index + 1}',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_$index',
              status: 'completed',
              workspacePath: '/tmp/session_$index',
            ),
          ),
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView).first, const Offset(0, -2000));
    await tester.pumpAndSettle();

    expect(find.text('Session 16'), findsOneWidget);
  });

  testWidgets('keeps session cards readable at large text scales', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
    tester.platformDispatcher.textScaleFactorTestValue = 2.4;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await pumpApp(
      tester,
      api: FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: <WorkspaceRoot>[],
          sessions: [
            SessionSummary(
              id: 'sess_running',
              title: 'Running session',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_running',
              status: 'running',
              workspacePath: '/tmp/running',
            ),
          ],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('running-session-strip')), findsNothing);
    expect(find.text('Running now'), findsNothing);
    expect(find.text('Running session'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows voice configured when the daemon supports voice input', (
    tester,
  ) async {
    await pumpApp(
      tester,
      api: FakeDaemonApi(
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Mobile migration',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: true),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    expect(find.text('Voice input not configured'), findsNothing);
  });

  testWidgets('saves daemon URL token and user id after login', (tester) async {
    final storage = MemoryAuthStorage();
    await pumpApp(tester, api: FakeDaemonApi(), storage: storage);

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    expect(storage.profile?.daemonUrl, Uri.parse('https://daemon.example.com'));
    expect(storage.profile?.token, 'tok_workspace');
    expect(storage.profile?.userId, 'usr_workspace');
  });

  testWidgets(
    'signing in as another user on the same daemon clears the previous user in-memory drafts and caches',
    (tester) async {
      final daemonUrl = Uri.parse('https://daemon.example.com');
      final storage = MemoryAuthStorage(
        profile: AuthProfile(
          daemonUrl: daemonUrl,
          token: 'tok_alice',
          userId: 'usr_alice',
        ),
      );
      final composerDraftStore = MemorySessionComposerDraftStore();
      final sessionDetailCacheStore = MemorySessionDetailCacheStore();
      const aliceSessionId = 'sess_alice';

      composerDraftStore.saveDraft(
        scope: SessionComposerDraftScope(
          daemonUrl: daemonUrl,
          userId: 'usr_alice',
          sessionId: aliceSessionId,
        ),
        draft: const SessionComposerDraft(text: 'Alice draft'),
      );
      sessionDetailCacheStore.saveCache(
        scope: SessionDetailCacheScope(
          daemonUrl: daemonUrl,
          userId: 'usr_alice',
          sessionId: aliceSessionId,
        ),
        entry: const SessionDetailCacheEntry(
          events: <SessionEvent>[
            SessionEvent(
              id: 1,
              eventType: 'assistant.message',
              payload: {'text': 'alice'},
            ),
          ],
          hasMoreHistory: false,
          expandedItemKeys: <String>{'tool:1'},
          autoExpandedFailedToolItemKeys: <String>{'tool:2'},
          scrollOffset: 48,
        ),
      );

      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrapErrors: <Object>[const SocketException('offline')],
          loginResults: const <LoginResult>[
            LoginResult(
              token: 'tok_bob',
              user: CurrentUser(id: 'usr_bob', displayName: 'Bob'),
            ),
          ],
          bootstrap: const MobileBootstrap(
            daemonVersion: '0.1.0',
            user: CurrentUser(id: 'usr_bob', displayName: 'Bob'),
            roots: <WorkspaceRoot>[],
            sessions: <SessionSummary>[
              SessionSummary(
                id: 'sess_bob',
                title: 'Bob session',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_bob',
                status: 'running',
                workspacePath: '/tmp/bob',
              ),
            ],
            voice: VoiceConfig(doubaoDirectAvailable: false),
          ),
        ),
        daemonUrl: daemonUrl,
        storage: storage,
        composerDraftStore: composerDraftStore,
        sessionDetailCacheStore: sessionDetailCacheStore,
      );

      expect(find.text('Restoring session...'), findsOneWidget);
      expect(find.text('Offline. Waiting for network...'), findsOneWidget);
      expect(find.text('Sign in manually'), findsOneWidget);

      await tester.tap(find.text('Sign in manually'));
      await tester.pumpAndSettle();

      expect(find.text('Unlock workspace'), findsOneWidget);

      await tester.enterText(find.byType(TextField).at(0), 'bob');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      expect(find.text('Bob session'), findsOneWidget);
      expect(
        composerDraftStore.readDraft(
          scope: SessionComposerDraftScope(
            daemonUrl: daemonUrl,
            userId: 'usr_alice',
            sessionId: aliceSessionId,
          ),
        ),
        isNull,
      );
      expect(
        sessionDetailCacheStore.readCache(
          scope: SessionDetailCacheScope(
            daemonUrl: daemonUrl,
            userId: 'usr_alice',
            sessionId: aliceSessionId,
          ),
        ),
        isNull,
      );
      expect(storage.profile?.token, 'tok_bob');
      expect(storage.profile?.userId, 'usr_bob');
    },
  );

  testWidgets('restores a saved token with mobile bootstrap on launch', (
    tester,
  ) async {
    final api = FakeDaemonApi(
      bootstrap: const MobileBootstrap(
        daemonVersion: '0.1.0',
        user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: <WorkspaceRoot>[],
        sessions: [
          SessionSummary(
            id: 'sess_1',
            title: 'Restored session',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            status: 'running',
            workspacePath: '/home/jhz/projects/agent-dock',
          ),
        ],
        voice: VoiceConfig(doubaoDirectAvailable: false),
      ),
    );
    final storage = MemoryAuthStorage(
      profile: AuthProfile(
        daemonUrl: Uri.parse('https://daemon.example.com'),
        token: 'tok_workspace',
        userId: 'usr_workspace',
      ),
    );

    await pumpApp(
      tester,
      api: api,
      daemonUrl: Uri.parse('https://fallback.example.com'),
      storage: storage,
    );

    expect(api.bootstrappedTokens, ['tok_workspace']);
    expect(find.text('Sessions'), findsOneWidget);
    expect(find.text('Restored session'), findsOneWidget);
    expect(find.text('Unlock workspace'), findsNothing);
  });

  testWidgets(
    'keeps the saved session restore flow visible for startup network errors and lets the user retry',
    (tester) async {
      final storage = MemoryAuthStorage(
        profile: AuthProfile(
          daemonUrl: Uri.parse('https://daemon.example.com'),
          token: 'tok_workspace',
          userId: 'usr_workspace',
        ),
      );
      final api = FakeDaemonApi(
        bootstrapErrors: <Object>[
          const SocketException('Network is unreachable'),
        ],
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: <WorkspaceRoot>[],
          sessions: <SessionSummary>[
            SessionSummary(
              id: 'sess_1',
              title: 'Restored session',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
      );

      await pumpApp(tester, api: api, storage: storage);

      expect(find.text('Restoring session...'), findsOneWidget);
      expect(find.text('Offline. Waiting for network...'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Unlock workspace'), findsNothing);
      expect(storage.profile?.token, 'tok_workspace');

      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(api.bootstrappedTokens, ['tok_workspace', 'tok_workspace']);
      expect(find.text('Sessions'), findsOneWidget);
      expect(find.text('Restored session'), findsOneWidget);
    },
  );

  testWidgets(
    'startup restore failure shows a user-facing error instead of the raw exception string',
    (tester) async {
      final storage = MemoryAuthStorage(
        profile: AuthProfile(
          daemonUrl: Uri.parse('https://daemon.example.com'),
          token: 'tok_workspace',
          userId: 'usr_workspace',
        ),
      );
      final api = FakeDaemonApi(
        bootstrapErrors: <Object>[StateError('Restore state corrupted')],
      );

      await pumpApp(tester, api: api, storage: storage);

      expect(find.text('Restoring session...'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Bad state: Restore state corrupted'), findsNothing);
      expect(find.text('Could not restore session'), findsOneWidget);
      expect(storage.profile?.token, 'tok_workspace');
      expect(find.text('Unlock workspace'), findsNothing);
    },
  );

  testWidgets(
    'restore failure lets the user change daemon directly from the restore page',
    (tester) async {
      final storage = MemoryAuthStorage(
        profile: AuthProfile(
          daemonUrl: Uri.parse('https://saved.example.com'),
          token: 'tok_workspace',
          userId: 'usr_workspace',
        ),
      );

      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrapErrors: <Object>[
            const SocketException('Network is unreachable'),
          ],
        ),
        daemonUrl: Uri.parse('https://fallback.example.com'),
        storage: storage,
      );

      expect(find.text('Restoring session...'), findsOneWidget);
      expect(find.text('Change daemon'), findsOneWidget);

      await tester.tap(find.text('Change daemon'));
      await tester.pumpAndSettle();

      expect(storage.didClear, isTrue);
      expect(find.text('Connect daemon'), findsOneWidget);
      expect(
        find.widgetWithText(TextField, 'https://saved.example.com'),
        findsOneWidget,
      );
      expect(find.text('Unlock workspace'), findsNothing);
    },
  );

  testWidgets(
    'routes back to login with session expired when restoring a saved token is unauthorized on launch',
    (tester) async {
      final storage = MemoryAuthStorage(
        profile: AuthProfile(
          daemonUrl: Uri.parse('https://daemon.example.com'),
          token: 'tok_workspace',
          userId: 'usr_workspace',
        ),
      );

      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrapErrors: <Object>[
            const DaemonApiException(
              statusCode: 401,
              code: 'UNAUTHORIZED',
              message: 'Session expired',
            ),
          ],
        ),
        storage: storage,
      );

      expect(storage.profile, isNull);
      expect(find.text('Unlock workspace'), findsOneWidget);
      expect(find.text('Session expired. Sign in again.'), findsOneWidget);
      expect(find.text('Restoring session...'), findsNothing);
      expect(find.text('Sessions'), findsNothing);
    },
  );

  testWidgets(
    'shows the launch restore page and delayed daemon host while restoring a saved session',
    (tester) async {
      final storage = MemoryAuthStorage(
        profile: AuthProfile(
          daemonUrl: Uri.parse('https://saved.example.com'),
          token: 'tok_workspace',
          userId: 'usr_workspace',
        ),
      );
      final api = FakeDaemonApi(
        bootstrapDelay: const Duration(seconds: 3),
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: <WorkspaceRoot>[],
          sessions: <SessionSummary>[
            SessionSummary(
              id: 'sess_1',
              title: 'Restored session',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
      );

      await tester.pumpWidget(
        AgentDockApp(
          api: api,
          authStorage: storage,
          daemonUrl: Uri.parse('https://fallback.example.com'),
        ),
      );
      await tester.pump();

      expect(find.text('Restoring session...'), findsOneWidget);
      expect(find.text('saved.example.com'), findsNothing);

      await tester.pump(const Duration(milliseconds: 2100));

      expect(find.text('saved.example.com'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 1000));
      await tester.pumpAndSettle();

      expect(find.text('Sessions'), findsOneWidget);
      expect(find.text('Restored session'), findsOneWidget);
    },
  );

  testWidgets('pulses the launch app mark while restore work is active', (
    tester,
  ) async {
    final storage = MemoryAuthStorage(
      profile: AuthProfile(
        daemonUrl: Uri.parse('https://saved.example.com'),
        token: 'tok_workspace',
        userId: 'usr_workspace',
      ),
    );

    await tester.pumpWidget(
      AgentDockApp(
        api: FakeDaemonApi(bootstrapDelay: const Duration(seconds: 3)),
        authStorage: storage,
        daemonUrl: Uri.parse('https://fallback.example.com'),
      ),
    );
    await tester.pump();

    final opacityFinder = find.byKey(
      const ValueKey('restore-app-mark-opacity'),
    );
    expect(tester.widget<AnimatedOpacity>(opacityFinder).opacity, equals(1));

    await tester.pump(const Duration(milliseconds: 950));

    expect(tester.widget<AnimatedOpacity>(opacityFinder).opacity, equals(0.84));

    await tester.pump(const Duration(milliseconds: 2050));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'keeps the launch app mark static when reduced motion is enabled during restore',
    (tester) async {
      tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(
            disableAnimations: true,
            reduceMotion: true,
          );
      addTearDown(
        tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );

      final storage = MemoryAuthStorage(
        profile: AuthProfile(
          daemonUrl: Uri.parse('https://saved.example.com'),
          token: 'tok_workspace',
          userId: 'usr_workspace',
        ),
      );

      await tester.pumpWidget(
        AgentDockApp(
          api: FakeDaemonApi(bootstrapDelay: const Duration(seconds: 3)),
          authStorage: storage,
          daemonUrl: Uri.parse('https://fallback.example.com'),
        ),
      );
      await tester.pump();

      final opacityFinder = find.byKey(
        const ValueKey('restore-app-mark-opacity'),
      );
      expect(tester.widget<AnimatedOpacity>(opacityFinder).opacity, equals(1));

      await tester.pump(const Duration(milliseconds: 950));

      expect(tester.widget<AnimatedOpacity>(opacityFinder).opacity, equals(1));

      await tester.pump(const Duration(milliseconds: 2050));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('restores using the saved daemon URL instead of fallback URL', (
    tester,
  ) async {
    final createdClients = <Uri, FakeDaemonApi>{};
    final storage = MemoryAuthStorage(
      profile: AuthProfile(
        daemonUrl: Uri.parse('https://saved.example.com'),
        token: 'tok_workspace',
        userId: 'usr_workspace',
      ),
    );

    await tester.pumpWidget(
      AgentDockApp(
        daemonUrl: Uri.parse('https://fallback.example.com'),
        authStorage: storage,
        apiFactory: (daemonUrl) {
          final api = FakeDaemonApi(
            bootstrap: MobileBootstrap(
              daemonVersion: '0.1.0',
              user: const CurrentUser(
                id: 'usr_workspace',
                displayName: 'Workspace',
              ),
              roots: const <WorkspaceRoot>[],
              sessions: [
                SessionSummary(
                  id: 'sess_saved',
                  title: 'Saved daemon session',
                  agentKind: 'codex',
                  sourceKind: 'managed',
                  runtimeSessionId: 'runtime_1',
                  status: 'running',
                  workspacePath: daemonUrl.host,
                ),
              ],
              voice: const VoiceConfig(doubaoDirectAvailable: false),
            ),
          );
          createdClients[daemonUrl] = api;
          return api;
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(createdClients.keys, [Uri.parse('https://saved.example.com')]);
    expect(
      createdClients[Uri.parse('https://saved.example.com')]!
          .bootstrappedTokens,
      ['tok_workspace'],
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('sessions-appbar-connection')),
        matching: find.text('saved.example.com'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('opens a session and renders daemon snapshot events', (
    tester,
  ) async {
    await pumpApp(
      tester,
      api: FakeDaemonApi(
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Mobile migration',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'idle',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Mobile migration',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: true,
          events: [
            SessionEvent(
              id: 1,
              eventType: 'user.message',
              payload: {'text': 'please migrate mobile'},
            ),
            SessionEvent(
              id: 2,
              eventType: 'assistant.message',
              payload: {'text': 'migrated'},
            ),
            SessionEvent(
              id: 3,
              eventType: 'session.attached',
              payload: {'runtimeSessionId': 'thread-abc'},
            ),
            SessionEvent(
              id: 4,
              eventType: 'assistant.thinking.delta',
              payload: {'text': 'plan first'},
            ),
            SessionEvent(
              id: 5,
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
            SessionEvent(
              id: 6,
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
            SessionEvent(
              id: 7,
              eventType: 'session.status.changed',
              payload: {'status': 'running'},
            ),
          ],
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mobile migration'));
    await tester.pumpAndSettle();

    expect(find.text('Mobile migration'), findsOneWidget);
    expect(find.byKey(const ValueKey('session-status-pill')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('session-status-pill')),
        matching: find.text('running'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('session-status-pill')),
        matching: find.byKey(const ValueKey('session-status-pill-dot')),
      ),
      findsOneWidget,
    );
    final runningDot = tester.widget<Container>(
      find.byKey(const ValueKey('session-status-pill-dot')),
    );
    final runningDotDecoration = runningDot.decoration! as BoxDecoration;
    expect(runningDotDecoration.color, const Color(0xFF43D17A));
    final runningDotOpacity = tester.widget<Opacity>(
      find.byKey(const ValueKey('session-status-pill-dot-opacity')),
    );
    expect(runningDotOpacity.opacity, 1);

    await tester.pump(const Duration(milliseconds: 400));

    final midRunningDotOpacity = tester.widget<Opacity>(
      find.byKey(const ValueKey('session-status-pill-dot-opacity')),
    );
    await tester.pump(const Duration(milliseconds: 400));

    final lateRunningDotOpacity = tester.widget<Opacity>(
      find.byKey(const ValueKey('session-status-pill-dot-opacity')),
    );
    expect(<double>[
      midRunningDotOpacity.opacity,
      lateRunningDotOpacity.opacity,
    ], contains(isNot(runningDotOpacity.opacity)));
    expect(find.text('running'), findsAtLeastNWidgets(1));
    expect(find.text('session.status.changed'), findsNothing);
    expect(find.text('tool.call.completed'), findsNothing);

    await tester.drag(find.byType(ListView).last, const Offset(0, 1200));
    await tester.pumpAndSettle();

    expect(find.text('migrated'), findsOneWidget);
    expect(find.text('Attached runtime'), findsOneWidget);
    expect(find.text('Reasoning'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Message the agent'), findsOneWidget);
  });

  testWidgets(
    'opens a suspended session detail immediately before resume completes',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Slow resume',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'suspended',
              workspacePath: '/tmp/workspace',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        resumeResult: const SessionSnapshot(
          id: 'sess_1',
          title: 'Slow resume',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/tmp/workspace',
          status: 'running',
          hasMoreHistory: false,
          events: [
            SessionEvent(
              id: 3,
              eventType: 'session.status.changed',
              payload: {'status': 'running'},
            ),
          ],
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Slow resume',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/tmp/workspace',
          status: 'suspended',
          hasMoreHistory: false,
          events: [
            SessionEvent(
              id: 2,
              eventType: 'assistant.message',
              payload: {'text': 'cached-ish content'},
            ),
          ],
        ),
        attachDelay: const Duration(milliseconds: 1),
        resumeDelay: const Duration(seconds: 2),
        snapshotDelay: const Duration(seconds: 2),
      );

      await pumpApp(tester, api: api);
      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Slow resume'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Chat'), findsNothing);
      expect(
        find.byKey(const ValueKey('composer-input-surface')),
        findsOneWidget,
      );

      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
    },
  );

  testWidgets(
    'background resume subscribes after the recovered snapshot tail instead of replaying from zero',
    (tester) async {
      final resumedEvents = StreamController<SessionEvent>();
      final api = FakeDaemonApi(
        liveEventStreams: [resumedEvents.stream],
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Resume window',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'suspended',
              workspacePath: '/tmp/workspace',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        resumeDelay: const Duration(seconds: 2),
        snapshotDelay: const Duration(seconds: 2),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Resume window',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/tmp/workspace',
          status: 'suspended',
          hasMoreHistory: true,
          events: [
            SessionEvent(
              id: 50,
              eventType: 'assistant.message',
              payload: {'text': 'window tail'},
            ),
          ],
        ),
        resumeResult: const SessionSnapshot(
          id: 'sess_1',
          title: 'Resume window',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/tmp/workspace',
          status: 'running',
          hasMoreHistory: true,
          events: [
            SessionEvent(
              id: 50,
              eventType: 'assistant.message',
              payload: {'text': 'window tail'},
            ),
          ],
        ),
      );

      await pumpApp(tester, api: api);
      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Resume window'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();

      expect(api.eventSubscriptions, ['sess_1:tok_workspace:50']);
      await resumedEvents.close();
    },
  );

  testWidgets(
    'opens a running online session detail without starting a background resume',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Online session',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              runtimeHealth: 'online',
              status: 'running',
              workspacePath: '/tmp/workspace',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Online session',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          runtimeHealth: 'online',
          workspacePath: '/tmp/workspace',
          status: 'running',
          hasMoreHistory: false,
          events: [
            SessionEvent(
              id: 2,
              eventType: 'assistant.message',
              payload: {'text': 'live content'},
            ),
          ],
        ),
        attachDelay: const Duration(milliseconds: 1),
      );

      await pumpApp(tester, api: api);
      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Online session'));
      await tester.pumpAndSettle();

      expect(api.resumedSessions, isEmpty);
      expect(api.snapshotRequests, ['sess_1:tok_workspace:null']);
    },
  );

  testWidgets(
    'opens a running recoverable-error session detail and starts a background resume',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Recoverable session',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              runtimeHealth: 'recoverable_error',
              status: 'running',
              workspacePath: '/tmp/workspace',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        resumeResult: const SessionSnapshot(
          id: 'sess_1',
          title: 'Recoverable session',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          runtimeHealth: 'online',
          workspacePath: '/tmp/workspace',
          status: 'running',
          hasMoreHistory: false,
          events: [
            SessionEvent(
              id: 3,
              eventType: 'session.status.changed',
              payload: {'status': 'running'},
            ),
          ],
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Recoverable session',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          runtimeHealth: 'recoverable_error',
          workspacePath: '/tmp/workspace',
          status: 'running',
          hasMoreHistory: false,
          events: [
            SessionEvent(
              id: 2,
              eventType: 'assistant.message',
              payload: {'text': 'cached-ish content'},
            ),
          ],
        ),
        attachDelay: const Duration(milliseconds: 1),
        resumeDelay: const Duration(seconds: 2),
        snapshotDelay: const Duration(seconds: 2),
      );

      await pumpApp(tester, api: api);
      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Recoverable session'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(api.resumedSessions, ['sess_1:tok_workspace']);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
    },
  );

  testWidgets(
    'opens a running provider-error session detail without starting a background resume',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Provider error session',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              runtimeHealth: 'recoverable_error',
              runtimeErrorKind: 'provider',
              status: 'running',
              workspacePath: '/tmp/workspace',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Provider error session',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          runtimeHealth: 'recoverable_error',
          runtimeErrorKind: 'provider',
          runtimeErrorMessage: 'compact service returned 502',
          workspacePath: '/tmp/workspace',
          status: 'running',
          hasMoreHistory: false,
          events: [
            SessionEvent(
              id: 2,
              eventType: 'session.error',
              payload: {'message': 'compact service returned 502'},
            ),
          ],
        ),
        attachDelay: const Duration(milliseconds: 1),
      );

      await pumpApp(tester, api: api);
      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Provider error session'));
      await tester.pumpAndSettle();

      expect(api.resumedSessions, isEmpty);
      expect(api.snapshotRequests, ['sess_1:tok_workspace:null']);
    },
  );

  testWidgets(
    'cold opening without cached events subscribes after the latest snapshot event instead of replaying from zero',
    (tester) async {
      final resumedEvents = StreamController<SessionEvent>();
      final api = FakeDaemonApi(
        liveEventStreams: [resumedEvents.stream],
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Open fast',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/tmp/workspace',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshotDelay: const Duration(seconds: 2),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Open fast',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/tmp/workspace',
          status: 'running',
          hasMoreHistory: true,
          events: [
            SessionEvent(
              id: 50,
              eventType: 'assistant.message',
              payload: {'text': 'latest window tail'},
            ),
          ],
        ),
      );

      await pumpApp(tester, api: api);
      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Open fast'));
      await tester.pump();

      expect(api.eventSubscriptions, isNot(contains('sess_1:tok_workspace:0')));

      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(api.eventSubscriptions, ['sess_1:tok_workspace:50']);
      await resumedEvents.close();
    },
  );

  testWidgets(
    'cold opening without cached events shows the snapshot window before streaming newer events',
    (tester) async {
      final resumedEvents = StreamController<SessionEvent>();
      final api = FakeDaemonApi(
        liveEventStreams: [resumedEvents.stream],
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: <WorkspaceRoot>[],
          sessions: [
            SessionSummary(
              id: 'sess_1',
              title: 'Live first',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/tmp/workspace',
            ),
          ],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshotDelay: const Duration(seconds: 2),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Live first',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/tmp/workspace',
          status: 'running',
          hasMoreHistory: true,
          events: [
            SessionEvent(
              id: 50,
              eventType: 'user.message',
              payload: {'text': 'window tail'},
            ),
          ],
        ),
      );

      await pumpApp(tester, api: api);
      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Live first'));
      await tester.pump();

      expect(find.text('window tail'), findsNothing);
      expect(find.text('streamed before snapshot'), findsNothing);

      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(find.text('window tail'), findsOneWidget);
      resumedEvents.add(
        const SessionEvent(
          id: 51,
          eventType: 'assistant.message',
          payload: {'text': 'streamed before snapshot'},
        ),
      );
      await tester.pump();
      expect(api.eventSubscriptions, ['sess_1:tok_workspace:50']);
      await resumedEvents.close();
    },
  );

  testWidgets('shows an inline offline banner when background resume fails', (
    tester,
  ) async {
    final api = FakeDaemonApi(
      bootstrap: const MobileBootstrap(
        daemonVersion: '0.1.0',
        user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: <WorkspaceRoot>[],
        sessions: [
          SessionSummary(
            id: 'sess_1',
            title: 'Resume fails',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            status: 'suspended',
            workspacePath: '/tmp/workspace',
          ),
        ],
        voice: VoiceConfig(doubaoDirectAvailable: false),
      ),
      snapshot: const SessionSnapshot(
        id: 'sess_1',
        title: 'Resume fails',
        agentKind: 'codex',
        sourceKind: 'managed',
        runtimeSessionId: 'runtime_1',
        workspacePath: '/tmp/workspace',
        status: 'suspended',
        hasMoreHistory: false,
        events: [],
      ),
      resumeDelay: const Duration(milliseconds: 50),
      resumeError: const SocketException('network down'),
    );

    await pumpApp(tester, api: api);
    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Resume fails'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    expect(find.text('Offline. Waiting for network...'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('composer-input-surface')),
      findsOneWidget,
    );
  });

  testWidgets(
    'keeps the newer streamed status when a stale snapshot resolves later',
    (tester) async {
      final resumedEvents = StreamController<SessionEvent>();
      final api = FakeDaemonApi(
        liveEventStreams: [resumedEvents.stream],
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: <WorkspaceRoot>[],
          sessions: [
            SessionSummary(
              id: 'sess_1',
              title: 'Status race',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'idle',
              workspacePath: '/tmp/workspace',
            ),
          ],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshotDelay: const Duration(seconds: 2),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Status race',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/tmp/workspace',
          status: 'suspended',
          hasMoreHistory: false,
          events: [],
        ),
      );

      await pumpApp(tester, api: api);
      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Status race'));
      await tester.pump();

      resumedEvents.add(
        const SessionEvent(
          id: 4,
          eventType: 'session.status.changed',
          payload: {'status': 'running'},
        ),
      );
      await tester.pump();

      expect(
        find.descendant(
          of: find.byKey(const ValueKey('session-status-pill')),
          matching: find.text('running'),
        ),
        findsOneWidget,
      );

      await tester.pump(const Duration(seconds: 2));
      await tester.pump();

      expect(
        find.descendant(
          of: find.byKey(const ValueKey('session-status-pill')),
          matching: find.text('running'),
        ),
        findsOneWidget,
      );

      await resumedEvents.close();
    },
  );

  testWidgets(
    'shows suspended when turn completion payload carries completed status inside turn',
    (tester) async {
      final resumedEvents = StreamController<SessionEvent>();
      final api = FakeDaemonApi(
        liveEventStreams: [resumedEvents.stream],
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: <WorkspaceRoot>[],
          sessions: [
            SessionSummary(
              id: 'sess_1',
              title: 'Completed turn',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'idle',
              workspacePath: '/tmp/workspace',
            ),
          ],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Completed turn',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/tmp/workspace',
          status: 'idle',
          hasMoreHistory: false,
          events: [],
        ),
      );

      await pumpApp(tester, api: api);
      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Completed turn'));
      await tester.pump();

      resumedEvents.add(
        const SessionEvent(
          id: 4,
          eventType: 'session.status.changed',
          payload: {
            'threadId': 'thread-1',
            'turn': {'status': 'completed'},
          },
        ),
      );
      await tester.pump();

      expect(
        find.descendant(
          of: find.byKey(const ValueKey('session-status-pill')),
          matching: find.text('suspended'),
        ),
        findsOneWidget,
      );

      await resumedEvents.close();
    },
  );

  testWidgets('heartbeat timeout forces session event stream reconnect', (
    tester,
  ) async {
    final silentEvents = StreamController<SessionEvent>();
    final lateEvents = StreamController<SessionEvent>();
    final api = FakeDaemonApi(
      liveEventStreams: [silentEvents.stream, lateEvents.stream],
      bootstrap: const MobileBootstrap(
        daemonVersion: '0.1.0',
        user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: <WorkspaceRoot>[],
        sessions: [
          SessionSummary(
            id: 'sess_1',
            title: 'Heartbeat timeout',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            status: 'running',
            workspacePath: '/tmp/workspace',
          ),
        ],
        voice: VoiceConfig(doubaoDirectAvailable: false),
      ),
      snapshot: const SessionSnapshot(
        id: 'sess_1',
        title: 'Heartbeat timeout',
        agentKind: 'codex',
        sourceKind: 'managed',
        runtimeSessionId: 'runtime_1',
        workspacePath: '/tmp/workspace',
        status: 'running',
        hasMoreHistory: false,
        events: [],
      ),
    );

    await pumpApp(tester, api: api);
    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Heartbeat timeout'));
    await tester.pump();

    await tester.pump(const Duration(seconds: 65));
    await tester.pump();

    expect(api.eventSubscriptions, [
      'sess_1:tok_workspace:0',
      'sess_1:tok_workspace:0',
    ]);

    await tester.pageBack();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets(
    'session heartbeat keeps the stream alive without rendering timeline events',
    (tester) async {
      final heartbeatEvents = StreamController<SessionEvent>();
      final api = FakeDaemonApi(
        liveEventStreams: [heartbeatEvents.stream],
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: <WorkspaceRoot>[],
          sessions: [
            SessionSummary(
              id: 'sess_1',
              title: 'Heartbeat keepalive',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/tmp/workspace',
            ),
          ],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Heartbeat keepalive',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/tmp/workspace',
          status: 'running',
          hasMoreHistory: false,
          events: [],
        ),
      );

      await pumpApp(tester, api: api);
      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Heartbeat keepalive'));
      await tester.pumpAndSettle();

      await tester.pump(const Duration(seconds: 30));
      heartbeatEvents.add(
        const SessionEvent(id: 0, eventType: 'session.heartbeat', payload: {}),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 35));
      await tester.pump();

      expect(api.eventSubscriptions, ['sess_1:tok_workspace:0']);
      expect(find.text('No session events yet'), findsOneWidget);

      await tester.pageBack();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    },
  );

  testWidgets(
    'attached runtime card opens details and can copy the runtime session id',
    (tester) async {
      final clipboardTexts = <String>[];
      final hapticCalls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboardTexts.add(
              (call.arguments as Map<Object?, Object?>)['text']! as String,
            );
          }
          if (call.method == 'HapticFeedback.vibrate') {
            hapticCalls.add(call.arguments as String? ?? 'vibrate');
          }
          return null;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
      });

      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: const MobileBootstrap(
            daemonVersion: '0.1.0',
            user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
            roots: <WorkspaceRoot>[],
            sessions: [
              SessionSummary(
                id: 'sess_1',
                title: 'Mobile migration',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'running',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: VoiceConfig(doubaoDirectAvailable: false),
          ),
          snapshot: const SessionSnapshot(
            id: 'sess_1',
            title: 'Mobile migration',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            workspacePath: '/home/jhz/projects/agent-dock',
            status: 'running',
            hasMoreHistory: false,
            events: [
              SessionEvent(
                id: 1,
                eventType: 'session.attached',
                payload: {'runtimeSessionId': 'thread-abc'},
              ),
            ],
          ),
        ),
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mobile migration'));
      await tester.pumpAndSettle();

      expect(find.text('thread-abc'), findsNothing);
      await tester.tap(find.text('Attached runtime'));
      await tester.pumpAndSettle();

      expect(find.text('Runtime session ID'), findsOneWidget);
      expect(find.text('thread-abc'), findsOneWidget);
      expect(find.text('Copy runtime session ID'), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);

      await tester.tap(find.text('Copy runtime session ID'));
      await tester.pumpAndSettle();

      expect(clipboardTexts, ['thread-abc']);
      expect(
        hapticCalls.where(
          (call) => call == 'HapticFeedbackType.selectionClick',
        ),
        hasLength(1),
      );
    },
  );

  testWidgets(
    'attached runtime expansion persists when older history is inserted',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: <WorkspaceRoot>[],
          sessions: [
            SessionSummary(
              id: 'sess_1',
              title: 'Mobile migration',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Mobile migration',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: true,
          events: [
            SessionEvent(
              id: 10,
              eventType: 'session.attached',
              payload: {'runtimeSessionId': 'thread-abc'},
            ),
          ],
        ),
        olderSnapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Mobile migration',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: [
            SessionEvent(
              id: 1,
              eventType: 'assistant.message',
              payload: {'text': 'older'},
            ),
          ],
        ),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mobile migration'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Attached runtime'));
      await tester.pumpAndSettle();
      expect(find.text('thread-abc'), findsOneWidget);

      await tester.drag(find.byType(ListView).first, const Offset(0, 1200));
      await tester.pumpAndSettle();

      expect(find.text('thread-abc'), findsOneWidget);
      expect(find.text('older'), findsOneWidget);
    },
  );

  testWidgets('shows session metadata from the top bar details menu', (
    tester,
  ) async {
    await pumpApp(
      tester,
      api: FakeDaemonApi(
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Metadata detail',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Metadata detail',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: [],
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Metadata detail'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Session details'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Session details').last);
    await tester.pumpAndSettle();

    expect(find.text('Agent kind'), findsOneWidget);
    expect(find.text('codex'), findsOneWidget);
    expect(find.text('Source kind'), findsOneWidget);
    expect(find.text('managed'), findsOneWidget);
    expect(find.text('Workspace path'), findsOneWidget);
    expect(find.text('/home/jhz/projects/agent-dock'), findsOneWidget);
    expect(find.text('Runtime session ID'), findsOneWidget);
    expect(find.text('runtime_1'), findsOneWidget);
    expect(find.text('Daemon URL host'), findsOneWidget);
    expect(find.text('daemon.example.com'), findsOneWidget);
    expect(find.text('Daemon host'), findsNothing);
  });

  testWidgets(
    'chat details sheet uses the visible derived session title when a session has no explicit title',
    (tester) async {
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: const MobileBootstrap(
            daemonVersion: '0.1.0',
            user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
            roots: <WorkspaceRoot>[],
            sessions: [
              SessionSummary(
                id: 'sess_untitled_details',
                title: null,
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: null,
                status: 'active',
                workspacePath: '/home/jhz/projects/mobile-app',
              ),
            ],
            voice: VoiceConfig(doubaoDirectAvailable: false),
          ),
          snapshot: const SessionSnapshot(
            id: 'sess_untitled_details',
            title: null,
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: null,
            workspacePath: '/home/jhz/projects/mobile-app',
            status: 'active',
            hasMoreHistory: false,
            events: [],
          ),
        ),
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('mobile-app'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Session details'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Session details').last);
      await tester.pumpAndSettle();

      expect(find.text('Title'), findsOneWidget);
      expect(find.text('mobile-app'), findsAtLeastNWidgets(1));
      expect(find.text('Untitled session'), findsNothing);
    },
  );

  testWidgets(
    'chat overflow menu picks up a runtime session id that arrives in the snapshot',
    (tester) async {
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: const MobileBootstrap(
            daemonVersion: '0.1.0',
            user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
            roots: <WorkspaceRoot>[],
            sessions: [
              SessionSummary(
                id: 'sess_snapshot_runtime',
                title: 'Snapshot runtime',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: null,
                status: 'active',
                workspacePath: '/home/jhz/projects/mobile-app',
              ),
            ],
            voice: VoiceConfig(doubaoDirectAvailable: false),
          ),
          snapshot: const SessionSnapshot(
            id: 'sess_snapshot_runtime',
            title: 'Snapshot runtime',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_from_snapshot',
            workspacePath: '/home/jhz/projects/mobile-app',
            status: 'active',
            hasMoreHistory: false,
            events: [],
          ),
        ),
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Snapshot runtime'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Session details'));
      await tester.pumpAndSettle();

      expect(find.text('Copy runtime session ID'), findsOneWidget);
    },
  );

  testWidgets(
    'chat top bar falls back to the workspace basename when the session has no explicit title',
    (tester) async {
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: const MobileBootstrap(
            daemonVersion: '0.1.0',
            user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
            roots: <WorkspaceRoot>[],
            sessions: [
              SessionSummary(
                id: 'sess_untitled_chat',
                title: null,
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: null,
                status: 'active',
                workspacePath: '/home/jhz/projects/mobile-app',
              ),
            ],
            voice: VoiceConfig(doubaoDirectAvailable: false),
          ),
          snapshot: const SessionSnapshot(
            id: 'sess_untitled_chat',
            title: null,
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: null,
            workspacePath: '/home/jhz/projects/mobile-app',
            status: 'active',
            hasMoreHistory: false,
            events: [],
          ),
        ),
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('mobile-app'));
      await tester.pumpAndSettle();

      expect(find.text('mobile-app'), findsOneWidget);
      expect(find.text('Chat'), findsNothing);
    },
  );

  testWidgets(
    'chat top bar falls back to the agent kind when title and workspace basename are unavailable',
    (tester) async {
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: const MobileBootstrap(
            daemonVersion: '0.1.0',
            user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
            roots: <WorkspaceRoot>[],
            sessions: [
              SessionSummary(
                id: 'sess_agent_fallback_chat',
                title: null,
                agentKind: 'claude',
                sourceKind: 'attached',
                runtimeSessionId: null,
                status: 'completed',
                workspacePath: '/',
              ),
            ],
            voice: VoiceConfig(doubaoDirectAvailable: false),
          ),
          snapshot: const SessionSnapshot(
            id: 'sess_agent_fallback_chat',
            title: null,
            agentKind: 'claude',
            sourceKind: 'attached',
            runtimeSessionId: null,
            workspacePath: '/',
            status: 'completed',
            hasMoreHistory: false,
            events: [],
          ),
        ),
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('claude').first);
      await tester.pumpAndSettle();

      expect(find.text('claude'), findsOneWidget);
      expect(find.text('Chat'), findsNothing);
    },
  );

  testWidgets(
    'deletes the current session from the detail page overflow menu',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: <WorkspaceRoot>[],
          sessions: [
            SessionSummary(
              id: 'sess_1',
              title: 'Mobile migration',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'idle',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Mobile migration',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: <SessionEvent>[],
        ),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mobile migration'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Session details'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete session'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete session'));
      await tester.pumpAndSettle();

      expect(api.deletedSessions, ['sess_1']);
      expect(find.text('Mobile migration'), findsNothing);
      expect(find.text('No sessions yet'), findsOneWidget);
    },
  );

  testWidgets(
    'keeps the current session detail visible when deleting the current session fails',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: <WorkspaceRoot>[],
          sessions: [
            SessionSummary(
              id: 'sess_1',
              title: 'Mobile migration',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'idle',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Mobile migration',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: <SessionEvent>[],
        ),
        deleteError: const DaemonApiException(
          statusCode: 500,
          code: 'DELETE_FAILED',
          message: 'Could not delete session',
        ),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mobile migration'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Session details'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete session'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete session'));
      await tester.pumpAndSettle();

      expect(api.deletedSessions, ['sess_1']);
      expect(
        find.widgetWithText(TextField, 'Message the agent'),
        findsOneWidget,
      );
      expect(find.byTooltip('Session details'), findsOneWidget);
      expect(find.text('Could not delete session'), findsOneWidget);
      expect(find.text('No sessions yet'), findsNothing);
    },
  );

  testWidgets(
    'copies session id workspace path and runtime session id from the details menu',
    (tester) async {
      final clipboardTexts = <String>[];
      final hapticCalls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboardTexts.add(
              (call.arguments as Map<Object?, Object?>)['text']! as String,
            );
          }
          if (call.method == 'HapticFeedback.vibrate') {
            hapticCalls.add(call.arguments as String? ?? 'vibrate');
          }
          return null;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
      });

      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: MobileBootstrap(
            daemonVersion: '0.1.0',
            user: const CurrentUser(
              id: 'usr_workspace',
              displayName: 'Workspace',
            ),
            roots: const <WorkspaceRoot>[],
            sessions: const [
              SessionSummary(
                id: 'sess_1',
                title: 'Copy detail',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'running',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: const VoiceConfig(doubaoDirectAvailable: false),
          ),
          snapshot: const SessionSnapshot(
            id: 'sess_1',
            title: 'Copy detail',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            workspacePath: '/home/jhz/projects/agent-dock',
            status: 'running',
            hasMoreHistory: false,
            events: [],
          ),
        ),
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy detail'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Session details'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy workspace path'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Session details'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy session ID'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Session details'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy runtime session ID'));
      await tester.pumpAndSettle();

      expect(
        clipboardTexts,
        containsAll(['sess_1', '/home/jhz/projects/agent-dock', 'runtime_1']),
      );
      expect(
        hapticCalls.where(
          (call) => call == 'HapticFeedbackType.selectionClick',
        ),
        hasLength(3),
      );
    },
  );

  testWidgets('long pressing an assistant message copies markdown text', (
    tester,
  ) async {
    final clipboardTexts = <String>[];
    final hapticCalls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardTexts.add(
            (call.arguments as Map<Object?, Object?>)['text']! as String,
          );
        }
        if (call.method == 'HapticFeedback.vibrate') {
          hapticCalls.add(call.arguments as String? ?? 'vibrate');
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    await pumpApp(
      tester,
      api: FakeDaemonApi(
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Copy assistant',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Copy assistant',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: [
            SessionEvent(
              id: 1,
              eventType: 'assistant.message',
              payload: {'text': '## Done\n\n- Copy this markdown'},
            ),
          ],
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy assistant'));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Done'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy assistant message'));
    await tester.pumpAndSettle();

    expect(clipboardTexts, ['## Done\n\n- Copy this markdown']);
    expect(find.text('Assistant message copied'), findsOneWidget);
    expect(hapticCalls, contains('HapticFeedbackType.selectionClick'));
  });

  testWidgets('renders assistant messages without an assistant title', (
    tester,
  ) async {
    await pumpApp(
      tester,
      api: FakeDaemonApi(
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Assistant direct',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Assistant direct',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: [
            SessionEvent(
              id: 1,
              eventType: 'assistant.message',
              payload: {'text': 'Direct assistant content'},
            ),
          ],
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Assistant direct'));
    await tester.pumpAndSettle();

    expect(find.text('Assistant'), findsNothing);
    expect(find.text('Direct assistant content'), findsOneWidget);
  });

  testWidgets('renders assistant markdown headings and lists', (tester) async {
    await pumpApp(
      tester,
      api: FakeDaemonApi(
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Assistant markdown',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Assistant markdown',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: [
            SessionEvent(
              id: 1,
              eventType: 'assistant.message',
              payload: {
                'text': '## Done\n\n- Render markdown\n- Keep readable spacing',
              },
            ),
          ],
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Assistant markdown'));
    await tester.pumpAndSettle();

    expect(find.text('Done'), findsOneWidget);
    expect(find.text('Render markdown'), findsOneWidget);
    expect(find.text('Keep readable spacing'), findsOneWidget);
    expect(find.textContaining('## Done'), findsNothing);
  });

  testWidgets(
    'assistant markdown block upgrades crossfade only the affected block',
    (tester) async {
      final liveEvents = StreamController<SessionEvent>();
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          liveEvents: liveEvents.stream,
          bootstrap: MobileBootstrap(
            daemonVersion: '0.1.0',
            user: const CurrentUser(
              id: 'usr_workspace',
              displayName: 'Workspace',
            ),
            roots: const <WorkspaceRoot>[],
            sessions: const [
              SessionSummary(
                id: 'sess_1',
                title: 'Markdown upgrade fade',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'running',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: const VoiceConfig(doubaoDirectAvailable: false),
          ),
          snapshot: const SessionSnapshot(
            id: 'sess_1',
            title: 'Markdown upgrade fade',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            workspacePath: '/home/jhz/projects/agent-dock',
            status: 'running',
            hasMoreHistory: false,
            events: [
              SessionEvent(
                id: 1,
                eventType: 'assistant.message',
                payload: {'text': '##'},
              ),
            ],
          ),
        ),
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Markdown upgrade fade'));
      await tester.pumpAndSettle();

      expect(find.text('##'), findsOneWidget);

      liveEvents.add(
        const SessionEvent(
          id: 2,
          eventType: 'assistant.message',
          payload: {'text': ' drafting plan'},
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));

      final blockFadeFinder = find.byKey(
        const ValueKey(
          'assistant-markdown-block-fade-0-'
          'assistant-markdown-block-0-heading:2:drafting plan',
        ),
      );
      expect(blockFadeFinder, findsOneWidget);
      expect(
        tester.widget<FadeTransition>(blockFadeFinder).opacity.value,
        lessThan(1),
      );

      final assistantCardFadeFinder = find.byKey(
        const ValueKey('assistant-message-card-fade'),
      );
      expect(assistantCardFadeFinder, findsNothing);

      await tester.pump(const Duration(milliseconds: 180));

      expect(tester.widget<FadeTransition>(blockFadeFinder).opacity.value, 1);
      expect(find.text('drafting plan'), findsOneWidget);
      expect(find.text('##'), findsNothing);

      await liveEvents.close();
    },
  );

  testWidgets('renders assistant fenced code blocks in a dedicated scroller', (
    tester,
  ) async {
    await pumpApp(
      tester,
      api: FakeDaemonApi(
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Assistant code',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Assistant code',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: [
            SessionEvent(
              id: 1,
              eventType: 'assistant.message',
              payload: {'text': '```sh\nnpm test\nflutter test\n```'},
            ),
          ],
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Assistant code'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('assistant-code-block')), findsOneWidget);
    expect(find.text('npm test'), findsOneWidget);
  });

  testWidgets(
    'assistant streaming keeps a stable code block area once fenced code is detected',
    (tester) async {
      final liveEvents = StreamController<SessionEvent>();
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          liveEvents: liveEvents.stream,
          bootstrap: MobileBootstrap(
            daemonVersion: '0.1.0',
            user: const CurrentUser(
              id: 'usr_workspace',
              displayName: 'Workspace',
            ),
            roots: const <WorkspaceRoot>[],
            sessions: const [
              SessionSummary(
                id: 'sess_1',
                title: 'Assistant code streaming',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'running',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: const VoiceConfig(doubaoDirectAvailable: false),
          ),
          snapshot: const SessionSnapshot(
            id: 'sess_1',
            title: 'Assistant code streaming',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            workspacePath: '/home/jhz/projects/agent-dock',
            status: 'running',
            hasMoreHistory: false,
            events: [
              SessionEvent(
                id: 1,
                eventType: 'assistant.message',
                payload: {'text': '```sh\nnpm test'},
              ),
            ],
          ),
        ),
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Assistant code streaming'));
      await tester.pumpAndSettle();

      final codeBlock = find.byKey(const ValueKey('assistant-code-block'));
      expect(codeBlock, findsOneWidget);
      expect(find.text('npm test'), findsOneWidget);

      final initialCodeBlockWidget = tester.widget<Container>(codeBlock);

      liveEvents.add(
        const SessionEvent(
          id: 2,
          eventType: 'assistant.message',
          payload: {'text': '\nflutter test\n```'},
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(codeBlock, findsOneWidget);
      expect(find.text('flutter test'), findsOneWidget);
      expect(find.text('```sh'), findsNothing);
      expect(find.text('```'), findsNothing);

      final updatedCodeBlockWidget = tester.widget<Container>(codeBlock);
      expect(updatedCodeBlockWidget.key, initialCodeBlockWidget.key);

      await liveEvents.close();
    },
  );

  testWidgets('caps assistant code block text scaling for readability', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
    tester.platformDispatcher.textScaleFactorTestValue = 2.4;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await pumpSessionDetailForTest(
      tester,
      api: FakeDaemonApi(
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Assistant code scale',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: [
            SessionEvent(
              id: 1,
              eventType: 'assistant.message',
              payload: {'text': '```sh\nnpm test\n```'},
            ),
          ],
        ),
      ),
      session: const SessionSummary(
        id: 'sess_1',
        title: 'Assistant code scale',
        agentKind: 'codex',
        sourceKind: 'managed',
        runtimeSessionId: 'runtime_1',
        status: 'running',
        workspacePath: '/home/jhz/projects/agent-dock',
      ),
    );
    await tester.pumpAndSettle();

    final codeText = tester.widget<Text>(find.text('npm test'));
    final codeScaler = codeText.textScaler;
    expect(codeScaler, isNotNull);
    expect(codeScaler!.scale(14), lessThanOrEqualTo(17.5));
  });

  testWidgets('renders assistant links with external-link affordance', (
    tester,
  ) async {
    final openedLinks = <Uri>[];
    await pumpApp(
      tester,
      api: FakeDaemonApi(
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Assistant link',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Assistant link',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: [
            SessionEvent(
              id: 1,
              eventType: 'assistant.message',
              payload: {
                'text':
                    'Read [the docs](https://example.com/docs) before proceeding.',
              },
            ),
          ],
        ),
      ),
      openExternalLink: (uri) async {
        openedLinks.add(uri);
        return true;
      },
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Assistant link'));
    await tester.pumpAndSettle();

    expect(find.text('the docs'), findsOneWidget);
    expect(
      find.byKey(
        const ValueKey('assistant-link-icon-https://example.com/docs'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('the docs'));
    await tester.pumpAndSettle();

    expect(openedLinks, [Uri.parse('https://example.com/docs')]);
  });

  testWidgets(
    'uses the latest non-empty session status event for the top bar pill',
    (tester) async {
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: MobileBootstrap(
            daemonVersion: '0.1.0',
            user: const CurrentUser(
              id: 'usr_workspace',
              displayName: 'Workspace',
            ),
            roots: const <WorkspaceRoot>[],
            sessions: const [
              SessionSummary(
                id: 'sess_1',
                title: 'Status precedence',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'running',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: const VoiceConfig(doubaoDirectAvailable: false),
          ),
          snapshot: const SessionSnapshot(
            id: 'sess_1',
            title: 'Status precedence',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            workspacePath: '/home/jhz/projects/agent-dock',
            status: 'running',
            hasMoreHistory: false,
            events: [
              SessionEvent(
                id: 1,
                eventType: 'session.status.changed',
                payload: {'status': 'active'},
              ),
              SessionEvent(
                id: 2,
                eventType: 'session.status.changed',
                payload: {'status': ''},
              ),
            ],
          ),
        ),
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Status precedence'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('session-status-pill')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('session-status-pill')),
          matching: find.text('active'),
        ),
        findsOneWidget,
      );
      final activeDot = tester.widget<Container>(
        find.byKey(const ValueKey('session-status-pill-dot')),
      );
      final activeDotDecoration = activeDot.decoration! as BoxDecoration;
      expect(activeDotDecoration.color, const Color(0xFF43D17A));
      final activeDotOpacity = tester.widget<Opacity>(
        find.byKey(const ValueKey('session-status-pill-dot-opacity')),
      );
      expect(activeDotOpacity.opacity, 1);

      await tester.pump(const Duration(milliseconds: 400));

      final midActiveDotOpacity = tester.widget<Opacity>(
        find.byKey(const ValueKey('session-status-pill-dot-opacity')),
      );
      await tester.pump(const Duration(milliseconds: 400));

      final lateActiveDotOpacity = tester.widget<Opacity>(
        find.byKey(const ValueKey('session-status-pill-dot-opacity')),
      );
      expect(<double>[
        midActiveDotOpacity.opacity,
        lateActiveDotOpacity.opacity,
      ], contains(isNot(activeDotOpacity.opacity)));
    },
  );

  testWidgets(
    'shows the latest turn error message in the top bar pill when the current session status is not more specific',
    (tester) async {
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: MobileBootstrap(
            daemonVersion: '0.1.0',
            user: const CurrentUser(
              id: 'usr_workspace',
              displayName: 'Workspace',
            ),
            roots: const <WorkspaceRoot>[],
            sessions: const [
              SessionSummary(
                id: 'sess_1',
                title: 'Turn error status',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'failed',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: const VoiceConfig(doubaoDirectAvailable: false),
          ),
          snapshot: const SessionSnapshot(
            id: 'sess_1',
            title: 'Turn error status',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            workspacePath: '/home/jhz/projects/agent-dock',
            status: 'failed',
            hasMoreHistory: false,
            events: [
              SessionEvent(
                id: 1,
                eventType: 'session.status.changed',
                payload: {
                  'status': {'type': 'systemError'},
                },
              ),
              SessionEvent(
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
            ],
          ),
        ),
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Turn error status'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('session-status-pill')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('session-status-pill')),
          matching: find.text(
            'Selected model is at capacity. Please try a different model.',
          ),
        ),
        findsOneWidget,
      );
      final errorDot = tester.widget<Container>(
        find.byKey(const ValueKey('session-status-pill-dot')),
      );
      final errorDotDecoration = errorDot.decoration! as BoxDecoration;
      expect(errorDotDecoration.color, const Color(0xFFF0B84A));
    },
  );

  testWidgets(
    'prefers the current session status over older timeline error text in the top bar pill',
    (tester) async {
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: MobileBootstrap(
            daemonVersion: '0.1.0',
            user: const CurrentUser(
              id: 'usr_workspace',
              displayName: 'Workspace',
            ),
            roots: const <WorkspaceRoot>[],
            sessions: const [
              SessionSummary(
                id: 'sess_1',
                title: 'Recovered session',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'idle',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: const VoiceConfig(doubaoDirectAvailable: false),
          ),
          snapshot: const SessionSnapshot(
            id: 'sess_1',
            title: 'Recovered session',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            workspacePath: '/home/jhz/projects/agent-dock',
            status: 'idle',
            hasMoreHistory: false,
            events: [
              SessionEvent(
                id: 1,
                eventType: 'session.status.changed',
                payload: {
                  'turn': {
                    'status': 'failed',
                    'error': {
                      'message':
                          'Selected model is at capacity. Please try a different model.',
                    },
                  },
                },
              ),
            ],
          ),
        ),
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Recovered session'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('session-status-pill')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('session-status-pill')),
          matching: find.text('idle'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'shows an assistant typing indicator when assistant text is latest in a running session',
    (tester) async {
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: MobileBootstrap(
            daemonVersion: '0.1.0',
            user: const CurrentUser(
              id: 'usr_workspace',
              displayName: 'Workspace',
            ),
            roots: const <WorkspaceRoot>[],
            sessions: const [
              SessionSummary(
                id: 'sess_1',
                title: 'Assistant stream',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'running',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: const VoiceConfig(doubaoDirectAvailable: false),
          ),
          snapshot: const SessionSnapshot(
            id: 'sess_1',
            title: 'Assistant stream',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            workspacePath: '/home/jhz/projects/agent-dock',
            status: 'running',
            hasMoreHistory: false,
            events: [
              SessionEvent(
                id: 1,
                eventType: 'assistant.message',
                payload: {'text': 'Streaming reply'},
              ),
            ],
          ),
        ),
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Assistant stream'));
      await tester.pumpAndSettle();

      expect(find.text('Streaming reply'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('assistant-typing-indicator')),
        findsOneWidget,
      );
    },
  );

  testWidgets('assistant typing indicator blinks at a calm pace', (
    tester,
  ) async {
    await pumpApp(
      tester,
      api: FakeDaemonApi(
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Assistant blink',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Assistant blink',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: [
            SessionEvent(
              id: 1,
              eventType: 'assistant.message',
              payload: {'text': 'Streaming reply'},
            ),
          ],
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Assistant blink'));
    await tester.pumpAndSettle();

    final indicator = find.byKey(const ValueKey('assistant-typing-indicator'));
    expect(indicator, findsOneWidget);
    final opacityFinder = find.ancestor(
      of: indicator,
      matching: find.byType(Opacity),
    );
    final initialOpacity = tester.widget<Opacity>(opacityFinder).opacity;

    await tester.pump(const Duration(milliseconds: 650));

    final dimmedOpacity = tester.widget<Opacity>(opacityFinder).opacity;
    expect(dimmedOpacity, lessThan(initialOpacity));

    await tester.pump(const Duration(milliseconds: 650));

    final restoredOpacity = tester.widget<Opacity>(opacityFinder).opacity;
    expect(restoredOpacity, initialOpacity);
  });

  testWidgets(
    'assistant typing indicator pauses while the app is backgrounded',
    (tester) async {
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: MobileBootstrap(
            daemonVersion: '0.1.0',
            user: const CurrentUser(
              id: 'usr_workspace',
              displayName: 'Workspace',
            ),
            roots: const <WorkspaceRoot>[],
            sessions: const [
              SessionSummary(
                id: 'sess_1',
                title: 'Assistant background pause',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'running',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: const VoiceConfig(doubaoDirectAvailable: false),
          ),
          snapshot: const SessionSnapshot(
            id: 'sess_1',
            title: 'Assistant background pause',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            workspacePath: '/home/jhz/projects/agent-dock',
            status: 'running',
            hasMoreHistory: false,
            events: [
              SessionEvent(
                id: 1,
                eventType: 'assistant.message',
                payload: {'text': 'Streaming reply'},
              ),
            ],
          ),
        ),
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Assistant background pause'));
      await tester.pumpAndSettle();

      final indicator = find.byKey(
        const ValueKey('assistant-typing-indicator'),
      );
      expect(indicator, findsOneWidget);
      final opacityFinder = find.ancestor(
        of: indicator,
        matching: find.byType(Opacity),
      );

      await tester.pump(const Duration(milliseconds: 650));
      final dimmedOpacity = tester.widget<Opacity>(opacityFinder).opacity;
      expect(dimmedOpacity, lessThan(1));

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();

      final pausedOpacity = tester.widget<Opacity>(opacityFinder).opacity;

      await tester.pump(const Duration(milliseconds: 700));

      final stillPausedOpacity = tester.widget<Opacity>(opacityFinder).opacity;
      expect(stillPausedOpacity, pausedOpacity);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 650));

      final resumedOpacity = tester.widget<Opacity>(opacityFinder).opacity;
      expect(resumedOpacity, isNot(stillPausedOpacity));
    },
  );

  testWidgets(
    'hides the assistant typing indicator when the session is completed',
    (tester) async {
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: MobileBootstrap(
            daemonVersion: '0.1.0',
            user: const CurrentUser(
              id: 'usr_workspace',
              displayName: 'Workspace',
            ),
            roots: const <WorkspaceRoot>[],
            sessions: const [
              SessionSummary(
                id: 'sess_1',
                title: 'Assistant completed',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'completed',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: const VoiceConfig(doubaoDirectAvailable: false),
          ),
          snapshot: const SessionSnapshot(
            id: 'sess_1',
            title: 'Assistant completed',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            workspacePath: '/home/jhz/projects/agent-dock',
            status: 'completed',
            hasMoreHistory: false,
            events: [
              SessionEvent(
                id: 1,
                eventType: 'assistant.message',
                payload: {'text': 'Final reply'},
              ),
              SessionEvent(
                id: 2,
                eventType: 'session.status.changed',
                payload: {'status': 'completed'},
              ),
            ],
          ),
        ),
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Assistant completed'));
      await tester.pumpAndSettle();

      expect(find.text('Final reply'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('assistant-typing-indicator')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'hides the assistant typing indicator once a non-assistant event follows',
    (tester) async {
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: MobileBootstrap(
            daemonVersion: '0.1.0',
            user: const CurrentUser(
              id: 'usr_workspace',
              displayName: 'Workspace',
            ),
            roots: const <WorkspaceRoot>[],
            sessions: const [
              SessionSummary(
                id: 'sess_1',
                title: 'Assistant followed',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'running',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: const VoiceConfig(doubaoDirectAvailable: false),
          ),
          snapshot: const SessionSnapshot(
            id: 'sess_1',
            title: 'Assistant followed',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            workspacePath: '/home/jhz/projects/agent-dock',
            status: 'running',
            hasMoreHistory: false,
            events: [
              SessionEvent(
                id: 1,
                eventType: 'assistant.message',
                payload: {'text': 'Reply before tool'},
              ),
              SessionEvent(
                id: 2,
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
            ],
          ),
        ),
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Assistant followed'));
      await tester.pumpAndSettle();

      expect(find.text('Reply before tool'), findsOneWidget);
      expect(find.text('npm test'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('assistant-typing-indicator')),
        findsNothing,
      );
    },
  );

  testWidgets('timeline cards expose concise semantic labels', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.binding.setSurfaceSize(const Size(900, 1400));
      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
      });

      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: MobileBootstrap(
            daemonVersion: '0.1.0',
            user: const CurrentUser(
              id: 'usr_workspace',
              displayName: 'Workspace',
            ),
            roots: const <WorkspaceRoot>[],
            sessions: const [
              SessionSummary(
                id: 'sess_1',
                title: 'Accessible timeline',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'running',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: const VoiceConfig(doubaoDirectAvailable: false),
          ),
          snapshot: const SessionSnapshot(
            id: 'sess_1',
            title: 'Accessible timeline',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            workspacePath: '/home/jhz/projects/agent-dock',
            status: 'running',
            hasMoreHistory: false,
            events: [
              SessionEvent(
                id: 1,
                eventType: 'user.message',
                payload: {'text': 'hello mobile'},
              ),
              SessionEvent(
                id: 2,
                eventType: 'assistant.message',
                payload: {'text': 'hello back'},
              ),
              SessionEvent(
                id: 3,
                eventType: 'assistant.thinking.delta',
                payload: {'text': 'checking the next step'},
              ),
              SessionEvent(
                id: 4,
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
              SessionEvent(
                id: 5,
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
            ],
          ),
        ),
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Accessible timeline'));
      await tester.pumpAndSettle();

      expect(find.bySemanticsLabel('User message'), findsOneWidget);
      expect(find.bySemanticsLabel('Assistant message'), findsOneWidget);
      expect(find.bySemanticsLabel('Reasoning card'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Tool call: npm test, completed'),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('File change: Edited src/app.ts, completed'),
        findsOneWidget,
      );
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('renders user message image attachments and opens preview', (
    tester,
  ) async {
    await pumpApp(
      tester,
      api: FakeDaemonApi(
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'User images',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'User images',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: [
            SessionEvent(
              id: 1,
              eventType: 'user.message',
              payload: {
                'text': 'see the screenshot',
                'imagePaths': ['/tmp/attachments/sess_1/screenshot.png'],
              },
            ),
          ],
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('User images'));
    await tester.pumpAndSettle();

    expect(find.text('see the screenshot'), findsOneWidget);
    await tester.tap(
      find.byKey(
        const ValueKey(
          'user-message-image-/tmp/attachments/sess_1/screenshot.png',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Image preview'), findsOneWidget);
  });

  testWidgets('long pressing a user message copies its text', (tester) async {
    final clipboardTexts = <String>[];
    final hapticCalls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardTexts.add(
            (call.arguments as Map<Object?, Object?>)['text']! as String,
          );
        }
        if (call.method == 'HapticFeedback.vibrate') {
          hapticCalls.add(call.arguments as String? ?? 'vibrate');
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    await pumpApp(
      tester,
      api: FakeDaemonApi(
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'User copy',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'User copy',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: [
            SessionEvent(
              id: 1,
              eventType: 'user.message',
              payload: {'text': 'copy this prompt'},
            ),
          ],
        ),
      ),
      shareAttachments: (_, _) async {},
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('User copy'));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('copy this prompt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy message text'));
    await tester.pumpAndSettle();

    expect(clipboardTexts, ['copy this prompt']);
    expect(find.text('Message text copied'), findsOneWidget);
    expect(hapticCalls, contains('HapticFeedbackType.selectionClick'));
  });

  testWidgets('long pressing a user image message exposes share image action', (
    tester,
  ) async {
    final sharedPaths = <List<String>>[];
    final hapticCalls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'HapticFeedback.vibrate') {
          hapticCalls.add(call.arguments as String? ?? 'vibrate');
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
    await pumpApp(
      tester,
      api: FakeDaemonApi(
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'User share',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'User share',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: [
            SessionEvent(
              id: 1,
              eventType: 'user.message',
              payload: {
                'text': 'see the screenshot',
                'imagePaths': ['/tmp/attachments/sess_1/screenshot.png'],
              },
            ),
          ],
        ),
      ),
      shareAttachments: (paths, _) async {
        sharedPaths.add(paths);
      },
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('User share'));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('see the screenshot'));
    await tester.pumpAndSettle();

    expect(find.text('Copy message text'), findsOneWidget);
    expect(find.text('Share image'), findsOneWidget);

    await tester.tap(find.text('Share image'));
    await tester.pumpAndSettle();

    expect(sharedPaths, [
      ['/tmp/attachments/sess_1/screenshot.png'],
    ]);
    expect(find.text('Image shared'), findsOneWidget);
    expect(hapticCalls, contains('HapticFeedbackType.selectionClick'));
  });

  testWidgets('renders reasoning collapsed by default and expands on tap', (
    tester,
  ) async {
    const reasoningText =
        'plan first and inspect the daemon timeline before applying the final '
        'migration changes so the mobile reader stays coherent';

    await pumpApp(
      tester,
      api: FakeDaemonApi(
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Reasoning detail',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Reasoning detail',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: [
            SessionEvent(
              id: 1,
              eventType: 'assistant.thinking.delta',
              payload: {'text': reasoningText},
            ),
          ],
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reasoning detail'));
    await tester.pumpAndSettle();

    expect(find.text('Reasoning'), findsOneWidget);
    expect(
      find.text(
        'plan first and inspect the daemon timeline before applying the final mig...',
      ),
      findsOneWidget,
    );
    expect(find.text(reasoningText), findsNothing);

    await tester.tap(find.text('Reasoning'));
    await tester.pumpAndSettle();

    expect(find.text(reasoningText), findsOneWidget);
  });

  testWidgets('constrains long reasoning expansions with internal scrolling', (
    tester,
  ) async {
    final reasoningText = List<String>.generate(
      40,
      (index) => 'reasoning line ${index + 1}',
    ).join('\n');

    await pumpApp(
      tester,
      api: FakeDaemonApi(
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Long reasoning',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: SessionSnapshot(
          id: 'sess_1',
          title: 'Long reasoning',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: [
            SessionEvent(
              id: 1,
              eventType: 'assistant.thinking.delta',
              payload: {'text': reasoningText},
            ),
          ],
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Long reasoning'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Reasoning'));
    await tester.pumpAndSettle();

    expect(find.text(reasoningText), findsOneWidget);
    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(
      tester.getSize(find.byType(SingleChildScrollView)).height,
      lessThanOrEqualTo(220),
    );
  });

  testWidgets(
    'shows an active reasoning indicator only for the latest unresolved reasoning item',
    (tester) async {
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: MobileBootstrap(
            daemonVersion: '0.1.0',
            user: const CurrentUser(
              id: 'usr_workspace',
              displayName: 'Workspace',
            ),
            roots: const <WorkspaceRoot>[],
            sessions: const [
              SessionSummary(
                id: 'sess_1',
                title: 'Reasoning active',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'running',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: const VoiceConfig(doubaoDirectAvailable: false),
          ),
          snapshot: const SessionSnapshot(
            id: 'sess_1',
            title: 'Reasoning active',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            workspacePath: '/home/jhz/projects/agent-dock',
            status: 'running',
            hasMoreHistory: false,
            events: [
              SessionEvent(
                id: 1,
                eventType: 'assistant.thinking.delta',
                payload: {'text': 'still thinking'},
              ),
            ],
          ),
        ),
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reasoning active'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('reasoning-active-indicator')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'pulses the collapsed reasoning indicator while reasoning is still active',
    (tester) async {
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: MobileBootstrap(
            daemonVersion: '0.1.0',
            user: const CurrentUser(
              id: 'usr_workspace',
              displayName: 'Workspace',
            ),
            roots: const <WorkspaceRoot>[],
            sessions: const [
              SessionSummary(
                id: 'sess_1',
                title: 'Reasoning pulse',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'running',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: const VoiceConfig(doubaoDirectAvailable: false),
          ),
          snapshot: const SessionSnapshot(
            id: 'sess_1',
            title: 'Reasoning pulse',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            workspacePath: '/home/jhz/projects/agent-dock',
            status: 'running',
            hasMoreHistory: false,
            events: [
              SessionEvent(
                id: 1,
                eventType: 'assistant.thinking.delta',
                payload: {'text': 'still thinking'},
              ),
            ],
          ),
        ),
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reasoning pulse'));
      await tester.pumpAndSettle();

      final opacityFinder = find.byKey(
        const ValueKey('reasoning-active-indicator-opacity'),
      );
      final indicatorFinder = find.descendant(
        of: opacityFinder,
        matching: find.byKey(const ValueKey('reasoning-active-indicator')),
      );
      expect(opacityFinder, findsOneWidget);
      expect(indicatorFinder, findsOneWidget);

      final initialOpacity = tester.widget<Opacity>(opacityFinder).opacity;
      await tester.pump(const Duration(milliseconds: 700));
      final pulsedOpacity = tester.widget<Opacity>(opacityFinder).opacity;

      expect(initialOpacity, 1);
      expect(pulsedOpacity, 0.24);
    },
  );

  testWidgets(
    'collapsed reasoning preview crossfades when streaming text substantially changes it',
    (tester) async {
      final liveEvents = StreamController<SessionEvent>();
      final api = FakeDaemonApi(
        liveEvents: liveEvents.stream,
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Reasoning preview fade',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Reasoning preview fade',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: [
            SessionEvent(
              id: 1,
              eventType: 'assistant.thinking.delta',
              payload: {'text': 'initial plan draft'},
            ),
          ],
        ),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reasoning preview fade'));
      await tester.pumpAndSettle();

      final cardFinder = find.byKey(const ValueKey('timeline-item-thinking:1'));
      expect(cardFinder, findsOneWidget);
      expect(find.text('initial plan draft'), findsOneWidget);

      liveEvents.add(
        const SessionEvent(
          id: 2,
          eventType: 'assistant.thinking.delta',
          payload: {'text': 'initial plan draft with more concrete steps'},
        ),
      );
      await tester.pump();
      await tester.pump();

      final fadeFinder = find.descendant(
        of: cardFinder,
        matching: find.byWidgetPredicate((widget) {
          if (widget is! FadeTransition) {
            return false;
          }
          if (widget.key is! ValueKey<String>) {
            return false;
          }
          final key = (widget.key as ValueKey<String>).value;
          if (!key.startsWith('reasoning-preview-fade-')) {
            return false;
          }
          final child = widget.child;
          return child is Text &&
              (child.data?.contains('with more concrete steps') ?? false);
        }),
      );
      expect(fadeFinder, findsOneWidget);
      expect(
        tester.widget<FadeTransition>(fadeFinder).opacity.value,
        lessThan(1),
      );
      expect(find.textContaining('with more concrete steps'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 250));
      expect(tester.widget<FadeTransition>(fadeFinder).opacity.value, 1);

      await liveEvents.close();
    },
  );

  testWidgets(
    'collapsed reasoning preview stays stable for small streaming extensions',
    (tester) async {
      final liveEvents = StreamController<SessionEvent>();
      final api = FakeDaemonApi(
        liveEvents: liveEvents.stream,
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Reasoning preview stable',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Reasoning preview stable',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: [
            SessionEvent(
              id: 1,
              eventType: 'assistant.thinking.delta',
              payload: {'text': 'drafting plan'},
            ),
          ],
        ),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reasoning preview stable'));
      await tester.pumpAndSettle();

      final cardFinder = find.byKey(const ValueKey('timeline-item-thinking:1'));
      expect(cardFinder, findsOneWidget);
      expect(find.text('drafting plan'), findsOneWidget);

      liveEvents.add(
        const SessionEvent(
          id: 2,
          eventType: 'assistant.thinking.delta',
          payload: {'text': 'drafting plan.'},
        ),
      );
      await tester.pump();
      await tester.pump();

      final fadeFinder = find.descendant(
        of: cardFinder,
        matching: find.byWidgetPredicate((widget) {
          if (widget is! FadeTransition) {
            return false;
          }
          if (widget.key is! ValueKey<String>) {
            return false;
          }
          final key = (widget.key as ValueKey<String>).value;
          if (!key.startsWith('reasoning-preview-fade-')) {
            return false;
          }
          return key == 'reasoning-preview-fade-drafting plan';
        }),
      );
      expect(fadeFinder, findsOneWidget);
      expect(tester.widget<FadeTransition>(fadeFinder).opacity.value, 1);
      expect(find.textContaining('drafting plan.'), findsOneWidget);

      await liveEvents.close();
    },
  );

  testWidgets(
    'hides the active reasoning indicator once assistant output follows',
    (tester) async {
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: MobileBootstrap(
            daemonVersion: '0.1.0',
            user: const CurrentUser(
              id: 'usr_workspace',
              displayName: 'Workspace',
            ),
            roots: const <WorkspaceRoot>[],
            sessions: const [
              SessionSummary(
                id: 'sess_1',
                title: 'Reasoning resolved',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'running',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: const VoiceConfig(doubaoDirectAvailable: false),
          ),
          snapshot: const SessionSnapshot(
            id: 'sess_1',
            title: 'Reasoning resolved',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            workspacePath: '/home/jhz/projects/agent-dock',
            status: 'running',
            hasMoreHistory: false,
            events: [
              SessionEvent(
                id: 1,
                eventType: 'assistant.thinking.delta',
                payload: {'text': 'plan first'},
              ),
              SessionEvent(
                id: 2,
                eventType: 'assistant.message',
                payload: {'text': 'done'},
              ),
            ],
          ),
        ),
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reasoning resolved'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('reasoning-active-indicator')),
        findsNothing,
      );
    },
  );

  testWidgets('renders undetailed tool lifecycle events as an activity card', (
    tester,
  ) async {
    await pumpApp(
      tester,
      api: FakeDaemonApi(
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Mobile migration',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'idle',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Mobile migration',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: [
            SessionEvent(
              id: 1,
              eventType: 'tool.call.completed',
              payload: {
                'item': {'id': 'tool-1', 'type': 'commandExecution'},
              },
            ),
            SessionEvent(
              id: 2,
              eventType: 'tool.call.completed',
              payload: {
                'item': {'id': 'tool-2', 'type': 'commandExecution'},
              },
            ),
          ],
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mobile migration'));
    await tester.pumpAndSettle();

    expect(find.text('Activity'), findsNothing);
    expect(find.text('2 events · commandExecution completed'), findsOneWidget);
    expect(find.text('commandExecution completed '), findsNothing);
    expect(
      find.byKey(
        const ValueKey(
          'activity-summary-count-value-commandExecution-completed-2',
        ),
      ),
      findsNothing,
    );
    expect(find.text('tool.call.completed'), findsNothing);
    expect(
      find.byKey(const ValueKey('activity-summary-active-indicator')),
      findsNothing,
    );

    await tester.tap(find.text('2 events · commandExecution completed'));
    await tester.pumpAndSettle();

    expect(find.text('Activity'), findsOneWidget);
    expect(find.text('commandExecution completed '), findsOneWidget);
    expect(
      find.byKey(
        const ValueKey(
          'activity-summary-count-value-commandExecution-completed-2',
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'activity cards show an active indicator while grouped started items are present',
    (tester) async {
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: MobileBootstrap(
            daemonVersion: '0.1.0',
            user: const CurrentUser(
              id: 'usr_workspace',
              displayName: 'Workspace',
            ),
            roots: const <WorkspaceRoot>[],
            sessions: const [
              SessionSummary(
                id: 'sess_1',
                title: 'Tool activity',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'running',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: const VoiceConfig(doubaoDirectAvailable: false),
          ),
          snapshot: const SessionSnapshot(
            id: 'sess_1',
            title: 'Tool activity',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            workspacePath: '/home/jhz/projects/agent-dock',
            status: 'running',
            hasMoreHistory: false,
            events: [
              SessionEvent(
                id: 1,
                eventType: 'tool.call.started',
                payload: {
                  'item': {'id': 'tool-1', 'type': 'commandExecution'},
                },
              ),
              SessionEvent(
                id: 2,
                eventType: 'tool.call.completed',
                payload: {
                  'item': {'id': 'tool-2', 'type': 'commandExecution'},
                },
              ),
            ],
          ),
        ),
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tool activity'));
      await tester.pumpAndSettle();

      expect(find.text('Activity'), findsNothing);
      expect(find.text('2 events · commandExecution started'), findsOneWidget);
      expect(find.text('commandExecution started '), findsNothing);
      expect(find.text('commandExecution completed '), findsNothing);
      await tester.tap(find.text('2 events · commandExecution started'));
      await tester.pumpAndSettle();

      expect(find.text('Activity'), findsOneWidget);
      expect(find.text('commandExecution started '), findsOneWidget);
      expect(find.text('commandExecution completed '), findsOneWidget);
      expect(
        find.byKey(
          const ValueKey(
            'activity-summary-count-value-commandExecution-started-1',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey(
            'activity-summary-count-value-commandExecution-completed-1',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('activity-summary-active-indicator')),
        findsOneWidget,
      );
      final opacityFinder = find.byKey(
        const ValueKey('activity-summary-active-indicator-opacity'),
      );
      final initialOpacity = tester.widget<Opacity>(opacityFinder).opacity;
      expect(initialOpacity, anyOf(1, 0.24));

      await tester.pump(const Duration(milliseconds: 700));

      expect(
        tester.widget<Opacity>(opacityFinder).opacity,
        isNot(initialOpacity),
      );
    },
  );

  testWidgets('activity count changes crossfade within the existing card', (
    tester,
  ) async {
    final liveEvents = StreamController<SessionEvent>();
    final api = FakeDaemonApi(
      liveEvents: liveEvents.stream,
      bootstrap: MobileBootstrap(
        daemonVersion: '0.1.0',
        user: const CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: const <WorkspaceRoot>[],
        sessions: const [
          SessionSummary(
            id: 'sess_1',
            title: 'Activity count transition',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            status: 'running',
            workspacePath: '/home/jhz/projects/agent-dock',
          ),
        ],
        voice: const VoiceConfig(doubaoDirectAvailable: false),
      ),
      snapshot: const SessionSnapshot(
        id: 'sess_1',
        title: 'Activity count transition',
        agentKind: 'codex',
        sourceKind: 'managed',
        runtimeSessionId: 'runtime_1',
        workspacePath: '/home/jhz/projects/agent-dock',
        status: 'running',
        hasMoreHistory: false,
        events: [
          SessionEvent(
            id: 1,
            eventType: 'tool.call.completed',
            payload: {
              'item': {'id': 'tool-1', 'type': 'commandExecution'},
            },
          ),
        ],
      ),
    );
    await pumpApp(tester, api: api);

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Activity count transition'));
    await tester.pumpAndSettle();

    expect(find.text('1 event · commandExecution completed'), findsOneWidget);
    expect(find.text('commandExecution completed '), findsNothing);
    await tester.tap(find.text('1 event · commandExecution completed'));
    await tester.pumpAndSettle();
    expect(find.text('Activity'), findsOneWidget);
    expect(
      find.byKey(
        const ValueKey(
          'activity-summary-count-value-commandExecution-completed-1',
        ),
      ),
      findsOneWidget,
    );
    final activityCard = find.byKey(
      const ValueKey('timeline-item-activity:commandExecution:completed'),
    );
    expect(activityCard, findsOneWidget);

    liveEvents.add(
      const SessionEvent(
        id: 2,
        eventType: 'tool.call.completed',
        payload: {
          'item': {'id': 'tool-2', 'type': 'commandExecution'},
        },
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      find.descendant(
        of: activityCard,
        matching: find.byKey(
          const ValueKey(
            'activity-summary-count-fade-commandExecution-completed',
          ),
        ),
      ),
      findsOneWidget,
    );
    final fade = tester.widget<FadeTransition>(
      find.byKey(
        const ValueKey(
          'activity-summary-count-fade-commandExecution-completed',
        ),
      ),
    );
    expect(fade.opacity.value, lessThan(1));
    expect(
      find.byKey(
        const ValueKey(
          'activity-summary-count-value-commandExecution-completed-2',
        ),
      ),
      findsOneWidget,
    );

    await tester.pump(const Duration(milliseconds: 250));

    expect(
      tester
          .widget<FadeTransition>(
            find.byKey(
              const ValueKey(
                'activity-summary-count-fade-commandExecution-completed',
              ),
            ),
          )
          .opacity
          .value,
      1,
    );
    expect(activityCard, findsOneWidget);
    expect(find.text('2 events · commandExecution completed'), findsOneWidget);

    await liveEvents.close();
  });

  testWidgets('reduced motion keeps the activity summary indicator static', (
    tester,
  ) async {
    tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(
          disableAnimations: true,
          reduceMotion: true,
        );
    addTearDown(
      tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
    );

    await pumpApp(
      tester,
      api: FakeDaemonApi(
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Tool activity',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Tool activity',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: [
            SessionEvent(
              id: 1,
              eventType: 'tool.call.started',
              payload: {
                'item': {'id': 'tool-1', 'type': 'commandExecution'},
              },
            ),
          ],
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tool activity'));
    await tester.pumpAndSettle();

    expect(find.text('1 event · commandExecution started'), findsOneWidget);
    await tester.tap(find.text('1 event · commandExecution started'));
    await tester.pumpAndSettle();

    final opacityFinder = find.byKey(
      const ValueKey('activity-summary-active-indicator-opacity'),
    );
    expect(tester.widget<Opacity>(opacityFinder).opacity, 1);

    await tester.pump(const Duration(milliseconds: 700));

    expect(tester.widget<Opacity>(opacityFinder).opacity, 1);
  });

  testWidgets(
    'renders useful status summaries as compact session status rows',
    (tester) async {
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: MobileBootstrap(
            daemonVersion: '0.1.0',
            user: const CurrentUser(
              id: 'usr_workspace',
              displayName: 'Workspace',
            ),
            roots: const <WorkspaceRoot>[],
            sessions: const [
              SessionSummary(
                id: 'sess_1',
                title: 'Status detail',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'completed',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: const VoiceConfig(doubaoDirectAvailable: false),
          ),
          snapshot: const SessionSnapshot(
            id: 'sess_1',
            title: 'Status detail',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            workspacePath: '/home/jhz/projects/agent-dock',
            status: 'completed',
            hasMoreHistory: false,
            events: [
              SessionEvent(
                id: 1,
                eventType: 'session.status.changed',
                payload: {'status': 'completed'},
              ),
            ],
          ),
        ),
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Status detail'));
      await tester.pumpAndSettle();

      expect(find.text('Session completed'), findsOneWidget);
      expect(find.text('Status'), findsNothing);
    },
  );

  testWidgets('hides unknown timeline items when debug diagnostics are off', (
    tester,
  ) async {
    await pumpApp(
      tester,
      showDebugTimelineItems: false,
      api: FakeDaemonApi(
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Unknown detail',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Unknown detail',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: [
            SessionEvent(
              id: 1,
              eventType: 'tool.unknown',
              payload: {'text': 'debug payload'},
            ),
          ],
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unknown detail'));
    await tester.pumpAndSettle();

    expect(find.text('tool.unknown'), findsNothing);
    expect(find.textContaining('"text": "debug payload"'), findsNothing);
  });

  testWidgets('shows unknown timeline items when debug diagnostics are on', (
    tester,
  ) async {
    await pumpApp(
      tester,
      showDebugTimelineItems: true,
      api: FakeDaemonApi(
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Unknown detail',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Unknown detail',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: [
            SessionEvent(
              id: 1,
              eventType: 'tool.unknown',
              payload: {'text': 'debug payload'},
            ),
          ],
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unknown detail'));
    await tester.pumpAndSettle();

    expect(find.text('tool.unknown'), findsOneWidget);
    expect(find.textContaining('"text": "debug payload"'), findsNothing);

    await tester.tap(find.text('tool.unknown'));
    await tester.pumpAndSettle();

    expect(find.textContaining('"text": "debug payload"'), findsOneWidget);
  });

  testWidgets(
    'unknown diagnostic expansion persists when older history is inserted',
    (tester) async {
      final api = FakeDaemonApi(
        olderSnapshotDelay: const Duration(milliseconds: 1),
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: <WorkspaceRoot>[],
          sessions: [
            SessionSummary(
              id: 'sess_1',
              title: 'Unknown detail',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Unknown detail',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: true,
          events: [
            SessionEvent(
              id: 10,
              eventType: 'tool.unknown',
              payload: {'text': 'debug payload'},
            ),
          ],
        ),
        olderSnapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Unknown detail',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: [
            SessionEvent(
              id: 1,
              eventType: 'assistant.message',
              payload: {'text': 'older'},
            ),
          ],
        ),
      );
      await pumpApp(tester, showDebugTimelineItems: true, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Unknown detail'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('tool.unknown'));
      await tester.pumpAndSettle();
      expect(find.textContaining('"text": "debug payload"'), findsOneWidget);

      await tester.drag(find.byType(ListView).last, const Offset(0, 1200));
      await tester.pumpAndSettle();

      expect(find.textContaining('"text": "debug payload"'), findsOneWidget);
      expect(find.text('older'), findsOneWidget);
    },
  );

  testWidgets(
    'renders shell and file change cards as compact summaries and expands on tap',
    (tester) async {
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: MobileBootstrap(
            daemonVersion: '0.1.0',
            user: const CurrentUser(
              id: 'usr_workspace',
              displayName: 'Workspace',
            ),
            roots: const <WorkspaceRoot>[],
            sessions: const [
              SessionSummary(
                id: 'sess_1',
                title: 'Tool details',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'running',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: const VoiceConfig(doubaoDirectAvailable: false),
          ),
          snapshot: const SessionSnapshot(
            id: 'sess_1',
            title: 'Tool details',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            workspacePath: '/home/jhz/projects/agent-dock',
            status: 'running',
            hasMoreHistory: false,
            events: [
              SessionEvent(
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
                      {
                        'type': 'runCommand',
                        'command': 'npm test',
                        'path': null,
                      },
                    ],
                    'aggregatedOutput': 'PASS src/app.test.ts\n',
                    'exitCode': 0,
                    'durationMs': 42,
                  },
                },
              ),
              SessionEvent(
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
            ],
          ),
        ),
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tool details'));
      await tester.pumpAndSettle();

      expect(find.text('shell'), findsNothing);
      expect(find.text('npm test'), findsOneWidget);
      expect(find.text('Files changed'), findsNothing);
      expect(find.text('1 file · src/app.ts'), findsOneWidget);
      expect(find.text('Edited src/app.ts'), findsNothing);
      expect(find.widgetWithText(Chip, 'completed'), findsNothing);
      expect(
        find.byKey(const ValueKey('compact-timeline-status-dot-success')),
        findsNWidgets(2),
      );
      expect(find.text('PASS src/app.test.ts'), findsNothing);
      expect(find.text('src/app.ts'), findsNothing);
      expect(find.textContaining('@@\n-old\n+new'), findsNothing);

      await tester.tap(find.text('npm test'));
      await tester.pumpAndSettle();

      expect(find.text('shell'), findsOneWidget);
      expect(find.text('PASS src/app.test.ts'), findsOneWidget);
      expect(find.text('exit 0'), findsOneWidget);
      expect(find.text('42ms'), findsOneWidget);

      await tester.tap(find.text('1 file · src/app.ts'));
      await tester.pumpAndSettle();

      expect(find.text('Files changed'), findsOneWidget);
      expect(find.text('src/app.ts'), findsNWidgets(2));
      expect(find.text('@@'), findsOneWidget);
      expect(find.text('-old'), findsOneWidget);
      expect(find.text('+new'), findsOneWidget);
    },
  );

  testWidgets('long pressing tool and file cards exposes copy actions', (
    tester,
  ) async {
    final clipboardTexts = <String>[];
    final hapticCalls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardTexts.add(
            (call.arguments as Map<Object?, Object?>)['text']! as String,
          );
        }
        if (call.method == 'HapticFeedback.vibrate') {
          hapticCalls.add(call.arguments as String? ?? 'vibrate');
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    await pumpApp(
      tester,
      api: FakeDaemonApi(
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Copy tool cards',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Copy tool cards',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: [
            SessionEvent(
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
            SessionEvent(
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
          ],
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy tool cards'));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('npm test'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy command'));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('npm test'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy output'));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('1 file · src/app.ts'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy path'));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('1 file · src/app.ts'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy diff'));
    await tester.pumpAndSettle();

    expect(
      clipboardTexts,
      containsAll([
        'npm test',
        'PASS src/app.test.ts',
        'src/app.ts',
        '@@\n-old\n+new',
      ]),
    );
    expect(
      hapticCalls.where((call) => call == 'HapticFeedbackType.selectionClick'),
      hasLength(4),
    );
  });

  testWidgets('renders file diffs as colored line blocks', (tester) async {
    await pumpApp(
      tester,
      api: FakeDaemonApi(
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Diff colors',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Diff colors',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: [
            SessionEvent(
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
                      'diff': '@@\n context\n-old\n+new\n',
                    },
                  ],
                },
              },
            ),
          ],
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Diff colors'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1 file · src/app.ts'));
    await tester.pumpAndSettle();

    expect(find.textContaining('@@\n context\n-old\n+new'), findsNothing);
    expect(find.text('@@'), findsOneWidget);
    expect(find.text(' context'), findsOneWidget);
    expect(find.text('-old'), findsOneWidget);
    expect(find.text('+new'), findsOneWidget);

    expect(
      tester.widget<Text>(find.text('-old')).style?.color,
      const Color(0xFFFCA5A5),
    );
    expect(
      tester.widget<Text>(find.text('+new')).style?.color,
      const Color(0xFF86EFAC),
    );
    expect(
      tester.widget<Text>(find.text(' context')).style?.color,
      const Color(0xFF9FB3C8),
    );
  });

  testWidgets('caps file diff text scaling for readability', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
    tester.platformDispatcher.textScaleFactorTestValue = 2.4;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await pumpSessionDetailForTest(
      tester,
      api: FakeDaemonApi(
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Diff scale',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: [
            SessionEvent(
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
          ],
        ),
      ),
      session: const SessionSummary(
        id: 'sess_1',
        title: 'Diff scale',
        agentKind: 'codex',
        sourceKind: 'managed',
        runtimeSessionId: 'runtime_1',
        status: 'running',
        workspacePath: '/home/jhz/projects/agent-dock',
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('1 file · src/app.ts'));
    await tester.pumpAndSettle();

    final diffText = tester.widget<Text>(find.text('+new'));
    final diffScaler = diffText.textScaler;
    expect(diffScaler, isNotNull);
    expect(diffScaler!.scale(14), lessThanOrEqualTo(17.5));
  });

  testWidgets('shows file change kinds alongside expanded file paths', (
    tester,
  ) async {
    await pumpApp(
      tester,
      api: FakeDaemonApi(
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'File kinds',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'File kinds',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: [
            SessionEvent(
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
                    {
                      'path': 'src/old.ts',
                      'kind': {'type': 'delete', 'move_path': null},
                      'diff': '',
                    },
                  ],
                },
              },
            ),
          ],
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('File kinds'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2 files · src/app.ts'));
    await tester.pumpAndSettle();

    expect(find.text('src/app.ts'), findsWidgets);
    expect(find.text('src/old.ts'), findsOneWidget);
    expect(find.text('updated'), findsOneWidget);
    expect(find.text('deleted'), findsOneWidget);
  });

  testWidgets('shows rename file changes as source to destination paths', (
    tester,
  ) async {
    await pumpApp(
      tester,
      api: FakeDaemonApi(
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'File rename',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'File rename',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: [
            SessionEvent(
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
                      'kind': {
                        'type': 'rename',
                        'move_path': 'src/new_name.dart',
                      },
                      'diff': '',
                    },
                  ],
                },
              },
            ),
          ],
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('File rename'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.text('1 file · src/old_name.dart -> src/new_name.dart'),
    );
    await tester.pumpAndSettle();

    expect(find.text('src/old_name.dart -> src/new_name.dart'), findsOneWidget);
    expect(find.text('renamed'), findsOneWidget);
    expect(find.text('moved to src/new_name.dart'), findsNothing);
  });

  testWidgets('renders failed shell commands with failure status metadata', (
    tester,
  ) async {
    await pumpApp(
      tester,
      api: FakeDaemonApi(
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Failed command',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Failed command',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: [
            SessionEvent(
              id: 1,
              eventType: 'tool.call.completed',
              payload: {
                'item': {
                  'id': 'cmd-1',
                  'type': 'commandExecution',
                  'command': '/bin/zsh -lc npm test',
                  'cwd': '/tmp/workspace',
                  'status': 'completed',
                  'aggregatedOutput': 'FAIL src/app.test.ts\n',
                  'exitCode': 1,
                },
              },
            ),
          ],
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Failed command'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('compact-timeline-status-dot-failure')),
      findsOneWidget,
    );
    expect(find.text('shell'), findsOneWidget);
    expect(find.text('npm test'), findsWidgets);
    expect(find.text('FAIL src/app.test.ts'), findsOneWidget);
    expect(find.text('exit 1'), findsOneWidget);
  });

  testWidgets(
    'automatically expands the latest failed shell command when no assistant message follows',
    (tester) async {
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: MobileBootstrap(
            daemonVersion: '0.1.0',
            user: const CurrentUser(
              id: 'usr_workspace',
              displayName: 'Workspace',
            ),
            roots: const <WorkspaceRoot>[],
            sessions: const [
              SessionSummary(
                id: 'sess_1',
                title: 'Auto expand failure',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'running',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: const VoiceConfig(doubaoDirectAvailable: false),
          ),
          snapshot: const SessionSnapshot(
            id: 'sess_1',
            title: 'Auto expand failure',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            workspacePath: '/home/jhz/projects/agent-dock',
            status: 'running',
            hasMoreHistory: false,
            events: [
              SessionEvent(
                id: 1,
                eventType: 'tool.call.completed',
                payload: {
                  'item': {
                    'id': 'cmd-1',
                    'type': 'commandExecution',
                    'command': '/bin/zsh -lc npm test',
                    'cwd': '/tmp/workspace',
                    'status': 'completed',
                    'aggregatedOutput': 'FAIL src/app.test.ts\n',
                    'exitCode': 1,
                  },
                },
              ),
            ],
          ),
        ),
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Auto expand failure'));
      await tester.pumpAndSettle();

      expect(find.text('FAIL src/app.test.ts'), findsOneWidget);
      expect(find.text('exit 1'), findsOneWidget);
    },
  );

  testWidgets(
    'keeps a failed shell command collapsed when assistant output follows it',
    (tester) async {
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: MobileBootstrap(
            daemonVersion: '0.1.0',
            user: const CurrentUser(
              id: 'usr_workspace',
              displayName: 'Workspace',
            ),
            roots: const <WorkspaceRoot>[],
            sessions: const [
              SessionSummary(
                id: 'sess_1',
                title: 'Explained failure',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'running',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: const VoiceConfig(doubaoDirectAvailable: false),
          ),
          snapshot: const SessionSnapshot(
            id: 'sess_1',
            title: 'Explained failure',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            workspacePath: '/home/jhz/projects/agent-dock',
            status: 'running',
            hasMoreHistory: false,
            events: [
              SessionEvent(
                id: 1,
                eventType: 'tool.call.completed',
                payload: {
                  'item': {
                    'id': 'cmd-1',
                    'type': 'commandExecution',
                    'command': '/bin/zsh -lc npm test',
                    'cwd': '/tmp/workspace',
                    'status': 'completed',
                    'aggregatedOutput': 'FAIL src/app.test.ts\n',
                    'exitCode': 1,
                  },
                },
              ),
              SessionEvent(
                id: 2,
                eventType: 'assistant.message',
                payload: {
                  'text': 'The test failed because the snapshot changed.',
                },
              ),
            ],
          ),
        ),
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Explained failure'));
      await tester.pumpAndSettle();

      expect(find.text('FAIL src/app.test.ts'), findsNothing);
      expect(
        find.text('The test failed because the snapshot changed.'),
        findsOneWidget,
      );

      await tester.tap(find.text('npm test'));
      await tester.pumpAndSettle();

      expect(find.text('FAIL src/app.test.ts'), findsOneWidget);
    },
  );

  testWidgets(
    'long shell output shows a preview with an explicit expand action',
    (tester) async {
      final longOutput = List<String>.generate(
        13,
        (index) => 'output line ${index + 1}',
      ).join('\n');
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: MobileBootstrap(
            daemonVersion: '0.1.0',
            user: const CurrentUser(
              id: 'usr_workspace',
              displayName: 'Workspace',
            ),
            roots: const <WorkspaceRoot>[],
            sessions: const [
              SessionSummary(
                id: 'sess_1',
                title: 'Long output',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'running',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: const VoiceConfig(doubaoDirectAvailable: false),
          ),
          snapshot: SessionSnapshot(
            id: 'sess_1',
            title: 'Long output',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            workspacePath: '/home/jhz/projects/agent-dock',
            status: 'running',
            hasMoreHistory: false,
            events: [
              SessionEvent(
                id: 1,
                eventType: 'tool.call.completed',
                payload: {
                  'item': {
                    'id': 'cmd-1',
                    'type': 'commandExecution',
                    'command': '/bin/zsh -lc npm test',
                    'cwd': '/tmp/workspace',
                    'status': 'completed',
                    'aggregatedOutput': longOutput,
                    'exitCode': 0,
                  },
                },
              ),
            ],
          ),
        ),
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Long output'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('npm test'));
      await tester.pumpAndSettle();

      expect(find.text('output line 1'), findsOneWidget);
      expect(find.text('output line 12'), findsOneWidget);
      expect(find.text('output line 13'), findsNothing);
      expect(find.text('Show full output'), findsOneWidget);

      await tester.scrollUntilVisible(
        find.widgetWithText(TextButton, 'Show full output'),
        120,
        scrollable: find.byType(Scrollable).last,
      );
      final expandButton = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Show full output'),
      );
      expandButton.onPressed!.call();
      await tester.pumpAndSettle();

      expect(find.text('output line 13'), findsOneWidget);
      expect(find.text('Collapse output'), findsOneWidget);
    },
  );

  testWidgets('shows shell and file placeholders for in-progress tool items', (
    tester,
  ) async {
    await pumpApp(
      tester,
      api: FakeDaemonApi(
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Tool progress',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Tool progress',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: [
            SessionEvent(
              id: 1,
              eventType: 'tool.call.started',
              payload: {
                'item': {
                  'id': 'cmd-1',
                  'type': 'commandExecution',
                  'command': '/bin/zsh -lc npm test',
                  'cwd': '/tmp/workspace',
                  'status': 'inProgress',
                },
              },
            ),
            SessionEvent(
              id: 2,
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
          ],
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tool progress'));
    await tester.pumpAndSettle();

    expect(find.text('npm test'), findsOneWidget);
    expect(find.text('1 file · src/app.ts'), findsOneWidget);

    await tester.tap(find.text('npm test'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1 file · src/app.ts'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(Chip, 'inProgress'), findsNWidgets(2));
    for (final chip in tester.widgetList<Chip>(
      find.widgetWithText(Chip, 'inProgress'),
    )) {
      expect(chip.backgroundColor, _inProgressStatusPillColor);
    }
    expect(
      find.byKey(const ValueKey('tool-call-in-progress-spinner')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('file-change-in-progress-accent')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('file-change-in-progress-scan-line')),
      findsOneWidget,
    );
    final inProgressPillOpacity = tester.widget<Opacity>(
      find.byKey(
        const ValueKey('status-pill-opacity-inProgress-tool.call.started'),
      ),
    );
    expect(inProgressPillOpacity.opacity, 1);

    await tester.pump(const Duration(milliseconds: 700));

    expect(
      tester
          .widget<Opacity>(
            find.byKey(
              const ValueKey(
                'status-pill-opacity-inProgress-tool.call.started',
              ),
            ),
          )
          .opacity,
      isNot(inProgressPillOpacity.opacity),
    );
    expect(
      find.byKey(const ValueKey('file-change-in-progress-scan-line')),
      findsOneWidget,
    );

    expect(find.text('Waiting for output...'), findsOneWidget);

    expect(find.text('Preparing changes...'), findsOneWidget);
  });

  testWidgets('reduced motion keeps the file change running accent static', (
    tester,
  ) async {
    tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(
          disableAnimations: true,
          reduceMotion: true,
        );
    addTearDown(
      tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
    );

    await pumpApp(
      tester,
      api: FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: <WorkspaceRoot>[],
          sessions: [
            SessionSummary(
              id: 'sess_1',
              title: 'Static file accent',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Static file accent',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: [
            SessionEvent(
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
          ],
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Static file accent'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('file-change-in-progress-accent')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('file-change-in-progress-scan-line')),
      findsNothing,
    );
  });

  testWidgets(
    'shell lifecycle cards crossfade from spinner to success icon when they complete',
    (tester) async {
      final liveEvents = StreamController<SessionEvent>();
      final api = FakeDaemonApi(
        liveEvents: liveEvents.stream,
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Tool completion transition',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Tool completion transition',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: [
            SessionEvent(
              id: 1,
              eventType: 'tool.call.started',
              payload: {
                'item': {
                  'id': 'cmd-1',
                  'type': 'commandExecution',
                  'command': '/bin/zsh -lc npm test',
                  'cwd': '/tmp/workspace',
                  'status': 'inProgress',
                },
              },
            ),
          ],
        ),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tool completion transition'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('npm test'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('tool-call-in-progress-spinner')),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.check_circle_outline), findsNothing);

      liveEvents.add(
        const SessionEvent(
          id: 2,
          eventType: 'tool.call.completed',
          payload: {
            'item': {
              'id': 'cmd-1',
              'type': 'commandExecution',
              'command': '/bin/zsh -lc npm test',
              'cwd': '/tmp/workspace',
              'status': 'completed',
              'aggregatedOutput': 'PASS src/app.test.ts\n',
              'exitCode': 0,
            },
          },
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        find.byKey(const ValueKey('tool-call-in-progress-spinner')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('tool-status-complete')),
        findsOneWidget,
      );

      await tester.pump(const Duration(milliseconds: 250));

      expect(
        find.byKey(const ValueKey('tool-call-in-progress-spinner')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('tool-status-complete')),
        findsOneWidget,
      );

      await liveEvents.close();
    },
  );

  testWidgets('shell output preview fades in when output first appears', (
    tester,
  ) async {
    final liveEvents = StreamController<SessionEvent>();
    final api = FakeDaemonApi(
      liveEvents: liveEvents.stream,
      bootstrap: MobileBootstrap(
        daemonVersion: '0.1.0',
        user: const CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: const <WorkspaceRoot>[],
        sessions: const [
          SessionSummary(
            id: 'sess_1',
            title: 'Tool output fade',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            status: 'running',
            workspacePath: '/home/jhz/projects/agent-dock',
          ),
        ],
        voice: const VoiceConfig(doubaoDirectAvailable: false),
      ),
      snapshot: const SessionSnapshot(
        id: 'sess_1',
        title: 'Tool output fade',
        agentKind: 'codex',
        sourceKind: 'managed',
        runtimeSessionId: 'runtime_1',
        workspacePath: '/home/jhz/projects/agent-dock',
        status: 'running',
        hasMoreHistory: false,
        events: [
          SessionEvent(
            id: 1,
            eventType: 'tool.call.started',
            payload: {
              'item': {
                'id': 'cmd-1',
                'type': 'commandExecution',
                'command': '/bin/zsh -lc npm test',
                'cwd': '/tmp/workspace',
                'status': 'inProgress',
              },
            },
          ),
        ],
      ),
    );
    await pumpApp(tester, api: api);

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tool output fade'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('npm test'));
    await tester.pumpAndSettle();

    expect(find.text('Waiting for output...'), findsOneWidget);

    liveEvents.add(
      const SessionEvent(
        id: 2,
        eventType: 'tool.call.completed',
        payload: {
          'item': {
            'id': 'cmd-1',
            'type': 'commandExecution',
            'command': '/bin/zsh -lc npm test',
            'cwd': '/tmp/workspace',
            'status': 'completed',
            'aggregatedOutput': 'PASS src/app.test.ts\n',
            'exitCode': 0,
          },
        },
      ),
    );
    await tester.pump();
    await tester.pump();

    final outputFadeFinder = find.byKey(
      const ValueKey('tool-output-fade-PASS src/app.test.ts'),
    );
    expect(outputFadeFinder, findsOneWidget);
    expect(
      tester.widget<FadeTransition>(outputFadeFinder).opacity.value,
      lessThan(1),
    );
    expect(find.text('PASS src/app.test.ts'), findsOneWidget);
    expect(find.text('Waiting for output...'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 250));

    expect(tester.widget<FadeTransition>(outputFadeFinder).opacity.value, 1);
    expect(find.text('Waiting for output...'), findsNothing);

    await liveEvents.close();
  });

  testWidgets(
    'file change lifecycle cards briefly show a success check when they complete',
    (tester) async {
      final liveEvents = StreamController<SessionEvent>();
      final api = FakeDaemonApi(
        liveEvents: liveEvents.stream,
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'File change completion transition',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'File change completion transition',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: [
            SessionEvent(
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
          ],
        ),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('File change completion transition'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('1 file · src/app.ts'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('file-change-completion-icon')),
        findsNothing,
      );
      expect(find.widgetWithText(Chip, 'inProgress'), findsOneWidget);
      expect(find.text('Preparing changes...'), findsOneWidget);

      liveEvents.add(
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
      );
      await tester.pump();
      await tester.pump();

      expect(find.widgetWithText(Chip, 'completed'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('file-change-completion-icon')),
        findsOneWidget,
      );
      expect(find.text('@@'), findsOneWidget);
      final diffFade = tester.widget<FadeTransition>(
        find.byKey(const ValueKey('file-change-diff-group-fade')),
      );
      expect(diffFade.opacity.value, lessThan(1));

      await tester.pump(const Duration(milliseconds: 700));

      expect(
        find.byKey(const ValueKey('file-change-completion-icon')),
        findsNothing,
      );
      expect(
        tester
            .widget<FadeTransition>(
              find.byKey(const ValueKey('file-change-diff-group-fade')),
            )
            .opacity
            .value,
        1,
      );

      await liveEvents.close();
    },
  );

  testWidgets('file change count changes crossfade within the existing card', (
    tester,
  ) async {
    final liveEvents = StreamController<SessionEvent>();
    final api = FakeDaemonApi(
      liveEvents: liveEvents.stream,
      bootstrap: MobileBootstrap(
        daemonVersion: '0.1.0',
        user: const CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: const <WorkspaceRoot>[],
        sessions: const [
          SessionSummary(
            id: 'sess_1',
            title: 'File change count transition',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            status: 'running',
            workspacePath: '/home/jhz/projects/agent-dock',
          ),
        ],
        voice: const VoiceConfig(doubaoDirectAvailable: false),
      ),
      snapshot: const SessionSnapshot(
        id: 'sess_1',
        title: 'File change count transition',
        agentKind: 'codex',
        sourceKind: 'managed',
        runtimeSessionId: 'runtime_1',
        workspacePath: '/home/jhz/projects/agent-dock',
        status: 'running',
        hasMoreHistory: false,
        events: [
          SessionEvent(
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
        ],
      ),
    );
    await pumpApp(tester, api: api);

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('File change count transition'));
    await tester.pumpAndSettle();

    expect(find.text('1 file · src/app.ts'), findsOneWidget);
    await tester.tap(find.text('1 file · src/app.ts'));
    await tester.pumpAndSettle();
    final fileCard = find.byKey(
      const ValueKey('timeline-item-fileChange:patch-1'),
    );
    expect(fileCard, findsOneWidget);

    liveEvents.add(
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
              {
                'path': 'src/lib.rs',
                'kind': {'type': 'create', 'move_path': null},
                'diff': '@@\n+pub fn main() {}\n',
              },
            ],
          },
        },
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      find.descendant(
        of: fileCard,
        matching: find.byKey(const ValueKey('file-change-count-fade-2 files')),
      ),
      findsOneWidget,
    );
    final fade = tester.widget<FadeTransition>(
      find.byKey(const ValueKey('file-change-count-fade-2 files')),
    );
    expect(fade.opacity.value, lessThan(1));
    expect(find.text('2 files'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 250));

    expect(
      tester
          .widget<FadeTransition>(
            find.byKey(const ValueKey('file-change-count-fade-2 files')),
          )
          .opacity
          .value,
      1,
    );
    expect(fileCard, findsOneWidget);

    await liveEvents.close();
  });

  testWidgets(
    'renders metadata-only file change reports without placeholder diff text',
    (tester) async {
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: MobileBootstrap(
            daemonVersion: '0.1.0',
            user: const CurrentUser(
              id: 'usr_workspace',
              displayName: 'Workspace',
            ),
            roots: const <WorkspaceRoot>[],
            sessions: const [
              SessionSummary(
                id: 'sess_1',
                title: 'Reported files',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'running',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: const VoiceConfig(doubaoDirectAvailable: false),
          ),
          snapshot: const SessionSnapshot(
            id: 'sess_1',
            title: 'Reported files',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            workspacePath: '/home/jhz/projects/agent-dock',
            status: 'running',
            hasMoreHistory: false,
            events: [
              SessionEvent(
                id: 1,
                eventType: 'file.change.reported',
                payload: {
                  'files': ['src/app.ts', 'src/lib.rs'],
                },
              ),
            ],
          ),
        ),
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reported files'));
      await tester.pumpAndSettle();

      expect(find.text('Files changed'), findsNothing);
      expect(find.text('2 files · src/app.ts'), findsOneWidget);
      expect(find.text('Edited 2 files'), findsNothing);

      await tester.tap(find.text('2 files · src/app.ts'));
      await tester.pumpAndSettle();

      expect(find.text('2 files'), findsOneWidget);
      expect(find.text('src/app.ts'), findsOneWidget);
      expect(find.text('src/lib.rs'), findsOneWidget);
      expect(find.text('No changes'), findsNothing);
    },
  );

  testWidgets('scrolls to the latest events on first session load', (
    tester,
  ) async {
    final events = List<SessionEvent>.generate(24, (index) {
      final eventNumber = index + 1;
      return SessionEvent(
        id: eventNumber,
        eventType: eventNumber.isEven ? 'assistant.message' : 'user.message',
        payload: {'text': 'event $eventNumber'},
      );
    });

    await pumpApp(
      tester,
      api: FakeDaemonApi(
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Mobile migration',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: SessionSnapshot(
          id: 'sess_1',
          title: 'Mobile migration',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: events,
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mobile migration'));
    await tester.pumpAndSettle();

    expect(find.text('event 24'), findsOneWidget);
    expect(find.text('event 1'), findsNothing);
  });

  testWidgets('shows chat skeleton cards while the first snapshot is loading', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: SessionDetailPage(
          api: FakeDaemonApi(snapshotDelay: const Duration(seconds: 1)),
          daemonUrl: Uri.parse('https://daemon.example.com'),
          session: const SessionSummary(
            id: 'sess_1',
            title: 'Mobile migration',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            status: 'running',
            workspacePath: '/home/jhz/projects/agent-dock',
          ),
          token: 'tok_workspace',
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
      ),
    );

    await tester.pump();

    expect(
      find.byKey(const ValueKey('chat-timeline-skeleton')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('chat-skeleton-user-bubble')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('chat-skeleton-assistant-card')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('chat-skeleton-activity-card')),
      findsOneWidget,
    );

    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('session-timeline-expanded')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('chat-timeline-skeleton')), findsNothing);

    await tester.pumpAndSettle();
  });

  testWidgets('chat skeleton stays static when reduced motion is enabled', (
    tester,
  ) async {
    tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(
          disableAnimations: true,
          reduceMotion: true,
        );
    addTearDown(
      tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: SessionDetailPage(
          api: FakeDaemonApi(snapshotDelay: const Duration(seconds: 1)),
          daemonUrl: Uri.parse('https://daemon.example.com'),
          session: const SessionSummary(
            id: 'sess_1',
            title: 'Mobile migration',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            status: 'running',
            workspacePath: '/home/jhz/projects/agent-dock',
          ),
          token: 'tok_workspace',
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
      ),
    );

    await tester.pump();

    expect(
      find.byKey(const ValueKey('chat-timeline-skeleton')),
      findsOneWidget,
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(ShaderMask), findsNothing);

    await tester.pump(const Duration(seconds: 1));
    expect(
      find.byKey(const ValueKey('chat-timeline-initial-fade')),
      findsNothing,
    );
    await tester.pumpAndSettle();
  });

  testWidgets('sends a text message from the session detail composer', (
    tester,
  ) async {
    final hapticCalls = recordHapticCalls(tester);
    final api = FakeDaemonApi(
      bootstrap: MobileBootstrap(
        daemonVersion: '0.1.0',
        user: const CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: const <WorkspaceRoot>[],
        sessions: const [
          SessionSummary(
            id: 'sess_1',
            title: 'Mobile migration',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            status: 'running',
            workspacePath: '/home/jhz/projects/agent-dock',
          ),
        ],
        voice: const VoiceConfig(doubaoDirectAvailable: false),
      ),
      snapshot: const SessionSnapshot(
        id: 'sess_1',
        title: 'Mobile migration',
        agentKind: 'codex',
        sourceKind: 'managed',
        runtimeSessionId: 'runtime_1',
        workspacePath: '/home/jhz/projects/agent-dock',
        status: 'running',
        hasMoreHistory: false,
        events: <SessionEvent>[],
      ),
    );
    await pumpApp(tester, api: api);

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mobile migration'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Message the agent'),
      'continue the Flutter work',
    );
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pump();

    expect(api.sentMessages, ['sess_1:continue the Flutter work']);
    expect(find.byKey(const ValueKey('composer-clear-fade')), findsOneWidget);
    expect(
      hapticCalls,
      containsAll(<String>[
        'HapticFeedbackType.lightImpact',
        'HapticFeedbackType.successNotification',
      ]),
    );

    await tester.pumpAndSettle();
    expect(find.text('continue the Flutter work'), findsNothing);
  });

  testWidgets(
    'reduced motion keeps the send button progress static while sending',
    (tester) async {
      tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(
            disableAnimations: true,
            reduceMotion: true,
          );
      addTearDown(
        tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );

      final api = FakeDaemonApi(
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Mobile migration',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Mobile migration',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: <SessionEvent>[],
        ),
        sendMessageDelay: const Duration(milliseconds: 200),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mobile migration'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Message the agent'),
        'continue the Flutter work',
      );
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pump();

      expect(
        find.byKey(const ValueKey('composer-send-static-progress-icon')),
        findsOneWidget,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);

      await tester.pump(const Duration(milliseconds: 220));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('reduced motion keeps successful composer clearing static', (
    tester,
  ) async {
    tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(
          disableAnimations: true,
          reduceMotion: true,
        );
    addTearDown(
      tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
    );

    final api = FakeDaemonApi(
      bootstrap: MobileBootstrap(
        daemonVersion: '0.1.0',
        user: const CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: const <WorkspaceRoot>[],
        sessions: const [
          SessionSummary(
            id: 'sess_1',
            title: 'Mobile migration',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            status: 'running',
            workspacePath: '/home/jhz/projects/agent-dock',
          ),
        ],
        voice: const VoiceConfig(doubaoDirectAvailable: false),
      ),
      snapshot: const SessionSnapshot(
        id: 'sess_1',
        title: 'Mobile migration',
        agentKind: 'codex',
        sourceKind: 'managed',
        runtimeSessionId: 'runtime_1',
        workspacePath: '/home/jhz/projects/agent-dock',
        status: 'running',
        hasMoreHistory: false,
        events: <SessionEvent>[],
      ),
    );
    await pumpApp(tester, api: api);

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mobile migration'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Message the agent'),
      'continue the Flutter work',
    );
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pump();

    expect(api.sentMessages, ['sess_1:continue the Flutter work']);
    expect(find.byKey(const ValueKey('composer-clear-fade')), findsNothing);

    await tester.pumpAndSettle();
    expect(find.text('continue the Flutter work'), findsNothing);
  });

  testWidgets('composer clear fade is removed after successful send settles', (
    tester,
  ) async {
    final api = FakeDaemonApi(
      bootstrap: MobileBootstrap(
        daemonVersion: '0.1.0',
        user: const CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: const <WorkspaceRoot>[],
        sessions: const [
          SessionSummary(
            id: 'sess_1',
            title: 'Mobile migration',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            status: 'running',
            workspacePath: '/home/jhz/projects/agent-dock',
          ),
        ],
        voice: const VoiceConfig(doubaoDirectAvailable: false),
      ),
      snapshot: const SessionSnapshot(
        id: 'sess_1',
        title: 'Mobile migration',
        agentKind: 'codex',
        sourceKind: 'managed',
        runtimeSessionId: 'runtime_1',
        workspacePath: '/home/jhz/projects/agent-dock',
        status: 'running',
        hasMoreHistory: false,
        events: <SessionEvent>[],
      ),
    );
    await pumpApp(tester, api: api);

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mobile migration'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Message the agent'),
      'continue the Flutter work',
    );
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('composer-clear-fade')), findsNothing);
  });

  testWidgets(
    'failed send preserves draft and attachments and allows keep editing',
    (tester) async {
      final hapticCalls = recordHapticCalls(tester);
      final api = FakeDaemonApi(
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Mobile migration',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Mobile migration',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: <SessionEvent>[],
        ),
        sendMessageErrors: const [
          DaemonApiException(
            statusCode: 503,
            code: 'UNAVAILABLE',
            message: 'Cannot send right now',
          ),
        ],
      );
      await pumpApp(
        tester,
        api: api,
        attachmentPicker: FakeImageAttachmentPicker(
          image: PickedImageAttachment(
            filename: 'screenshot.png',
            contentType: 'image/png',
            bytes: const <int>[137, 80, 78, 71],
          ),
        ),
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mobile migration'));
      await tester.pumpAndSettle();
      await choosePhotoLibraryAttachment(tester);
      await tester.enterText(
        find.widgetWithText(TextField, 'Message the agent'),
        'continue the Flutter work',
      );
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();

      expect(api.sentMessages, [
        'sess_1:continue the Flutter work|/tmp/attachments/sess_1/screenshot.png',
      ]);
      final composerField = tester.widget<TextField>(
        find.byType(TextField).last,
      );
      expect(composerField.controller?.text, 'continue the Flutter work');
      expect(find.text('screenshot.png'), findsAtLeastNWidgets(1));
      expect(find.text('Cannot send right now'), findsOneWidget);
      expect(find.byKey(const ValueKey('composer-retry-send')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('composer-keep-editing')),
        findsOneWidget,
      );
      expect(
        hapticCalls,
        containsAll(<String>[
          'HapticFeedbackType.lightImpact',
          'HapticFeedbackType.warningNotification',
        ]),
      );

      await tester.tap(find.byKey(const ValueKey('composer-keep-editing')));
      await tester.pumpAndSettle();

      final keptEditingField = tester.widget<TextField>(
        find.byType(TextField).last,
      );
      expect(keptEditingField.controller?.text, 'continue the Flutter work');
      expect(find.text('screenshot.png'), findsAtLeastNWidgets(1));
      expect(find.text('Cannot send right now'), findsNothing);
    },
  );

  testWidgets('routes back to login for 401 send message errors', (
    tester,
  ) async {
    final storage = MemoryAuthStorage();
    final api = FakeDaemonApi(
      bootstrap: const MobileBootstrap(
        daemonVersion: '0.1.0',
        user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: <WorkspaceRoot>[],
        sessions: [
          SessionSummary(
            id: 'sess_1',
            title: 'Expired send',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            status: 'running',
            workspacePath: '/home/jhz/projects/agent-dock',
          ),
        ],
        voice: VoiceConfig(doubaoDirectAvailable: false),
      ),
      snapshot: const SessionSnapshot(
        id: 'sess_1',
        title: 'Expired send',
        agentKind: 'codex',
        sourceKind: 'managed',
        runtimeSessionId: 'runtime_1',
        workspacePath: '/home/jhz/projects/agent-dock',
        status: 'running',
        hasMoreHistory: false,
        events: <SessionEvent>[],
      ),
      sendMessageErrors: const [
        DaemonApiException(
          statusCode: 401,
          code: 'UNAUTHORIZED',
          message: 'Unauthorized',
        ),
      ],
    );
    await pumpApp(tester, api: api, storage: storage);

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Expired send'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Message the agent'),
      'send after expiry',
    );
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();

    expect(api.sentMessages, ['sess_1:send after expiry']);
    expect(storage.didClear, isTrue);
    expect(storage.profile, isNull);
    expect(find.text('Unlock workspace'), findsOneWidget);
    expect(find.text('Expired send'), findsNothing);
    expect(find.text('Session expired. Sign in again.'), findsOneWidget);
    expect(find.text('Send failed. Retry'), findsNothing);
  });

  testWidgets('send failure shakes the composer status row once', (
    tester,
  ) async {
    final api = FakeDaemonApi(
      bootstrap: MobileBootstrap(
        daemonVersion: '0.1.0',
        user: const CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: const <WorkspaceRoot>[],
        sessions: const [
          SessionSummary(
            id: 'sess_1',
            title: 'Mobile migration',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            status: 'running',
            workspacePath: '/home/jhz/projects/agent-dock',
          ),
        ],
        voice: const VoiceConfig(doubaoDirectAvailable: false),
      ),
      snapshot: const SessionSnapshot(
        id: 'sess_1',
        title: 'Mobile migration',
        agentKind: 'codex',
        sourceKind: 'managed',
        runtimeSessionId: 'runtime_1',
        workspacePath: '/home/jhz/projects/agent-dock',
        status: 'running',
        hasMoreHistory: false,
        events: <SessionEvent>[],
      ),
      sendMessageErrors: const [
        DaemonApiException(
          statusCode: 503,
          code: 'UNAVAILABLE',
          message: 'Cannot send right now',
        ),
      ],
    );
    await pumpApp(
      tester,
      api: api,
      attachmentPicker: FakeImageAttachmentPicker(
        image: PickedImageAttachment(
          filename: 'screenshot.png',
          contentType: 'image/png',
          bytes: const <int>[137, 80, 78, 71],
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mobile migration'));
    await tester.pumpAndSettle();
    await choosePhotoLibraryAttachment(tester);
    await tester.enterText(
      find.widgetWithText(TextField, 'Message the agent'),
      'continue the Flutter work',
    );
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();

    expect(find.text('Cannot send right now'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('composer-status-row-shake')),
      findsOneWidget,
    );
  });

  testWidgets('retrying a failed send resends the preserved payload', (
    tester,
  ) async {
    final api = FakeDaemonApi(
      bootstrap: MobileBootstrap(
        daemonVersion: '0.1.0',
        user: const CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: const <WorkspaceRoot>[],
        sessions: const [
          SessionSummary(
            id: 'sess_1',
            title: 'Mobile migration',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            status: 'running',
            workspacePath: '/home/jhz/projects/agent-dock',
          ),
        ],
        voice: const VoiceConfig(doubaoDirectAvailable: false),
      ),
      snapshot: const SessionSnapshot(
        id: 'sess_1',
        title: 'Mobile migration',
        agentKind: 'codex',
        sourceKind: 'managed',
        runtimeSessionId: 'runtime_1',
        workspacePath: '/home/jhz/projects/agent-dock',
        status: 'running',
        hasMoreHistory: false,
        events: <SessionEvent>[],
      ),
      sendMessageErrors: const [
        DaemonApiException(
          statusCode: 503,
          code: 'UNAVAILABLE',
          message: 'Cannot send right now',
        ),
      ],
    );
    await pumpApp(
      tester,
      api: api,
      attachmentPicker: FakeImageAttachmentPicker(
        image: PickedImageAttachment(
          filename: 'screenshot.png',
          contentType: 'image/png',
          bytes: const <int>[137, 80, 78, 71],
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mobile migration'));
    await tester.pumpAndSettle();
    await choosePhotoLibraryAttachment(tester);
    await tester.enterText(
      find.widgetWithText(TextField, 'Message the agent'),
      'continue the Flutter work',
    );
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('composer-retry-send')));
    await tester.pumpAndSettle();

    expect(api.sentMessages, [
      'sess_1:continue the Flutter work|/tmp/attachments/sess_1/screenshot.png',
      'sess_1:continue the Flutter work|/tmp/attachments/sess_1/screenshot.png',
    ]);
    final composerField = tester.widget<TextField>(find.byType(TextField).last);
    expect(composerField.controller?.text, isEmpty);
    expect(find.text('screenshot.png'), findsNothing);
    expect(find.text('Send failed. Retry'), findsNothing);
  });

  testWidgets('failed send keeps a retryable pending message visible', (
    tester,
  ) async {
    final outboxStore = MemorySessionOutboxStore();
    final api = FakeDaemonApi(
      bootstrap: const MobileBootstrap(
        daemonVersion: '0.1.0',
        user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: <WorkspaceRoot>[],
        sessions: [
          SessionSummary(
            id: 'sess_1',
            title: 'Pending send',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            status: 'running',
            workspacePath: '/tmp/workspace',
          ),
        ],
        voice: VoiceConfig(doubaoDirectAvailable: false),
      ),
      snapshot: const SessionSnapshot(
        id: 'sess_1',
        title: 'Pending send',
        agentKind: 'codex',
        sourceKind: 'managed',
        runtimeSessionId: 'runtime_1',
        workspacePath: '/tmp/workspace',
        status: 'running',
        hasMoreHistory: false,
        events: [],
      ),
      sendMessageErrors: const <Object>[SocketException('offline')],
    );

    await pumpApp(tester, api: api, outboxStore: outboxStore);
    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pending send'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Message the agent'),
      'hello',
    );
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();

    final entries = outboxStore.listEntries(
      scope: SessionOutboxScope(
        daemonUrl: Uri.parse('https://daemon.example.com'),
        userId: 'usr_workspace',
        sessionId: 'sess_1',
      ),
    );
    expect(find.text('Offline. Waiting for network...'), findsOneWidget);
    expect(find.text('hello'), findsAtLeastNWidgets(1));
    expect(find.byKey(const ValueKey('composer-retry-send')), findsOneWidget);

    expect(entries, hasLength(1));
    expect(entries.single.text, 'hello');
    expect(entries.single.status, SessionOutboxStatus.failedRetryable);
  });

  testWidgets('snapshot user.message with matching clientMessageId clears pending outbox echo', (
    tester,
  ) async {
    final outboxStore = MemorySessionOutboxStore();
    const pendingEntry = SessionOutboxEntry(
      clientMessageId: 'cli_1',
      text: 'hello',
      imagePaths: <String>[],
      createdAtMillis: 1,
      status: SessionOutboxStatus.failedRetryable,
    );
    outboxStore.saveEntry(
      scope: SessionOutboxScope(
        daemonUrl: Uri.parse('https://daemon.example.com'),
        userId: 'usr_workspace',
        sessionId: 'sess_1',
      ),
      entry: pendingEntry,
    );
    final api = FakeDaemonApi(
      bootstrap: const MobileBootstrap(
        daemonVersion: '0.1.0',
        user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: <WorkspaceRoot>[],
        sessions: [
          SessionSummary(
            id: 'sess_1',
            title: 'Pending send',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            status: 'running',
            workspacePath: '/tmp/workspace',
          ),
        ],
        voice: VoiceConfig(doubaoDirectAvailable: false),
      ),
      snapshot: const SessionSnapshot(
        id: 'sess_1',
        title: 'Pending send',
        agentKind: 'codex',
        sourceKind: 'managed',
        runtimeSessionId: 'runtime_1',
        workspacePath: '/tmp/workspace',
        status: 'running',
        hasMoreHistory: false,
        events: [
          SessionEvent(
            id: 1,
            eventType: 'user.message',
            payload: {'text': 'hello', 'clientMessageId': 'cli_1'},
          ),
        ],
      ),
    );

    await pumpApp(tester, api: api, outboxStore: outboxStore);
    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pending send'));
    await tester.pumpAndSettle();

    final entries = outboxStore.listEntries(
      scope: SessionOutboxScope(
        daemonUrl: Uri.parse('https://daemon.example.com'),
        userId: 'usr_workspace',
        sessionId: 'sess_1',
      ),
    );
    expect(entries, isEmpty);
    expect(find.byKey(const ValueKey('composer-retry-send')), findsNothing);
    expect(find.text('hello'), findsOneWidget);
  });

  testWidgets('composer text field grows up to five lines before scrolling', (
    tester,
  ) async {
    final api = FakeDaemonApi(
      bootstrap: MobileBootstrap(
        daemonVersion: '0.1.0',
        user: const CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: const <WorkspaceRoot>[],
        sessions: const [
          SessionSummary(
            id: 'sess_1',
            title: 'Mobile migration',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            status: 'running',
            workspacePath: '/home/jhz/projects/agent-dock',
          ),
        ],
        voice: const VoiceConfig(doubaoDirectAvailable: false),
      ),
      snapshot: const SessionSnapshot(
        id: 'sess_1',
        title: 'Mobile migration',
        agentKind: 'codex',
        sourceKind: 'managed',
        runtimeSessionId: 'runtime_1',
        workspacePath: '/home/jhz/projects/agent-dock',
        status: 'running',
        hasMoreHistory: false,
        events: <SessionEvent>[],
      ),
    );
    await pumpApp(tester, api: api);

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mobile migration'));
    await tester.pumpAndSettle();

    final composerField = tester.widget<TextField>(
      find.widgetWithText(TextField, 'Message the agent'),
    );
    expect(composerField.minLines, 1);
    expect(composerField.maxLines, 5);
  });

  testWidgets('shows slash command suggestions and inserts the selection', (
    tester,
  ) async {
    final api = FakeDaemonApi(
      bootstrap: MobileBootstrap(
        daemonVersion: '0.1.0',
        user: const CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: const <WorkspaceRoot>[],
        sessions: const [
          SessionSummary(
            id: 'sess_1',
            title: 'Mobile migration',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            status: 'running',
            workspacePath: '/home/jhz/projects/agent-dock',
          ),
        ],
        voice: const VoiceConfig(doubaoDirectAvailable: false),
      ),
      snapshot: const SessionSnapshot(
        id: 'sess_1',
        title: 'Mobile migration',
        agentKind: 'codex',
        sourceKind: 'managed',
        runtimeSessionId: 'runtime_1',
        workspacePath: '/home/jhz/projects/agent-dock',
        status: 'running',
        hasMoreHistory: false,
        events: <SessionEvent>[],
      ),
    );
    await pumpApp(tester, api: api);

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mobile migration'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Message the agent'),
      '/r',
    );
    await tester.pumpAndSettle();

    expect(find.text('/resume'), findsOneWidget);
    expect(find.text('/model'), findsNothing);

    await tester.tap(find.text('/resume'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextField, '/resume '), findsOneWidget);
  });

  testWidgets('shows dollar command suggestions and inserts the selection', (
    tester,
  ) async {
    final api = FakeDaemonApi(
      bootstrap: MobileBootstrap(
        daemonVersion: '0.1.0',
        user: const CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: const <WorkspaceRoot>[],
        sessions: const [
          SessionSummary(
            id: 'sess_1',
            title: 'Mobile migration',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            status: 'running',
            workspacePath: '/home/jhz/projects/agent-dock',
          ),
        ],
        voice: const VoiceConfig(doubaoDirectAvailable: false),
      ),
    );
    await pumpApp(tester, api: api);

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mobile migration'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Message the agent'),
      '\$s',
    );
    await tester.pumpAndSettle();

    expect(find.text('\$skills'), findsOneWidget);
    expect(find.text('/resume'), findsNothing);

    await tester.tap(find.text('\$skills'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextField, '\$skills '), findsOneWidget);
  });

  testWidgets(
    'preserves an unsent composer draft when leaving and reopening the same session in the active app process',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Mobile migration',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Mobile migration',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: <SessionEvent>[],
        ),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mobile migration'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'Message the agent'),
        'keep this draft',
      );
      await tester.pumpAndSettle();

      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mobile migration'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextField, 'keep this draft'), findsOneWidget);
    },
  );

  testWidgets(
    'preserves uploaded attachments when leaving and reopening the same session in the active app process',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Mobile migration',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Mobile migration',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: <SessionEvent>[],
        ),
      );
      final attachmentPicker = FakeImageAttachmentPicker(
        image: const PickedImageAttachment(
          filename: 'screenshot.png',
          contentType: 'image/png',
          bytes: <int>[1, 2, 3, 4],
        ),
      );
      await pumpApp(tester, api: api, attachmentPicker: attachmentPicker);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mobile migration'));
      await tester.pumpAndSettle();

      await choosePhotoLibraryAttachment(tester);
      expect(find.text('screenshot.png'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mobile migration'));
      await tester.pumpAndSettle();

      expect(find.text('screenshot.png'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextField, 'Message the agent'),
        'send restored attachment',
      );
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();

      expect(api.sentMessages, [
        'sess_1:send restored attachment|/tmp/attachments/sess_1/screenshot.png',
      ]);
    },
  );

  testWidgets('signing out clears in-memory composer drafts', (tester) async {
    final api = FakeDaemonApi(
      bootstrap: MobileBootstrap(
        daemonVersion: '0.1.0',
        user: const CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: const <WorkspaceRoot>[],
        sessions: const [
          SessionSummary(
            id: 'sess_1',
            title: 'Mobile migration',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            status: 'running',
            workspacePath: '/home/jhz/projects/agent-dock',
          ),
        ],
        voice: const VoiceConfig(doubaoDirectAvailable: false),
      ),
      snapshot: const SessionSnapshot(
        id: 'sess_1',
        title: 'Mobile migration',
        agentKind: 'codex',
        sourceKind: 'managed',
        runtimeSessionId: 'runtime_1',
        workspacePath: '/home/jhz/projects/agent-dock',
        status: 'running',
        hasMoreHistory: false,
        events: <SessionEvent>[],
      ),
    );
    final attachmentPicker = FakeImageAttachmentPicker(
      image: const PickedImageAttachment(
        filename: 'logout.png',
        contentType: 'image/png',
        bytes: <int>[5, 6, 7, 8],
      ),
    );
    await pumpApp(tester, api: api, attachmentPicker: attachmentPicker);

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mobile migration'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Message the agent'),
      'clear this draft on logout',
    );
    await tester.pumpAndSettle();
    await choosePhotoLibraryAttachment(tester);
    expect(find.text('logout.png'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Logout'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mobile migration'));
    await tester.pumpAndSettle();

    expect(
      find.widgetWithText(TextField, 'clear this draft on logout'),
      findsNothing,
    );
    expect(find.text('logout.png'), findsNothing);
  });

  testWidgets(
    'reopening the same session reuses in-memory timeline state instead of showing the first-load skeleton again',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: <WorkspaceRoot>[],
          sessions: [
            SessionSummary(
              id: 'sess_1',
              title: 'Mobile migration',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshotDelay: const Duration(seconds: 1),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Mobile migration',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: [
            SessionEvent(
              id: 1,
              eventType: 'assistant.message',
              payload: {'text': 'cached result'},
            ),
          ],
        ),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Mobile migration'));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('cached result'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mobile migration'));
      await tester.pump();

      expect(
        find.byKey(const ValueKey('chat-timeline-skeleton')),
        findsNothing,
      );
      expect(api.snapshotRequests, [
        'sess_1:tok_workspace:null',
        'sess_1:tok_workspace:null',
      ]);
      expect(api.eventSubscriptions, [
        'sess_1:tok_workspace:1',
        'sess_1:tok_workspace:1',
      ]);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();
      expect(find.text('cached result'), findsOneWidget);
    },
  );

  testWidgets('reopening the same session opens at the latest message', (
    tester,
  ) async {
    final events = List<SessionEvent>.generate(24, (index) {
      return SessionEvent(
        id: index + 1,
        eventType: index.isEven ? 'assistant.message' : 'user.message',
        payload: {
          'text': 'message $index\nline two for $index\nline three for $index',
        },
      );
    });
    final api = FakeDaemonApi(
      bootstrap: const MobileBootstrap(
        daemonVersion: '0.1.0',
        user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: <WorkspaceRoot>[],
        sessions: [
          SessionSummary(
            id: 'sess_1',
            title: 'Mobile migration',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            status: 'running',
            workspacePath: '/home/jhz/projects/agent-dock',
          ),
        ],
        voice: VoiceConfig(doubaoDirectAvailable: false),
      ),
      snapshot: SessionSnapshot(
        id: 'sess_1',
        title: 'Mobile migration',
        agentKind: 'codex',
        sourceKind: 'managed',
        runtimeSessionId: 'runtime_1',
        workspacePath: '/home/jhz/projects/agent-dock',
        status: 'running',
        hasMoreHistory: false,
        events: events,
      ),
    );
    await pumpApp(tester, api: api);

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Mobile migration'));
    await tester.pumpAndSettle();

    final timelineFinder = find.byType(ListView).last;
    await tester.drag(timelineFinder, const Offset(0, 800));
    await tester.pumpAndSettle();
    final scrolledOffset = tester
        .widget<ListView>(timelineFinder)
        .controller!
        .offset;
    expect(scrolledOffset, greaterThan(0));

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mobile migration'));
    await tester.pumpAndSettle();

    final reopenedTimeline = tester.widget<ListView>(
      find.byType(ListView).last,
    );
    final reopenedController = reopenedTimeline.controller!;
    expect(
      reopenedController.offset,
      closeTo(reopenedController.position.maxScrollExtent, 1),
    );
    expect(find.textContaining('message 23'), findsOneWidget);
    expect(find.textContaining('message 0'), findsNothing);
    expect(api.snapshotRequests, [
      'sess_1:tok_workspace:null',
      'sess_1:tok_workspace:null',
    ]);
  });

  testWidgets('appends live session events after opening a session', (
    tester,
  ) async {
    final liveEvents = StreamController<SessionEvent>();
    final api = FakeDaemonApi(
      liveEvents: liveEvents.stream,
      bootstrap: MobileBootstrap(
        daemonVersion: '0.1.0',
        user: const CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: const <WorkspaceRoot>[],
        sessions: const [
          SessionSummary(
            id: 'sess_1',
            title: 'Mobile migration',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            status: 'running',
            workspacePath: '/home/jhz/projects/agent-dock',
          ),
        ],
        voice: const VoiceConfig(doubaoDirectAvailable: false),
      ),
      snapshot: const SessionSnapshot(
        id: 'sess_1',
        title: 'Mobile migration',
        agentKind: 'codex',
        sourceKind: 'managed',
        runtimeSessionId: 'runtime_1',
        workspacePath: '/home/jhz/projects/agent-dock',
        status: 'running',
        hasMoreHistory: false,
        events: [
          SessionEvent(
            id: 1,
            eventType: 'user.message',
            payload: {'text': 'initial prompt'},
          ),
        ],
      ),
    );
    await pumpApp(tester, api: api);

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mobile migration'));
    await tester.pumpAndSettle();

    liveEvents.add(
      const SessionEvent(
        id: 2,
        eventType: 'assistant.message',
        payload: {'text': 'live assistant reply'},
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    expect(
      find.byWidgetPredicate((widget) {
        final key = widget.key;
        return key is ValueKey<String> &&
            key.value.startsWith('timeline-item-entry-appear-');
      }),
      findsOneWidget,
    );
    await tester.pumpAndSettle();

    expect(api.eventSubscriptions, ['sess_1:tok_workspace:0']);
    expect(find.text('initial prompt'), findsOneWidget);
    expect(find.text('live assistant reply'), findsOneWidget);

    await liveEvents.close();
  });

  testWidgets('keeps live session events ordered by numeric event id', (
    tester,
  ) async {
    final liveEvents = StreamController<SessionEvent>();
    final api = FakeDaemonApi(
      liveEvents: liveEvents.stream,
      bootstrap: MobileBootstrap(
        daemonVersion: '0.1.0',
        user: const CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: const <WorkspaceRoot>[],
        sessions: const [
          SessionSummary(
            id: 'sess_1',
            title: 'Mobile migration',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            status: 'running',
            workspacePath: '/home/jhz/projects/agent-dock',
          ),
        ],
        voice: const VoiceConfig(doubaoDirectAvailable: false),
      ),
      snapshot: const SessionSnapshot(
        id: 'sess_1',
        title: 'Mobile migration',
        agentKind: 'codex',
        sourceKind: 'managed',
        runtimeSessionId: 'runtime_1',
        workspacePath: '/home/jhz/projects/agent-dock',
        status: 'running',
        hasMoreHistory: false,
        events: [
          SessionEvent(
            id: 1,
            eventType: 'user.message',
            payload: {'text': 'first'},
          ),
        ],
      ),
    );
    await pumpApp(tester, api: api);

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mobile migration'));
    await tester.pumpAndSettle();

    liveEvents.add(
      const SessionEvent(
        id: 3,
        eventType: 'assistant.message',
        payload: {'text': 'third'},
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    liveEvents.add(
      const SessionEvent(
        id: 2,
        eventType: 'user.message',
        payload: {'text': 'second'},
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    final firstIndex = tester.getTopLeft(find.text('first')).dy;
    final secondIndex = tester.getTopLeft(find.text('second')).dy;
    final thirdIndex = tester.getTopLeft(find.text('third')).dy;

    expect(firstIndex, lessThan(secondIndex));
    expect(secondIndex, lessThan(thirdIndex));

    await liveEvents.close();
  });

  testWidgets('reduced motion keeps new timeline entries static', (
    tester,
  ) async {
    tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(
          disableAnimations: true,
          reduceMotion: true,
        );
    addTearDown(
      tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
    );

    final liveEvents = StreamController<SessionEvent>();
    final api = FakeDaemonApi(
      liveEvents: liveEvents.stream,
      bootstrap: MobileBootstrap(
        daemonVersion: '0.1.0',
        user: const CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: const <WorkspaceRoot>[],
        sessions: const [
          SessionSummary(
            id: 'sess_1',
            title: 'Mobile migration',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            status: 'running',
            workspacePath: '/home/jhz/projects/agent-dock',
          ),
        ],
        voice: const VoiceConfig(doubaoDirectAvailable: false),
      ),
      snapshot: const SessionSnapshot(
        id: 'sess_1',
        title: 'Mobile migration',
        agentKind: 'codex',
        sourceKind: 'managed',
        runtimeSessionId: 'runtime_1',
        workspacePath: '/home/jhz/projects/agent-dock',
        status: 'running',
        hasMoreHistory: false,
        events: [
          SessionEvent(
            id: 1,
            eventType: 'user.message',
            payload: {'text': 'initial prompt'},
          ),
        ],
      ),
    );
    await pumpApp(tester, api: api);

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mobile migration'));
    await tester.pumpAndSettle();

    liveEvents.add(
      const SessionEvent(
        id: 2,
        eventType: 'assistant.message',
        payload: {'text': 'live assistant reply'},
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    expect(
      find.byWidgetPredicate((widget) {
        final key = widget.key;
        return key is ValueKey<String> &&
            key.value.startsWith('timeline-item-entry-appear-');
      }),
      findsNothing,
    );

    await liveEvents.close();
  });

  testWidgets(
    'preserves expanded tool card state when older history is inserted',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Lifecycle expansion',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Lifecycle expansion',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: true,
          events: [
            SessionEvent(
              id: 1,
              eventType: 'tool.call.started',
              payload: {
                'item': {
                  'id': 'cmd-1',
                  'type': 'commandExecution',
                  'command': '/bin/zsh -lc npm test',
                  'status': 'completed',
                  'aggregatedOutput': 'CURRENT TOOL OUTPUT\n',
                  'exitCode': 0,
                },
              },
            ),
          ],
        ),
        olderSnapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Lifecycle expansion',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: [
            SessionEvent(
              id: 0,
              eventType: 'assistant.message',
              payload: {'text': 'older assistant context'},
            ),
          ],
        ),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Lifecycle expansion'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('npm test'));
      await tester.pumpAndSettle();

      expect(find.text('older assistant context'), findsOneWidget);
      expect(find.text('CURRENT TOOL OUTPUT'), findsOneWidget);
    },
  );

  testWidgets('tool lifecycle cards expose stable timeline keys', (
    tester,
  ) async {
    await pumpApp(
      tester,
      api: FakeDaemonApi(
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Stable lifecycle keys',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Stable lifecycle keys',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: [
            SessionEvent(
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
            SessionEvent(
              id: 2,
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
          ],
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stable lifecycle keys'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('timeline-item-commandExecution:cmd-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('timeline-item-fileChange:patch-1')),
      findsOneWidget,
    );
  });

  testWidgets(
    'shows a new update chip instead of auto-scrolling when the user is away from bottom',
    (tester) async {
      final liveEvents = StreamController<SessionEvent>();
      final initialEvents = List<SessionEvent>.generate(18, (index) {
        final id = index + 1;
        return SessionEvent(
          id: id,
          eventType: id.isEven ? 'assistant.message' : 'user.message',
          payload: {'text': 'seed $id'},
        );
      });
      final api = FakeDaemonApi(
        liveEvents: liveEvents.stream,
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Mobile migration',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: SessionSnapshot(
          id: 'sess_1',
          title: 'Mobile migration',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: initialEvents,
        ),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mobile migration'));
      await tester.pumpAndSettle();

      await tester.drag(find.byType(ListView).first, const Offset(0, 400));
      await tester.pumpAndSettle();

      liveEvents.add(
        const SessionEvent(
          id: 19,
          eventType: 'assistant.message',
          payload: {'text': 'late reply'},
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('1 new update'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('new-updates-chip-scale')),
        findsOneWidget,
      );
      expect(find.textContaining('late reply'), findsNothing);

      await tester.tap(find.text('1 new update'));
      await tester.pumpAndSettle();

      expect(find.textContaining('late reply'), findsOneWidget);

      await liveEvents.close();
    },
  );

  testWidgets(
    'assistant streaming away from bottom increments the new updates chip only once',
    (tester) async {
      final liveEvents = StreamController<SessionEvent>();
      final initialEvents = List<SessionEvent>.generate(18, (index) {
        final id = index + 1;
        return SessionEvent(
          id: id,
          eventType: id.isEven ? 'assistant.message' : 'user.message',
          payload: {'text': 'seed $id'},
        );
      });
      final api = FakeDaemonApi(
        liveEvents: liveEvents.stream,
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Streaming updates',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: SessionSnapshot(
          id: 'sess_1',
          title: 'Streaming updates',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: initialEvents,
        ),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Streaming updates'));
      await tester.pumpAndSettle();

      await tester.drag(find.byType(ListView).first, const Offset(0, 400));
      await tester.pumpAndSettle();

      liveEvents.add(
        const SessionEvent(
          id: 19,
          eventType: 'assistant.message',
          payload: {'text': ' first delta'},
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));

      liveEvents.add(
        const SessionEvent(
          id: 20,
          eventType: 'assistant.message',
          payload: {'text': ' second delta'},
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.text('1 new update'), findsOneWidget);
      expect(find.text('2 new updates'), findsNothing);

      await liveEvents.close();
    },
  );

  testWidgets('reduced motion keeps the new updates chip static', (
    tester,
  ) async {
    tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(
          disableAnimations: true,
          reduceMotion: true,
        );
    addTearDown(
      tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
    );

    final liveEvents = StreamController<SessionEvent>();
    final initialEvents = List<SessionEvent>.generate(18, (index) {
      final id = index + 1;
      return SessionEvent(
        id: id,
        eventType: id.isEven ? 'assistant.message' : 'user.message',
        payload: {'text': 'seed $id'},
      );
    });
    final api = FakeDaemonApi(
      liveEvents: liveEvents.stream,
      bootstrap: MobileBootstrap(
        daemonVersion: '0.1.0',
        user: const CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: const <WorkspaceRoot>[],
        sessions: const [
          SessionSummary(
            id: 'sess_1',
            title: 'Mobile migration',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            status: 'running',
            workspacePath: '/home/jhz/projects/agent-dock',
          ),
        ],
        voice: const VoiceConfig(doubaoDirectAvailable: false),
      ),
      snapshot: SessionSnapshot(
        id: 'sess_1',
        title: 'Mobile migration',
        agentKind: 'codex',
        sourceKind: 'managed',
        runtimeSessionId: 'runtime_1',
        workspacePath: '/home/jhz/projects/agent-dock',
        status: 'running',
        hasMoreHistory: false,
        events: initialEvents,
      ),
    );
    await pumpApp(tester, api: api);

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mobile migration'));
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView).first, const Offset(0, 800));
    await tester.pumpAndSettle();

    liveEvents.add(
      const SessionEvent(
        id: 19,
        eventType: 'assistant.message',
        payload: {'text': 'late reply'},
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('1 new update'), findsOneWidget);
    expect(find.byKey(const ValueKey('new-updates-chip-scale')), findsNothing);

    await liveEvents.close();
  });

  testWidgets('automatically retries stream errors from the latest event id', (
    tester,
  ) async {
    final retryEvents = StreamController<SessionEvent>();
    final api = FakeDaemonApi(
      liveEventStreams: [
        Stream<SessionEvent>.error(Exception('socket closed')),
        retryEvents.stream,
      ],
      bootstrap: MobileBootstrap(
        daemonVersion: '0.1.0',
        user: const CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: const <WorkspaceRoot>[],
        sessions: const [
          SessionSummary(
            id: 'sess_1',
            title: 'Mobile migration',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            status: 'running',
            workspacePath: '/home/jhz/projects/agent-dock',
          ),
        ],
        voice: const VoiceConfig(doubaoDirectAvailable: false),
      ),
      snapshot: const SessionSnapshot(
        id: 'sess_1',
        title: 'Mobile migration',
        agentKind: 'codex',
        sourceKind: 'managed',
        runtimeSessionId: 'runtime_1',
        workspacePath: '/home/jhz/projects/agent-dock',
        status: 'running',
        hasMoreHistory: false,
        events: [
          SessionEvent(
            id: 5,
            eventType: 'user.message',
            payload: {'text': 'initial prompt'},
          ),
        ],
      ),
    );
    await pumpApp(tester, api: api);

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mobile migration'));
    await tester.pumpAndSettle();

    expect(find.text('Reconnecting to event stream...'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
    expect(
      find.byKey(const ValueKey('stream-reconnecting-progress-sweep')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('session-status-pill')),
        matching: find.text('reconnecting'),
      ),
      findsOneWidget,
    );
    final reconnectingDot = tester.widget<Container>(
      find.byKey(const ValueKey('session-status-pill-dot')),
    );
    final reconnectingDotDecoration =
        reconnectingDot.decoration! as BoxDecoration;
    expect(reconnectingDotDecoration.color, const Color(0xFFF0B84A));
    final reconnectingDotOpacity = tester.widget<Opacity>(
      find.byKey(const ValueKey('session-status-pill-dot-opacity')),
    );
    expect(reconnectingDotOpacity.opacity, 1);

    await tester.pump(const Duration(milliseconds: 700));

    final dimmedReconnectingDotOpacity = tester.widget<Opacity>(
      find.byKey(const ValueKey('session-status-pill-dot-opacity')),
    );
    expect(dimmedReconnectingDotOpacity.opacity, 0.24);

    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    retryEvents.add(
      const SessionEvent(
        id: 6,
        eventType: 'assistant.message',
        payload: {'text': 'reconnected reply'},
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('stream-status-banner-collapse')),
      findsOneWidget,
    );
    expect(find.text('Reconnecting to event stream...'), findsOneWidget);

    await tester.pumpAndSettle();

    expect(api.eventSubscriptions, [
      'sess_1:tok_workspace:0',
      'sess_1:tok_workspace:5',
    ]);
    expect(find.text('reconnected reply'), findsOneWidget);
    expect(find.text('Reconnecting to event stream...'), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('session-status-pill')),
        matching: find.text('running'),
      ),
      findsOneWidget,
    );

    await retryEvents.close();
  });

  testWidgets('shows offline state for socket event stream errors', (
    tester,
  ) async {
    await pumpApp(
      tester,
      api: FakeDaemonApi(
        liveEvents: Stream<SessionEvent>.error(
          const SocketException('Network is unreachable'),
        ),
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Mobile migration',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Mobile migration',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: [
            SessionEvent(
              id: 5,
              eventType: 'user.message',
              payload: {'text': 'initial prompt'},
            ),
          ],
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mobile migration'));
    await tester.pumpAndSettle();

    expect(find.text('Offline. Waiting for network...'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
    expect(find.text('Reconnecting to event stream...'), findsNothing);
    expect(
      find.byKey(const ValueKey('stream-reconnecting-progress-sweep')),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('session-status-pill')),
        matching: find.text('offline'),
      ),
      findsOneWidget,
    );
    final offlineDot = tester.widget<Container>(
      find.byKey(const ValueKey('session-status-pill-dot')),
    );
    final offlineDotDecoration = offlineDot.decoration! as BoxDecoration;
    expect(offlineDotDecoration.color, const Color(0xFFF0B84A));
  });

  testWidgets('shows still reconnecting after repeated event stream failures', (
    tester,
  ) async {
    Stream<SessionEvent> socketClosedStream(String label) =>
        Stream<SessionEvent>.multi((controller) {
          controller.addError(Exception(label));
          controller.close();
        });
    final api = FakeDaemonApi(
      liveEventStreams: [
        socketClosedStream('socket closed 1'),
        socketClosedStream('socket closed 2'),
        socketClosedStream('socket closed 3'),
      ],
      bootstrap: MobileBootstrap(
        daemonVersion: '0.1.0',
        user: const CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: const <WorkspaceRoot>[],
        sessions: const [
          SessionSummary(
            id: 'sess_1',
            title: 'Mobile migration',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            status: 'running',
            workspacePath: '/home/jhz/projects/agent-dock',
          ),
        ],
        voice: const VoiceConfig(doubaoDirectAvailable: false),
      ),
      snapshot: const SessionSnapshot(
        id: 'sess_1',
        title: 'Mobile migration',
        agentKind: 'codex',
        sourceKind: 'managed',
        runtimeSessionId: 'runtime_1',
        workspacePath: '/home/jhz/projects/agent-dock',
        status: 'running',
        hasMoreHistory: false,
        events: [
          SessionEvent(
            id: 5,
            eventType: 'user.message',
            payload: {'text': 'initial prompt'},
          ),
        ],
      ),
    );
    await pumpApp(tester, api: api);

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mobile migration'));
    await tester.pumpAndSettle();

    expect(find.text('Reconnecting to event stream...'), findsOneWidget);
    expect(find.text('Still reconnecting...'), findsNothing);
    expect(find.text('Retry'), findsNothing);

    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(api.eventSubscriptions, [
      'sess_1:tok_workspace:0',
      'sess_1:tok_workspace:5',
      'sess_1:tok_workspace:5',
    ]);
    expect(find.text('Still reconnecting...'), findsOneWidget);
    expect(find.text('Reconnecting to event stream...'), findsNothing);
    expect(find.text('Reconnect'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('session-status-pill')),
        matching: find.text('reconnecting'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('event stream retries use exponential backoff delays', (
    tester,
  ) async {
    final api = FakeDaemonApi(
      liveEventStreams: [
        Stream<SessionEvent>.error(Exception('socket closed 1')),
        Stream<SessionEvent>.error(Exception('socket closed 2')),
        Stream<SessionEvent>.error(Exception('socket closed 3')),
      ],
      bootstrap: MobileBootstrap(
        daemonVersion: '0.1.0',
        user: const CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: const <WorkspaceRoot>[],
        sessions: const [
          SessionSummary(
            id: 'sess_1',
            title: 'Mobile migration',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            status: 'running',
            workspacePath: '/home/jhz/projects/agent-dock',
          ),
        ],
        voice: const VoiceConfig(doubaoDirectAvailable: false),
      ),
      snapshot: const SessionSnapshot(
        id: 'sess_1',
        title: 'Mobile migration',
        agentKind: 'codex',
        sourceKind: 'managed',
        runtimeSessionId: 'runtime_1',
        workspacePath: '/home/jhz/projects/agent-dock',
        status: 'running',
        hasMoreHistory: false,
        events: [
          SessionEvent(
            id: 5,
            eventType: 'user.message',
            payload: {'text': 'initial prompt'},
          ),
        ],
      ),
    );
    await pumpApp(tester, api: api);

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mobile migration'));
    await tester.pumpAndSettle();

    expect(api.eventSubscriptions, [
      'sess_1:tok_workspace:0',
      'sess_1:tok_workspace:5',
    ]);

    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(api.eventSubscriptions, [
      'sess_1:tok_workspace:0',
      'sess_1:tok_workspace:5',
    ]);
  });

  testWidgets('resuming the app reconnects the session event stream', (
    tester,
  ) async {
    var firstSubscriptionCanceled = false;
    final resumedEvents = StreamController<SessionEvent>();
    final initialEvents = StreamController<SessionEvent>(
      onCancel: () {
        firstSubscriptionCanceled = true;
      },
    );
    final api = FakeDaemonApi(
      liveEventStreams: [initialEvents.stream, resumedEvents.stream],
      bootstrap: const MobileBootstrap(
        daemonVersion: '0.1.0',
        user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: <WorkspaceRoot>[],
        sessions: [
          SessionSummary(
            id: 'sess_1',
            title: 'Mobile migration',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            status: 'running',
            workspacePath: '/home/jhz/projects/agent-dock',
          ),
        ],
        voice: VoiceConfig(doubaoDirectAvailable: false),
      ),
      snapshot: const SessionSnapshot(
        id: 'sess_1',
        title: 'Mobile migration',
        agentKind: 'codex',
        sourceKind: 'managed',
        runtimeSessionId: 'runtime_1',
        workspacePath: '/home/jhz/projects/agent-dock',
        status: 'running',
        hasMoreHistory: false,
        events: [
          SessionEvent(
            id: 5,
            eventType: 'user.message',
            payload: {'text': 'initial prompt'},
          ),
        ],
      ),
    );
    await pumpApp(tester, api: api);

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mobile migration'));
    await tester.pumpAndSettle();

    expect(api.eventSubscriptions, ['sess_1:tok_workspace:0']);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();

    expect(firstSubscriptionCanceled, isTrue);
    expect(api.eventSubscriptions, ['sess_1:tok_workspace:0']);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    resumedEvents.add(
      const SessionEvent(
        id: 6,
        eventType: 'assistant.message',
        payload: {'text': 'reply after resume'},
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(api.eventSubscriptions, [
      'sess_1:tok_workspace:0',
      'sess_1:tok_workspace:5',
    ]);
    expect(find.text('reply after resume'), findsOneWidget);
    expect(find.text('Connecting to event stream...'), findsNothing);
  });

  testWidgets(
    'stream repair falls back to snapshot when reconnect continuity is lost',
    (tester) async {
      Stream<SessionEvent> socketClosedStream(String label) =>
          Stream<SessionEvent>.multi((controller) {
            controller.addError(Exception(label));
            controller.close();
          });
      final api = FakeDaemonApi(
        liveEventStreams: [
          socketClosedStream('socket closed 1'),
          socketClosedStream('socket closed 2'),
          const Stream<SessionEvent>.empty(),
        ],
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Repair me',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/tmp/workspace',
          status: 'running',
          hasMoreHistory: false,
          events: [
            SessionEvent(
              id: 7,
              eventType: 'assistant.message',
              payload: {'text': 'repair snapshot'},
            ),
          ],
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: SessionDetailPage(
            api: api,
            daemonUrl: Uri.parse('https://daemon.example.com'),
            currentUserId: 'usr_workspace',
            session: const SessionSummary(
              id: 'sess_1',
              title: 'Repair me',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/tmp/workspace',
            ),
            token: 'tok_workspace',
            voice: const VoiceConfig(doubaoDirectAvailable: false),
            initialSnapshot: SessionSnapshot(
              id: 'sess_1',
              title: 'Repair me',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              workspacePath: '/tmp/workspace',
              status: 'running',
              hasMoreHistory: false,
              events: const [
                SessionEvent(
                  id: 5,
                  eventType: 'assistant.message',
                  payload: {'text': 'stale cached reply'},
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('stale cached reply'), findsOneWidget);
      expect(find.text('repair snapshot'), findsNothing);

      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();

      expect(api.eventSubscriptions.take(3), [
        'sess_1:tok_workspace:5',
        'sess_1:tok_workspace:5',
        'sess_1:tok_workspace:5',
      ]);
      expect(api.eventSubscriptions.length, greaterThanOrEqualTo(4));
      expect(api.eventSubscriptions[3], 'sess_1:tok_workspace:7');
      expect(api.snapshotRequests, isNotEmpty);
      expect(find.textContaining('repair snapshot'), findsOneWidget);
    },
  );

  testWidgets(
    'session resync event repairs the stream from a fresh snapshot',
    (tester) async {
      final api = FakeDaemonApi(
        liveEventStreams: [
          Stream<SessionEvent>.fromIterable(const [
            SessionEvent(
              id: 7,
              eventType: 'session.resync.required',
              payload: {
                'reason': 'cursor_ahead',
                'requestedAfter': 99,
                'latestEventId': 7,
              },
            ),
          ]),
          const Stream<SessionEvent>.empty(),
        ],
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Repair me',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/tmp/workspace',
          status: 'running',
          hasMoreHistory: false,
          events: [
            SessionEvent(
              id: 7,
              eventType: 'assistant.message',
              payload: {'text': 'repair snapshot'},
            ),
          ],
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: SessionDetailPage(
            api: api,
            daemonUrl: Uri.parse('https://daemon.example.com'),
            currentUserId: 'usr_workspace',
            session: const SessionSummary(
              id: 'sess_1',
              title: 'Repair me',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/tmp/workspace',
            ),
            token: 'tok_workspace',
            voice: const VoiceConfig(doubaoDirectAvailable: false),
            initialSnapshot: const SessionSnapshot(
              id: 'sess_1',
              title: 'Repair me',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              workspacePath: '/tmp/workspace',
              status: 'running',
              hasMoreHistory: false,
              events: [
                SessionEvent(
                  id: 5,
                  eventType: 'assistant.message',
                  payload: {'text': 'stale cached reply'},
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      expect(api.eventSubscriptions.first, 'sess_1:tok_workspace:5');

      await tester.pumpAndSettle();

      expect(api.snapshotRequests, isNotEmpty);
      expect(api.snapshotRequests.first, 'sess_1:tok_workspace:null');
      expect(find.textContaining('repair snapshot'), findsOneWidget);

      expect(api.eventSubscriptions, ['sess_1:tok_workspace:5', 'sess_1:tok_workspace:7']);
      expect(find.textContaining('repair snapshot'), findsOneWidget);
    },
  );

  testWidgets('reduced motion keeps the reconnecting banner static', (
    tester,
  ) async {
    tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(
          disableAnimations: true,
          reduceMotion: true,
        );
    addTearDown(
      tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
    );

    await pumpApp(
      tester,
      api: FakeDaemonApi(
        liveEvents: Stream<SessionEvent>.error(Exception('socket closed')),
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Mobile migration',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Mobile migration',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: [
            SessionEvent(
              id: 5,
              eventType: 'user.message',
              payload: {'text': 'initial prompt'},
            ),
          ],
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mobile migration'));
    await tester.pumpAndSettle();

    expect(find.text('Reconnecting to event stream...'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('stream-reconnecting-progress-sweep')),
      findsNothing,
    );
    final reconnectingDotOpacity = tester.widget<Opacity>(
      find.byKey(const ValueKey('session-status-pill-dot-opacity')),
    );
    expect(reconnectingDotOpacity.opacity, 1);

    await tester.pump(const Duration(milliseconds: 700));

    final steadyReconnectingDotOpacity = tester.widget<Opacity>(
      find.byKey(const ValueKey('session-status-pill-dot-opacity')),
    );
    expect(steadyReconnectingDotOpacity.opacity, 1);
  });

  testWidgets('reduced motion keeps the running status dot static', (
    tester,
  ) async {
    tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(
          disableAnimations: true,
          reduceMotion: true,
        );
    addTearDown(
      tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
    );

    await pumpApp(
      tester,
      api: FakeDaemonApi(
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Mobile migration',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Mobile migration',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: [
            SessionEvent(
              id: 5,
              eventType: 'user.message',
              payload: {'text': 'initial prompt'},
            ),
          ],
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mobile migration'));
    await tester.pumpAndSettle();

    final runningDotOpacity = tester.widget<Opacity>(
      find.byKey(const ValueKey('session-status-pill-dot-opacity')),
    );
    expect(runningDotOpacity.opacity, 1);

    await tester.pump(const Duration(milliseconds: 700));

    final steadyRunningDotOpacity = tester.widget<Opacity>(
      find.byKey(const ValueKey('session-status-pill-dot-opacity')),
    );
    expect(steadyRunningDotOpacity.opacity, 1);
  });

  testWidgets(
    'shows forbidden state for 403 event stream errors without logging out',
    (tester) async {
      final voice = FakeVoiceInputController(transcript: 'continue by voice');
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          liveEvents: Stream<SessionEvent>.error(
            const DaemonApiException(
              statusCode: 403,
              code: 'FORBIDDEN',
              message: 'Forbidden',
            ),
          ),
          bootstrap: MobileBootstrap(
            daemonVersion: '0.1.0',
            user: const CurrentUser(
              id: 'usr_workspace',
              displayName: 'Workspace',
            ),
            roots: const <WorkspaceRoot>[],
            sessions: const [
              SessionSummary(
                id: 'sess_1',
                title: 'Restricted stream',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'running',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: VoiceConfig(
              doubaoDirectAvailable: true,
              providerCredentials: _providerVoiceCredentials,
            ),
          ),
          snapshot: const SessionSnapshot(
            id: 'sess_1',
            title: 'Restricted stream',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            workspacePath: '/home/jhz/projects/agent-dock',
            status: 'running',
            hasMoreHistory: false,
            events: [
              SessionEvent(
                id: 5,
                eventType: 'user.message',
                payload: {'text': 'initial prompt'},
              ),
            ],
          ),
        ),
        voiceInputController: voice,
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restricted stream'));
      await tester.pumpAndSettle();

      expect(
        find.text('You no longer have access to this session.'),
        findsOneWidget,
      );
      expect(find.text('Back to Sessions'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
      expect(find.text('Event stream disconnected'), findsNothing);
      expect(find.text('initial prompt'), findsOneWidget);
      expect(find.text('Unlock workspace'), findsNothing);

      final messageField = tester.widget<TextField>(
        find.byType(TextField).last,
      );
      expect(messageField.enabled, isFalse);

      final attachButton = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.add_photo_alternate_outlined),
      );
      expect(attachButton.onPressed, isNull);

      final voiceButton = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.mic_none_rounded),
      );
      expect(voiceButton.onPressed, isNull);

      await tester.tap(find.text('Back to Sessions'));
      await tester.pumpAndSettle();

      expect(find.text('Sessions'), findsOneWidget);
      expect(find.text('Unlock workspace'), findsNothing);
    },
  );

  testWidgets(
    'shows forbidden state for 403 snapshot errors without logging out',
    (tester) async {
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: const MobileBootstrap(
            daemonVersion: '0.1.0',
            user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
            roots: <WorkspaceRoot>[],
            sessions: [
              SessionSummary(
                id: 'sess_1',
                title: 'Restricted snapshot',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'running',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: VoiceConfig(doubaoDirectAvailable: false),
          ),
          snapshotError: const DaemonApiException(
            statusCode: 403,
            code: 'FORBIDDEN',
            message: 'Forbidden',
          ),
        ),
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restricted snapshot'));
      await tester.pumpAndSettle();

      expect(
        find.text('You no longer have access to this session.'),
        findsOneWidget,
      );
      expect(find.text('Back to Sessions'), findsOneWidget);
      expect(find.text('Unlock workspace'), findsNothing);

      final messageField = tester.widget<TextField>(
        find.byType(TextField).last,
      );
      expect(messageField.enabled, isFalse);

      final attachButton = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.add_photo_alternate_outlined),
      );
      expect(attachButton.onPressed, isNull);
    },
  );

  testWidgets(
    'shows an inline offline banner instead of a generic error page for initial snapshot network failures',
    (tester) async {
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: const MobileBootstrap(
            daemonVersion: '0.1.0',
            user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
            roots: <WorkspaceRoot>[],
            sessions: [
              SessionSummary(
                id: 'sess_1',
                title: 'Offline snapshot',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'running',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: VoiceConfig(doubaoDirectAvailable: false),
          ),
          snapshotError: const SocketException('Network is unreachable'),
        ),
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Offline snapshot'));
      await tester.pumpAndSettle();

      expect(find.text('Offline. Waiting for network...'), findsOneWidget);
      expect(find.textContaining('Could not load session:'), findsNothing);
      expect(find.byType(TextField).last, findsOneWidget);
    },
  );

  testWidgets('routes back to login for 401 initial snapshot errors', (
    tester,
  ) async {
    final storage = MemoryAuthStorage();
    await pumpApp(
      tester,
      api: FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: <WorkspaceRoot>[],
          sessions: [
            SessionSummary(
              id: 'sess_1',
              title: 'Expired snapshot',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshotError: const DaemonApiException(
          statusCode: 401,
          code: 'UNAUTHORIZED',
          message: 'Unauthorized',
        ),
      ),
      storage: storage,
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Expired snapshot'));
    await tester.pumpAndSettle();

    expect(storage.didClear, isTrue);
    expect(storage.profile, isNull);
    expect(find.text('Unlock workspace'), findsOneWidget);
    expect(find.text('Expired snapshot'), findsNothing);
    expect(find.text('Session expired. Sign in again.'), findsOneWidget);
    expect(find.textContaining('Could not load session:'), findsNothing);
  });

  testWidgets('routes back to login for 401 event stream errors', (
    tester,
  ) async {
    final storage = MemoryAuthStorage();
    await pumpApp(
      tester,
      api: FakeDaemonApi(
        liveEvents: Stream<SessionEvent>.error(
          const DaemonApiException(
            statusCode: 401,
            code: 'UNAUTHORIZED',
            message: 'Unauthorized',
          ),
        ),
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: <WorkspaceRoot>[],
          sessions: [
            SessionSummary(
              id: 'sess_1',
              title: 'Expired stream',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Expired stream',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: [
            SessionEvent(
              id: 5,
              eventType: 'user.message',
              payload: {'text': 'initial prompt'},
            ),
          ],
        ),
      ),
      storage: storage,
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Expired stream'));
    await tester.pumpAndSettle();

    expect(storage.didClear, isTrue);
    expect(storage.profile, isNull);
    expect(find.text('Unlock workspace'), findsOneWidget);
    expect(find.text('Expired stream'), findsNothing);
    expect(find.text('Session expired. Sign in again.'), findsOneWidget);
    expect(
      find.text('You do not have access to this session stream.'),
      findsNothing,
    );
  });

  testWidgets(
    'shows a disabled not-configured voice state when voice is unavailable',
    (tester) async {
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: MobileBootstrap(
            daemonVersion: '0.1.0',
            user: const CurrentUser(
              id: 'usr_workspace',
              displayName: 'Workspace',
            ),
            roots: const <WorkspaceRoot>[],
            sessions: const [
              SessionSummary(
                id: 'sess_1',
                title: 'Mobile migration',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'running',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: const VoiceConfig(doubaoDirectAvailable: false),
          ),
        ),
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mobile migration'));
      await tester.pumpAndSettle();

      expect(find.text('Voice input is not configured'), findsOneWidget);
      expect(find.byTooltip('Voice input unavailable'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.mic_none_rounded),
            )
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets(
    'inserts voice transcript into the composer when voice is available',
    (tester) async {
      final voice = FakeVoiceInputController(transcript: 'continue by voice');
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: MobileBootstrap(
            daemonVersion: '0.1.0',
            user: const CurrentUser(
              id: 'usr_workspace',
              displayName: 'Workspace',
            ),
            roots: const <WorkspaceRoot>[],
            sessions: const [
              SessionSummary(
                id: 'sess_1',
                title: 'Mobile migration',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'running',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: VoiceConfig(
              doubaoDirectAvailable: true,
              providerCredentials: _providerVoiceCredentials,
            ),
          ),
        ),
        voiceInputController: voice,
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mobile migration'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Voice input'));
      await tester.pump();
      expect(find.text('Connecting Doubao voice...'), findsOneWidget);
      await tester.pumpAndSettle();

      expect(voice.startCount, 1);
      expect(
        find.widgetWithText(TextField, 'continue by voice'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'connecting voice input shows a spinner on the microphone button',
    (tester) async {
      final voice = FakeVoiceInputController(
        transcript: 'continue by voice',
        phaseDelayMs: 20,
      );
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: MobileBootstrap(
            daemonVersion: '0.1.0',
            user: const CurrentUser(
              id: 'usr_workspace',
              displayName: 'Workspace',
            ),
            roots: const <WorkspaceRoot>[],
            sessions: const [
              SessionSummary(
                id: 'sess_1',
                title: 'Mobile migration',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'running',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: VoiceConfig(
              doubaoDirectAvailable: true,
              providerCredentials: _providerVoiceCredentials,
            ),
          ),
        ),
        voiceInputController: voice,
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mobile migration'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Voice input'));
      await tester.pump();

      expect(find.text('Connecting Doubao voice...'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('composer-voice-connecting-spinner')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('composer-voice-listening-ring')),
        findsNothing,
      );

      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'reduced motion keeps the active voice indicator static in the composer',
    (tester) async {
      tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(
            disableAnimations: true,
            reduceMotion: true,
          );
      addTearDown(
        tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );

      final voice = FakeVoiceInputController(
        transcript: 'continue by voice',
        phaseDelayMs: 20,
      );
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: MobileBootstrap(
            daemonVersion: '0.1.0',
            user: const CurrentUser(
              id: 'usr_workspace',
              displayName: 'Workspace',
            ),
            roots: const <WorkspaceRoot>[],
            sessions: const [
              SessionSummary(
                id: 'sess_1',
                title: 'Mobile migration',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'running',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: const VoiceConfig(doubaoDirectAvailable: true),
          ),
        ),
        voiceInputController: voice,
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mobile migration'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Voice input'));
      await tester.pump();

      expect(find.text('Connecting Doubao voice...'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('composer-voice-active-static-icon')),
        findsOneWidget,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);

      await tester.pump(const Duration(milliseconds: 25));

      expect(find.text('Listening...'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('composer-voice-listening-ring')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('composer-voice-active-static-icon')),
        findsOneWidget,
      );

      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'listening voice input shows a breathing ring around the mic button',
    (tester) async {
      final voice = FakeVoiceInputController(
        transcript: 'continue by voice',
        phaseDelayMs: 20,
      );
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: MobileBootstrap(
            daemonVersion: '0.1.0',
            user: const CurrentUser(
              id: 'usr_workspace',
              displayName: 'Workspace',
            ),
            roots: const <WorkspaceRoot>[],
            sessions: const [
              SessionSummary(
                id: 'sess_1',
                title: 'Mobile migration',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'running',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: const VoiceConfig(doubaoDirectAvailable: true),
          ),
        ),
        voiceInputController: voice,
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mobile migration'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Voice input'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 25));

      expect(find.text('Listening...'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('composer-voice-listening-ring')),
        findsOneWidget,
      );

      await tester.pumpAndSettle();
    },
  );

  testWidgets('leaving Chat cancels active voice input', (tester) async {
    final voice = CancelableFakeVoiceInputController();
    await pumpApp(
      tester,
      api: FakeDaemonApi(
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Voice session',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: true),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Voice session',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: <SessionEvent>[],
        ),
      ),
      voiceInputController: voice,
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Voice session'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Voice input'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 25));

    expect(find.text('Listening...'), findsOneWidget);
    expect(voice.cancelCount, 0);

    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(voice.cancelCount, 1);
  });

  testWidgets(
    'listening voice input shows a subtle waveform in the status row',
    (tester) async {
      final voice = FakeVoiceInputController(
        transcript: 'continue by voice',
        phaseDelayMs: 20,
      );
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: MobileBootstrap(
            daemonVersion: '0.1.0',
            user: const CurrentUser(
              id: 'usr_workspace',
              displayName: 'Workspace',
            ),
            roots: const <WorkspaceRoot>[],
            sessions: const [
              SessionSummary(
                id: 'sess_1',
                title: 'Mobile migration',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'running',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: const VoiceConfig(doubaoDirectAvailable: true),
          ),
        ),
        voiceInputController: voice,
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mobile migration'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Voice input'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 25));

      expect(find.text('Listening...'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('composer-voice-status-waveform')),
        findsOneWidget,
      );

      await tester.pumpAndSettle();
    },
  );

  testWidgets('shows finishing transcript while voice input is stopping', (
    tester,
  ) async {
    final voice = FakeVoiceInputController(
      transcript: 'continue by voice',
      phaseDelayMs: 20,
    );
    await pumpApp(
      tester,
      api: FakeDaemonApi(
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Mobile migration',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: true),
        ),
      ),
      voiceInputController: voice,
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mobile migration'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Voice input'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 25));
    await tester.pump(const Duration(milliseconds: 25));
    expect(find.text('Finishing transcript...'), findsOneWidget);
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextField, 'continue by voice'), findsOneWidget);
  });

  testWidgets(
    'stopping voice input freezes the status waveform and shows an inline spinner',
    (tester) async {
      final voice = FakeVoiceInputController(
        transcript: 'continue by voice',
        phaseDelayMs: 20,
      );
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: MobileBootstrap(
            daemonVersion: '0.1.0',
            user: const CurrentUser(
              id: 'usr_workspace',
              displayName: 'Workspace',
            ),
            roots: const <WorkspaceRoot>[],
            sessions: const [
              SessionSummary(
                id: 'sess_1',
                title: 'Mobile migration',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'running',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: const VoiceConfig(doubaoDirectAvailable: true),
          ),
        ),
        voiceInputController: voice,
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mobile migration'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Voice input'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 25));
      await tester.pump(const Duration(milliseconds: 25));

      expect(find.text('Finishing transcript...'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('composer-voice-status-waveform')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('composer-voice-status-spinner')),
        findsOneWidget,
      );

      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'reduced motion keeps the voice status waveform static and replaces the stopping spinner',
    (tester) async {
      tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(
            disableAnimations: true,
            reduceMotion: true,
          );
      addTearDown(
        tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );

      final voice = FakeVoiceInputController(
        transcript: 'continue by voice',
        phaseDelayMs: 20,
      );
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: MobileBootstrap(
            daemonVersion: '0.1.0',
            user: const CurrentUser(
              id: 'usr_workspace',
              displayName: 'Workspace',
            ),
            roots: const <WorkspaceRoot>[],
            sessions: const [
              SessionSummary(
                id: 'sess_1',
                title: 'Mobile migration',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'running',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: const VoiceConfig(doubaoDirectAvailable: true),
          ),
        ),
        voiceInputController: voice,
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mobile migration'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Voice input'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 25));

      expect(find.text('Listening...'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('composer-voice-status-waveform')),
        findsOneWidget,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);

      await tester.pump(const Duration(milliseconds: 25));

      expect(find.text('Finishing transcript...'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('composer-voice-status-waveform')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('composer-voice-status-static-spinner')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('composer-voice-status-spinner')),
        findsNothing,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);

      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'disables send while voice input is connecting listening or stopping',
    (tester) async {
      final voice = FakeVoiceInputController(
        transcript: 'continue by voice',
        phaseDelayMs: 20,
      );
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: MobileBootstrap(
            daemonVersion: '0.1.0',
            user: const CurrentUser(
              id: 'usr_workspace',
              displayName: 'Workspace',
            ),
            roots: const <WorkspaceRoot>[],
            sessions: const [
              SessionSummary(
                id: 'sess_1',
                title: 'Mobile migration',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'running',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: const VoiceConfig(doubaoDirectAvailable: true),
          ),
        ),
        voiceInputController: voice,
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mobile migration'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Message the agent'),
        'queued while voice runs',
      );

      await tester.tap(find.byTooltip('Voice input'));
      await tester.pump();

      var sendButton = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.arrow_upward_rounded),
      );
      expect(sendButton.onPressed, isNull);
      expect(find.text('Connecting Doubao voice...'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 25));

      sendButton = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.arrow_upward_rounded),
      );
      expect(sendButton.onPressed, isNull);
      expect(find.text('Listening...'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 25));

      sendButton = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.arrow_upward_rounded),
      );
      expect(sendButton.onPressed, isNull);
      expect(find.text('Finishing transcript...'), findsOneWidget);

      await tester.pumpAndSettle();
    },
  );

  testWidgets('tapping the microphone again cancels active voice input', (
    tester,
  ) async {
    final voice = CancelableFakeVoiceInputController();
    await pumpApp(
      tester,
      api: FakeDaemonApi(
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Mobile migration',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: true),
        ),
      ),
      voiceInputController: voice,
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mobile migration'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Voice input'));
    await tester.pump();
    expect(find.text('Connecting Doubao voice...'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 30));
    expect(find.text('Listening...'), findsOneWidget);

    await tester.tap(find.byTooltip('Voice input'));

    final cancelFadeFinder = find.byKey(
      const ValueKey('composer-voice-cancel-fade'),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    expect(cancelFadeFinder, findsOneWidget);
    expect(
      tester.widget<FadeTransition>(cancelFadeFinder).opacity.value,
      lessThan(1),
    );

    await tester.pumpAndSettle();

    expect(voice.cancelCount, 1);
    expect(find.text('Listening...'), findsNothing);
    expect(find.text('continue by voice'), findsNothing);
  });

  testWidgets('reduced motion keeps voice cancel status removal static', (
    tester,
  ) async {
    tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(
          disableAnimations: true,
          reduceMotion: true,
        );
    addTearDown(
      tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
    );

    final voice = CancelableFakeVoiceInputController();
    await pumpApp(
      tester,
      api: FakeDaemonApi(
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Mobile migration',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: true),
        ),
      ),
      voiceInputController: voice,
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mobile migration'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Voice input'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    expect(find.text('Listening...'), findsOneWidget);

    await tester.tap(find.byTooltip('Voice input'));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('composer-voice-cancel-fade')),
      findsNothing,
    );
    expect(find.text('Listening...'), findsNothing);

    await tester.pumpAndSettle();

    expect(voice.cancelCount, 1);
  });

  testWidgets('shows a clear microphone permission error for voice input', (
    tester,
  ) async {
    final voice = FakeVoiceInputController(
      error: 'Microphone permission denied',
    );
    await pumpApp(
      tester,
      api: FakeDaemonApi(
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Mobile migration',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: true),
        ),
      ),
      voiceInputController: voice,
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mobile migration'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Voice input'));
    await tester.pumpAndSettle();

    expect(
      find.text('Microphone permission denied. Enable it in settings.'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('composer-voice-permission-warning-icon')),
      findsOneWidget,
    );
  });

  testWidgets('shows provider voice errors and allows retry', (tester) async {
    final voice = FakeVoiceInputController(error: 'quota exceeded');
    await pumpApp(
      tester,
      api: FakeDaemonApi(
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Mobile migration',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: true),
        ),
      ),
      voiceInputController: voice,
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mobile migration'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Voice input'));
    await tester.pumpAndSettle();

    expect(find.text('quota exceeded'), findsOneWidget);
    expect(find.text('Retry voice'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Retry voice'));
    await tester.pumpAndSettle();
    expect(voice.startCount, 2);
  });

  testWidgets(
    'shows a user-facing fallback for unexpected voice errors instead of a raw exception string',
    (tester) async {
      final voice = FakeVoiceInputController(
        error: StateError('Provider handshake corrupted'),
      );
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: MobileBootstrap(
            daemonVersion: '0.1.0',
            user: const CurrentUser(
              id: 'usr_workspace',
              displayName: 'Workspace',
            ),
            roots: const <WorkspaceRoot>[],
            sessions: const [
              SessionSummary(
                id: 'sess_1',
                title: 'Mobile migration',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'running',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: const VoiceConfig(doubaoDirectAvailable: true),
          ),
        ),
        voiceInputController: voice,
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mobile migration'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Voice input'));
      await tester.pumpAndSettle();

      expect(find.text('Voice input failed. Retry.'), findsOneWidget);
      expect(
        find.text('Bad state: Provider handshake corrupted'),
        findsNothing,
      );
      expect(find.text('Retry voice'), findsOneWidget);
    },
  );

  testWidgets(
    'enables voice input when the daemon provides voice input without local credentials',
    (tester) async {
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: MobileBootstrap(
            daemonVersion: '0.1.0',
            user: const CurrentUser(
              id: 'usr_workspace',
              displayName: 'Workspace',
            ),
            roots: const <WorkspaceRoot>[],
            sessions: const [
              SessionSummary(
                id: 'sess_1',
                title: 'Mobile migration',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'running',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: VoiceConfig(
              doubaoDirectAvailable: true,
              providerCredentials: _providerVoiceCredentials,
            ),
          ),
        ),
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      expect(find.text('Sessions'), findsOneWidget);
      await tester.pump();
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(find.text('Voice input configured'), findsOneWidget);
    },
  );

  testWidgets('prepares configured voice input after sign in', (tester) async {
    final voice = FakeVoiceInputController(transcript: 'continue by voice');
    await pumpApp(
      tester,
      api: FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: <WorkspaceRoot>[],
          sessions: [
            SessionSummary(
              id: 'sess_1',
              title: 'Mobile migration',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: VoiceConfig(doubaoDirectAvailable: true),
        ),
      ),
      voiceInputController: voice,
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    expect(voice.prepareCount, 1);
    expect(voice.startCount, 0);
  });

  testWidgets(
    'enables voice input when saved Doubao credentials exist for the signed-in user',
    (tester) async {
      final voiceStorage = MemoryVoiceCredentialsStorage()
        ..seed(
          daemonUrl: Uri.parse('https://daemon.example.com'),
          userId: 'usr_workspace',
          credentials: const DoubaoVoiceCredentials(
            appId: 'app-123',
            accessToken: 'token-abc',
            resourceId: 'volc.bigasr.sauc.duration',
            websocketUrl: 'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel',
          ),
        );
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: MobileBootstrap(
            daemonVersion: '0.1.0',
            user: const CurrentUser(
              id: 'usr_workspace',
              displayName: 'Workspace',
            ),
            roots: const <WorkspaceRoot>[],
            sessions: const [
              SessionSummary(
                id: 'sess_1',
                title: 'Mobile migration',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'running',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: const VoiceConfig(doubaoDirectAvailable: true),
          ),
        ),
        voiceStorage: voiceStorage,
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.pump();
      await tester.tap(find.text('Mobile migration'));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Voice input'), findsOneWidget);
      expect(find.byTooltip('Voice input unavailable'), findsNothing);
    },
  );

  testWidgets(
    'default credential-backed voice wiring inserts transcript into the composer',
    (tester) async {
      final voiceStorage = MemoryVoiceCredentialsStorage()
        ..seed(
          daemonUrl: Uri.parse('https://daemon.example.com'),
          userId: 'usr_workspace',
          credentials: const DoubaoVoiceCredentials(
            appId: 'app-123',
            accessToken: 'token-abc',
            resourceId: 'volc.bigasr.sauc.duration',
            websocketUrl: 'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel',
          ),
        );
      final socket = FakeDoubaoSocketConnection();
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: MobileBootstrap(
            daemonVersion: '0.1.0',
            user: const CurrentUser(
              id: 'usr_workspace',
              displayName: 'Workspace',
            ),
            roots: const <WorkspaceRoot>[],
            sessions: const [
              SessionSummary(
                id: 'sess_1',
                title: 'Mobile migration',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'running',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: const VoiceConfig(doubaoDirectAvailable: true),
          ),
        ),
        voiceStorage: voiceStorage,
        doubaoSocketClient: FakeDoubaoSocketClient(socket),
        doubaoRecorder: FakeDoubaoRecorder(
          stream: Stream<Uint8List>.value(Uint8List.fromList(const [1, 2, 3])),
        ),
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.pump();
      await tester.tap(find.text('Mobile migration'));
      await tester.pumpAndSettle();

      for (var attempt = 0; attempt < 10; attempt++) {
        if (find.byTooltip('Voice input').evaluate().isNotEmpty) {
          break;
        }
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(find.byTooltip('Voice input'), findsOneWidget);
      expect(find.byTooltip('Voice input unavailable'), findsNothing);

      scheduleMicrotask(() async {
        socket.emit(buildTranscriptResponseFrame('hello', isFinal: false));
        await socket.waitForSentFrames(3);
        await Future<void>.delayed(const Duration(milliseconds: 40));
        socket.emit(buildTranscriptResponseFrame('hello world', isFinal: true));
      });

      await tester.tap(find.byTooltip('Voice input'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextField, 'hello world'), findsOneWidget);
    },
  );

  testWidgets(
    'default credential-backed voice wiring updates the composer with partial transcript before final transcript',
    (tester) async {
      final voiceStorage = MemoryVoiceCredentialsStorage()
        ..seed(
          daemonUrl: Uri.parse('https://daemon.example.com'),
          userId: 'usr_workspace',
          credentials: const DoubaoVoiceCredentials(
            appId: 'app-123',
            accessToken: 'token-abc',
            resourceId: 'volc.bigasr.sauc.duration',
            websocketUrl: 'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel',
          ),
        );
      final socket = FakeDoubaoSocketConnection();
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: MobileBootstrap(
            daemonVersion: '0.1.0',
            user: const CurrentUser(
              id: 'usr_workspace',
              displayName: 'Workspace',
            ),
            roots: const <WorkspaceRoot>[],
            sessions: const [
              SessionSummary(
                id: 'sess_1',
                title: 'Mobile migration',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'running',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: const VoiceConfig(doubaoDirectAvailable: true),
          ),
        ),
        voiceStorage: voiceStorage,
        doubaoSocketClient: FakeDoubaoSocketClient(socket),
        doubaoRecorder: FakeDoubaoRecorder(
          stream: Stream<Uint8List>.fromIterable([
            Uint8List.fromList(const [1, 2, 3]),
          ]),
        ),
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.pump();
      await tester.tap(find.text('Mobile migration'));
      await tester.pumpAndSettle();

      for (var attempt = 0; attempt < 10; attempt++) {
        if (find.byTooltip('Voice input').evaluate().isNotEmpty) {
          break;
        }
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.byTooltip('Voice input'), findsOneWidget);
      expect(find.byTooltip('Voice input unavailable'), findsNothing);

      scheduleMicrotask(() async {
        socket.emit(buildTranscriptResponseFrame('hello', isFinal: false));
        await socket.waitForSentFrames(3);
        await Future<void>.delayed(const Duration(milliseconds: 120));
        socket.emit(buildTranscriptResponseFrame('hello world', isFinal: true));
      });

      await tester.tap(find.byTooltip('Voice input'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.widgetWithText(TextField, 'hello'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'hello world'), findsOneWidget);
    },
  );

  testWidgets(
    'provider-managed voice wiring uses direct Doubao config from bootstrap instead of the daemon proxy',
    (tester) async {
      final socket = FakeDoubaoSocketConnection();
      final socketClient = FakeDoubaoSocketClient(socket);
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: MobileBootstrap(
            daemonVersion: '0.1.0',
            user: const CurrentUser(
              id: 'usr_workspace',
              displayName: 'Workspace',
            ),
            roots: const <WorkspaceRoot>[],
            sessions: const [
              SessionSummary(
                id: 'sess_1',
                title: 'Mobile migration',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'running',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: VoiceConfig(
              doubaoDirectAvailable: true,
              providerCredentials: DoubaoVoiceCredentials(
                appId: 'app-provider',
                accessToken: 'token-provider',
                resourceId: 'volc.bigasr.sauc.duration',
                websocketUrl:
                    'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel',
              ),
            ),
          ),
        ),
        doubaoSocketClient: socketClient,
        doubaoRecorder: FakeDoubaoRecorder(
          stream: Stream<Uint8List>.value(Uint8List.fromList(const [1, 2, 3])),
        ),
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Voice input unavailable'), findsNothing);
      await tester.tap(find.text('Mobile migration'));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Voice input unavailable'), findsNothing);
      expect(find.byTooltip('Voice input'), findsOneWidget);

      scheduleMicrotask(() async {
        socket.emit(buildTranscriptResponseFrame('hello', isFinal: false));
        await socket.waitForSentFrames(3);
        await Future<void>.delayed(const Duration(milliseconds: 40));
        socket.emit(buildTranscriptResponseFrame('hello world', isFinal: true));
      });

      await tester.tap(find.byTooltip('Voice input'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextField, 'hello world'), findsOneWidget);
      expect(socketClient.requests, hasLength(1));
      final request = socketClient.requests.single;
      expect(
        request.url,
        'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel',
      );
      expect(request.headers['X-Api-App-Key'], 'app-provider');
      expect(request.headers['X-Api-Access-Key'], 'token-provider');
      expect(request.headers['X-Api-Resource-Id'], 'volc.bigasr.sauc.duration');
      expect(request.url, isNot(contains('/ws/voice-input')));
    },
  );

  testWidgets(
    'provider-managed voice wiring prefers bootstrap direct credentials over saved local credentials',
    (tester) async {
      final voiceStorage = MemoryVoiceCredentialsStorage()
        ..seed(
          daemonUrl: Uri.parse('https://daemon.example.com'),
          userId: 'usr_workspace',
          credentials: const DoubaoVoiceCredentials(
            appId: 'app-local',
            accessToken: 'token-local',
            resourceId: 'resource-local',
            websocketUrl: 'wss://local.example.com/asr',
          ),
        );
      final socket = FakeDoubaoSocketConnection();
      final socketClient = FakeDoubaoSocketClient(socket);
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: MobileBootstrap(
            daemonVersion: '0.1.0',
            user: const CurrentUser(
              id: 'usr_workspace',
              displayName: 'Workspace',
            ),
            roots: const <WorkspaceRoot>[],
            sessions: const [
              SessionSummary(
                id: 'sess_1',
                title: 'Mobile migration',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'running',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: VoiceConfig(
              doubaoDirectAvailable: true,
              providerCredentials: DoubaoVoiceCredentials(
                appId: 'app-provider',
                accessToken: 'token-provider',
                resourceId: 'volc.bigasr.sauc.duration',
                websocketUrl:
                    'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel',
              ),
            ),
          ),
        ),
        voiceStorage: voiceStorage,
        doubaoSocketClient: socketClient,
        doubaoRecorder: FakeDoubaoRecorder(
          stream: Stream<Uint8List>.value(Uint8List.fromList(const [1, 2, 3])),
        ),
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Voice input unavailable'), findsNothing);
      await tester.tap(find.text('Mobile migration'));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Voice input unavailable'), findsNothing);
      expect(find.byTooltip('Voice input'), findsOneWidget);

      scheduleMicrotask(() async {
        socket.emit(buildTranscriptResponseFrame('hello', isFinal: false));
        await socket.waitForSentFrames(3);
        await Future<void>.delayed(const Duration(milliseconds: 40));
        socket.emit(buildTranscriptResponseFrame('hello world', isFinal: true));
      });

      await tester.tap(find.byTooltip('Voice input'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextField, 'hello world'), findsOneWidget);
      expect(socketClient.requests, hasLength(1));
      final request = socketClient.requests.single;
      expect(
        request.url,
        'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel',
      );
      expect(request.headers['X-Api-App-Key'], 'app-provider');
      expect(request.headers['X-Api-Access-Key'], 'token-provider');
      expect(request.headers['X-Api-Resource-Id'], 'volc.bigasr.sauc.duration');
      expect(request.headers['X-Api-App-Key'], isNot('app-local'));
      expect(request.headers['X-Api-Access-Key'], isNot('token-local'));
      expect(request.url, isNot('wss://local.example.com/asr'));
    },
  );

  testWidgets('loads older session history before the current first event', (
    tester,
  ) async {
    final api = FakeDaemonApi(
      bootstrap: MobileBootstrap(
        daemonVersion: '0.1.0',
        user: const CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: const <WorkspaceRoot>[],
        sessions: const [
          SessionSummary(
            id: 'sess_1',
            title: 'Mobile migration',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            status: 'running',
            workspacePath: '/home/jhz/projects/agent-dock',
          ),
        ],
        voice: const VoiceConfig(doubaoDirectAvailable: false),
      ),
      snapshot: const SessionSnapshot(
        id: 'sess_1',
        title: 'Mobile migration',
        agentKind: 'codex',
        sourceKind: 'managed',
        runtimeSessionId: 'runtime_1',
        workspacePath: '/home/jhz/projects/agent-dock',
        status: 'running',
        hasMoreHistory: true,
        events: [
          SessionEvent(
            id: 10,
            eventType: 'user.message',
            payload: {'text': 'newer prompt'},
          ),
        ],
      ),
      olderSnapshot: const SessionSnapshot(
        id: 'sess_1',
        title: 'Mobile migration',
        agentKind: 'codex',
        sourceKind: 'managed',
        runtimeSessionId: 'runtime_1',
        workspacePath: '/home/jhz/projects/agent-dock',
        status: 'running',
        hasMoreHistory: false,
        events: [
          SessionEvent(
            id: 7,
            eventType: 'assistant.message',
            payload: {'text': 'older reply'},
          ),
        ],
      ),
      olderSnapshotDelay: const Duration(milliseconds: 40),
    );
    await pumpApp(tester, api: api);

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mobile migration'));
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView).last, const Offset(0, 1200));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      find.byWidgetPredicate((widget) {
        final key = widget.key;
        return key is ValueKey<String> &&
            key.value.startsWith('timeline-item-prepend-appear-');
      }),
      findsOneWidget,
    );
    await tester.pumpAndSettle();

    expect(api.snapshotRequests, [
      'sess_1:tok_workspace:null',
      'sess_1:tok_workspace:10',
    ]);
    expect(find.text('older reply'), findsOneWidget);
    expect(find.text('newer prompt'), findsOneWidget);
    expect(find.text('Load older events'), findsNothing);
  });

  testWidgets(
    'automatically loads older history when the user scrolls near the top',
    (tester) async {
      final newerEvents = List<SessionEvent>.generate(12, (index) {
        final id = 20 + index;
        return SessionEvent(
          id: id,
          eventType: id.isEven ? 'assistant.message' : 'user.message',
          payload: {'text': 'newer $id'},
        );
      });
      final api = FakeDaemonApi(
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Mobile migration',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: SessionSnapshot(
          id: 'sess_1',
          title: 'Mobile migration',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: true,
          events: newerEvents,
        ),
        olderSnapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Mobile migration',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: [
            SessionEvent(
              id: 12,
              eventType: 'assistant.message',
              payload: {'text': 'older 12'},
            ),
          ],
        ),
        olderSnapshotDelay: const Duration(milliseconds: 40),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mobile migration'));
      await tester.pumpAndSettle();

      await tester.drag(find.byType(ListView).last, const Offset(0, 1200));
      await tester.pump(const Duration(milliseconds: 10));

      expect(find.text('Loading earlier events...'), findsAtLeastNWidgets(1));
      expect(
        find.byKey(const ValueKey('older-history-loader-spinner')),
        findsOneWidget,
      );
      expect(
        tester
            .getSize(find.byKey(const ValueKey('older-history-loader')))
            .height,
        36,
      );
      await tester.pumpAndSettle();

      expect(api.snapshotRequests, [
        'sess_1:tok_workspace:null',
        'sess_1:tok_workspace:20',
      ]);
      expect(find.textContaining('older 12'), findsOneWidget);
    },
  );

  testWidgets(
    'automatically loads older history when the initial timeline is shorter than one viewport',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: <WorkspaceRoot>[],
          sessions: [
            SessionSummary(
              id: 'sess_1',
              title: 'Short history',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Short history',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: true,
          events: [
            SessionEvent(
              id: 20,
              eventType: 'assistant.message',
              payload: {'text': 'latest answer'},
            ),
          ],
        ),
        olderSnapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Short history',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: [
            SessionEvent(
              id: 12,
              eventType: 'user.message',
              payload: {'text': 'older 12'},
            ),
          ],
        ),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Short history'));
      await tester.pumpAndSettle();

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();

      expect(api.snapshotRequests, [
        'sess_1:tok_workspace:null',
        'sess_1:tok_workspace:20',
      ]);
      expect(find.text('older 12'), findsOneWidget);
    },
  );

  testWidgets(
    'keeps auto-loading older history until the initial timeline can scroll or history ends',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: <WorkspaceRoot>[],
          sessions: [
            SessionSummary(
              id: 'sess_1',
              title: 'Very short history',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Very short history',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: true,
          events: [
            SessionEvent(
              id: 20,
              eventType: 'assistant.message',
              payload: {'text': 'latest answer'},
            ),
          ],
        ),
        olderSnapshots: const [
          SessionSnapshot(
            id: 'sess_1',
            title: 'Very short history',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            workspacePath: '/home/jhz/projects/agent-dock',
            status: 'running',
            hasMoreHistory: true,
            events: [
              SessionEvent(
                id: 12,
                eventType: 'user.message',
                payload: {'text': 'older 12'},
              ),
            ],
          ),
          SessionSnapshot(
            id: 'sess_1',
            title: 'Very short history',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            workspacePath: '/home/jhz/projects/agent-dock',
            status: 'running',
            hasMoreHistory: false,
            events: [
              SessionEvent(
                id: 8,
                eventType: 'assistant.message',
                payload: {'text': 'older 8'},
              ),
            ],
          ),
        ],
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Very short history'));
      await tester.pumpAndSettle();

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();

      expect(api.snapshotRequests, [
        'sess_1:tok_workspace:null',
        'sess_1:tok_workspace:20',
        'sess_1:tok_workspace:12',
      ]);
      expect(find.text('older 12'), findsOneWidget);
      expect(find.text('older 8'), findsOneWidget);
    },
  );

  testWidgets('routes back to login for 401 older-history requests', (
    tester,
  ) async {
    final storage = MemoryAuthStorage();
    final newerEvents = List<SessionEvent>.generate(12, (index) {
      final id = 20 + index;
      return SessionEvent(
        id: id,
        eventType: id.isEven ? 'assistant.message' : 'user.message',
        payload: {'text': 'newer $id'},
      );
    });
    final api = FakeDaemonApi(
      bootstrap: const MobileBootstrap(
        daemonVersion: '0.1.0',
        user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: <WorkspaceRoot>[],
        sessions: [
          SessionSummary(
            id: 'sess_1',
            title: 'Expired older history',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            status: 'running',
            workspacePath: '/home/jhz/projects/agent-dock',
          ),
        ],
        voice: VoiceConfig(doubaoDirectAvailable: false),
      ),
      snapshot: SessionSnapshot(
        id: 'sess_1',
        title: 'Expired older history',
        agentKind: 'codex',
        sourceKind: 'managed',
        runtimeSessionId: 'runtime_1',
        workspacePath: '/home/jhz/projects/agent-dock',
        status: 'running',
        hasMoreHistory: true,
        events: newerEvents,
      ),
      olderSnapshot: const SessionSnapshot(
        id: 'sess_1',
        title: 'Expired older history',
        agentKind: 'codex',
        sourceKind: 'managed',
        runtimeSessionId: 'runtime_1',
        workspacePath: '/home/jhz/projects/agent-dock',
        status: 'running',
        hasMoreHistory: false,
        events: <SessionEvent>[],
      ),
      olderSnapshotError: const DaemonApiException(
        statusCode: 401,
        code: 'UNAUTHORIZED',
        message: 'Unauthorized',
      ),
    );
    await pumpApp(tester, api: api, storage: storage);

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Expired older history'));
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView).last, const Offset(0, 1200));
    await tester.pumpAndSettle();

    expect(api.snapshotRequests.first, 'sess_1:tok_workspace:null');
    expect(
      api.snapshotRequests.where(
        (request) => request == 'sess_1:tok_workspace:20',
      ),
      isNotEmpty,
    );
    expect(storage.didClear, isTrue);
    expect(storage.profile, isNull);
    expect(find.text('Unlock workspace'), findsOneWidget);
    expect(find.text('Expired older history'), findsNothing);
    expect(find.text('Session expired. Sign in again.'), findsOneWidget);
  });

  testWidgets('keeps the current chat visible for 403 older-history requests', (
    tester,
  ) async {
    final storage = MemoryAuthStorage();
    final newerEvents = List<SessionEvent>.generate(12, (index) {
      final id = 20 + index;
      return SessionEvent(
        id: id,
        eventType: id.isEven ? 'assistant.message' : 'user.message',
        payload: {'text': 'newer $id'},
      );
    });
    final api = FakeDaemonApi(
      bootstrap: const MobileBootstrap(
        daemonVersion: '0.1.0',
        user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: <WorkspaceRoot>[],
        sessions: [
          SessionSummary(
            id: 'sess_1',
            title: 'Forbidden older history',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            status: 'running',
            workspacePath: '/home/jhz/projects/agent-dock',
          ),
        ],
        voice: VoiceConfig(doubaoDirectAvailable: false),
      ),
      snapshot: SessionSnapshot(
        id: 'sess_1',
        title: 'Forbidden older history',
        agentKind: 'codex',
        sourceKind: 'managed',
        runtimeSessionId: 'runtime_1',
        workspacePath: '/home/jhz/projects/agent-dock',
        status: 'running',
        hasMoreHistory: true,
        events: newerEvents,
      ),
      olderSnapshot: const SessionSnapshot(
        id: 'sess_1',
        title: 'Forbidden older history',
        agentKind: 'codex',
        sourceKind: 'managed',
        runtimeSessionId: 'runtime_1',
        workspacePath: '/home/jhz/projects/agent-dock',
        status: 'running',
        hasMoreHistory: false,
        events: <SessionEvent>[],
      ),
      olderSnapshotError: const DaemonApiException(
        statusCode: 403,
        code: 'FORBIDDEN',
        message: 'Forbidden',
      ),
    );
    await pumpApp(tester, api: api, storage: storage);

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Forbidden older history'));
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView).last, const Offset(0, 1200));
    await tester.pumpAndSettle();

    expect(storage.didClear, isFalse);
    expect(
      find.text('You no longer have access to this session.'),
      findsOneWidget,
    );
    expect(find.text('Back to Sessions'), findsOneWidget);
    expect(find.text('Unlock workspace'), findsNothing);
    expect(find.text('Forbidden older history'), findsOneWidget);

    final messageField = tester.widget<TextField>(find.byType(TextField).last);
    expect(messageField.enabled, isFalse);
  });

  testWidgets('keeps the current viewport anchored when older history loads', (
    tester,
  ) async {
    final newerEvents = List<SessionEvent>.generate(12, (index) {
      final id = 20 + index;
      return SessionEvent(
        id: id,
        eventType: id.isEven ? 'assistant.message' : 'user.message',
        payload: {'text': 'newer $id'},
      );
    });
    final olderEvents = List<SessionEvent>.generate(8, (index) {
      final id = 12 + index;
      return SessionEvent(
        id: id,
        eventType: id.isEven ? 'assistant.message' : 'user.message',
        payload: {'text': 'older $id'},
      );
    });
    final api = FakeDaemonApi(
      bootstrap: MobileBootstrap(
        daemonVersion: '0.1.0',
        user: const CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: const <WorkspaceRoot>[],
        sessions: const [
          SessionSummary(
            id: 'sess_1',
            title: 'Mobile migration',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            status: 'running',
            workspacePath: '/home/jhz/projects/agent-dock',
          ),
        ],
        voice: const VoiceConfig(doubaoDirectAvailable: false),
      ),
      snapshot: SessionSnapshot(
        id: 'sess_1',
        title: 'Mobile migration',
        agentKind: 'codex',
        sourceKind: 'managed',
        runtimeSessionId: 'runtime_1',
        workspacePath: '/home/jhz/projects/agent-dock',
        status: 'running',
        hasMoreHistory: true,
        events: newerEvents,
      ),
      olderSnapshot: SessionSnapshot(
        id: 'sess_1',
        title: 'Mobile migration',
        agentKind: 'codex',
        sourceKind: 'managed',
        runtimeSessionId: 'runtime_1',
        workspacePath: '/home/jhz/projects/agent-dock',
        status: 'running',
        hasMoreHistory: false,
        events: olderEvents,
      ),
    );
    await pumpApp(tester, api: api);

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mobile migration'));
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView).last, const Offset(0, 1200));
    await tester.pumpAndSettle();
    expect(find.text('newer 22'), findsOneWidget);
    await tester.pumpAndSettle();

    expect(find.text('newer 22'), findsOneWidget);
    expect(find.text('older 12'), findsNothing);
  });

  testWidgets(
    'shows a beginning-of-session marker once no more history remains',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: <WorkspaceRoot>[],
          sessions: [
            SessionSummary(
              id: 'sess_1',
              title: 'Mobile migration',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Mobile migration',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: true,
          events: [
            SessionEvent(
              id: 20,
              eventType: 'assistant.message',
              payload: {'text': 'latest answer'},
            ),
          ],
        ),
        olderSnapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Mobile migration',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: [
            SessionEvent(
              id: 12,
              eventType: 'user.message',
              payload: {'text': 'older 12'},
            ),
          ],
        ),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mobile migration'));
      await tester.pumpAndSettle();

      expect(find.text('Load older events'), findsNothing);

      await tester.drag(find.byType(ListView).last, const Offset(0, 1200));
      await tester.pumpAndSettle();

      expect(api.snapshotRequests, [
        'sess_1:tok_workspace:null',
        'sess_1:tok_workspace:20',
      ]);
      expect(find.text('older 12'), findsOneWidget);
      expect(find.text('Load older events'), findsNothing);
      expect(find.text('Beginning of session'), findsOneWidget);
    },
  );

  testWidgets('signs out from settings and clears saved auth', (tester) async {
    final storage = MemoryAuthStorage();
    final sessionDetailCacheStore = MemorySessionDetailCacheStore();
    final voice = FakeVoiceInputController(
      transcript: 'continue by voice',
      phaseDelayMs: 25,
    );
    sessionDetailCacheStore.saveCache(
      scope: SessionDetailCacheScope(
        daemonUrl: Uri.parse('https://daemon.example.com'),
        userId: 'usr_workspace',
        sessionId: 'sess_1',
      ),
      entry: const SessionDetailCacheEntry(
        events: <SessionEvent>[],
        hasMoreHistory: false,
        expandedItemKeys: <String>{},
        autoExpandedFailedToolItemKeys: <String>{},
        scrollOffset: 12,
      ),
    );
    await pumpApp(
      tester,
      api: FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: <WorkspaceRoot>[],
          sessions: [
            SessionSummary(
              id: 'sess_1',
              title: 'Mobile migration',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
      ),
      storage: storage,
      sessionDetailCacheStore: sessionDetailCacheStore,
      voiceInputController: voice,
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mobile migration'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Voice input'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    expect(find.text('Listening...'), findsOneWidget);
    expect(voice.cancelCount, 0);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Logout'));
    await tester.pumpAndSettle();

    expect(storage.didClear, isTrue);
    expect(storage.profile, isNull);
    expect(voice.cancelCount, 1);
    expect(
      sessionDetailCacheStore.readCache(
        scope: SessionDetailCacheScope(
          daemonUrl: Uri.parse('https://daemon.example.com'),
          userId: 'usr_workspace',
          sessionId: 'sess_1',
        ),
      ),
      isNull,
    );
    expect(find.text('Unlock workspace'), findsOneWidget);
    expect(find.text('daemon.example.com'), findsOneWidget);
    expect(find.text('Sessions'), findsNothing);
  });

  testWidgets(
    'routes to daemon setup from settings and keeps the current URL',
    (tester) async {
      final storage = MemoryAuthStorage();
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: const MobileBootstrap(
            daemonVersion: '0.1.0',
            user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
            roots: <WorkspaceRoot>[],
            sessions: [
              SessionSummary(
                id: 'sess_1',
                title: 'Mobile migration',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'completed',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: VoiceConfig(doubaoDirectAvailable: false),
          ),
        ),
        storage: storage,
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Change daemon'));
      await tester.pumpAndSettle();

      expect(find.text('Connect daemon'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'https://daemon.example.com'),
        'https://saved.example.com',
      );
      await tester.tap(find.text('Test connection'));
      await tester.pumpAndSettle();

      expect(storage.didClear, isTrue);
      expect(find.text('Unlock workspace'), findsOneWidget);
      expect(find.text('saved.example.com'), findsOneWidget);
      expect(find.text('Sessions'), findsNothing);
    },
  );

  testWidgets(
    'change daemon asks for confirmation when there is a running session',
    (tester) async {
      final storage = MemoryAuthStorage();
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: const MobileBootstrap(
            daemonVersion: '0.1.0',
            user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
            roots: <WorkspaceRoot>[],
            sessions: [
              SessionSummary(
                id: 'sess_1',
                title: 'Mobile migration',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'running',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: VoiceConfig(doubaoDirectAvailable: false),
          ),
        ),
        storage: storage,
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Change daemon'));
      await tester.pumpAndSettle();

      expect(find.text('Change daemon?'), findsOneWidget);
      expect(
        find.text('A running session may disconnect. Continue?'),
        findsOneWidget,
      );
      expect(storage.didClear, isFalse);

      await tester.tap(find.text('Stay'));
      await tester.pumpAndSettle();

      expect(find.text('Sessions'), findsOneWidget);
      expect(storage.didClear, isFalse);
    },
  );

  testWidgets(
    'change daemon does not ask for confirmation when the session is only active',
    (tester) async {
      final storage = MemoryAuthStorage();
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: const MobileBootstrap(
            daemonVersion: '0.1.0',
            user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
            roots: <WorkspaceRoot>[],
            sessions: [
              SessionSummary(
                id: 'sess_1',
                title: 'Mobile migration',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'active',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: VoiceConfig(doubaoDirectAvailable: false),
          ),
        ),
        storage: storage,
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Change daemon'));
      await tester.pumpAndSettle();

      expect(find.text('Change daemon?'), findsNothing);
      expect(find.text('Connect daemon'), findsOneWidget);
      expect(storage.didClear, isTrue);
    },
  );

  testWidgets(
    'changing daemon cancels active voice input before leaving the current daemon',
    (tester) async {
      final storage = MemoryAuthStorage();
      final voice = FakeVoiceInputController(
        transcript: 'continue by voice',
        phaseDelayMs: 25,
      );
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: const MobileBootstrap(
            daemonVersion: '0.1.0',
            user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
            roots: <WorkspaceRoot>[],
            sessions: [
              SessionSummary(
                id: 'sess_1',
                title: 'Mobile migration',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'completed',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: VoiceConfig(doubaoDirectAvailable: false),
          ),
        ),
        storage: storage,
        voiceInputController: voice,
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mobile migration'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Voice input'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(find.text('Listening...'), findsOneWidget);
      expect(voice.cancelCount, 0);
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Change daemon'));
      await tester.pumpAndSettle();

      expect(storage.didClear, isTrue);
      expect(voice.cancelCount, 1);
      expect(find.text('Connect daemon'), findsOneWidget);
    },
  );

  testWidgets(
    'session expiry cancels active voice input before returning to login',
    (tester) async {
      final liveEvents = StreamController<SessionEvent>();
      final voice = FakeVoiceInputController(
        transcript: 'continue by voice',
        phaseDelayMs: 25,
      );
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          liveEvents: liveEvents.stream,
          bootstrap: const MobileBootstrap(
            daemonVersion: '0.1.0',
            user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
            roots: <WorkspaceRoot>[],
            sessions: [
              SessionSummary(
                id: 'sess_1',
                title: 'Mobile migration',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'running',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: VoiceConfig(doubaoDirectAvailable: false),
          ),
          snapshot: const SessionSnapshot(
            id: 'sess_1',
            title: 'Mobile migration',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            workspacePath: '/home/jhz/projects/agent-dock',
            status: 'running',
            hasMoreHistory: false,
            events: <SessionEvent>[],
          ),
        ),
        voiceInputController: voice,
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mobile migration'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Voice input'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(find.text('Listening...'), findsOneWidget);
      expect(voice.cancelCount, 0);

      liveEvents.addError(
        const DaemonApiException(
          statusCode: 401,
          code: 'UNAUTHORIZED',
          message: 'Unauthorized',
        ),
      );
      await tester.pumpAndSettle();

      expect(voice.cancelCount, greaterThanOrEqualTo(1));
      expect(find.text('Unlock workspace'), findsOneWidget);
      expect(find.text('Session expired. Sign in again.'), findsOneWidget);
    },
  );

  testWidgets('shows richer daemon metadata in settings', (tester) async {
    await pumpApp(
      tester,
      api: FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: <WorkspaceRoot>[],
          sessions: [
            SessionSummary(
              id: 'sess_1',
              title: 'Mobile migration',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();

    expect(find.text('Signed in as Workspace'), findsOneWidget);
    expect(
      find.text('Connected to daemon.example.com'),
      findsAtLeastNWidgets(1),
    );
    expect(find.text('Daemon version 0.1.0'), findsOneWidget);
    expect(find.text('Voice input is not configured'), findsAtLeastNWidgets(1));
    expect(find.text('Test connection'), findsOneWidget);
  });

  testWidgets(
    'shows full daemon url and explicit connection status in settings',
    (tester) async {
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: const MobileBootstrap(
            daemonVersion: '0.1.0',
            user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
            roots: <WorkspaceRoot>[],
            sessions: <SessionSummary>[],
            voice: VoiceConfig(doubaoDirectAvailable: false),
          ),
        ),
        daemonUrl: Uri.parse('https://daemon.example.com'),
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();

      expect(find.text('Connection status'), findsOneWidget);
      expect(find.text('Connected'), findsOneWidget);
      expect(find.text('Daemon URL'), findsOneWidget);
      expect(find.text('https://daemon.example.com'), findsOneWidget);
    },
  );

  testWidgets('shows app version in settings', (tester) async {
    await pumpApp(
      tester,
      api: FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: <WorkspaceRoot>[],
          sessions: <SessionSummary>[],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
      ),
      daemonUrl: Uri.parse('https://daemon.example.com'),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();

    expect(find.text('App version'), findsOneWidget);
    expect(find.text('1.0.0+1'), findsOneWidget);
  });

  testWidgets('hides daemon version in settings when it is not known', (
    tester,
  ) async {
    await pumpApp(
      tester,
      api: FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: <WorkspaceRoot>[],
          sessions: <SessionSummary>[],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();

    final settingsSheet = find.byType(BottomSheet);
    expect(
      find.descendant(
        of: settingsSheet,
        matching: find.textContaining('Daemon version'),
      ),
      findsNothing,
    );
  });

  testWidgets('tests daemon connection from settings', (tester) async {
    final api = FakeDaemonApi(
      bootstrap: const MobileBootstrap(
        daemonVersion: '0.1.0',
        user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: <WorkspaceRoot>[],
        sessions: [
          SessionSummary(
            id: 'sess_1',
            title: 'Mobile migration',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            status: 'running',
            workspacePath: '/home/jhz/projects/agent-dock',
          ),
        ],
        voice: VoiceConfig(doubaoDirectAvailable: false),
      ),
      refreshBootstrapDelay: const Duration(milliseconds: 200),
      refreshBootstrap: const MobileBootstrap(
        daemonVersion: '0.1.0',
        user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: <WorkspaceRoot>[],
        sessions: <SessionSummary>[],
        voice: VoiceConfig(doubaoDirectAvailable: false),
      ),
    );
    await pumpApp(tester, api: api);

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Test connection'));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('settings-test-connection-spinner')),
      findsNothing,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Testing connection...'),
          )
          .onPressed,
      isNull,
    );

    await tester.pump(const Duration(milliseconds: 220));
    await tester.pumpAndSettle();

    expect(api.bootstrappedTokens, ['tok_workspace', 'tok_workspace']);
    expect(find.text('Connection looks good'), findsOneWidget);
  });

  testWidgets(
    'settings test connection shows a user-facing daemon API error instead of the raw exception string',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: <WorkspaceRoot>[],
          sessions: <SessionSummary>[],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
        refreshBootstrapDelay: const Duration(milliseconds: 200),
        refreshBootstrapErrors: const [
          DaemonApiException(
            statusCode: 503,
            code: 'UNAVAILABLE',
            message: 'Daemon temporarily unavailable',
          ),
        ],
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Test connection'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 220));
      await tester.pumpAndSettle();

      expect(find.text('Daemon temporarily unavailable'), findsOneWidget);
      expect(
        find.text(
          'DaemonApiException(503, UNAVAILABLE, Daemon temporarily unavailable)',
        ),
        findsNothing,
      );
    },
  );

  testWidgets(
    'settings test connection shows the shared offline message for network errors',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: <WorkspaceRoot>[],
          sessions: <SessionSummary>[],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
        refreshBootstrapDelay: const Duration(milliseconds: 200),
        refreshBootstrapErrors: <Object>[
          const SocketException('Network is unreachable'),
        ],
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Test connection'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 220));
      await tester.pumpAndSettle();

      expect(find.text('Offline. Waiting for network...'), findsOneWidget);
      expect(
        find.text('SocketException: Network is unreachable'),
        findsNothing,
      );
    },
  );

  testWidgets(
    'settings shows offline connection status when the sessions page is offline',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: <WorkspaceRoot>[],
          sessions: [
            SessionSummary(
              id: 'sess_1',
              title: 'Initial session',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: null,
              status: 'completed',
              workspacePath: '/tmp/initial',
            ),
          ],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
        refreshBootstrapErrors: <Object>[
          const SocketException('Network is unreachable'),
        ],
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      expect(find.text('Refresh'), findsNothing);
      await tester.drag(find.byType(ListView).last, const Offset(0, 1200));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();

      expect(find.text('Offline. Waiting for network...'), findsOneWidget);

      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();

      expect(find.text('Connection status'), findsOneWidget);
      expect(find.text('Offline'), findsOneWidget);
      expect(find.text('Connected'), findsNothing);
    },
  );

  testWidgets('saves and clears Doubao voice credentials from settings', (
    tester,
  ) async {
    final storage = MemoryAuthStorage();
    final voiceStorage = MemoryVoiceCredentialsStorage();
    await pumpApp(
      tester,
      api: FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: <WorkspaceRoot>[],
          sessions: [
            SessionSummary(
              id: 'sess_1',
              title: 'Mobile migration',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
      ),
      storage: storage,
      voiceStorage: voiceStorage,
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Configure Doubao voice'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'App ID'), 'app-123');
    await tester.enterText(
      find.widgetWithText(TextField, 'Access Token'),
      'token-abc',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Resource ID'),
      'volc.bigasr.sauc.duration',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'WebSocket URL'),
      'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel',
    );
    await tester.tap(find.text('Save voice settings'));
    await tester.pumpAndSettle();

    expect(voiceStorage.savedScopes.single, (
      daemonUrl: Uri.parse('https://daemon.example.com'),
      userId: 'usr_workspace',
    ));

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Configure Doubao voice'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextField, 'app-123'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'token-abc'), findsOneWidget);

    await tester.tap(find.text('Clear voice settings'));
    await tester.pumpAndSettle();

    expect(voiceStorage.deletedScopes.single, (
      daemonUrl: Uri.parse('https://daemon.example.com'),
      userId: 'usr_workspace',
    ));
  });

  testWidgets(
    'provider-managed voice settings show a read-only daemon-backed status',
    (tester) async {
      final voiceStorage = MemoryVoiceCredentialsStorage();
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: const MobileBootstrap(
            daemonVersion: '0.1.0',
            user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
            roots: <WorkspaceRoot>[],
            sessions: [
              SessionSummary(
                id: 'sess_1',
                title: 'Mobile migration',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'running',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: VoiceConfig(
              doubaoDirectAvailable: true,
              providerCredentials: _providerVoiceCredentials,
            ),
          ),
        ),
        voiceStorage: voiceStorage,
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Configure Doubao voice'));
      await tester.pumpAndSettle();

      final voiceDialog = find.byType(BottomSheet);
      expect(
        find.text('Daemon-managed voice input is active.'),
        findsOneWidget,
      );
      expect(
        find.descendant(of: voiceDialog, matching: find.text('Refresh')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: voiceDialog,
          matching: find.text('Test connection'),
        ),
        findsOneWidget,
      );
      expect(find.text('Save voice settings'), findsNothing);
      expect(find.text('Clear voice settings'), findsNothing);
      expect(find.widgetWithText(TextField, 'App ID'), findsNothing);
      expect(find.widgetWithText(TextField, 'Access Token'), findsNothing);
      expect(find.widgetWithText(TextField, 'Resource ID'), findsNothing);
      expect(find.widgetWithText(TextField, 'WebSocket URL'), findsNothing);
    },
  );

  testWidgets(
    'provider-managed voice settings stay read-only even when local credentials are saved',
    (tester) async {
      final voiceStorage = MemoryVoiceCredentialsStorage()
        ..seed(
          daemonUrl: Uri.parse('https://daemon.example.com'),
          userId: 'usr_workspace',
          credentials: const DoubaoVoiceCredentials(
            appId: 'app-local',
            accessToken: 'token-local',
            resourceId: 'resource-local',
            websocketUrl: 'wss://local.example.com/asr',
          ),
        );
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: const MobileBootstrap(
            daemonVersion: '0.1.0',
            user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
            roots: <WorkspaceRoot>[],
            sessions: [
              SessionSummary(
                id: 'sess_1',
                title: 'Mobile migration',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'running',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: VoiceConfig(
              doubaoDirectAvailable: true,
              providerCredentials: _providerVoiceCredentials,
            ),
          ),
        ),
        voiceStorage: voiceStorage,
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Configure Doubao voice'));
      await tester.pumpAndSettle();

      final voiceDialog = find.byType(BottomSheet);
      expect(
        find.text('Daemon-managed voice input is active.'),
        findsOneWidget,
      );
      expect(
        find.descendant(of: voiceDialog, matching: find.text('Refresh')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: voiceDialog,
          matching: find.text('Test connection'),
        ),
        findsOneWidget,
      );
      expect(find.text('Save voice settings'), findsNothing);
      expect(find.text('Clear voice settings'), findsNothing);
      expect(find.widgetWithText(TextField, 'App ID'), findsNothing);
      expect(find.widgetWithText(TextField, 'Access Token'), findsNothing);
      expect(find.widgetWithText(TextField, 'Resource ID'), findsNothing);
      expect(find.widgetWithText(TextField, 'WebSocket URL'), findsNothing);
    },
  );

  testWidgets(
    'placeholder provider voice settings allow local Doubao editing',
    (tester) async {
      final voiceStorage = MemoryVoiceCredentialsStorage();
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: const MobileBootstrap(
            daemonVersion: '0.1.0',
            user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
            roots: <WorkspaceRoot>[],
            sessions: [
              SessionSummary(
                id: 'sess_1',
                title: 'Mobile migration',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'running',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: VoiceConfig(
              doubaoDirectAvailable: true,
              providerCredentials: DoubaoVoiceCredentials(
                appId: 'your-app-id',
                accessToken: 'your-access-token',
                resourceId: 'volc.bigasr.sauc.duration',
                websocketUrl:
                    'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async',
              ),
            ),
          ),
        ),
        voiceStorage: voiceStorage,
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Configure Doubao voice'));
      await tester.pumpAndSettle();

      expect(find.text('Daemon-managed voice input is active.'), findsNothing);
      expect(find.widgetWithText(TextField, 'App ID'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Access Token'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Resource ID'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'WebSocket URL'), findsOneWidget);
      expect(find.text('Save voice settings'), findsOneWidget);
    },
  );

  testWidgets(
    'placeholder provider credentials fall back to saved local Doubao direct config',
    (tester) async {
      final voiceStorage = MemoryVoiceCredentialsStorage()
        ..seed(
          daemonUrl: Uri.parse('https://daemon.example.com'),
          userId: 'usr_workspace',
          credentials: const DoubaoVoiceCredentials(
            appId: 'test-app-id',
            accessToken: 'test-access-token',
            resourceId: 'volc.test.resource',
            websocketUrl: 'wss://example.com/test-voice',
          ),
        );
      final socket = FakeDoubaoSocketConnection();
      final socketClient = FakeDoubaoSocketClient(socket);
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: const MobileBootstrap(
            daemonVersion: '0.1.0',
            user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
            roots: <WorkspaceRoot>[],
            sessions: [
              SessionSummary(
                id: 'sess_1',
                title: 'Mobile migration',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'running',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: VoiceConfig(
              doubaoDirectAvailable: true,
              providerCredentials: DoubaoVoiceCredentials(
                appId: 'your-app-id',
                accessToken: 'your-access-token',
                resourceId: 'volc.bigasr.sauc.duration',
                websocketUrl:
                    'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async',
              ),
            ),
          ),
        ),
        voiceStorage: voiceStorage,
        doubaoSocketClient: socketClient,
        doubaoRecorder: FakeDoubaoRecorder(
          stream: Stream<Uint8List>.value(Uint8List.fromList(const [1, 2, 3])),
        ),
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mobile migration'));
      await tester.pumpAndSettle();

      scheduleMicrotask(() async {
        socket.emit(buildTranscriptResponseFrame('hello', isFinal: false));
        await socket.waitForSentFrames(3);
        await Future<void>.delayed(const Duration(milliseconds: 40));
        socket.emit(buildTranscriptResponseFrame('hello world', isFinal: true));
      });

      await tester.tap(find.byTooltip('Voice input'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextField, 'hello world'), findsOneWidget);
      expect(socketClient.requests, hasLength(1));
      final request = socketClient.requests.single;
      expect(request.url, 'wss://example.com/test-voice');
      expect(request.headers['X-Api-App-Key'], 'test-app-id');
      expect(request.headers['X-Api-Access-Key'], 'test-access-token');
      expect(request.headers['X-Api-Resource-Id'], 'volc.test.resource');
    },
  );

  testWidgets(
    'voice settings opens as a mobile bottom sheet instead of an alert dialog',
    (tester) async {
      final voiceStorage = MemoryVoiceCredentialsStorage();
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: const MobileBootstrap(
            daemonVersion: '0.1.0',
            user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
            roots: <WorkspaceRoot>[],
            sessions: [
              SessionSummary(
                id: 'sess_1',
                title: 'Mobile migration',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'running',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: VoiceConfig(doubaoDirectAvailable: false),
          ),
        ),
        voiceStorage: voiceStorage,
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Configure Doubao voice'));
      await tester.pumpAndSettle();

      expect(find.text('Configure Doubao voice'), findsAtLeastNWidgets(1));
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  testWidgets(
    'provider-managed voice refresh reloads daemon voice availability',
    (tester) async {
      final voiceStorage = MemoryVoiceCredentialsStorage();
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: const MobileBootstrap(
            daemonVersion: '0.1.0',
            user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
            roots: <WorkspaceRoot>[],
            sessions: [
              SessionSummary(
                id: 'sess_1',
                title: 'Mobile migration',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'running',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: VoiceConfig(
              doubaoDirectAvailable: true,
              providerCredentials: _providerVoiceCredentials,
            ),
          ),
          refreshBootstrap: const MobileBootstrap(
            daemonVersion: '0.1.0',
            user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
            roots: <WorkspaceRoot>[],
            sessions: [
              SessionSummary(
                id: 'sess_1',
                title: 'Mobile migration',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'running',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: VoiceConfig(doubaoDirectAvailable: false),
          ),
        ),
        voiceStorage: voiceStorage,
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Configure Doubao voice'));
      await tester.pumpAndSettle();

      final voiceDialog = find.byType(BottomSheet);
      await tester.tap(
        find.descendant(of: voiceDialog, matching: find.text('Refresh')),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();

      expect(
        find.text('Voice input is not configured'),
        findsAtLeastNWidgets(1),
      );

      await tester.tap(find.text('Configure Doubao voice'));
      await tester.pumpAndSettle();

      expect(find.text('Daemon-managed voice input is active.'), findsNothing);
      expect(find.widgetWithText(TextField, 'App ID'), findsOneWidget);
    },
  );

  testWidgets('save voice settings avoids spinner flicker for quick saves', (
    tester,
  ) async {
    final voiceStorage = MemoryVoiceCredentialsStorage(
      saveDelay: const Duration(milliseconds: 200),
    );
    await pumpApp(
      tester,
      api: FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: <WorkspaceRoot>[],
          sessions: [
            SessionSummary(
              id: 'sess_1',
              title: 'Mobile migration',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
      ),
      voiceStorage: voiceStorage,
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Configure Doubao voice'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'App ID'), 'app-123');
    await tester.enterText(
      find.widgetWithText(TextField, 'Access Token'),
      'token-abc',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Resource ID'),
      'volc.bigasr.sauc.duration',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'WebSocket URL'),
      'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel',
    );
    await tester.tap(find.text('Save voice settings'));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('voice-settings-save-spinner')),
      findsNothing,
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Saving...'))
          .onPressed,
      isNull,
    );

    await tester.pump(const Duration(milliseconds: 220));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'saving Doubao voice settings enables the microphone without re-login',
    (tester) async {
      final voiceStorage = MemoryVoiceCredentialsStorage();
      await pumpApp(
        tester,
        api: FakeDaemonApi(
          bootstrap: const MobileBootstrap(
            daemonVersion: '0.1.0',
            user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
            roots: <WorkspaceRoot>[],
            sessions: [
              SessionSummary(
                id: 'sess_1',
                title: 'Mobile migration',
                agentKind: 'codex',
                sourceKind: 'managed',
                runtimeSessionId: 'runtime_1',
                status: 'running',
                workspacePath: '/home/jhz/projects/agent-dock',
              ),
            ],
            voice: VoiceConfig(doubaoDirectAvailable: false),
          ),
        ),
        voiceStorage: voiceStorage,
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Mobile migration'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Voice input unavailable'), findsOneWidget);
      expect(find.byTooltip('Voice input'), findsNothing);

      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Configure Doubao voice'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'App ID'),
        'app-123',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Access Token'),
        'token-abc',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Resource ID'),
        'volc.bigasr.sauc.duration',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'WebSocket URL'),
        'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel',
      );
      await tester.tap(find.text('Save voice settings'));
      await tester.pumpAndSettle();
      for (var attempt = 0; attempt < 10; attempt++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      await tester.tap(find.text('Mobile migration'));
      await tester.pumpAndSettle();
      for (var attempt = 0; attempt < 10; attempt++) {
        if (find.byTooltip('Voice input').evaluate().isNotEmpty) {
          break;
        }
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(find.byTooltip('Voice input'), findsOneWidget);
      expect(find.byTooltip('Voice input unavailable'), findsNothing);
    },
  );

  testWidgets('uploads an image and sends its attachment path', (tester) async {
    final api = FakeDaemonApi(
      bootstrap: MobileBootstrap(
        daemonVersion: '0.1.0',
        user: const CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: const <WorkspaceRoot>[],
        sessions: const [
          SessionSummary(
            id: 'sess_1',
            title: 'Mobile migration',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            status: 'running',
            workspacePath: '/home/jhz/projects/agent-dock',
          ),
        ],
        voice: const VoiceConfig(doubaoDirectAvailable: false),
      ),
      snapshot: const SessionSnapshot(
        id: 'sess_1',
        title: 'Mobile migration',
        agentKind: 'codex',
        sourceKind: 'managed',
        runtimeSessionId: 'runtime_1',
        workspacePath: '/home/jhz/projects/agent-dock',
        status: 'running',
        hasMoreHistory: false,
        events: <SessionEvent>[],
      ),
    );

    await pumpApp(
      tester,
      api: api,
      attachmentPicker: FakeImageAttachmentPicker(
        image: PickedImageAttachment(
          filename: 'screenshot.png',
          contentType: 'image/png',
          bytes: const <int>[137, 80, 78, 71],
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mobile migration'));
    await tester.pumpAndSettle();
    await choosePhotoLibraryAttachment(tester);

    expect(api.uploadedAttachments, ['sess_1:screenshot.png:image/png:4']);
    expect(find.text('screenshot.png'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'Message the agent'),
      'include screenshot',
    );
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();

    expect(api.sentMessages, [
      'sess_1:include screenshot|/tmp/attachments/sess_1/screenshot.png',
    ]);
    expect(find.text('screenshot.png'), findsNothing);
  });

  testWidgets(
    'composer actions are grouped inside a unified composer surface',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Mobile migration',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Mobile migration',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: <SessionEvent>[],
        ),
      );

      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mobile migration'));
      await tester.pumpAndSettle();

      final surfaceFinder = find.byKey(
        const ValueKey('composer-input-surface'),
      );
      expect(surfaceFinder, findsOneWidget);
      expect(
        find.descendant(
          of: surfaceFinder,
          matching: find.byTooltip('Attach image'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: surfaceFinder,
          matching: find.widgetWithText(TextField, 'Message the agent'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: surfaceFinder,
          matching: find.byTooltip('Voice input unavailable'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: surfaceFinder, matching: find.byTooltip('Send')),
        findsOneWidget,
      );
    },
  );

  testWidgets('attachment picker lets the user choose camera or gallery', (
    tester,
  ) async {
    final api = FakeDaemonApi(
      bootstrap: MobileBootstrap(
        daemonVersion: '0.1.0',
        user: const CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: const <WorkspaceRoot>[],
        sessions: const [
          SessionSummary(
            id: 'sess_1',
            title: 'Mobile migration',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            status: 'running',
            workspacePath: '/home/jhz/projects/agent-dock',
          ),
        ],
        voice: const VoiceConfig(doubaoDirectAvailable: false),
      ),
      snapshot: const SessionSnapshot(
        id: 'sess_1',
        title: 'Mobile migration',
        agentKind: 'codex',
        sourceKind: 'managed',
        runtimeSessionId: 'runtime_1',
        workspacePath: '/home/jhz/projects/agent-dock',
        status: 'running',
        hasMoreHistory: false,
        events: <SessionEvent>[],
      ),
    );
    final attachmentPicker = FakeImageAttachmentPicker(
      image: const PickedImageAttachment(
        filename: 'camera.jpg',
        contentType: 'image/jpeg',
        bytes: <int>[4, 5, 6, 7],
      ),
    );

    await pumpApp(tester, api: api, attachmentPicker: attachmentPicker);

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mobile migration'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Attach image'));
    await tester.pumpAndSettle();

    expect(find.text('Add image'), findsOneWidget);
    expect(find.text('Photo library'), findsOneWidget);
    expect(find.text('Camera'), findsOneWidget);

    expect(api.uploadedAttachments, isEmpty);

    await tester.tap(find.text('Camera'));
    await tester.pumpAndSettle();

    expect(attachmentPicker.sources, [ImageAttachmentSource.camera]);
    expect(api.uploadedAttachments, ['sess_1:camera.jpg:image/jpeg:4']);
    expect(find.text('camera.jpg'), findsOneWidget);
  });

  testWidgets(
    'local attachment picking failure shows a user-facing inline error instead of a raw exception string',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: <WorkspaceRoot>[],
          sessions: [
            SessionSummary(
              id: 'sess_1',
              title: 'Mobile migration',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Mobile migration',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: <SessionEvent>[],
        ),
      );

      await pumpApp(
        tester,
        api: api,
        attachmentPicker: FakeImageAttachmentPicker(
          error: StateError('Photo library unavailable'),
        ),
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mobile migration'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Attach image'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Photo library'));
      await tester.pumpAndSettle();

      expect(find.text('Could not pick image'), findsOneWidget);
      expect(find.text('Bad state: Photo library unavailable'), findsNothing);
      expect(api.uploadedAttachments, isEmpty);
    },
  );

  testWidgets(
    'selected image shows a thumbnail chip while upload is in progress',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Mobile migration',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Mobile migration',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: <SessionEvent>[],
        ),
        uploadAttachmentDelay: const Duration(milliseconds: 200),
      );

      await pumpApp(
        tester,
        api: api,
        attachmentPicker: FakeImageAttachmentPicker(
          image: PickedImageAttachment(
            filename: 'screenshot.png',
            contentType: 'image/png',
            bytes: const <int>[137, 80, 78, 71],
          ),
        ),
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mobile migration'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Attach image'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Photo library'));
      await tester.pump();

      expect(find.text('screenshot.png'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('attachment-chip-thumbnail-screenshot.png')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('attachment-chip-appear-screenshot.png')),
        findsOneWidget,
      );
      expect(find.text('Uploading...'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(
            const ValueKey('attachment-chip-thumbnail-screenshot.png'),
          ),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );

      await tester.pump(const Duration(milliseconds: 220));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('uploaded image chip briefly shows a success check icon', (
    tester,
  ) async {
    final hapticCalls = recordHapticCalls(tester);
    final api = FakeDaemonApi(
      bootstrap: MobileBootstrap(
        daemonVersion: '0.1.0',
        user: const CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: const <WorkspaceRoot>[],
        sessions: const [
          SessionSummary(
            id: 'sess_1',
            title: 'Mobile migration',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            status: 'running',
            workspacePath: '/home/jhz/projects/agent-dock',
          ),
        ],
        voice: const VoiceConfig(doubaoDirectAvailable: false),
      ),
      snapshot: const SessionSnapshot(
        id: 'sess_1',
        title: 'Mobile migration',
        agentKind: 'codex',
        sourceKind: 'managed',
        runtimeSessionId: 'runtime_1',
        workspacePath: '/home/jhz/projects/agent-dock',
        status: 'running',
        hasMoreHistory: false,
        events: <SessionEvent>[],
      ),
    );

    await pumpApp(
      tester,
      api: api,
      attachmentPicker: FakeImageAttachmentPicker(
        image: PickedImageAttachment(
          filename: 'screenshot.png',
          contentType: 'image/png',
          bytes: const <int>[137, 80, 78, 71],
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mobile migration'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Attach image'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Photo library'));
    await tester.pump();

    expect(api.uploadedAttachments, ['sess_1:screenshot.png:image/png:4']);
    expect(
      find.byKey(const ValueKey('attachment-chip-success-icon')),
      findsOneWidget,
    );
    expect(hapticCalls, contains('HapticFeedbackType.successNotification'));

    await tester.pump(const Duration(milliseconds: 650));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('attachment-chip-success-icon')),
      findsNothing,
    );
  });

  testWidgets(
    'reduced motion keeps the uploading attachment indicator static',
    (tester) async {
      tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(
            disableAnimations: true,
            reduceMotion: true,
          );
      addTearDown(
        tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );

      final api = FakeDaemonApi(
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const <WorkspaceRoot>[],
          sessions: const [
            SessionSummary(
              id: 'sess_1',
              title: 'Mobile migration',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Mobile migration',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: <SessionEvent>[],
        ),
        uploadAttachmentDelay: const Duration(milliseconds: 200),
      );

      await pumpApp(
        tester,
        api: api,
        attachmentPicker: FakeImageAttachmentPicker(
          image: PickedImageAttachment(
            filename: 'screenshot.png',
            contentType: 'image/png',
            bytes: const <int>[137, 80, 78, 71],
          ),
        ),
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mobile migration'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Attach image'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Photo library'));
      await tester.pump();

      expect(
        find.byKey(
          const ValueKey('attachment-chip-upload-static-icon-screenshot.png'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('attachment-chip-appear-screenshot.png')),
        findsNothing,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);

      await tester.pump(const Duration(milliseconds: 220));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('failed image upload shows retry and remove controls', (
    tester,
  ) async {
    final hapticCalls = recordHapticCalls(tester);
    final api = FakeDaemonApi(
      bootstrap: MobileBootstrap(
        daemonVersion: '0.1.0',
        user: const CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: const <WorkspaceRoot>[],
        sessions: const [
          SessionSummary(
            id: 'sess_1',
            title: 'Mobile migration',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            status: 'running',
            workspacePath: '/home/jhz/projects/agent-dock',
          ),
        ],
        voice: const VoiceConfig(doubaoDirectAvailable: false),
      ),
      snapshot: const SessionSnapshot(
        id: 'sess_1',
        title: 'Mobile migration',
        agentKind: 'codex',
        sourceKind: 'managed',
        runtimeSessionId: 'runtime_1',
        workspacePath: '/home/jhz/projects/agent-dock',
        status: 'running',
        hasMoreHistory: false,
        events: <SessionEvent>[],
      ),
      uploadAttachmentErrors: const [
        DaemonApiException(
          statusCode: 503,
          code: 'UNAVAILABLE',
          message: 'Upload failed',
        ),
      ],
    );

    await pumpApp(
      tester,
      api: api,
      attachmentPicker: FakeImageAttachmentPicker(
        image: PickedImageAttachment(
          filename: 'screenshot.png',
          contentType: 'image/png',
          bytes: const <int>[137, 80, 78, 71],
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mobile migration'));
    await tester.pumpAndSettle();
    await choosePhotoLibraryAttachment(tester);

    expect(api.uploadedAttachments, ['sess_1:screenshot.png:image/png:4']);
    expect(find.text('screenshot.png'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('attachment-chip-retry-screenshot.png')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('attachment-chip-delete-screenshot.png')),
      findsOneWidget,
    );
    expect(hapticCalls, contains('HapticFeedbackType.warningNotification'));
    final sendButton = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.arrow_upward_rounded),
        matching: find.byType(IconButton),
      ),
    );
    expect(sendButton.onPressed, isNull);

    await tester.tap(
      find.byKey(const ValueKey('attachment-chip-delete-screenshot.png')),
    );
    await tester.pumpAndSettle();

    expect(find.text('screenshot.png'), findsNothing);
    expect(
      find.byKey(const ValueKey('attachment-chip-retry-screenshot.png')),
      findsNothing,
    );
  });

  testWidgets('routes back to login for 401 image upload errors', (
    tester,
  ) async {
    final storage = MemoryAuthStorage();
    final api = FakeDaemonApi(
      bootstrap: const MobileBootstrap(
        daemonVersion: '0.1.0',
        user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: <WorkspaceRoot>[],
        sessions: [
          SessionSummary(
            id: 'sess_1',
            title: 'Expired upload',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            status: 'running',
            workspacePath: '/home/jhz/projects/agent-dock',
          ),
        ],
        voice: VoiceConfig(doubaoDirectAvailable: false),
      ),
      snapshot: const SessionSnapshot(
        id: 'sess_1',
        title: 'Expired upload',
        agentKind: 'codex',
        sourceKind: 'managed',
        runtimeSessionId: 'runtime_1',
        workspacePath: '/home/jhz/projects/agent-dock',
        status: 'running',
        hasMoreHistory: false,
        events: <SessionEvent>[],
      ),
      uploadAttachmentErrors: const [
        DaemonApiException(
          statusCode: 401,
          code: 'UNAUTHORIZED',
          message: 'Unauthorized',
        ),
      ],
    );

    await pumpApp(
      tester,
      api: api,
      storage: storage,
      attachmentPicker: FakeImageAttachmentPicker(
        image: PickedImageAttachment(
          filename: 'expired.png',
          contentType: 'image/png',
          bytes: const <int>[137, 80, 78, 71],
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Expired upload'));
    await tester.pumpAndSettle();

    await choosePhotoLibraryAttachment(tester);
    await tester.pumpAndSettle();

    expect(api.uploadedAttachments, ['sess_1:expired.png:image/png:4']);
    expect(storage.didClear, isTrue);
    expect(storage.profile, isNull);
    expect(find.text('Unlock workspace'), findsOneWidget);
    expect(find.text('Expired upload'), findsNothing);
    expect(find.text('Session expired. Sign in again.'), findsOneWidget);
    expect(find.text('expired.png'), findsNothing);
  });

  testWidgets('retrying a failed image upload reuses it in the send payload', (
    tester,
  ) async {
    final api = FakeDaemonApi(
      bootstrap: MobileBootstrap(
        daemonVersion: '0.1.0',
        user: const CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: const <WorkspaceRoot>[],
        sessions: const [
          SessionSummary(
            id: 'sess_1',
            title: 'Mobile migration',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            status: 'running',
            workspacePath: '/home/jhz/projects/agent-dock',
          ),
        ],
        voice: const VoiceConfig(doubaoDirectAvailable: false),
      ),
      snapshot: const SessionSnapshot(
        id: 'sess_1',
        title: 'Mobile migration',
        agentKind: 'codex',
        sourceKind: 'managed',
        runtimeSessionId: 'runtime_1',
        workspacePath: '/home/jhz/projects/agent-dock',
        status: 'running',
        hasMoreHistory: false,
        events: <SessionEvent>[],
      ),
      uploadAttachmentErrors: const [
        DaemonApiException(
          statusCode: 503,
          code: 'UNAVAILABLE',
          message: 'Upload failed',
        ),
      ],
    );

    await pumpApp(
      tester,
      api: api,
      attachmentPicker: FakeImageAttachmentPicker(
        image: PickedImageAttachment(
          filename: 'screenshot.png',
          contentType: 'image/png',
          bytes: const <int>[137, 80, 78, 71],
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mobile migration'));
    await tester.pumpAndSettle();
    await choosePhotoLibraryAttachment(tester);

    await tester.tap(
      find.byKey(const ValueKey('attachment-chip-retry-screenshot.png')),
    );
    await tester.pumpAndSettle();

    expect(api.uploadedAttachments, [
      'sess_1:screenshot.png:image/png:4',
      'sess_1:screenshot.png:image/png:4',
    ]);
    await tester.enterText(
      find.widgetWithText(TextField, 'Message the agent'),
      'include screenshot',
    );
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();

    expect(api.sentMessages, [
      'sess_1:include screenshot|/tmp/attachments/sess_1/screenshot.png',
    ]);
    expect(find.text('screenshot.png'), findsNothing);
  });

  testWidgets('uploads multiple images and sends all attachment paths', (
    tester,
  ) async {
    final api = FakeDaemonApi(
      bootstrap: MobileBootstrap(
        daemonVersion: '0.1.0',
        user: const CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: const <WorkspaceRoot>[],
        sessions: const [
          SessionSummary(
            id: 'sess_1',
            title: 'Mobile migration',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            status: 'running',
            workspacePath: '/home/jhz/projects/agent-dock',
          ),
        ],
        voice: const VoiceConfig(doubaoDirectAvailable: false),
      ),
      snapshot: const SessionSnapshot(
        id: 'sess_1',
        title: 'Mobile migration',
        agentKind: 'codex',
        sourceKind: 'managed',
        runtimeSessionId: 'runtime_1',
        workspacePath: '/home/jhz/projects/agent-dock',
        status: 'running',
        hasMoreHistory: false,
        events: <SessionEvent>[],
      ),
    );

    await pumpApp(
      tester,
      api: api,
      attachmentPicker: FakeImageAttachmentPicker(
        images: const [
          PickedImageAttachment(
            filename: 'first.png',
            contentType: 'image/png',
            bytes: <int>[1, 2, 3],
          ),
          PickedImageAttachment(
            filename: 'second.png',
            contentType: 'image/png',
            bytes: <int>[4, 5, 6],
          ),
        ],
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mobile migration'));
    await tester.pumpAndSettle();

    await choosePhotoLibraryAttachment(tester);
    await choosePhotoLibraryAttachment(tester);

    expect(find.text('first.png'), findsOneWidget);
    expect(find.text('second.png'), findsOneWidget);

    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();

    expect(api.sentMessages, [
      'sess_1:|/tmp/attachments/sess_1/first.png,/tmp/attachments/sess_1/second.png',
    ]);
    expect(find.text('first.png'), findsNothing);
    expect(find.text('second.png'), findsNothing);
  });

  testWidgets('removing one attachment excludes it from the send payload', (
    tester,
  ) async {
    final api = FakeDaemonApi(
      bootstrap: MobileBootstrap(
        daemonVersion: '0.1.0',
        user: const CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: const <WorkspaceRoot>[],
        sessions: const [
          SessionSummary(
            id: 'sess_1',
            title: 'Mobile migration',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            status: 'running',
            workspacePath: '/home/jhz/projects/agent-dock',
          ),
        ],
        voice: const VoiceConfig(doubaoDirectAvailable: false),
      ),
      snapshot: const SessionSnapshot(
        id: 'sess_1',
        title: 'Mobile migration',
        agentKind: 'codex',
        sourceKind: 'managed',
        runtimeSessionId: 'runtime_1',
        workspacePath: '/home/jhz/projects/agent-dock',
        status: 'running',
        hasMoreHistory: false,
        events: <SessionEvent>[],
      ),
    );

    await pumpApp(
      tester,
      api: api,
      attachmentPicker: FakeImageAttachmentPicker(
        images: const [
          PickedImageAttachment(
            filename: 'first.png',
            contentType: 'image/png',
            bytes: <int>[1, 2, 3],
          ),
          PickedImageAttachment(
            filename: 'second.png',
            contentType: 'image/png',
            bytes: <int>[4, 5, 6],
          ),
        ],
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mobile migration'));
    await tester.pumpAndSettle();

    await choosePhotoLibraryAttachment(tester);
    await choosePhotoLibraryAttachment(tester);

    await tester.tap(
      find.byKey(const ValueKey('attachment-chip-delete-first.png')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('attachment-chip-remove-first.png')),
      findsOneWidget,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();

    expect(api.sentMessages, ['sess_1:|/tmp/attachments/sess_1/second.png']);
    expect(find.text('first.png'), findsNothing);
    expect(find.text('second.png'), findsNothing);
  });

  testWidgets('reduced motion keeps attachment removal static', (tester) async {
    tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(
          disableAnimations: true,
          reduceMotion: true,
        );
    addTearDown(
      tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
    );

    final api = FakeDaemonApi(
      bootstrap: MobileBootstrap(
        daemonVersion: '0.1.0',
        user: const CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: const <WorkspaceRoot>[],
        sessions: const [
          SessionSummary(
            id: 'sess_1',
            title: 'Mobile migration',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            status: 'running',
            workspacePath: '/home/jhz/projects/agent-dock',
          ),
        ],
        voice: const VoiceConfig(doubaoDirectAvailable: false),
      ),
      snapshot: const SessionSnapshot(
        id: 'sess_1',
        title: 'Mobile migration',
        agentKind: 'codex',
        sourceKind: 'managed',
        runtimeSessionId: 'runtime_1',
        workspacePath: '/home/jhz/projects/agent-dock',
        status: 'running',
        hasMoreHistory: false,
        events: <SessionEvent>[],
      ),
    );

    await pumpApp(
      tester,
      api: api,
      attachmentPicker: FakeImageAttachmentPicker(
        images: const [
          PickedImageAttachment(
            filename: 'first.png',
            contentType: 'image/png',
            bytes: <int>[1, 2, 3],
          ),
          PickedImageAttachment(
            filename: 'second.png',
            contentType: 'image/png',
            bytes: <int>[4, 5, 6],
          ),
        ],
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mobile migration'));
    await tester.pumpAndSettle();

    await choosePhotoLibraryAttachment(tester);
    await choosePhotoLibraryAttachment(tester);

    await tester.tap(
      find.byKey(const ValueKey('attachment-chip-delete-first.png')),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('attachment-chip-remove-first.png')),
      findsNothing,
    );

    await tester.pumpAndSettle();
    expect(find.text('first.png'), findsNothing);
    expect(find.text('second.png'), findsOneWidget);
  });

  testWidgets('creates a managed session from the sessions page', (
    tester,
  ) async {
    final api = FakeDaemonApi(
      bootstrap: const MobileBootstrap(
        daemonVersion: '0.1.0',
        user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: [
          WorkspaceRoot(
            id: 'workspace',
            label: 'Workspace',
            path: '/home/jhz/projects',
          ),
        ],
        sessions: <SessionSummary>[],
        voice: VoiceConfig(doubaoDirectAvailable: false),
      ),
      createResult: const SessionSnapshot(
        id: 'sess_new',
        title: 'Fresh mobile session',
        agentKind: 'codex',
        sourceKind: 'managed',
        runtimeSessionId: null,
        workspacePath: 'agent-dock',
        status: 'created',
        hasMoreHistory: false,
        events: <SessionEvent>[],
      ),
    );
    await pumpApp(tester, api: api);

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'New session').first);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Session name'),
      'Fresh mobile session',
    );
    await tester.tap(find.text('Edit path'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Path'),
      'agent-dock',
    );
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(api.createdSessions, [
      'workspace:agent-dock:codex:Fresh mobile session',
    ]);
    expect(find.text('Fresh mobile session'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Message the agent'), findsOneWidget);
  });

  testWidgets('new session avoids spinner flicker for quick creation', (
    tester,
  ) async {
    final api = FakeDaemonApi(
      bootstrap: const MobileBootstrap(
        daemonVersion: '0.1.0',
        user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: [
          WorkspaceRoot(
            id: 'workspace',
            label: 'Workspace',
            path: '/home/jhz/projects',
          ),
        ],
        sessions: <SessionSummary>[],
        voice: VoiceConfig(doubaoDirectAvailable: false),
      ),
      createDelay: const Duration(milliseconds: 200),
      createResult: const SessionSnapshot(
        id: 'sess_new',
        title: 'Fresh mobile session',
        agentKind: 'codex',
        sourceKind: 'managed',
        runtimeSessionId: null,
        workspacePath: 'agent-dock',
        status: 'created',
        hasMoreHistory: false,
        events: <SessionEvent>[],
      ),
    );
    await pumpApp(tester, api: api);

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'New session').first);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Session name'),
      'Fresh mobile session',
    );
    await tester.tap(find.text('Edit path'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Path'),
      'agent-dock',
    );
    await tester.tap(find.text('Create'));
    await tester.pump();

    expect(find.byKey(const ValueKey('create-session-spinner')), findsNothing);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Creating...'),
          )
          .onPressed,
      isNull,
    );

    await tester.pump(const Duration(milliseconds: 220));
    await tester.pumpAndSettle();
  });

  testWidgets('navigates directly to the new session detail after creation', (
    tester,
  ) async {
    final api = FakeDaemonApi(
      bootstrap: const MobileBootstrap(
        daemonVersion: '0.1.0',
        user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: [
          WorkspaceRoot(
            id: 'workspace',
            label: 'Workspace',
            path: '/home/jhz/projects',
          ),
        ],
        sessions: <SessionSummary>[],
        voice: VoiceConfig(doubaoDirectAvailable: false),
      ),
      createResult: const SessionSnapshot(
        id: 'sess_new',
        title: 'Fresh mobile session',
        agentKind: 'codex',
        sourceKind: 'managed',
        runtimeSessionId: null,
        workspacePath: 'agent-dock',
        status: 'created',
        hasMoreHistory: false,
        events: <SessionEvent>[],
      ),
    );
    await pumpApp(tester, api: api);

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'New session').first);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Session name'),
      'Fresh mobile session',
    );
    await tester.tap(find.text('Edit path'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Path'),
      'agent-dock',
    );
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Session details'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Message the agent'), findsOneWidget);
    expect(find.text('Sessions'), findsNothing);
  });

  testWidgets(
    'creating a session refreshes an existing row instead of duplicating the same session id',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: [
            WorkspaceRoot(
              id: 'workspace',
              label: 'Workspace',
              path: '/home/jhz/projects',
            ),
          ],
          sessions: [
            SessionSummary(
              id: 'sess_new',
              title: 'Old session title',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: null,
              status: 'completed',
              workspacePath: 'agent-dock',
            ),
          ],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
        createResult: const SessionSnapshot(
          id: 'sess_new',
          title: 'Fresh mobile session',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: null,
          workspacePath: 'agent-dock',
          status: 'created',
          hasMoreHistory: false,
          events: <SessionEvent>[],
        ),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      expect(find.text('Old session title'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'New session').first);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Session name'),
        'Fresh mobile session',
      );
      await tester.tap(find.text('Edit path'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Path'),
        'agent-dock',
      );
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      expect(find.text('Fresh mobile session'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.text('Fresh mobile session'), findsOneWidget);
      expect(find.text('Old session title'), findsNothing);
      expect(
        find.byKey(const ValueKey('session-row-inkwell-sess_new')),
        findsOneWidget,
      );
      expect(find.text('created'), findsOneWidget);
    },
  );

  testWidgets('routes back to login when creating a session returns 401', (
    tester,
  ) async {
    final storage = MemoryAuthStorage();
    final api = FakeDaemonApi(
      bootstrap: const MobileBootstrap(
        daemonVersion: '0.1.0',
        user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: [
          WorkspaceRoot(
            id: 'workspace',
            label: 'Workspace',
            path: '/home/jhz/projects',
          ),
        ],
        sessions: <SessionSummary>[],
        voice: VoiceConfig(doubaoDirectAvailable: false),
      ),
      createError: const DaemonApiException(
        statusCode: 401,
        code: 'UNAUTHORIZED',
        message: 'Unauthorized',
      ),
    );
    await pumpApp(tester, api: api, storage: storage);

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'New session').first);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Session name'),
      'Fresh mobile session',
    );
    await tester.tap(find.text('Edit path'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Path'),
      'agent-dock',
    );
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(api.createdSessions, [
      'workspace:agent-dock:codex:Fresh mobile session',
    ]);
    expect(storage.didClear, isTrue);
    expect(storage.profile, isNull);
    expect(find.text('Unlock workspace'), findsOneWidget);
    expect(find.text('Fresh mobile session'), findsNothing);
    expect(find.text('Session expired. Sign in again.'), findsOneWidget);
  });

  testWidgets(
    'new session keeps the sheet open and shows an inline API error on failure',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: [
            WorkspaceRoot(
              id: 'workspace',
              label: 'Workspace',
              path: '/home/jhz/projects',
            ),
          ],
          sessions: <SessionSummary>[],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
        createError: const DaemonApiException(
          statusCode: 500,
          code: 'CREATE_FAILED',
          message: 'Could not create session',
        ),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'New session').first);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Session name'),
        'Fresh mobile session',
      );
      await tester.tap(find.text('Edit path'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Path'),
        'agent-dock',
      );
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('Could not create session'), findsOneWidget);
      expect(
        find.text(
          'DaemonApiException(500, CREATE_FAILED, Could not create session)',
        ),
        findsNothing,
      );
      expect(
        find.widgetWithText(TextField, 'Fresh mobile session'),
        findsOneWidget,
      );
      expect(find.widgetWithText(TextField, 'agent-dock'), findsOneWidget);
    },
  );

  testWidgets(
    'new session keeps the sheet open and shows the shared offline message on network failure',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: [
            WorkspaceRoot(
              id: 'workspace',
              label: 'Workspace',
              path: '/home/jhz/projects',
            ),
          ],
          sessions: <SessionSummary>[],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
        createError: const SocketException('Network is unreachable'),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'New session').first);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Session name'),
        'Fresh mobile session',
      );
      await tester.tap(find.text('Edit path'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Path'),
        'agent-dock',
      );
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('Offline. Waiting for network...'), findsOneWidget);
      expect(
        find.text('SocketException: Network is unreachable'),
        findsNothing,
      );
      expect(
        find.widgetWithText(TextField, 'Fresh mobile session'),
        findsOneWidget,
      );
      expect(find.widgetWithText(TextField, 'agent-dock'), findsOneWidget);
    },
  );

  testWidgets(
    'new session keeps the sheet open and shows a user-facing fallback for unexpected failures',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: [
            WorkspaceRoot(
              id: 'workspace',
              label: 'Workspace',
              path: '/home/jhz/projects',
            ),
          ],
          sessions: <SessionSummary>[],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
        createError: StateError('Create flow corrupted'),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'New session').first);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Session name'),
        'Fresh mobile session',
      );
      await tester.tap(find.text('Edit path'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Path'),
        'agent-dock',
      );
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('Could not create session'), findsOneWidget);
      expect(find.text('Bad state: Create flow corrupted'), findsNothing);
      expect(
        find.widgetWithText(TextField, 'Fresh mobile session'),
        findsOneWidget,
      );
      expect(find.widgetWithText(TextField, 'agent-dock'), findsOneWidget);
    },
  );

  testWidgets(
    'new session dialog lets the user browse directories to fill path',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: [
            WorkspaceRoot(
              id: 'workspace',
              label: 'Workspace',
              path: '/home/jhz/projects',
            ),
          ],
          sessions: <SessionSummary>[],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
        createResult: const SessionSnapshot(
          id: 'sess_new',
          title: 'Fresh mobile session',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: null,
          workspacePath: 'agent-dock',
          status: 'created',
          hasMoreHistory: false,
          events: <SessionEvent>[],
        ),
        directoryListings: {
          '/home/jhz/projects': const WorkspaceDirectoryListing(
            currentPath: '/home/jhz/projects',
            parentPath: '/home/jhz',
            directories: [
              WorkspaceDirectoryEntry(
                name: 'agent-dock',
                path: '/home/jhz/projects/agent-dock',
              ),
              WorkspaceDirectoryEntry(
                name: 'demo-app',
                path: '/home/jhz/projects/demo-app',
              ),
            ],
          ),
          '/home/jhz/projects/agent-dock': const WorkspaceDirectoryListing(
            currentPath: '/home/jhz/projects/agent-dock',
            parentPath: '/home/jhz/projects',
            directories: [],
          ),
        },
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'New session').first);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'Session name'),
        'Fresh mobile session',
      );
      await tester.tap(find.text('Browse'));
      await tester.pumpAndSettle();
      expect(find.text('Choose directory'), findsOneWidget);
      await tester.tap(find.text('agent-dock'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use this folder'));
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(TextField, '/home/jhz/projects/agent-dock'),
        findsOneWidget,
      );

      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      expect(api.directoryRequests, [
        '/home/jhz/projects',
        '/home/jhz/projects/agent-dock',
      ]);
      expect(api.createdSessions, [
        'workspace:/home/jhz/projects/agent-dock:codex:Fresh mobile session',
      ]);
    },
  );

  testWidgets('new session directory browsing shows a user-facing load error', (
    tester,
  ) async {
    final api = FakeDaemonApi(
      bootstrap: const MobileBootstrap(
        daemonVersion: '0.1.0',
        user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: [
          WorkspaceRoot(
            id: 'workspace',
            label: 'Workspace',
            path: '/home/jhz/projects',
          ),
        ],
        sessions: <SessionSummary>[],
        voice: VoiceConfig(doubaoDirectAvailable: false),
      ),
    );
    await pumpApp(tester, api: api);

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'New session').first);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Browse'));
    await tester.pumpAndSettle();

    expect(find.text('Could not load directories'), findsOneWidget);
    expect(
      find.textContaining('No directory listing stub for /home/jhz/projects'),
      findsNothing,
    );
  });

  testWidgets(
    'routes back to login when new session directory browsing returns 401',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: [
            WorkspaceRoot(
              id: 'workspace',
              label: 'Workspace',
              path: '/home/jhz/projects',
            ),
          ],
          sessions: <SessionSummary>[],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
        directoryErrors: {
          '/home/jhz/projects': const DaemonApiException(
            statusCode: 401,
            code: 'UNAUTHORIZED',
            message: 'Unauthorized',
          ),
        },
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'New session').first);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Browse'));
      await tester.pumpAndSettle();

      expect(find.text('Unlock workspace'), findsOneWidget);
      expect(find.text('Session expired. Sign in again.'), findsOneWidget);
      expect(find.text('Choose directory'), findsNothing);
    },
  );

  testWidgets(
    'new session dialog keeps manual path editing behind an edit affordance',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: [
            WorkspaceRoot(
              id: 'workspace',
              label: 'Workspace',
              path: '/home/jhz/projects',
            ),
          ],
          sessions: <SessionSummary>[],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'New session').first);
      await tester.pumpAndSettle();

      expect(find.text('Edit path'), findsOneWidget);
      final pathFieldBeforeEdit = tester.widget<TextField>(
        find.widgetWithText(TextField, '/home/jhz/projects'),
      );
      expect(pathFieldBeforeEdit.readOnly, isTrue);

      await tester.tap(find.text('Edit path'));
      await tester.pumpAndSettle();

      final pathFieldAfterEdit = tester.widget<TextField>(
        find.widgetWithText(TextField, '/home/jhz/projects'),
      );
      expect(pathFieldAfterEdit.readOnly, isFalse);
    },
  );

  testWidgets(
    'new session dialog shows single-root context instead of a root dropdown',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: [
            WorkspaceRoot(
              id: 'workspace',
              label: 'Workspace',
              path: '/home/jhz/projects',
            ),
          ],
          sessions: <SessionSummary>[],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'New session').first);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('create-session-root')), findsNothing);
      expect(
        find.byKey(const ValueKey('create-session-root-context')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('create-session-root-context')),
          matching: find.text('Workspace root'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('create-session-root-context')),
          matching: find.text('Workspace'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('create-session-root-context')),
          matching: find.text('/home/jhz/projects'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'new session dialog lets the user choose a different workspace root',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: [
            WorkspaceRoot(
              id: 'workspace',
              label: 'Workspace',
              path: '/home/jhz/projects',
            ),
            WorkspaceRoot(id: 'docs', label: 'Docs', path: '/srv/docs'),
          ],
          sessions: <SessionSummary>[],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
        createResult: const SessionSnapshot(
          id: 'sess_docs',
          title: 'Docs session',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: null,
          workspacePath: '/srv/docs/release-notes',
          status: 'created',
          hasMoreHistory: false,
          events: <SessionEvent>[],
        ),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'New session').first);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('create-session-root')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Docs').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Session name'),
        'Docs session',
      );
      await tester.tap(find.text('Edit path'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Path'),
        '/srv/docs/release-notes',
      );
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      expect(api.createdSessions, [
        'docs:/srv/docs/release-notes:codex:Docs session',
      ]);
      expect(find.text('Docs session'), findsOneWidget);
    },
  );

  testWidgets(
    'new session shows a spec-aligned required error when the session name is missing',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: [
            WorkspaceRoot(
              id: 'workspace',
              label: 'Workspace',
              path: '/home/jhz/projects',
            ),
          ],
          sessions: <SessionSummary>[],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'New session').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      expect(find.text('Session name is required'), findsOneWidget);
      expect(find.text('Title and path are required'), findsNothing);
      expect(api.createdSessions, isEmpty);
    },
  );

  testWidgets(
    'new session shows a spec-aligned required error when the path is missing',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: [
            WorkspaceRoot(
              id: 'workspace',
              label: 'Workspace',
              path: '/home/jhz/projects',
            ),
          ],
          sessions: <SessionSummary>[],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'New session').first);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Session name'),
        'Fresh mobile session',
      );
      await tester.tap(find.text('Edit path'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Path'), '');
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      expect(find.text('Path is required'), findsOneWidget);
      expect(api.createdSessions, isEmpty);
    },
  );

  testWidgets('new session dialog lets the user switch agent kind', (
    tester,
  ) async {
    final api = FakeDaemonApi(
      bootstrap: const MobileBootstrap(
        daemonVersion: '0.1.0',
        user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: [
          WorkspaceRoot(
            id: 'workspace',
            label: 'Workspace',
            path: '/home/jhz/projects',
          ),
        ],
        sessions: <SessionSummary>[],
        voice: VoiceConfig(doubaoDirectAvailable: false),
      ),
      createResult: const SessionSnapshot(
        id: 'sess_claude',
        title: 'Claude session',
        agentKind: 'claude',
        sourceKind: 'managed',
        runtimeSessionId: null,
        workspacePath: '/home/jhz/projects/agent-dock',
        status: 'created',
        hasMoreHistory: false,
        events: <SessionEvent>[],
      ),
    );
    await pumpApp(tester, api: api);

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'New session').first);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('create-session-agent-claude')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Session name'),
      'Claude session',
    );
    await tester.tap(find.text('Edit path'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Path'),
      '/home/jhz/projects/agent-dock',
    );
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(api.createdSessions, [
      'workspace:/home/jhz/projects/agent-dock:claude:Claude session',
    ]);
    expect(find.text('Claude session'), findsOneWidget);
  });

  testWidgets('newly created sessions animate in from the top of the list', (
    tester,
  ) async {
    final api = FakeDaemonApi(
      bootstrap: const MobileBootstrap(
        daemonVersion: '0.1.0',
        user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: [
          WorkspaceRoot(
            id: 'workspace',
            label: 'Workspace',
            path: '/home/jhz/projects',
          ),
        ],
        sessions: <SessionSummary>[],
        voice: VoiceConfig(doubaoDirectAvailable: false),
      ),
      createResult: const SessionSnapshot(
        id: 'sess_new',
        title: 'Fresh mobile session',
        agentKind: 'codex',
        sourceKind: 'managed',
        runtimeSessionId: null,
        workspacePath: 'agent-dock',
        status: 'created',
        hasMoreHistory: false,
        events: <SessionEvent>[],
      ),
    );
    await pumpApp(tester, api: api);

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'New session').first);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Session name'),
      'Fresh mobile session',
    );
    await tester.tap(find.text('Edit path'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Path'),
      'agent-dock',
    );
    await tester.tap(find.text('Create'));
    await tester.pump();

    final slide = tester.widget<AnimatedSlide>(
      find.byKey(const ValueKey('session-row-slide-sess_new')),
    );
    expect(slide.offset.dy, greaterThan(0));
    final opacity = tester.widget<AnimatedOpacity>(
      find.byKey(const ValueKey('session-row-opacity-sess_new')),
    );
    expect(opacity.opacity, lessThan(1));

    await tester.pumpAndSettle();

    expect(find.text('Fresh mobile session'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Message the agent'), findsOneWidget);
  });

  testWidgets(
    'newly created sessions stay static when reduced motion is enabled',
    (tester) async {
      tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(
            disableAnimations: true,
            reduceMotion: true,
          );
      addTearDown(
        tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );

      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: [
            WorkspaceRoot(
              id: 'workspace',
              label: 'Workspace',
              path: '/home/jhz/projects',
            ),
          ],
          sessions: <SessionSummary>[],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
        createResult: const SessionSnapshot(
          id: 'sess_new',
          title: 'Fresh mobile session',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: null,
          workspacePath: 'agent-dock',
          status: 'created',
          hasMoreHistory: false,
          events: <SessionEvent>[],
        ),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'New session').first);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Session name'),
        'Fresh mobile session',
      );
      await tester.tap(find.text('Edit path'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Path'),
        'agent-dock',
      );
      await tester.tap(find.text('Create'));
      await tester.pump();

      final slide = tester.widget<AnimatedSlide>(
        find.byKey(const ValueKey('session-row-slide-sess_new')),
      );
      expect(slide.offset, Offset.zero);
      final opacity = tester.widget<AnimatedOpacity>(
        find.byKey(const ValueKey('session-row-opacity-sess_new')),
      );
      expect(opacity.opacity, 1);

      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'new session opens as a mobile bottom sheet instead of an alert dialog',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: [
            WorkspaceRoot(
              id: 'workspace',
              label: 'Workspace',
              path: '/home/jhz/projects',
            ),
          ],
          sessions: <SessionSummary>[],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'New session').first);
      await tester.pumpAndSettle();

      expect(find.text('New session'), findsAtLeastNWidgets(1));
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  testWidgets(
    'new session sheet uses the spec labels for the name field and primary action',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: [
            WorkspaceRoot(
              id: 'workspace',
              label: 'Workspace',
              path: '/home/jhz/projects',
            ),
          ],
          sessions: <SessionSummary>[],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'New session').first);
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextField, 'Session name'), findsOneWidget);
      expect(find.text('Create'), findsOneWidget);
      expect(find.text('Title'), findsNothing);
      expect(find.text('Create session'), findsNothing);
    },
  );

  testWidgets('new session sheet shows the spec description under the title', (
    tester,
  ) async {
    final api = FakeDaemonApi(
      bootstrap: const MobileBootstrap(
        daemonVersion: '0.1.0',
        user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: [
          WorkspaceRoot(
            id: 'workspace',
            label: 'Workspace',
            path: '/home/jhz/projects',
          ),
        ],
        sessions: <SessionSummary>[],
        voice: VoiceConfig(doubaoDirectAvailable: false),
      ),
    );
    await pumpApp(tester, api: api);

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'New session').first);
    await tester.pumpAndSettle();

    expect(
      find.text('Create a new managed session in a workspace root.'),
      findsOneWidget,
    );
  });

  testWidgets('attaches an existing runtime session from the sessions page', (
    tester,
  ) async {
    final api = FakeDaemonApi(
      bootstrap: const MobileBootstrap(
        daemonVersion: '0.1.0',
        user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: [
          WorkspaceRoot(
            id: 'workspace',
            label: 'Workspace',
            path: '/home/jhz/projects',
          ),
        ],
        sessions: <SessionSummary>[],
        voice: VoiceConfig(doubaoDirectAvailable: false),
      ),
      attachResult: const SessionSnapshot(
        id: 'sess_attached',
        title: null,
        agentKind: 'claude',
        sourceKind: 'attached',
        runtimeSessionId: 'thread-abc',
        workspacePath: 'agent-dock',
        status: 'attached',
        hasMoreHistory: false,
        events: <SessionEvent>[],
      ),
    );
    await pumpApp(tester, api: api);

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Attach'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit path'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Path'),
      'agent-dock',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Runtime session ID'),
      'thread-abc',
    );
    await tester.tap(
      find
          .descendant(
            of: find.byType(BottomSheet),
            matching: find.text('Attach'),
          )
          .last,
    );
    await tester.pumpAndSettle();

    expect(api.attachedSessions, ['workspace:agent-dock:claude:thread-abc']);
    expect(find.byTooltip('Session details'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Message the agent'), findsOneWidget);
  });

  testWidgets('attach session avoids spinner flicker for quick attaches', (
    tester,
  ) async {
    final api = FakeDaemonApi(
      bootstrap: const MobileBootstrap(
        daemonVersion: '0.1.0',
        user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: [
          WorkspaceRoot(
            id: 'workspace',
            label: 'Workspace',
            path: '/home/jhz/projects',
          ),
        ],
        sessions: <SessionSummary>[],
        voice: VoiceConfig(doubaoDirectAvailable: false),
      ),
      attachDelay: const Duration(milliseconds: 200),
      attachResult: const SessionSnapshot(
        id: 'sess_attached',
        title: 'Attached runtime',
        agentKind: 'claude',
        sourceKind: 'attached',
        runtimeSessionId: 'thread-abc',
        workspacePath: 'agent-dock',
        status: 'attached',
        hasMoreHistory: false,
        events: <SessionEvent>[],
      ),
    );
    await pumpApp(tester, api: api);

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Attach'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit path'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Path'),
      'agent-dock',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Runtime session ID'),
      'thread-abc',
    );
    await tester.tap(
      find
          .descendant(
            of: find.byType(BottomSheet),
            matching: find.text('Attach'),
          )
          .last,
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('attach-session-spinner')), findsNothing);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Attaching...'),
          )
          .onPressed,
      isNull,
    );

    await tester.pump(const Duration(milliseconds: 220));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'navigates directly to the attached session detail after attach',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: [
            WorkspaceRoot(
              id: 'workspace',
              label: 'Workspace',
              path: '/home/jhz/projects',
            ),
          ],
          sessions: <SessionSummary>[],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
        attachResult: const SessionSnapshot(
          id: 'sess_attached',
          title: 'Attached runtime',
          agentKind: 'claude',
          sourceKind: 'attached',
          runtimeSessionId: 'thread-abc',
          workspacePath: 'agent-dock',
          status: 'attached',
          hasMoreHistory: false,
          events: <SessionEvent>[],
        ),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Attach'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit path'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Path'),
        'agent-dock',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Runtime session ID'),
        'thread-abc',
      );
      await tester.tap(
        find
            .descendant(
              of: find.byType(BottomSheet),
              matching: find.text('Attach'),
            )
            .last,
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('Session details'), findsOneWidget);
      expect(
        find.widgetWithText(TextField, 'Message the agent'),
        findsOneWidget,
      );
      expect(find.text('Sessions'), findsNothing);
    },
  );

  testWidgets('routes back to login when attaching a session returns 401', (
    tester,
  ) async {
    final storage = MemoryAuthStorage();
    final api = FakeDaemonApi(
      bootstrap: const MobileBootstrap(
        daemonVersion: '0.1.0',
        user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: [
          WorkspaceRoot(
            id: 'workspace',
            label: 'Workspace',
            path: '/home/jhz/projects',
          ),
        ],
        sessions: <SessionSummary>[],
        voice: VoiceConfig(doubaoDirectAvailable: false),
      ),
      attachError: const DaemonApiException(
        statusCode: 401,
        code: 'UNAUTHORIZED',
        message: 'Unauthorized',
      ),
    );
    await pumpApp(tester, api: api, storage: storage);

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Attach'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit path'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Path'),
      'agent-dock',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Runtime session ID'),
      'thread-abc',
    );
    await tester.tap(
      find
          .descendant(
            of: find.byType(BottomSheet),
            matching: find.text('Attach'),
          )
          .last,
    );
    await tester.pumpAndSettle();

    expect(api.attachedSessions, ['workspace:agent-dock:claude:thread-abc']);
    expect(storage.didClear, isTrue);
    expect(storage.profile, isNull);
    expect(find.text('Unlock workspace'), findsOneWidget);
    expect(find.text('Session expired. Sign in again.'), findsOneWidget);
    expect(find.text('Attached runtime'), findsNothing);
  });

  testWidgets(
    'attach session keeps the sheet open and shows an inline API error on failure',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: [
            WorkspaceRoot(
              id: 'workspace',
              label: 'Workspace',
              path: '/home/jhz/projects',
            ),
          ],
          sessions: <SessionSummary>[],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
        attachError: const DaemonApiException(
          statusCode: 500,
          code: 'ATTACH_FAILED',
          message: 'Could not attach session',
        ),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Attach'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit path'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Path'),
        'agent-dock',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Runtime session ID'),
        'thread-abc',
      );
      await tester.tap(
        find
            .descendant(
              of: find.byType(BottomSheet),
              matching: find.text('Attach'),
            )
            .last,
      );
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('Could not attach session'), findsOneWidget);
      expect(
        find.text(
          'DaemonApiException(500, ATTACH_FAILED, Could not attach session)',
        ),
        findsNothing,
      );
      expect(find.widgetWithText(TextField, 'agent-dock'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'thread-abc'), findsOneWidget);
    },
  );

  testWidgets(
    'attach session keeps the sheet open and shows the shared offline message on network failure',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: [
            WorkspaceRoot(
              id: 'workspace',
              label: 'Workspace',
              path: '/home/jhz/projects',
            ),
          ],
          sessions: <SessionSummary>[],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
        attachError: const SocketException('Network is unreachable'),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Attach'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit path'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Path'),
        'agent-dock',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Runtime session ID'),
        'thread-abc',
      );
      await tester.tap(
        find
            .descendant(
              of: find.byType(BottomSheet),
              matching: find.text('Attach'),
            )
            .last,
      );
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('Offline. Waiting for network...'), findsOneWidget);
      expect(
        find.text('SocketException: Network is unreachable'),
        findsNothing,
      );
      expect(find.widgetWithText(TextField, 'agent-dock'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'thread-abc'), findsOneWidget);
    },
  );

  testWidgets(
    'attach session keeps the sheet open and shows a user-facing fallback for unexpected failures',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: [
            WorkspaceRoot(
              id: 'workspace',
              label: 'Workspace',
              path: '/home/jhz/projects',
            ),
          ],
          sessions: <SessionSummary>[],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
        attachError: StateError('Attach flow corrupted'),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Attach'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit path'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Path'),
        'agent-dock',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Runtime session ID'),
        'thread-abc',
      );
      await tester.tap(
        find
            .descendant(
              of: find.byType(BottomSheet),
              matching: find.text('Attach'),
            )
            .last,
      );
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('Could not attach session'), findsOneWidget);
      expect(find.text('Bad state: Attach flow corrupted'), findsNothing);
      expect(find.widgetWithText(TextField, 'agent-dock'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'thread-abc'), findsOneWidget);
    },
  );

  testWidgets(
    'attach session shows a spec-aligned required error when the runtime session id is missing',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: [
            WorkspaceRoot(
              id: 'workspace',
              label: 'Workspace',
              path: '/home/jhz/projects',
            ),
          ],
          sessions: <SessionSummary>[],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Attach'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit path'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Path'),
        'agent-dock',
      );
      await tester.tap(
        find
            .descendant(
              of: find.byType(BottomSheet),
              matching: find.text('Attach'),
            )
            .last,
      );
      await tester.pumpAndSettle();

      expect(find.text('Runtime session ID is required'), findsOneWidget);
      expect(
        find.text('Path and runtime session ID are required'),
        findsNothing,
      );
      expect(api.attachedSessions, isEmpty);
    },
  );

  testWidgets(
    'attach session shows a spec-aligned required error when the path is missing',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: [
            WorkspaceRoot(
              id: 'workspace',
              label: 'Workspace',
              path: '/home/jhz/projects',
            ),
          ],
          sessions: <SessionSummary>[],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Attach'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit path'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Path'), '');
      await tester.enterText(
        find.widgetWithText(TextField, 'Runtime session ID'),
        'thread-abc',
      );
      await tester.tap(
        find
            .descendant(
              of: find.byType(BottomSheet),
              matching: find.text('Attach'),
            )
            .last,
      );
      await tester.pumpAndSettle();

      expect(find.text('Path is required'), findsOneWidget);
      expect(api.attachedSessions, isEmpty);
    },
  );

  testWidgets(
    'attach sheet lets the user pick a recent session to fill path and runtime id',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: [
            WorkspaceRoot(
              id: 'workspace',
              label: 'Workspace',
              path: '/home/jhz/projects',
            ),
          ],
          sessions: [
            SessionSummary(
              id: 'sess_recent',
              title: 'Resume target',
              agentKind: 'claude',
              sourceKind: 'attached',
              runtimeSessionId: 'thread-xyz',
              status: 'running',
              workspacePath: 'agent-dock',
            ),
          ],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
        attachResult: const SessionSnapshot(
          id: 'sess_attached',
          title: 'Resume target',
          agentKind: 'claude',
          sourceKind: 'attached',
          runtimeSessionId: 'thread-xyz',
          workspacePath: 'agent-dock',
          status: 'attached',
          hasMoreHistory: false,
          events: <SessionEvent>[],
        ),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Attach'));
      await tester.pumpAndSettle();

      expect(find.text('Recent sessions'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text('Resume target'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextField, 'agent-dock'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'thread-xyz'), findsOneWidget);

      await tester.tap(
        find
            .descendant(
              of: find.byType(BottomSheet),
              matching: find.text('Attach'),
            )
            .last,
      );
      await tester.pumpAndSettle();

      expect(api.attachedSessions, ['workspace:agent-dock:claude:thread-xyz']);
      expect(find.text('Resume target'), findsAtLeastNWidgets(1));
    },
  );

  testWidgets(
    'attach sheet recent session selection also switches to the matching workspace root',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: [
            WorkspaceRoot(
              id: 'workspace',
              label: 'Workspace',
              path: '/home/jhz/projects',
            ),
            WorkspaceRoot(id: 'docs', label: 'Docs', path: '/srv/docs'),
          ],
          sessions: [
            SessionSummary(
              id: 'sess_recent',
              title: 'Docs runtime',
              agentKind: 'claude',
              sourceKind: 'attached',
              runtimeSessionId: 'thread-docs',
              status: 'running',
              workspacePath: '/srv/docs/release-notes',
            ),
          ],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
        attachResult: const SessionSnapshot(
          id: 'sess_attached',
          title: 'Docs runtime',
          agentKind: 'claude',
          sourceKind: 'attached',
          runtimeSessionId: 'thread-docs',
          workspacePath: '/srv/docs/release-notes',
          status: 'attached',
          hasMoreHistory: false,
          events: <SessionEvent>[],
        ),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Attach'));
      await tester.pumpAndSettle();

      await tester.tap(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text('Docs runtime'),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(TextField, '/srv/docs/release-notes'),
        findsOneWidget,
      );
      expect(find.widgetWithText(TextField, 'thread-docs'), findsOneWidget);

      await tester.tap(
        find
            .descendant(
              of: find.byType(BottomSheet),
              matching: find.text('Attach'),
            )
            .last,
      );
      await tester.pumpAndSettle();

      expect(api.attachedSessions, [
        'docs:/srv/docs/release-notes:claude:thread-docs',
      ]);
      expect(find.text('Docs runtime'), findsAtLeastNWidgets(1));
    },
  );

  testWidgets(
    'attach sheet shows the full visible recent session list instead of truncating to four items',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: MobileBootstrap(
          daemonVersion: '0.1.0',
          user: const CurrentUser(
            id: 'usr_workspace',
            displayName: 'Workspace',
          ),
          roots: const [
            WorkspaceRoot(
              id: 'workspace',
              label: 'Workspace',
              path: '/home/jhz/projects',
            ),
          ],
          sessions: List<SessionSummary>.generate(
            5,
            (index) => SessionSummary(
              id: 'sess_recent_$index',
              title: 'Resume target ${index + 1}',
              agentKind: index.isEven ? 'claude' : 'codex',
              sourceKind: 'attached',
              runtimeSessionId: 'thread-${index + 1}',
              status: 'running',
              workspacePath: '/home/jhz/projects/workspace_${index + 1}',
            ),
          ),
          voice: const VoiceConfig(doubaoDirectAvailable: false),
        ),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Attach'));
      await tester.pumpAndSettle();

      final attachSheet = find.byType(BottomSheet);
      expect(
        find.descendant(
          of: attachSheet,
          matching: find.text('Recent sessions'),
        ),
        findsOneWidget,
      );
      for (var index = 1; index <= 5; index++) {
        expect(
          find.descendant(
            of: attachSheet,
            matching: find.text('Resume target $index'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: attachSheet,
            matching: find.text('thread-$index'),
          ),
          findsOneWidget,
        );
      }
    },
  );

  testWidgets(
    'attach sheet keeps manual path editing behind an edit affordance',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: [
            WorkspaceRoot(
              id: 'workspace',
              label: 'Workspace',
              path: '/home/jhz/projects',
            ),
          ],
          sessions: <SessionSummary>[],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Attach'));
      await tester.pumpAndSettle();

      expect(find.text('Edit path'), findsOneWidget);
      final pathFieldBeforeEdit = tester.widget<TextField>(
        find.widgetWithText(TextField, '/home/jhz/projects'),
      );
      expect(pathFieldBeforeEdit.readOnly, isTrue);

      await tester.tap(find.text('Edit path'));
      await tester.pumpAndSettle();

      final pathFieldAfterEdit = tester.widget<TextField>(
        find.widgetWithText(TextField, '/home/jhz/projects'),
      );
      expect(pathFieldAfterEdit.readOnly, isFalse);
    },
  );

  testWidgets(
    'attach sheet shows single-root context instead of a root dropdown',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: [
            WorkspaceRoot(
              id: 'workspace',
              label: 'Workspace',
              path: '/home/jhz/projects',
            ),
          ],
          sessions: <SessionSummary>[],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Attach'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('attach-session-root')), findsNothing);
      expect(
        find.byKey(const ValueKey('attach-session-root-context')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('attach-session-root-context')),
          matching: find.text('Workspace root'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('attach-session-root-context')),
          matching: find.text('Workspace'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('attach-session-root-context')),
          matching: find.text('/home/jhz/projects'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'attach sheet lets the user browse within a selected workspace root',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: [
            WorkspaceRoot(
              id: 'workspace',
              label: 'Workspace',
              path: '/home/jhz/projects',
            ),
            WorkspaceRoot(id: 'docs', label: 'Docs', path: '/srv/docs'),
          ],
          sessions: <SessionSummary>[],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
        attachResult: const SessionSnapshot(
          id: 'sess_docs_attach',
          title: 'Docs runtime',
          agentKind: 'claude',
          sourceKind: 'attached',
          runtimeSessionId: 'thread-docs',
          workspacePath: '/srv/docs/release-notes',
          status: 'attached',
          hasMoreHistory: false,
          events: <SessionEvent>[],
        ),
        directoryListings: {
          '/srv/docs': const WorkspaceDirectoryListing(
            currentPath: '/srv/docs',
            parentPath: '/srv',
            directories: [
              WorkspaceDirectoryEntry(
                name: 'release-notes',
                path: '/srv/docs/release-notes',
              ),
            ],
          ),
          '/srv/docs/release-notes': const WorkspaceDirectoryListing(
            currentPath: '/srv/docs/release-notes',
            parentPath: '/srv/docs',
            directories: [],
          ),
        },
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Attach'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('attach-session-root')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Docs').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Browse'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('release-notes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use this folder'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Runtime session ID'),
        'thread-docs',
      );
      await tester.tap(
        find
            .descendant(
              of: find.byType(BottomSheet),
              matching: find.text('Attach'),
            )
            .last,
      );
      await tester.pumpAndSettle();

      expect(api.directoryRequests, ['/srv/docs', '/srv/docs/release-notes']);
      expect(api.attachedSessions, [
        'docs:/srv/docs/release-notes:claude:thread-docs',
      ]);
      expect(find.text('Docs runtime'), findsAtLeastNWidgets(1));
    },
  );

  testWidgets(
    'attach session directory browsing shows a user-facing load error',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: [
            WorkspaceRoot(
              id: 'workspace',
              label: 'Workspace',
              path: '/home/jhz/projects',
            ),
          ],
          sessions: <SessionSummary>[],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Attach'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Browse'));
      await tester.pumpAndSettle();

      expect(find.text('Could not load directories'), findsOneWidget);
      expect(
        find.textContaining('No directory listing stub for /home/jhz/projects'),
        findsNothing,
      );
    },
  );

  testWidgets(
    'routes back to login when attach session directory browsing returns 401',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: [
            WorkspaceRoot(
              id: 'workspace',
              label: 'Workspace',
              path: '/home/jhz/projects',
            ),
          ],
          sessions: <SessionSummary>[],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
        directoryErrors: {
          '/home/jhz/projects': const DaemonApiException(
            statusCode: 401,
            code: 'UNAUTHORIZED',
            message: 'Unauthorized',
          ),
        },
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Attach'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Browse'));
      await tester.pumpAndSettle();

      expect(find.text('Unlock workspace'), findsOneWidget);
      expect(find.text('Session expired. Sign in again.'), findsOneWidget);
      expect(find.text('Choose directory'), findsNothing);
    },
  );

  testWidgets('attach sheet lets the user switch agent kind', (tester) async {
    final api = FakeDaemonApi(
      bootstrap: const MobileBootstrap(
        daemonVersion: '0.1.0',
        user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: [
          WorkspaceRoot(
            id: 'workspace',
            label: 'Workspace',
            path: '/home/jhz/projects',
          ),
        ],
        sessions: <SessionSummary>[],
        voice: VoiceConfig(doubaoDirectAvailable: false),
      ),
      attachResult: const SessionSnapshot(
        id: 'sess_codex_attach',
        title: 'Codex attach',
        agentKind: 'codex',
        sourceKind: 'attached',
        runtimeSessionId: 'thread-codex',
        workspacePath: '/home/jhz/projects/agent-dock',
        status: 'attached',
        hasMoreHistory: false,
        events: <SessionEvent>[],
      ),
    );
    await pumpApp(tester, api: api);

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Attach'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('attach-session-agent-codex')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit path'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Path'),
      '/home/jhz/projects/agent-dock',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Runtime session ID'),
      'thread-codex',
    );
    await tester.tap(
      find
          .descendant(
            of: find.byType(BottomSheet),
            matching: find.text('Attach'),
          )
          .last,
    );
    await tester.pumpAndSettle();

    expect(api.attachedSessions, [
      'workspace:/home/jhz/projects/agent-dock:codex:thread-codex',
    ]);
    expect(find.text('Codex attach'), findsAtLeastNWidgets(1));
  });

  testWidgets(
    'attach sheet loads real resume candidates and lets the user pick one',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: [
            WorkspaceRoot(
              id: 'workspace',
              label: 'Workspace',
              path: '/home/jhz/projects',
            ),
          ],
          sessions: <SessionSummary>[],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
        attachResult: const SessionSnapshot(
          id: 'sess_attached',
          title: 'Resume target',
          agentKind: 'codex',
          sourceKind: 'attached',
          runtimeSessionId: 'thread-xyz',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'attached',
          hasMoreHistory: false,
          events: <SessionEvent>[],
        ),
        resumeCandidates: const [
          ResumeCandidate(
            runtimeSessionId: 'thread-xyz',
            title: 'Resume target',
            agentKind: 'codex',
            workspacePath: '/home/jhz/projects/agent-dock',
            updatedAt: '2026-06-17T01:02:03Z',
            status: 'idle',
          ),
        ],
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Attach'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('attach-session-agent-codex')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit path'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Path'),
        '/home/jhz/projects/agent-dock',
      );
      await tester.tap(find.text('Load resume sessions'));
      await tester.pumpAndSettle();

      expect(api.resumeCandidateRequests, [
        'workspace:codex:/home/jhz/projects/agent-dock',
      ]);
      final resumeCandidateButton = find.widgetWithText(
        OutlinedButton,
        'Resume target',
      );
      await tester.ensureVisible(resumeCandidateButton);
      await tester.tap(resumeCandidateButton);
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(TextField, '/home/jhz/projects/agent-dock'),
        findsOneWidget,
      );
      expect(find.widgetWithText(TextField, 'thread-xyz'), findsOneWidget);

      await tester.tap(
        find
            .descendant(
              of: find.byType(BottomSheet),
              matching: find.text('Attach'),
            )
            .last,
      );
      await tester.pumpAndSettle();

      expect(api.attachedSessions, [
        'workspace:/home/jhz/projects/agent-dock:codex:thread-xyz',
      ]);
      expect(find.text('Resume target'), findsAtLeastNWidgets(1));
    },
  );

  testWidgets(
    'attach sheet shows a user-facing error when loading resume candidates fails',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: [
            WorkspaceRoot(
              id: 'workspace',
              label: 'Workspace',
              path: '/home/jhz/projects',
            ),
          ],
          sessions: <SessionSummary>[],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
        resumeCandidatesError: const DaemonApiException(
          statusCode: 500,
          code: 'RESUME_LIST_FAILED',
          message: 'Could not load resume candidates',
        ),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Attach'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit path'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Path'),
        '/home/jhz/projects/agent-dock',
      );
      await tester.tap(find.text('Load resume sessions'));
      await tester.pumpAndSettle();

      expect(find.text('Could not load resume candidates'), findsOneWidget);
    },
  );

  testWidgets(
    'attach runtime opens as a mobile bottom sheet instead of an alert dialog',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: [
            WorkspaceRoot(
              id: 'workspace',
              label: 'Workspace',
              path: '/home/jhz/projects',
            ),
          ],
          sessions: <SessionSummary>[],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Attach'));
      await tester.pumpAndSettle();

      expect(find.text('Attach runtime'), findsAtLeastNWidgets(1));
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  testWidgets('attach runtime sheet uses the spec primary action label', (
    tester,
  ) async {
    final api = FakeDaemonApi(
      bootstrap: const MobileBootstrap(
        daemonVersion: '0.1.0',
        user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: [
          WorkspaceRoot(
            id: 'workspace',
            label: 'Workspace',
            path: '/home/jhz/projects',
          ),
        ],
        sessions: <SessionSummary>[],
        voice: VoiceConfig(doubaoDirectAvailable: false),
      ),
    );
    await pumpApp(tester, api: api);

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Attach'));
    await tester.pumpAndSettle();

    expect(find.text('Attach runtime'), findsAtLeastNWidgets(1));
    expect(find.text('Attach').last, findsOneWidget);
    expect(find.text('Attach session'), findsNothing);
  });

  testWidgets(
    'attach runtime sheet shows the spec description under the title',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: [
            WorkspaceRoot(
              id: 'workspace',
              label: 'Workspace',
              path: '/home/jhz/projects',
            ),
          ],
          sessions: <SessionSummary>[],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Attach'));
      await tester.pumpAndSettle();

      expect(
        find.text('Attach an existing runtime to a workspace root.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('does not show delete buttons on session cards', (tester) async {
    final api = FakeDaemonApi(
      bootstrap: const MobileBootstrap(
        daemonVersion: '0.1.0',
        user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: [
          WorkspaceRoot(
            id: 'workspace',
            label: 'Workspace',
            path: '/home/jhz/projects',
          ),
        ],
        sessions: [
          SessionSummary(
            id: 'sess_1',
            title: 'Mobile migration',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            status: 'running',
            workspacePath: '/home/jhz/projects/agent-dock',
          ),
        ],
        voice: VoiceConfig(doubaoDirectAvailable: false),
      ),
    );
    await pumpApp(tester, api: api);

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    final sessionCard = find.byKey(
      const ValueKey('session-row-inkwell-sess_1'),
    );
    expect(
      find.descendant(
        of: sessionCard,
        matching: find.byIcon(Icons.delete_outline_rounded),
      ),
      findsNothing,
    );
    expect(api.deletedSessions, isEmpty);
  });

  testWidgets(
    'detail-page delete confirmation also uses the derived session title when a session has no explicit title',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: <WorkspaceRoot>[],
          sessions: [
            SessionSummary(
              id: 'sess_untitled',
              title: null,
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_untitled',
          title: null,
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/home/jhz/projects/agent-dock',
          status: 'running',
          hasMoreHistory: false,
          events: <SessionEvent>[],
        ),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('agent-dock'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Session details'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete session'));
      await tester.pumpAndSettle();

      expect(find.text('Delete agent-dock?'), findsOneWidget);
      expect(find.text('Delete /home/jhz/projects/agent-dock?'), findsNothing);
    },
  );

  testWidgets('long pressing a session opens the session actions sheet', (
    tester,
  ) async {
    final clipboardTexts = <String>[];
    final hapticCalls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardTexts.add(
            (call.arguments as Map<Object?, Object?>)['text']! as String,
          );
        }
        if (call.method == 'HapticFeedback.vibrate') {
          hapticCalls.add(call.arguments as String? ?? 'vibrate');
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    final api = FakeDaemonApi(
      bootstrap: const MobileBootstrap(
        daemonVersion: '0.1.0',
        user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: [
          WorkspaceRoot(
            id: 'workspace',
            label: 'Workspace',
            path: '/home/jhz/projects',
          ),
        ],
        sessions: [
          SessionSummary(
            id: 'sess_1',
            title: 'Mobile migration',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            status: 'running',
            workspacePath: '/home/jhz/projects/agent-dock',
          ),
        ],
        voice: VoiceConfig(doubaoDirectAvailable: false),
      ),
    );
    await pumpApp(tester, api: api);

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Mobile migration'));
    await tester.pumpAndSettle();

    expect(find.text('Session details'), findsOneWidget);
    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Open session'), findsNothing);
    expect(find.text('Copy workspace path'), findsOneWidget);
    expect(find.text('Copy runtime session ID'), findsOneWidget);
    expect(find.text('Delete session'), findsAtLeastNWidgets(1));

    final openTopLeft = tester.getTopLeft(find.text('Open'));
    final detailsTopLeft = tester.getTopLeft(find.text('Session details'));
    expect(openTopLeft.dy, lessThan(detailsTopLeft.dy));
    final runtimeTopLeft = tester.getTopLeft(
      find.text('Copy runtime session ID'),
    );
    final workspaceTopLeft = tester.getTopLeft(
      find.text('Copy workspace path'),
    );
    expect(runtimeTopLeft.dy, lessThan(workspaceTopLeft.dy));

    await tester.tap(find.text('Copy workspace path'));
    await tester.pumpAndSettle();

    expect(clipboardTexts, ['/home/jhz/projects/agent-dock']);
    expect(
      hapticCalls.where((call) => call == 'HapticFeedbackType.selectionClick'),
      hasLength(1),
    );
  });

  testWidgets('session files browser previews markdown files', (tester) async {
    final api = FakeDaemonApi(
      bootstrap: const MobileBootstrap(
        daemonVersion: '0.1.0',
        user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: [
          WorkspaceRoot(
            id: 'workspace',
            label: 'Workspace',
            path: '/home/jhz/projects',
          ),
        ],
        sessions: [
          SessionSummary(
            id: 'sess_1',
            title: 'Mobile migration',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: 'runtime_1',
            status: 'running',
            workspacePath: '/home/jhz/projects/agent-dock',
          ),
        ],
        voice: VoiceConfig(doubaoDirectAvailable: false),
      ),
      workspaceEntryListings: const {
        'sess_1:.': WorkspaceEntryListing(
          currentPath: '.',
          parentPath: null,
          entries: [
            WorkspaceEntry(
              name: 'docs',
              path: 'docs',
              kind: WorkspaceEntryKind.directory,
            ),
          ],
        ),
        'sess_1:docs': WorkspaceEntryListing(
          currentPath: 'docs',
          parentPath: '.',
          entries: [
            WorkspaceEntry(
              name: 'design.md',
              path: 'docs/design.md',
              kind: WorkspaceEntryKind.file,
            ),
          ],
        ),
      },
      workspaceFiles: const {
        'sess_1:docs/design.md': WorkspaceFile(
          name: 'design.md',
          path: 'docs/design.md',
          renderMode: WorkspaceFileRenderMode.markdown,
          content: '# Design Preview\n\n- Render markdown\n',
        ),
      },
    );
    await pumpApp(tester, api: api);

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Mobile migration'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Files'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('docs'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('design.md'));
    await tester.pumpAndSettle();

    expect(api.workspaceEntryRequests, ['sess_1:.', 'sess_1:docs']);
    expect(api.workspaceFileRequests, ['sess_1:docs/design.md']);
    expect(find.text('Markdown preview'), findsOneWidget);
    expect(find.text('Design Preview'), findsOneWidget);
    expect(find.text('Render markdown'), findsOneWidget);
    expect(find.text('# Design Preview'), findsNothing);
  });

  testWidgets(
    'deleting from the session actions sheet shows an in-sheet deleting state until the request finishes',
    (tester) async {
      final deleteCompleter = Completer<void>();
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: [
            WorkspaceRoot(
              id: 'workspace',
              label: 'Workspace',
              path: '/home/jhz/projects',
            ),
          ],
          sessions: [
            SessionSummary(
              id: 'sess_1',
              title: 'Mobile migration',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
        deleteFuture: deleteCompleter.future,
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Mobile migration'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete session'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.widgetWithText(FilledButton, 'Delete session'));
      await tester.pump();

      expect(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text('Deleting...'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text('Delete session'),
        ),
        findsNothing,
      );
      expect(find.text('Session details'), findsOneWidget);
      expect(find.text('Copy workspace path'), findsOneWidget);

      deleteCompleter.complete();
      await tester.pumpAndSettle();

      expect(api.deletedSessions, ['sess_1']);
      expect(find.text('Mobile migration'), findsNothing);
    },
  );

  testWidgets(
    'deleting from the session actions sheet keeps the sheet open and shows the error when delete fails',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: [
            WorkspaceRoot(
              id: 'workspace',
              label: 'Workspace',
              path: '/home/jhz/projects',
            ),
          ],
          sessions: [
            SessionSummary(
              id: 'sess_1',
              title: 'Mobile migration',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
        deleteError: const DaemonApiException(
          statusCode: 500,
          code: 'DELETE_FAILED',
          message: 'Could not delete session',
        ),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Mobile migration'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete session'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.widgetWithText(FilledButton, 'Delete session'));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('Could not delete session'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text('Delete session'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text('Deleting...'),
        ),
        findsNothing,
      );
      expect(find.text('Mobile migration'), findsAtLeastNWidgets(1));
    },
  );

  testWidgets(
    'deleting from the session actions sheet shows a user-facing fallback for unexpected failures',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: [
            WorkspaceRoot(
              id: 'workspace',
              label: 'Workspace',
              path: '/home/jhz/projects',
            ),
          ],
          sessions: [
            SessionSummary(
              id: 'sess_1',
              title: 'Mobile migration',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
        deleteError: StateError('Delete flow corrupted'),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Mobile migration'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete session'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.widgetWithText(FilledButton, 'Delete session'));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('Could not delete session'), findsOneWidget);
      expect(find.text('Bad state: Delete flow corrupted'), findsNothing);
      expect(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text('Delete session'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'session actions sheet exposes a details sheet with the hidden runtime id',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: [
            WorkspaceRoot(
              id: 'workspace',
              label: 'Workspace',
              path: '/home/jhz/projects',
            ),
          ],
          sessions: [
            SessionSummary(
              id: 'sess_1',
              title: 'Mobile migration',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'running',
              workspacePath: '/home/jhz/projects/agent-dock',
            ),
          ],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      expect(find.text('runtime_1'), findsNothing);

      await tester.longPress(find.text('Mobile migration'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Session details'));
      await tester.pumpAndSettle();

      final detailsSheet = find.byType(BottomSheet);
      expect(find.text('Source kind'), findsOneWidget);
      expect(find.text('Workspace path'), findsOneWidget);
      expect(find.text('Runtime session ID'), findsOneWidget);
      expect(find.text('runtime_1'), findsOneWidget);
      expect(find.text('Daemon URL host'), findsOneWidget);
      expect(
        find.descendant(
          of: detailsSheet,
          matching: find.text('daemon.example.com'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'empty sessions state exposes new session and attach runtime actions',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: [
            WorkspaceRoot(
              id: 'workspace',
              label: 'Workspace',
              path: '/home/jhz/projects',
            ),
          ],
          sessions: <SessionSummary>[],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      expect(find.text('No sessions yet'), findsOneWidget);
      expect(
        find.text('Start a managed session or attach an existing runtime.'),
        findsOneWidget,
      );
      expect(find.text('New session'), findsAtLeastNWidgets(1));
      expect(find.text('Attach runtime'), findsOneWidget);
      expect(find.text('Preview chat shell'), findsNothing);
    },
  );

  testWidgets('shows login errors without leaving the login form', (
    tester,
  ) async {
    await pumpApp(
      tester,
      api: FakeDaemonApi(
        loginError: const DaemonApiException(
          statusCode: 401,
          code: 'INVALID_CREDENTIALS',
          message: 'Invalid username or password',
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), 'wrong');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    expect(find.text('Unlock workspace'), findsOneWidget);
    expect(find.text('Invalid username or password'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField).at(0)).controller!.text,
      'workspace',
    );
    expect(
      tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text,
      isEmpty,
    );
    final passwordEditable = find.descendant(
      of: find.byType(TextField).at(1),
      matching: find.byType(EditableText),
    );
    expect(
      tester.widget<EditableText>(passwordEditable).focusNode.hasFocus,
      isTrue,
    );
    expect(find.text('Sessions'), findsNothing);
  });

  testWidgets(
    'shows a user-facing fallback for unexpected login failures without using restore wording',
    (tester) async {
      await pumpApp(
        tester,
        api: FakeDaemonApi(loginError: StateError('Login flow corrupted')),
      );

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      expect(find.text('Unlock workspace'), findsOneWidget);
      expect(find.text('Could not sign in'), findsOneWidget);
      expect(find.text('Could not restore session'), findsNothing);
      expect(find.text('Bad state: Login flow corrupted'), findsNothing);
      expect(find.text('Sessions'), findsNothing);
    },
  );

  testWidgets('pull to refresh reloads sessions from bootstrap', (
    tester,
  ) async {
    final api = FakeDaemonApi(
      bootstrap: const MobileBootstrap(
        daemonVersion: '0.1.0',
        user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: <WorkspaceRoot>[],
        sessions: [
          SessionSummary(
            id: 'sess_1',
            title: 'Initial session',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: null,
            status: 'completed',
            workspacePath: '/tmp/initial',
          ),
        ],
        voice: VoiceConfig(doubaoDirectAvailable: false),
      ),
      refreshBootstrap: const MobileBootstrap(
        daemonVersion: '0.1.0',
        user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: <WorkspaceRoot>[],
        sessions: [
          SessionSummary(
            id: 'sess_2',
            title: 'Refreshed session',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: null,
            status: 'running',
            workspacePath: '/tmp/refreshed',
          ),
        ],
        voice: VoiceConfig(doubaoDirectAvailable: false),
      ),
    );
    await pumpApp(tester, api: api);

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    expect(find.text('Initial session'), findsOneWidget);
    expect(find.text('Refreshed session'), findsNothing);

    expect(find.text('Refresh'), findsNothing);
    await tester.drag(find.byType(ListView).last, const Offset(0, 1200));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(api.bootstrappedTokens, ['tok_workspace', 'tok_workspace']);
    expect(find.text('Initial session'), findsNothing);
    expect(find.text('Refreshed session'), findsOneWidget);
  });

  testWidgets('refreshes sessions when the app returns to the foreground', (
    tester,
  ) async {
    final api = FakeDaemonApi(
      bootstrap: const MobileBootstrap(
        daemonVersion: '0.1.0',
        user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: <WorkspaceRoot>[],
        sessions: [
          SessionSummary(
            id: 'sess_1',
            title: 'Initial session',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: null,
            status: 'completed',
            workspacePath: '/tmp/initial',
          ),
        ],
        voice: VoiceConfig(doubaoDirectAvailable: false),
      ),
      refreshBootstrap: const MobileBootstrap(
        daemonVersion: '0.1.0',
        user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
        roots: <WorkspaceRoot>[],
        sessions: [
          SessionSummary(
            id: 'sess_2',
            title: 'Foreground refreshed session',
            agentKind: 'codex',
            sourceKind: 'managed',
            runtimeSessionId: null,
            status: 'running',
            workspacePath: '/tmp/refreshed',
          ),
        ],
        voice: VoiceConfig(doubaoDirectAvailable: false),
      ),
    );
    await pumpApp(tester, api: api);

    await tester.enterText(find.byType(TextField).at(0), 'workspace');
    await tester.enterText(find.byType(TextField).at(1), '1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    expect(find.text('Initial session'), findsOneWidget);
    expect(find.text('Foreground refreshed session'), findsNothing);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(api.bootstrappedTokens, ['tok_workspace', 'tok_workspace']);
    expect(find.text('Initial session'), findsNothing);
    expect(find.text('Foreground refreshed session'), findsOneWidget);
  });

  testWidgets(
    'returning from Chat keeps the list visible and refreshes sessions in the background',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: <WorkspaceRoot>[],
          sessions: [
            SessionSummary(
              id: 'sess_1',
              title: 'Initial session',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_1',
              status: 'completed',
              workspacePath: '/tmp/initial',
            ),
          ],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
        refreshBootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: <WorkspaceRoot>[],
          sessions: [
            SessionSummary(
              id: 'sess_2',
              title: 'Background refreshed session',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: 'runtime_2',
              status: 'running',
              workspacePath: '/tmp/refreshed',
            ),
          ],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
        snapshot: const SessionSnapshot(
          id: 'sess_1',
          title: 'Initial session',
          agentKind: 'codex',
          sourceKind: 'managed',
          runtimeSessionId: 'runtime_1',
          workspacePath: '/tmp/initial',
          status: 'completed',
          hasMoreHistory: false,
          events: [
            SessionEvent(
              id: 1,
              eventType: 'assistant.message',
              payload: {'text': 'done'},
            ),
          ],
        ),
        refreshBootstrapDelay: const Duration(seconds: 1),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      expect(find.text('Initial session'), findsOneWidget);
      expect(find.text('Background refreshed session'), findsNothing);

      await tester.tap(find.text('Initial session'));
      await tester.pumpAndSettle();

      expect(find.text('done'), findsOneWidget);
      expect(find.byKey(const ValueKey('sessions-loaded-list')), findsNothing);

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.text('Sessions'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('sessions-loaded-list')),
        findsOneWidget,
      );
      expect(find.text('Initial session'), findsOneWidget);
      expect(find.text('Background refreshed session'), findsNothing);

      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();

      expect(api.bootstrappedTokens, ['tok_workspace', 'tok_workspace']);
      expect(find.text('Initial session'), findsNothing);
      expect(find.text('Background refreshed session'), findsOneWidget);
    },
  );

  testWidgets(
    'shows session skeleton rows while the first sessions bootstrap is loading',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: <WorkspaceRoot>[],
          sessions: [
            SessionSummary(
              id: 'sess_1',
              title: 'Delayed session',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: null,
              status: 'completed',
              workspacePath: '/tmp/delayed',
            ),
          ],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
        bootstrapDelay: const Duration(seconds: 1),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pump();

      expect(
        find.byKey(const ValueKey('sessions-skeleton-list')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('sessions-loaded-list')), findsNothing);
      expect(
        find.byKey(const ValueKey('sessions-skeleton-row-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('sessions-skeleton-row-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('sessions-skeleton-row-2')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('sessions-skeleton-shimmer-0')),
        findsOneWidget,
      );

      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('sessions-skeleton-list')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('sessions-loaded-list')),
        findsOneWidget,
      );
      expect(find.text('Sessions'), findsOneWidget);
      expect(find.text('Delayed session'), findsOneWidget);
    },
  );

  testWidgets(
    'keeps the first sessions skeleton visible and shows an offline banner when the initial bootstrap fails',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrapErrors: <Object>[
          const SocketException('Network is unreachable'),
        ],
        bootstrapDelay: const Duration(seconds: 1),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pump();

      expect(
        find.byKey(const ValueKey('sessions-skeleton-list')),
        findsOneWidget,
      );

      await tester.pump(const Duration(seconds: 1));
      await tester.pump();

      expect(
        find.byKey(const ValueKey('sessions-status-banner')),
        findsOneWidget,
      );
      expect(find.text('Offline. Waiting for network...'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('sessions-skeleton-list')),
        findsOneWidget,
      );
      expect(find.text('No sessions yet'), findsNothing);
    },
  );

  testWidgets(
    'a successful refresh after the first bootstrap failure exits the sessions skeleton state',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrapErrors: <Object>[
          const SocketException('Network is unreachable'),
        ],
        refreshBootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: <WorkspaceRoot>[],
          sessions: [
            SessionSummary(
              id: 'sess_2',
              title: 'Recovered session',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: null,
              status: 'running',
              workspacePath: '/tmp/recovered',
            ),
          ],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
        bootstrapDelay: const Duration(seconds: 1),
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pump();

      expect(
        find.byKey(const ValueKey('sessions-skeleton-list')),
        findsOneWidget,
      );

      await tester.pump(const Duration(seconds: 1));
      await tester.pump();

      expect(
        find.byKey(const ValueKey('sessions-status-banner')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('sessions-skeleton-list')),
        findsOneWidget,
      );

      await tester.drag(find.byType(ListView).last, const Offset(0, 1200));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();

      expect(api.bootstrappedTokens, ['tok_workspace', 'tok_workspace']);
      expect(find.text('Recovered session'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('sessions-loaded-list')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('sessions-skeleton-list')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('sessions-status-banner')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'shows a slim offline banner and keeps existing sessions when refresh fails',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: <WorkspaceRoot>[],
          sessions: [
            SessionSummary(
              id: 'sess_1',
              title: 'Initial session',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: null,
              status: 'completed',
              workspacePath: '/tmp/initial',
            ),
          ],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
        refreshBootstrapErrors: <Object>[
          const SocketException('Network is unreachable'),
        ],
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      expect(find.text('Initial session'), findsOneWidget);
      expect(find.text('Offline. Waiting for network...'), findsNothing);

      expect(find.text('Refresh'), findsNothing);
      await tester.drag(find.byType(ListView).last, const Offset(0, 1200));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();

      expect(api.bootstrappedTokens, ['tok_workspace', 'tok_workspace']);
      expect(find.text('Initial session'), findsOneWidget);
      expect(find.text('Offline. Waiting for network...'), findsOneWidget);
      final dot = tester.widget<Container>(
        find.byKey(const ValueKey('sessions-appbar-status-dot')),
      );
      final dotDecoration = dot.decoration! as BoxDecoration;
      expect(dotDecoration.color, const Color(0xFFF0B84A));
    },
  );

  testWidgets(
    'shows a user-facing banner and keeps existing sessions when refresh fails unexpectedly',
    (tester) async {
      final api = FakeDaemonApi(
        bootstrap: const MobileBootstrap(
          daemonVersion: '0.1.0',
          user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
          roots: <WorkspaceRoot>[],
          sessions: [
            SessionSummary(
              id: 'sess_1',
              title: 'Initial session',
              agentKind: 'codex',
              sourceKind: 'managed',
              runtimeSessionId: null,
              status: 'completed',
              workspacePath: '/tmp/initial',
            ),
          ],
          voice: VoiceConfig(doubaoDirectAvailable: false),
        ),
        refreshBootstrapErrors: <Object>[StateError('Refresh flow corrupted')],
      );
      await pumpApp(tester, api: api);

      await tester.enterText(find.byType(TextField).at(0), 'workspace');
      await tester.enterText(find.byType(TextField).at(1), '1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      expect(find.text('Initial session'), findsOneWidget);
      expect(find.text('Could not refresh sessions'), findsNothing);

      await tester.drag(find.byType(ListView).last, const Offset(0, 1200));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();

      expect(api.bootstrappedTokens, ['tok_workspace', 'tok_workspace']);
      expect(find.text('Initial session'), findsOneWidget);
      expect(find.text('Could not refresh sessions'), findsOneWidget);
      expect(find.text('Bad state: Refresh flow corrupted'), findsNothing);
    },
  );
}

Future<void> pumpApp(
  WidgetTester tester, {
  required DaemonApi api,
  Uri? daemonUrl,
  MemoryAuthStorage? storage,
  MemoryVoiceCredentialsStorage? voiceStorage,
  SessionComposerDraftStore? composerDraftStore,
  SessionDetailCacheStore? sessionDetailCacheStore,
  SessionOutboxStore? outboxStore,
  DoubaoSocketClient? doubaoSocketClient,
  DoubaoRecorder? doubaoRecorder,
  ImageAttachmentPicker? attachmentPicker,
  Future<bool> Function(Uri uri)? openExternalLink,
  VoiceInputController? voiceInputController,
  Future<void> Function(List<String> paths, String? text)? shareAttachments,
  bool? showDebugTimelineItems,
  bool seedDaemonUrlInStorage = true,
}) async {
  final resolvedDaemonUrl =
      daemonUrl ?? Uri.parse('https://daemon.example.com');
  final resolvedStorage =
      storage ??
      MemoryAuthStorage(
        daemonUrl: seedDaemonUrlInStorage ? resolvedDaemonUrl : null,
      );
  if (seedDaemonUrlInStorage &&
      resolvedStorage.daemonUrl == null &&
      resolvedStorage.profile?.daemonUrl == null) {
    resolvedStorage.daemonUrl = resolvedDaemonUrl;
  }
  await tester.pumpWidget(
    AgentDockApp(
      api: api,
      attachmentPicker: attachmentPicker,
      openExternalLink: openExternalLink,
      shareAttachments: shareAttachments,
      voiceInputController: voiceInputController,
      showDebugTimelineItems: showDebugTimelineItems,
      daemonUrl: resolvedDaemonUrl,
      authStorage: resolvedStorage,
      composerDraftStore: composerDraftStore,
      sessionDetailCacheStore: sessionDetailCacheStore,
      outboxStore: outboxStore,
      voiceCredentialsStorage: voiceStorage,
      doubaoSocketClient: doubaoSocketClient,
      doubaoRecorder: doubaoRecorder,
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> pumpSessionDetailForTest(
  WidgetTester tester, {
  required DaemonApi api,
  required SessionSummary session,
  Uri? daemonUrl,
  VoiceConfig voice = const VoiceConfig(doubaoDirectAvailable: false),
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: SessionDetailPage(
        api: api,
        daemonUrl: daemonUrl ?? Uri.parse('https://daemon.example.com'),
        session: session,
        token: 'tok_workspace',
        voice: voice,
        showDebugTimelineItems: true,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> choosePhotoLibraryAttachment(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Attach image'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Photo library'));
  await tester.pumpAndSettle();
}

List<String> recordHapticCalls(WidgetTester tester) {
  final hapticCalls = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        hapticCalls.add(call.arguments as String? ?? 'vibrate');
      }
      return null;
    },
  );
  addTearDown(() {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });
  return hapticCalls;
}

class FakeDaemonApi implements DaemonApi {
  FakeDaemonApi({
    MobileBootstrap? bootstrap,
    MobileBootstrap? refreshBootstrap,
    List<LoginResult>? loginResults,
    List<Object>? bootstrapErrors,
    List<Object>? refreshBootstrapErrors,
    this.bootstrapDelay,
    this.snapshotDelay,
    this.snapshotError,
    SessionSnapshot? snapshot,
    SessionSnapshot? resumeResult,
    this.resumeError,
    this.resumeDelay,
    SessionSnapshot? olderSnapshot,
    List<SessionSnapshot>? olderSnapshots,
    this.olderSnapshotError,
    this.olderSnapshotDelay,
    this.sendMessageDelay,
    this.uploadAttachmentDelay,
    this.loginDelay,
    this.deleteFuture,
    this.deleteError,
    this.createDelay,
    this.createError,
    this.attachDelay,
    this.attachError,
    this.resumeCandidates = const <ResumeCandidate>[],
    this.resumeCandidatesError,
    SessionSnapshot? createResult,
    SessionSnapshot? attachResult,
    Map<String, WorkspaceDirectoryListing>? directoryListings,
    Map<String, Object>? directoryErrors,
    Map<String, WorkspaceEntryListing>? workspaceEntryListings,
    Map<String, WorkspaceFile>? workspaceFiles,
    Map<String, Object>? workspaceEntryErrors,
    Map<String, Object>? workspaceFileErrors,
    Stream<SessionEvent>? liveEvents,
    List<Stream<SessionEvent>>? liveEventStreams,
    List<Object>? sendMessageErrors,
    List<Object>? uploadAttachmentErrors,
    this.loginError,
    this.healthError,
    this.healthCheckDelay,
    this.refreshBootstrapDelay,
  }) : snapshotResult =
           snapshot ??
           const SessionSnapshot(
             id: 'sess_empty',
             title: null,
             agentKind: 'codex',
             sourceKind: 'managed',
             runtimeSessionId: null,
             workspacePath: '/tmp/workspace',
             status: 'idle',
             hasMoreHistory: false,
             events: <SessionEvent>[],
           ),
       attachResult =
           attachResult ??
           const SessionSnapshot(
             id: 'sess_attached',
             title: null,
             agentKind: 'claude',
             sourceKind: 'attached',
             runtimeSessionId: 'thread-abc',
             workspacePath: 'agent-dock',
             status: 'attached',
             hasMoreHistory: false,
             events: <SessionEvent>[],
           ),
       createResult =
           createResult ??
           const SessionSnapshot(
             id: 'sess_created',
             title: 'Created session',
             agentKind: 'codex',
             sourceKind: 'managed',
             runtimeSessionId: null,
             workspacePath: 'agent-dock',
             status: 'created',
             hasMoreHistory: false,
             events: <SessionEvent>[],
           ),
       resumeResult = resumeResult ?? snapshot,
       olderSnapshotResult = olderSnapshot,
       olderSnapshotResults = List<SessionSnapshot>.from(olderSnapshots ?? const []),
       bootstrapResult =
           bootstrap ??
           const MobileBootstrap(
             daemonVersion: '0.1.0',
             user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
             roots: <WorkspaceRoot>[],
             sessions: <SessionSummary>[],
             voice: VoiceConfig(doubaoDirectAvailable: false),
           ),
       refreshBootstrapResult = refreshBootstrap,
       loginResults = List<LoginResult>.from(loginResults ?? const []),
       directoryListings =
           directoryListings ?? const <String, WorkspaceDirectoryListing>{},
       directoryErrors = Map<String, Object>.from(
         directoryErrors ?? const <String, Object>{},
       ),
       workspaceEntryListings =
           workspaceEntryListings ?? const <String, WorkspaceEntryListing>{},
       workspaceFiles = workspaceFiles ?? const <String, WorkspaceFile>{},
       workspaceEntryErrors = Map<String, Object>.from(
         workspaceEntryErrors ?? const <String, Object>{},
       ),
       workspaceFileErrors = Map<String, Object>.from(
         workspaceFileErrors ?? const <String, Object>{},
       ),
       bootstrapErrors = List<Object>.from(bootstrapErrors ?? const []),
       refreshBootstrapErrors = List<Object>.from(
         refreshBootstrapErrors ?? const [],
       ),
       sendMessageErrors = List<Object>.from(sendMessageErrors ?? const []),
       uploadAttachmentErrors = List<Object>.from(
         uploadAttachmentErrors ?? const [],
       ),
       liveEventStreams =
           liveEventStreams ??
           <Stream<SessionEvent>>[
             liveEvents ?? const Stream<SessionEvent>.empty(),
           ],
       _mutableSessions = List<SessionSummary>.from(
         (bootstrap ??
                 const MobileBootstrap(
                   daemonVersion: '0.1.0',
                   user: CurrentUser(
                     id: 'usr_workspace',
                     displayName: 'Workspace',
                   ),
                   roots: <WorkspaceRoot>[],
                   sessions: <SessionSummary>[],
                   voice: VoiceConfig(doubaoDirectAvailable: false),
                 ))
             .sessions,
       );

  final MobileBootstrap bootstrapResult;
  final MobileBootstrap? refreshBootstrapResult;
  final List<LoginResult> loginResults;
  final List<Object> bootstrapErrors;
  final List<Object> refreshBootstrapErrors;
  final Duration? bootstrapDelay;
  final Duration? snapshotDelay;
  final Object? snapshotError;
  final SessionSnapshot snapshotResult;
  final SessionSnapshot? resumeResult;
  final Object? resumeError;
  final Duration? resumeDelay;
  final SessionSnapshot? olderSnapshotResult;
  final List<SessionSnapshot> olderSnapshotResults;
  final Object? olderSnapshotError;
  final Duration? olderSnapshotDelay;
  final Duration? sendMessageDelay;
  final Duration? uploadAttachmentDelay;
  final Duration? loginDelay;
  final Future<void>? deleteFuture;
  final Object? deleteError;
  final Duration? createDelay;
  final Object? createError;
  final Duration? attachDelay;
  final Object? attachError;
  final List<ResumeCandidate> resumeCandidates;
  final Object? resumeCandidatesError;
  final SessionSnapshot createResult;
  final SessionSnapshot attachResult;
  final Map<String, WorkspaceDirectoryListing> directoryListings;
  final Map<String, Object> directoryErrors;
  final Map<String, WorkspaceEntryListing> workspaceEntryListings;
  final Map<String, WorkspaceFile> workspaceFiles;
  final Map<String, Object> workspaceEntryErrors;
  final Map<String, Object> workspaceFileErrors;
  final List<Object> sendMessageErrors;
  final List<Object> uploadAttachmentErrors;
  final List<Stream<SessionEvent>> liveEventStreams;
  final Object? loginError;
  final Object? healthError;
  final Duration? healthCheckDelay;
  final Duration? refreshBootstrapDelay;
  final List<SessionSummary> _mutableSessions;
  final List<String> bootstrappedTokens = <String>[];
  final List<String> directoryRequests = <String>[];
  final List<String> workspaceEntryRequests = <String>[];
  final List<String> workspaceFileRequests = <String>[];
  final List<String> snapshotRequests = <String>[];
  final List<String> resumedSessions = <String>[];
  final List<String> eventSubscriptions = <String>[];
  final List<String> uploadedAttachments = <String>[];
  final List<String> sentMessages = <String>[];
  final List<String> createdSessions = <String>[];
  final List<String> attachedSessions = <String>[];
  final List<String> deletedSessions = <String>[];
  final List<Uri> healthChecks = <Uri>[];
  final List<String> resumeCandidateRequests = <String>[];

  @override
  Future<void> healthCheck() async {
    healthChecks.add(Uri.parse('https://fake-daemon.example.com'));
    if (healthCheckDelay != null) {
      await Future<void>.delayed(healthCheckDelay!);
    }
    if (healthError != null) {
      throw healthError!;
    }
  }

  @override
  Future<LoginResult> login({
    required String username,
    required String password,
  }) async {
    if (loginDelay != null) {
      await Future<void>.delayed(loginDelay!);
    }
    if (loginError != null) {
      throw loginError!;
    }
    if (loginResults.isNotEmpty) {
      return loginResults.removeAt(0);
    }
    return const LoginResult(
      token: 'tok_workspace',
      user: CurrentUser(id: 'usr_workspace', displayName: 'Workspace'),
    );
  }

  @override
  Future<MobileBootstrap> bootstrap({required String token}) async {
    bootstrappedTokens.add(token);
    if (bootstrapDelay != null) {
      await Future<void>.delayed(bootstrapDelay!);
    }
    if (bootstrapErrors.isNotEmpty) {
      throw bootstrapErrors.removeAt(0);
    }
    if (bootstrappedTokens.length > 1 && refreshBootstrapDelay != null) {
      await Future<void>.delayed(refreshBootstrapDelay!);
    }
    if (bootstrappedTokens.length > 1 && refreshBootstrapErrors.isNotEmpty) {
      throw refreshBootstrapErrors.removeAt(0);
    }
    if (bootstrappedTokens.length > 1 && refreshBootstrapResult != null) {
      return refreshBootstrapResult!;
    }
    return MobileBootstrap(
      daemonVersion: bootstrapResult.daemonVersion,
      user: bootstrapResult.user,
      roots: bootstrapResult.roots,
      sessions: List<SessionSummary>.from(_mutableSessions),
      voice: bootstrapResult.voice,
    );
  }

  @override
  Future<SessionSnapshot> sessionSnapshot({
    required String sessionId,
    required String token,
    int? beforeEventId,
  }) async {
    snapshotRequests.add('$sessionId:$token:$beforeEventId');
    if (beforeEventId != null && olderSnapshotResults.isNotEmpty) {
      if (olderSnapshotDelay != null) {
        await Future<void>.delayed(olderSnapshotDelay!);
      }
      if (olderSnapshotError != null) {
        throw olderSnapshotError!;
      }
      return olderSnapshotResults.removeAt(0);
    }
    if (beforeEventId != null && olderSnapshotResult != null) {
      if (olderSnapshotDelay != null) {
        await Future<void>.delayed(olderSnapshotDelay!);
      }
      if (olderSnapshotError != null) {
        throw olderSnapshotError!;
      }
      return olderSnapshotResult!;
    }
    if (snapshotDelay != null) {
      await Future<void>.delayed(snapshotDelay!);
    }
    if (snapshotError != null) {
      throw snapshotError!;
    }
    return snapshotResult;
  }

  @override
  Future<SessionSnapshot> resumeSession({
    required String sessionId,
    required String token,
  }) async {
    resumedSessions.add('$sessionId:$token');
    if (resumeDelay != null) {
      await Future<void>.delayed(resumeDelay!);
    }
    if (resumeError != null) {
      throw resumeError!;
    }
    return resumeResult ?? snapshotResult;
  }

  @override
  Stream<SessionEvent> sessionEvents({
    required String sessionId,
    required String token,
    required int afterEventId,
  }) {
    eventSubscriptions.add('$sessionId:$token:$afterEventId');
    if (liveEventStreams.length >= eventSubscriptions.length) {
      return liveEventStreams[eventSubscriptions.length - 1];
    }
    return liveEventStreams.last;
  }

  @override
  Future<SendMessageAck> sendMessage({
    required String sessionId,
    required String token,
    required String clientMessageId,
    required String message,
    List<String> imagePaths = const <String>[],
  }) async {
    final suffix = imagePaths.isEmpty ? '' : '|${imagePaths.join(',')}';
    sentMessages.add('$sessionId:$message$suffix');
    if (sendMessageDelay != null) {
      await Future<void>.delayed(sendMessageDelay!);
    }
    if (sendMessageErrors.isNotEmpty) {
      throw sendMessageErrors.removeAt(0);
    }
    return SendMessageAck(
      accepted: true,
      clientMessageId: clientMessageId,
      eventId: 0,
      sessionStatus: snapshotResult.status,
    );
  }

  @override
  Future<String> uploadAttachment({
    required String sessionId,
    required String token,
    required String filename,
    required String contentType,
    required List<int> bytes,
  }) async {
    uploadedAttachments.add(
      '$sessionId:$filename:$contentType:${bytes.length}',
    );
    if (uploadAttachmentDelay != null) {
      await Future<void>.delayed(uploadAttachmentDelay!);
    }
    if (uploadAttachmentErrors.isNotEmpty) {
      throw uploadAttachmentErrors.removeAt(0);
    }
    return '/tmp/attachments/$sessionId/$filename';
  }

  @override
  Future<SessionSnapshot> createSession({
    required String token,
    required String rootId,
    required String path,
    required String agentKind,
    required String title,
  }) async {
    createdSessions.add('$rootId:$path:$agentKind:$title');
    if (createDelay != null) {
      await Future<void>.delayed(createDelay!);
    }
    if (createError != null) {
      throw createError!;
    }
    _mutableSessions
      ..removeWhere((session) => session.id == createResult.id)
      ..insert(0, createResult.toSummary());
    return createResult;
  }

  @override
  Future<SessionSnapshot> attachSession({
    required String token,
    required String rootId,
    required String path,
    required String agentKind,
    required String runtimeSessionId,
  }) async {
    attachedSessions.add('$rootId:$path:$agentKind:$runtimeSessionId');
    if (attachDelay != null) {
      await Future<void>.delayed(attachDelay!);
    }
    if (attachError != null) {
      throw attachError!;
    }
    _mutableSessions
      ..removeWhere((session) => session.id == attachResult.id)
      ..insert(0, attachResult.toSummary());
    return attachResult;
  }

  @override
  Future<WorkspaceDirectoryListing> workspaceDirectories({
    required String token,
    required String path,
  }) async {
    directoryRequests.add(path);
    final error = directoryErrors[path];
    if (error != null) {
      throw error;
    }
    final listing = directoryListings[path];
    if (listing != null) {
      return listing;
    }
    throw StateError('No directory listing stub for $path');
  }

  @override
  Future<WorkspaceEntryListing> sessionWorkspaceEntries({
    required String sessionId,
    required String token,
    required String path,
  }) async {
    final key = '$sessionId:$path';
    workspaceEntryRequests.add(key);
    final error = workspaceEntryErrors[key];
    if (error != null) {
      throw error;
    }
    final listing = workspaceEntryListings[key];
    if (listing != null) {
      return listing;
    }
    throw StateError('No workspace entry listing stub for $key');
  }

  @override
  Future<WorkspaceFile> sessionWorkspaceFile({
    required String sessionId,
    required String token,
    required String path,
  }) async {
    final key = '$sessionId:$path';
    workspaceFileRequests.add(key);
    final error = workspaceFileErrors[key];
    if (error != null) {
      throw error;
    }
    final file = workspaceFiles[key];
    if (file != null) {
      return file;
    }
    throw StateError('No workspace file stub for $key');
  }

  @override
  Future<List<ResumeCandidate>> listResumeCandidates({
    required String token,
    required String rootId,
    required String agentKind,
    required String path,
  }) async {
    resumeCandidateRequests.add('$rootId:$agentKind:$path');
    final error = resumeCandidatesError;
    if (error != null) {
      throw error;
    }
    return resumeCandidates;
  }

  @override
  Future<void> deleteSession({
    required String sessionId,
    required String token,
  }) async {
    deletedSessions.add(sessionId);
    if (deleteError != null) {
      throw deleteError!;
    }
    final deleteFuture = this.deleteFuture;
    if (deleteFuture != null) {
      await deleteFuture;
    }
    _mutableSessions.removeWhere((session) => session.id == sessionId);
  }
}

class MemoryAuthStorage implements AuthStorage {
  MemoryAuthStorage({this.profile, this.daemonUrl});

  AuthProfile? profile;
  Uri? daemonUrl;
  var didClear = false;
  final lastSelectedSessionIds = <(Uri daemonUrl, String userId), String>{};

  Uri? get savedDaemonUrl => daemonUrl;

  @override
  Future<AuthProfile?> readProfile() async => profile;

  @override
  Future<Uri?> readDaemonUrl() async => daemonUrl ?? profile?.daemonUrl;

  @override
  Future<void> saveDaemonUrl(Uri daemonUrl) async {
    this.daemonUrl = daemonUrl;
  }

  @override
  Future<void> saveProfile(AuthProfile profile) async {
    this.profile = profile;
    daemonUrl = profile.daemonUrl;
  }

  @override
  Future<String?> readLastSelectedSessionId({
    required SessionStorageScope scope,
  }) async {
    return lastSelectedSessionIds[(scope.daemonUrl, scope.userId)];
  }

  @override
  Future<void> saveLastSelectedSessionId({
    required SessionStorageScope scope,
    required String sessionId,
  }) async {
    lastSelectedSessionIds[(scope.daemonUrl, scope.userId)] = sessionId;
  }

  @override
  Future<void> clearLastSelectedSessionId({
    required SessionStorageScope scope,
  }) async {
    lastSelectedSessionIds.remove((scope.daemonUrl, scope.userId));
  }

  @override
  Future<void> clearProfile() async {
    didClear = true;
    profile = null;
  }
}

class MemoryVoiceCredentialsStorage implements VoiceCredentialsStorage {
  MemoryVoiceCredentialsStorage({this.saveDelay});

  final _values = <(Uri daemonUrl, String userId), DoubaoVoiceCredentials>{};
  final savedScopes = <({Uri daemonUrl, String userId})>[];
  final deletedScopes = <({Uri daemonUrl, String userId})>[];
  final Duration? saveDelay;

  void seed({
    required Uri daemonUrl,
    required String userId,
    required DoubaoVoiceCredentials credentials,
  }) {
    _values[(daemonUrl, userId)] = credentials;
  }

  @override
  Future<DoubaoVoiceCredentials?> readCredentials({
    required VoiceCredentialScope scope,
  }) async {
    return _values[(scope.daemonUrl, scope.userId)];
  }

  @override
  Future<void> saveCredentials({
    required VoiceCredentialScope scope,
    required DoubaoVoiceCredentials credentials,
  }) async {
    if (saveDelay != null) {
      await Future<void>.delayed(saveDelay!);
    }
    _values[(scope.daemonUrl, scope.userId)] = credentials;
    savedScopes.add((daemonUrl: scope.daemonUrl, userId: scope.userId));
  }

  @override
  Future<void> clearCredentials({required VoiceCredentialScope scope}) async {
    _values.remove((scope.daemonUrl, scope.userId));
    deletedScopes.add((daemonUrl: scope.daemonUrl, userId: scope.userId));
  }
}

class FakeDoubaoSocketClient implements DoubaoSocketClient {
  FakeDoubaoSocketClient(this.connection);

  final FakeDoubaoSocketConnection connection;
  final requests = <DoubaoConnectRequest>[];

  @override
  Future<DoubaoSocketConnection> connect(DoubaoConnectRequest request) async {
    requests.add(request);
    return connection;
  }
}

class FakeDoubaoSocketConnection implements DoubaoSocketConnection {
  final _controller = StreamController<Object?>();
  final _sentFrameCount = StreamController<int>.broadcast();
  final sentFrames = <List<int>>[];
  final sentTexts = <String>[];

  @override
  Stream<Object?> get messages => _controller.stream;

  @override
  Future<void> send(List<int> bytes) async {
    sentFrames.add(bytes);
    _sentFrameCount.add(sentFrames.length);
  }

  @override
  Future<void> sendText(String message) async {
    sentTexts.add(message);
  }

  @override
  Future<void> close() async {
    await _controller.close();
  }

  void emit(List<int> bytes) {
    _controller.add(Uint8List.fromList(bytes));
  }

  void emitText(String message) {
    _controller.add(message);
  }

  Future<void> waitForSentFrames(int count) async {
    if (sentFrames.length >= count) {
      return;
    }
    await _sentFrameCount.stream.firstWhere((value) => value >= count);
  }
}

class FakeDoubaoRecorder implements DoubaoRecorder {
  FakeDoubaoRecorder({required this.stream});

  final Stream<Uint8List> stream;

  @override
  Future<bool> hasPermission({bool request = true}) async => true;

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async => stream;

  @override
  Future<String?> stop() async => null;
}

class FakeImageAttachmentPicker implements ImageAttachmentPicker {
  FakeImageAttachmentPicker({
    this.image,
    List<PickedImageAttachment>? images,
    this.error,
  }) : _images = images == null
           ? null
           : List<PickedImageAttachment>.from(images);

  final PickedImageAttachment? image;
  final List<PickedImageAttachment>? _images;
  final Object? error;
  final List<ImageAttachmentSource> sources = <ImageAttachmentSource>[];

  @override
  Future<PickedImageAttachment?> pickImage({
    ImageAttachmentSource source = ImageAttachmentSource.gallery,
  }) async {
    sources.add(source);
    if (error != null) {
      throw error!;
    }
    final images = _images;
    if (images != null) {
      if (images.isEmpty) {
        return null;
      }
      return images.removeAt(0);
    }
    return image;
  }
}

class FakeVoiceInputController implements VoiceInputController {
  FakeVoiceInputController({
    this.transcript = '',
    this.phaseDelayMs = 0,
    this.error,
  });

  final String transcript;
  final int phaseDelayMs;
  final Object? error;
  var startCount = 0;
  var cancelCount = 0;
  var prepareCount = 0;

  @override
  bool get isConfigured => true;

  @override
  Future<void> prepare() async {
    prepareCount += 1;
  }

  @override
  Future<String> listenForTranscript() async {
    startCount += 1;
    if (error case final value?) {
      if (value is String) {
        throw VoiceInputException(value);
      }
      throw value;
    }
    return transcript;
  }

  @override
  Stream<VoiceInputUpdate> listenWithUpdates() async* {
    startCount += 1;
    yield const VoiceInputUpdate(stage: VoiceInputStage.connecting);
    await Future<void>.delayed(Duration(milliseconds: phaseDelayMs));
    if (error case final value?) {
      if (value is String) {
        throw VoiceInputException(value);
      }
      throw value;
    }
    yield const VoiceInputUpdate(stage: VoiceInputStage.listening);
    await Future<void>.delayed(Duration(milliseconds: phaseDelayMs));
    yield const VoiceInputUpdate(stage: VoiceInputStage.stopping);
    await Future<void>.delayed(Duration(milliseconds: phaseDelayMs));
    yield VoiceInputUpdate(
      stage: VoiceInputStage.stopping,
      transcript: transcript,
      isFinal: true,
    );
  }

  @override
  Future<void> cancel() async {
    cancelCount += 1;
  }
}

class CancelableFakeVoiceInputController implements VoiceInputController {
  var cancelCount = 0;
  var _canceled = false;

  @override
  bool get isConfigured => true;

  @override
  Future<void> prepare() async {}

  @override
  Future<String> listenForTranscript() async {
    throw UnimplementedError('use listenWithUpdates in tests');
  }

  @override
  Stream<VoiceInputUpdate> listenWithUpdates() async* {
    yield const VoiceInputUpdate(stage: VoiceInputStage.connecting);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    if (_canceled) {
      return;
    }
    yield const VoiceInputUpdate(stage: VoiceInputStage.listening);
    for (var index = 0; index < 20; index += 1) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      if (_canceled) {
        return;
      }
    }
  }

  @override
  Future<void> cancel() async {
    cancelCount += 1;
    _canceled = true;
  }
}
