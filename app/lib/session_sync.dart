import 'dart:async';

import 'package:flutter/widgets.dart';

import 'api.dart';
import 'live_updates.dart';
import 'session.dart';

/// Keeps the session up to date with what others change, as an admin setting one's
/// color or role, or renaming the family. With a live connection it asks when the
/// server tells of such a change; without one every [interval]. Also whenever the
/// app comes back to the foreground. Unchanged answers rebuild nothing.
class SessionSync {
  SessionSync({required this.session, this.interval = const Duration(seconds: 30)});

  final AppSession session;
  final Duration interval;

  /// Even with a live connection, now and then, should one message have got lost.
  static const _safetyInterval = Duration(minutes: 5);

  Timer? _timer;
  AppLifecycleListener? _lifecycle;
  StreamSubscription<LiveEvent>? _events;
  Timer? _soon;
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);
  bool _running = false;

  void start() {
    _timer = Timer.periodic(interval, (_) {
      final live = session.live.connected.value;
      if (!live || DateTime.now().difference(_last) >= _safetyInterval) sync();
    });
    _lifecycle = AppLifecycleListener(onResume: sync);
    _events = session.live.events.where((e) => e.isResync || e.topic == 'family').listen((_) {
      // Several changes in a row are taken in together.
      _soon?.cancel();
      _soon = Timer(const Duration(milliseconds: 500), sync);
    });
  }

  Future<void> sync() async {
    if (_running) return;
    _running = true;
    _last = DateTime.now();
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
    _soon?.cancel();
    _soon = null;
    _events?.cancel();
    _events = null;
    _lifecycle?.dispose();
    _lifecycle = null;
  }
}
