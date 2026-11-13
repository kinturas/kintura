import 'dart:async';

import 'package:flutter/widgets.dart';

import 'api.dart';
import 'session.dart';

/// Keeps the session up to date with what others change, as an admin setting one's
/// color or role, or renaming the family. Asks every [interval] and whenever the app
/// comes back to the foreground; unchanged answers rebuild nothing.
class SessionSync {
  SessionSync({required this.session, this.interval = const Duration(seconds: 30)});

  final AppSession session;
  final Duration interval;

  Timer? _timer;
  AppLifecycleListener? _lifecycle;
  bool _running = false;

  void start() {
    _timer = Timer.periodic(interval, (_) => sync());
    _lifecycle = AppLifecycleListener(onResume: sync);
  }

  Future<void> sync() async {
    if (_running) return;
    _running = true;
    try {
      await session.sync();
    } on ApiException {
      // Unreachable or signed out; the next round tries again.
    } finally {
      _running = false;
    }
  }

  /// Ends the asking; a second call does nothing.
  void dispose() {
    _timer?.cancel();
    _timer = null;
    _lifecycle?.dispose();
    _lifecycle = null;
  }
}
