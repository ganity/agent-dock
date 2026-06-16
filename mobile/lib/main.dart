import 'package:flutter/material.dart';

import 'src/app/agent_dock_app.dart';

void main() {
  runApp(
    AgentDockApp(
      daemonUrl: Uri.parse(
        const String.fromEnvironment(
          'AGENT_DOCK_DAEMON_URL',
          defaultValue: 'http://10.0.2.2:4123',
        ),
      ),
    ),
  );
}
