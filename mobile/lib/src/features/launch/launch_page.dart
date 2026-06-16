import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../shared/delayed_inline_spinner.dart';

typedef SignInCallback =
    Future<void> Function({required String username, required String password});
typedef TestDaemonCallback = Future<void> Function(Uri daemonUrl);
typedef OpenDaemonSetupCallback = Future<void> Function();

const _localDevelopmentDaemonUrl = 'http://10.0.2.2:4123';
const _launchOfflineText = 'Offline. Waiting for network...';

class LaunchPage extends StatefulWidget {
  const LaunchPage({
    super.key,
    required this.daemonUrl,
    required this.onSignIn,
    required this.onOpenDaemonSetup,
    required this.onTestConnection,
    required this.isDaemonConfigured,
    this.errorText,
    this.isSigningIn = false,
    this.isTestingConnection = false,
    this.clearPasswordSignal = 0,
  });

  final Uri daemonUrl;
  final SignInCallback onSignIn;
  final OpenDaemonSetupCallback onOpenDaemonSetup;
  final TestDaemonCallback onTestConnection;
  final bool isDaemonConfigured;
  final String? errorText;
  final bool isSigningIn;
  final bool isTestingConnection;
  final int clearPasswordSignal;

  @override
  State<LaunchPage> createState() => _LaunchPageState();
}

class RestorePage extends StatefulWidget {
  const RestorePage({
    super.key,
    required this.statusText,
    this.daemonHost,
    this.errorText,
    this.onRetry,
    this.onSignInManually,
    this.onChangeDaemon,
  });

  final String statusText;
  final String? daemonHost;
  final String? errorText;
  final Future<void> Function()? onRetry;
  final VoidCallback? onSignInManually;
  final Future<void> Function()? onChangeDaemon;

  @override
  State<RestorePage> createState() => _RestorePageState();
}

class _RestorePageState extends State<RestorePage> {
  Timer? _hostRevealTimer;
  bool _showDaemonHost = false;

  @override
  void initState() {
    super.initState();
    _syncHostReveal();
  }

  @override
  void didUpdateWidget(covariant RestorePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.daemonHost != widget.daemonHost) {
      _syncHostReveal();
    }
  }

  @override
  void dispose() {
    _hostRevealTimer?.cancel();
    super.dispose();
  }

  void _syncHostReveal() {
    _hostRevealTimer?.cancel();
    _showDaemonHost = false;
    final daemonHost = widget.daemonHost;
    if (daemonHost == null || daemonHost.isEmpty) {
      return;
    }
    _hostRevealTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) {
        return;
      }
      setState(() {
        _showDaemonHost = true;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const _RestoreAppMark(),
                const SizedBox(height: 24),
                Text(
                  widget.statusText,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (widget.errorText case final errorText?) ...[
                  const SizedBox(height: 16),
                  _LaunchStatusBanner(text: errorText),
                  if (widget.onRetry != null ||
                      widget.onSignInManually != null ||
                      widget.onChangeDaemon != null) ...[
                    const SizedBox(height: 12),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 12,
                      children: [
                        if (widget.onRetry != null)
                          TextButton(
                            onPressed: widget.onRetry,
                            child: const Text('Retry'),
                          ),
                        if (widget.onSignInManually != null)
                          TextButton(
                            onPressed: widget.onSignInManually,
                            child: const Text('Sign in manually'),
                          ),
                        if (widget.onChangeDaemon != null)
                          TextButton(
                            onPressed: widget.onChangeDaemon,
                            child: const Text('Change daemon'),
                          ),
                      ],
                    ),
                  ]
                ],
                if (_showDaemonHost) ...[
                  const SizedBox(height: 16),
                  _HostPill(host: widget.daemonHost!),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LaunchPageState extends State<LaunchPage> {
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final FocusNode _passwordFocusNode = FocusNode();
  late final TextEditingController _daemonUrlController = TextEditingController(
    text: widget.daemonUrl.toString(),
  );
  String? _daemonUrlErrorText;

  @override
  void dispose() {
    _daemonUrlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _passwordFocusNode.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant LaunchPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.clearPasswordSignal == widget.clearPasswordSignal) {
      return;
    }
    _passwordController.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _passwordFocusNode.requestFocus();
    });
  }

  Future<void> _submit() async {
    await widget.onSignIn(
      username: _usernameController.text.trim(),
      password: _passwordController.text,
    );
  }

  Future<void> _testConnection() async {
    final value = _daemonUrlController.text.trim();
    final parsed = _parseDaemonUrl(value);
    if (parsed == null) {
      setState(() {
        _daemonUrlErrorText = 'Enter a valid daemon URL';
      });
      return;
    }
    if (parsed.scheme == 'http' && !_isLocalDevelopmentHost(parsed.host)) {
      setState(() {
        _daemonUrlErrorText = 'Use HTTPS for remote daemons';
      });
      return;
    }
    setState(() {
      _daemonUrlErrorText = null;
    });
    await widget.onTestConnection(parsed);
  }

  void _useLocalDevelopmentAddress() {
    setState(() {
      _daemonUrlController.text = _localDevelopmentDaemonUrl;
      _daemonUrlErrorText = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isDaemonConfigured) {
      return Scaffold(
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const SizedBox(height: 12),
              if (_showStatusBanner) ...[
                _LaunchStatusBanner(text: widget.errorText!),
                const SizedBox(height: 16),
              ],
              const _AppMark(),
              const SizedBox(height: 28),
              Text(
                'Connect daemon',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 10),
              Text(
                'Enter the HTTPS address of your remote Agent Dock daemon.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 28),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: _daemonUrlController,
                        enabled: !widget.isTestingConnection,
                        onChanged: (_) {
                          if (_daemonUrlErrorText == null) {
                            return;
                          }
                          setState(() {
                            _daemonUrlErrorText = null;
                          });
                        },
                        decoration: const InputDecoration(
                          labelText: 'Daemon URL',
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Example: https://agent.example.com',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (_daemonUrlErrorText != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          _daemonUrlErrorText!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ],
                      if (widget.errorText != null) ...[
                        const SizedBox(height: 12),
                        if (!_showStatusBanner)
                          Text(
                            widget.errorText!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                      ],
                      const SizedBox(height: 18),
                      FilledButton(
                        onPressed: widget.isTestingConnection
                            ? null
                            : _testConnection,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            DelayedInlineSpinner(
                              active: widget.isTestingConnection,
                              spinnerKey: const ValueKey(
                                'launch-test-connection-spinner',
                              ),
                            ),
                            Text(
                              widget.isTestingConnection
                                  ? 'Testing connection...'
                                  : 'Test connection',
                            ),
                          ],
                        ),
                      ),
                      if (kDebugMode) ...[
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: widget.isTestingConnection
                              ? null
                              : _useLocalDevelopmentAddress,
                          child: const Text('Use local development address'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 12),
            if (_showStatusBanner) ...[
              _LaunchStatusBanner(text: widget.errorText!),
              const SizedBox(height: 16),
            ],
            const _AppMark(),
            const SizedBox(height: 28),
            Text(
              'Agent Dock',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 10),
            Text(
              'A native mobile workbench for live coding sessions.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 28),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Unlock workspace',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    _HostPill(host: widget.daemonUrl.host),
                    const SizedBox(height: 18),
                    TextField(
                      controller: _usernameController,
                      enabled: !widget.isSigningIn,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(labelText: 'Username'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _passwordController,
                      focusNode: _passwordFocusNode,
                      enabled: !widget.isSigningIn,
                      obscureText: true,
                      onSubmitted: (_) => _submit(),
                      decoration: const InputDecoration(labelText: 'Password'),
                    ),
                    if (widget.errorText != null) ...[
                      const SizedBox(height: 12),
                      if (!_showStatusBanner)
                        Text(
                          widget.errorText!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                    ],
                    const SizedBox(height: 18),
                    FilledButton(
                      onPressed: widget.isSigningIn ? null : _submit,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          DelayedInlineSpinner(
                            active: widget.isSigningIn,
                            spinnerKey: const ValueKey(
                              'launch-sign-in-spinner',
                            ),
                          ),
                          Text(
                            widget.isSigningIn ? 'Signing in...' : 'Sign in',
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: widget.isSigningIn
                          ? null
                          : widget.onOpenDaemonSetup,
                      child: const Text('Change daemon'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  bool get _showStatusBanner => widget.errorText == _launchOfflineText;
}

class _LaunchStatusBanner extends StatelessWidget {
  const _LaunchStatusBanner({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('launch-status-banner'),
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

class _RestoreAppMark extends StatefulWidget {
  const _RestoreAppMark();

  @override
  State<_RestoreAppMark> createState() => _RestoreAppMarkState();
}

class _RestoreAppMarkState extends State<_RestoreAppMark> {
  static const _pulseInterval = Duration(milliseconds: 900);

  Timer? _pulseTimer;
  bool _dimmed = false;

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
      _dimmed = false;
      return;
    }
    _pulseTimer ??= Timer.periodic(_pulseInterval, (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _dimmed = !_dimmed;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    _syncPulseTimer();
    return AnimatedOpacity(
      key: const ValueKey('restore-app-mark-opacity'),
      duration: const Duration(milliseconds: 700),
      curve: Curves.easeInOut,
      opacity: _dimmed ? 0.84 : 1,
      child: AnimatedScale(
        duration: const Duration(milliseconds: 700),
        curve: Curves.easeInOut,
        scale: _dimmed ? 0.96 : 1,
        child: const _AppMark(),
      ),
    );
  }
}

class DaemonUrlDialog extends StatefulWidget {
  const DaemonUrlDialog({super.key, required this.initialUrl});

  final Uri initialUrl;

  @override
  State<DaemonUrlDialog> createState() => _DaemonUrlDialogState();
}

class _DaemonUrlDialogState extends State<DaemonUrlDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialUrl.toString(),
  );
  String? _errorText;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Change daemon'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _controller,
            decoration: const InputDecoration(labelText: 'Daemon URL'),
          ),
          if (_errorText != null) ...[
            const SizedBox(height: 12),
            Text(
              _errorText!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final parsed = _parseDaemonUrl(_controller.text.trim());
            if (parsed == null) {
              setState(() {
                _errorText = 'Enter a valid daemon URL';
              });
              return;
            }
            if (parsed.scheme == 'http' &&
                !_isLocalDevelopmentHost(parsed.host)) {
              setState(() {
                _errorText = 'Use HTTPS for remote daemons';
              });
              return;
            }
            Navigator.of(context).pop(parsed);
          },
          child: const Text('Save daemon'),
        ),
      ],
    );
  }
}

Uri? _parseDaemonUrl(String value) {
  final parsed = Uri.tryParse(value.trim());
  if (parsed == null ||
      !parsed.hasScheme ||
      (parsed.host.isEmpty && !parsed.hasAuthority)) {
    return null;
  }
  final normalizedPath = parsed.path == '/' ? '' : parsed.path;
  return parsed.replace(path: normalizedPath);
}

bool _isLocalDevelopmentHost(String host) {
  if (host == 'localhost' || host == '127.0.0.1' || host == '10.0.2.2') {
    return true;
  }
  return host.startsWith('192.168.') ||
      host.startsWith('10.') ||
      host.startsWith('172.16.') ||
      host.startsWith('172.17.') ||
      host.startsWith('172.18.') ||
      host.startsWith('172.19.') ||
      host.startsWith('172.2') ||
      host.startsWith('172.30.') ||
      host.startsWith('172.31.');
}

class _HostPill extends StatelessWidget {
  const _HostPill({required this.host});

  final String host;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF17232D),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: const Color(0xFF29404D)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Text(host, style: Theme.of(context).textTheme.labelLarge),
        ),
      ),
    );
  }
}

class _AppMark extends StatelessWidget {
  const _AppMark();

  @override
  Widget build(BuildContext context) {
    return Align(
      child: Container(
        width: 88,
        height: 88,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF43D17A), Color(0xFF103A2A)],
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x6638C96F),
              blurRadius: 40,
              offset: Offset(0, 18),
            ),
          ],
        ),
        child: const Icon(
          Icons.terminal_rounded,
          color: Color(0xFF05100A),
          size: 42,
        ),
      ),
    );
  }
}
