import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../live_updates.dart';
import '../screens/activity_screen.dart';
import '../session.dart';
import 'system_notifications.dart';

/// Tells of what is new in Aktuelles, from all circles, with a notification of the
/// system, while the app runs but is not in front. It hears of changes through the
/// live connection, asks the server what came, and shows what others did since it
/// last looked. Turned on and off for each device, see [setEnabled].
/// The one of the running app; none in tests.
ActivityNotifier? activityNotifier;

class ActivityNotifier {
  ActivityNotifier({required this.session, SystemNotifications? notifications, this.onOpen})
    : notifications = notifications ?? SystemNotifications();

  final AppSession session;
  final SystemNotifications notifications;

  /// Opens Aktuelles, when a notification is tapped.
  final VoidCallback? onOpen;

  /// Whether this device shows them. Off until the user turns them on, since most
  /// systems ask first.
  final enabled = ValueNotifier(false);

  static const _key = 'activity_notifications';

  /// How long to wait for more changes, which often come together, before asking.
  static const settle = Duration(seconds: 1);

  /// Entries newer than this were not told yet; null before the first look.
  String? _since;
  String _user = '';
  StreamSubscription<LiveEvent>? _events;
  Timer? _timer;
  bool _checking = false;
  bool _again = false;

  Future<void> start() async {
    await notifications.init((_) => onOpen?.call());
    try {
      final prefs = await SharedPreferences.getInstance();
      enabled.value = (prefs.getBool(_key) ?? false) && await notifications.allowed();
    } catch (_) {
      // Without storage they stay off.
    }
    session.addListener(_sessionChanged);
    _events = session.live.events.listen(_heard);
    _sessionChanged();
  }

  void dispose() {
    session.removeListener(_sessionChanged);
    _events?.cancel();
    _timer?.cancel();
  }

  /// Turns them on or off on this device. Turning them on asks the system first;
  /// returns whether they are on.
  Future<bool> setEnabled(bool on) async {
    if (on && !await notifications.requestPermission()) {
      enabled.value = false;
      return false;
    }
    enabled.value = on;
    // From now on, not what came before.
    _since = null;
    if (on) _schedule(Duration.zero);
    try {
      await (await SharedPreferences.getInstance()).setBool(_key, on);
    } catch (_) {
      // Holds until the app closes.
    }
    return on;
  }

  void _sessionChanged() {
    final user = session.status == SessionStatus.signedIn ? session.userId : '';
    if (user == _user) return;
    // Someone else, or no one: start over, without telling what was before.
    _user = user;
    _since = null;
    if (user.isNotEmpty) _schedule(Duration.zero);
  }

  void _heard(LiveEvent event) {
    if (event.isResync || const {'shopping', 'calendar', 'family'}.contains(event.topic)) _schedule(settle);
  }

  void _schedule(Duration after) {
    if (!enabled.value || _user.isEmpty) return;
    _timer?.cancel();
    _timer = Timer(after, _check);
  }

  bool get _inFront => WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  Future<void> _check() async {
    if (_checking) {
      _again = true;
      return;
    }
    _checking = true;
    try {
      do {
        _again = false;
        await _checkOnce();
      } while (_again);
    } finally {
      _checking = false;
    }
  }

  Future<void> _checkOnce() async {
    if (!enabled.value || _user.isEmpty) return;
    final user = _user;
    final List<Map<String, dynamic>> items;
    try {
      final result = await session.api.get('/api/activities?limit=20') as Map<String, dynamic>;
      items = (result['items'] as List).cast<Map<String, dynamic>>();
    } on ApiException {
      return;
    }
    if (user != _user) return;
    final since = _since;
    var newest = since ?? '';
    for (final item in items) {
      final at = item['updated_at'] as String? ?? '';
      if (at.compareTo(newest) > 0) newest = at;
    }
    _since = newest;
    // The first look only marks where to start.
    if (since == null) return;
    // In front, the app shows it already.
    if (_inFront) return;
    final fresh = items.where(
      (item) => item['own'] != true && item['new'] == true && (item['updated_at'] as String? ?? '').compareTo(since) > 0,
    );
    for (final item in fresh.toList().reversed) {
      await notifications.show(
        id: (item['id'] as String).hashCode & 0x7fffffff,
        title: _titleOf(item),
        body: activityText(item),
        payload: item['family_id'] as String? ?? '',
      );
    }
  }

  /// The circle, if there is more than one, so one knows where it happened.
  String _titleOf(Map<String, dynamic> item) {
    if (session.families.length < 2) return 'Kintura';
    final family = session.families.where((f) => f.id == item['family_id']).firstOrNull;
    return family == null ? 'Kintura' : 'Kintura · ${family.name}';
  }
}
