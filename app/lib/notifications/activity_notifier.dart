import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../live_updates.dart';
import '../screens/activity_screen.dart';
import '../screens/messages_screen.dart' show messagePreview;
import '../session.dart';
import 'push.dart';
import 'system_notifications.dart';

/// The one of the running app; none in tests.
ActivityNotifier? activityNotifier;

/// Tells of what is new in Aktuelles and of new messages, from all circles, with a notification of the
/// system, while the app runs but is not in front. It hears of changes through the
/// live connection, asks the server what came, and shows what others did since it
/// last looked. Turned on and off for each device, see [setEnabled].
///
/// On Android with Firebase, and a server that sends, the server sends push messages
/// instead, which also come while the app is closed; then this shows none itself.
class ActivityNotifier {
  ActivityNotifier({required this.session, SystemNotifications? notifications, this.push, this.onOpen})
    : notifications = notifications ?? SystemNotifications();

  final AppSession session;
  final SystemNotifications notifications;

  /// Push messages, where there are; see [PushMessaging].
  final PushMessaging? push;

  /// Whether this device can get push messages, also while the app is closed.
  bool get canPush => _canPush;
  bool _canPush = false;

  /// Whether the server sends push messages to this device now.
  bool get pushing => _pushing;
  bool _pushing = false;

  /// Where a tapped push message leads that opened the app before anyone was signed in.
  OpenTarget? _openWhenSignedIn;

  /// Opens Aktuelles or a chat, when a notification is tapped.
  final void Function(OpenTarget target)? onOpen;

  /// Whether this device shows them. Off until the user turns them on, since most
  /// systems ask first.
  final enabled = ValueNotifier(false);

  static const _key = 'activity_notifications';

  /// How long to wait for more changes, which often come together, before asking.
  static const settle = Duration(seconds: 1);

  /// Entries newer than this were not told yet; null before the first look.
  String? _since;

  /// The newest message of each chat at the last look; null before the first look.
  Map<String, String>? _chatsSeen;

  /// The newest reaction to one's own messages in each chat at the last look.
  Map<String, String>? _reactionsSeen;

  /// What to ask the server at the next check, from what changed.
  bool _wantActivities = false;
  bool _wantChats = false;
  String _user = '';
  StreamSubscription<LiveEvent>? _events;
  Timer? _timer;
  bool _checking = false;
  bool _again = false;

  Future<void> start() async {
    await notifications.init((payload) => onOpen?.call(OpenTarget.fromPayload(payload)));
    final push = this.push;
    if (push != null && await push.available()) {
      _canPush = true;
      push.onOpened = (target) => onOpen?.call(target);
      _openWhenSignedIn = await push.openedFrom();
    }
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
    _chatsSeen = null;
    _reactionsSeen = null;
    if (on) _schedule(Duration.zero);
    try {
      await (await SharedPreferences.getInstance()).setBool(_key, on);
    } catch (_) {
      // Holds until the app closes.
    }
    await _syncPush();
    return on;
  }

  void _sessionChanged() {
    final user = session.status == SessionStatus.signedIn ? session.userId : '';
    if (user == _user) return;
    // Someone else, or no one: start over, without telling what was before.
    _user = user;
    _since = null;
    _chatsSeen = null;
    _reactionsSeen = null;
    // Signing out took the device off the server.
    _pushing = false;
    if (user.isEmpty) return;
    _schedule(Duration.zero);
    // At every start, since the key of the device can change.
    unawaited(_syncPush());
    final target = _openWhenSignedIn;
    if (target != null) {
      _openWhenSignedIn = null;
      WidgetsBinding.instance.addPostFrameCallback((_) => onOpen?.call(target));
    }
  }

  /// Tells the server whether to send push messages to this device: when they are on.
  Future<void> _syncPush() async {
    final push = this.push;
    if (push == null || !_canPush || _user.isEmpty) return;
    if (!enabled.value) {
      _pushing = false;
      try {
        await session.api.delete('/api/me/push-device');
      } on ApiException {
        // The key is forgotten below; what the server sends then goes nowhere.
      }
      await push.deleteToken();
      return;
    }
    final token = await push.token();
    if (token == null) {
      _pushing = false;
      return;
    }
    try {
      await session.api.put('/api/me/push-device', {'token': token, 'platform': 'android'});
      _pushing = enabled.value;
    } on ApiException {
      // A server without Firebase, or an older one: the app tells by itself.
      _pushing = false;
    }
  }

  void _heard(LiveEvent event) {
    if (event.isResync || event.topic == 'messages') {
      _wantChats = true;
    }
    if (event.isResync || const {'shopping', 'calendar', 'family'}.contains(event.topic)) {
      _wantActivities = true;
    }
    if (_wantChats || _wantActivities) _schedule(settle);
  }

  void _schedule(Duration after) {
    // While the server sends, nothing to ask for here.
    if (!enabled.value || _user.isEmpty || _pushing) return;
    if (after == Duration.zero) {
      _wantActivities = true;
      _wantChats = true;
    }
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
        if (_wantActivities) {
          _wantActivities = false;
          await _checkOnce();
        }
        if (_wantChats) {
          _wantChats = false;
          await _checkChatsOnce();
        }
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
    // The server sends them, also while the app is closed.
    if (_pushing) return;
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

  /// Tells of the newest message of each chat that came from someone else since the
  /// last look and is unread; one notification for each chat, replaced by the next.
  Future<void> _checkChatsOnce() async {
    if (!enabled.value || _user.isEmpty) return;
    final user = _user;
    final List<Map<String, dynamic>> chats;
    try {
      chats = (await session.api.get('/api/chats') as List).cast<Map<String, dynamic>>();
    } on ApiException {
      return;
    }
    if (user != _user) return;
    final seen = _chatsSeen;
    final reactionsSeen = _reactionsSeen;
    _chatsSeen = {
      for (final chat in chats) chat['id'] as String: (chat['last_message'] as Map?)?['created_at'] as String? ?? '',
    };
    _reactionsSeen = {
      for (final chat in chats) chat['id'] as String: (chat['reaction'] as Map?)?['created_at'] as String? ?? '',
    };
    if (seen == null || _pushing || _inFront) return;
    // Reactions of others to one's own messages.
    for (final chat in chats) {
      final reaction = chat['reaction'] as Map<String, dynamic>?;
      if (reaction == null) continue;
      final at = reaction['created_at'] as String? ?? '';
      if (at.compareTo(reactionsSeen?[chat['id']] ?? '') <= 0) continue;
      await notifications.show(
        id: 'reaction-${chat['id']}'.hashCode & 0x7fffffff,
        title: _titleOf(chat, chat['name'] as String? ?? 'Kintura'),
        body: reaction['text'] as String? ?? '',
        payload: OpenTarget.chat(chat['family_id'] as String, chat['id'] as String).payload,
      );
    }
    for (final chat in chats) {
      final last = chat['last_message'] as Map<String, dynamic>?;
      if (last == null || last['own'] == true || last['deleted'] == true) continue;
      if (((chat['unread'] as num?) ?? 0) == 0) continue;
      final at = last['created_at'] as String? ?? '';
      if (at.compareTo(seen[chat['id']] ?? '') <= 0) continue;
      final group = chat['kind'] == 'group';
      final text = messagePreview(last);
      final sender = last['sender_name'] as String? ?? '';
      await notifications.show(
        id: 'chat-${chat['id']}'.hashCode & 0x7fffffff,
        title: _titleOf(chat, chat['name'] as String? ?? 'Kintura'),
        body: group && sender.isNotEmpty ? '$sender: $text' : text,
        payload: OpenTarget.chat(chat['family_id'] as String, chat['id'] as String).payload,
      );
    }
  }

  /// [title] with the circle, if there is more than one, so one knows where it happened.
  String _titleOf(Map<String, dynamic> item, [String title = 'Kintura']) {
    if (session.families.length < 2) return title;
    final family = session.families.where((f) => f.id == item['family_id']).firstOrNull;
    return family == null ? title : '$title · ${family.name}';
  }
}
