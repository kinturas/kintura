import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'api.dart';
import 'reload_stub.dart' if (dart.library.js_interop) 'reload_web.dart';

/// Version of this build, in the form the server reports it (`1.2.3+45`).
/// Set with `--dart-define=APP_VERSION=...`, empty in development.
const appVersion = String.fromEnvironment('APP_VERSION');

/// Notices when the server runs a newer web build than the open tab.
///
/// A loaded Flutter web app never reloads by itself, so a tab or an installed
/// app left open keeps the old version. Asks the server on start, whenever the
/// app comes back to the foreground and every few minutes.
class UpdateCheck {
  UpdateCheck({required this.api, this.interval = const Duration(minutes: 15)});

  final ApiClient api;
  final Duration interval;

  /// True once the server has a different version than this build.
  final available = ValueNotifier(false);

  Timer? _timer;
  AppLifecycleListener? _lifecycle;

  /// Only the web app is replaced by deploying the server, and only builds that
  /// know their own version can compare.
  static bool get supported => kIsWeb && appVersion.isNotEmpty;

  void start() {
    if (!supported) return;
    check();
    _timer = Timer.periodic(interval, (_) => check());
    _lifecycle = AppLifecycleListener(onResume: check);
  }

  Future<void> check() async {
    if (available.value) return;
    try {
      final body = await api.get('/api/version');
      final server = body is Map ? body['version'] : null;
      if (server is String && server.isNotEmpty && server != 'dev' && server != appVersion) {
        available.value = true;
      }
    } on ApiException {
      // Unreachable for now, the next check tries again.
    }
  }

  void dispose() {
    _timer?.cancel();
    _lifecycle?.dispose();
    available.dispose();
  }
}

/// Shows a bar above the app once a new version is available.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key, required this.check, required this.child});

  final UpdateCheck check;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: check.available,
      builder: (context, available, _) => Column(
        children: [
          if (available)
            Material(
              color: Theme.of(context).colorScheme.primaryContainer,
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
                  child: Row(
                    children: [
                      Icon(
                        Icons.system_update_alt,
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Eine neue Version von Kintura ist da.',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onPrimaryContainer,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: reloadPage,
                        child: const Text('Neu laden'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          Expanded(
            child: available
                // The bar already keeps the top inset clear.
                ? MediaQuery.removePadding(context: context, removeTop: true, child: child)
                : child,
          ),
        ],
      ),
    );
  }
}
