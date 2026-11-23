import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'system_notifications.dart';

SystemNotifications platformNotifications() => _WebNotifications();

/// The browser's own notifications. A click brings the tab to the front.
class _WebNotifications implements SystemNotifications {
  void Function(String payload)? _onTap;

  /// Shown ones by id, to replace them.
  final _shown = <int, web.Notification>{};

  @override
  bool get supported => web.window.has('Notification');

  @override
  Future<void> init(void Function(String payload) onTap) async => _onTap = onTap;

  @override
  Future<bool> allowed() async => supported && web.Notification.permission == 'granted';

  @override
  Future<bool> requestPermission() async {
    if (!supported) return false;
    if (web.Notification.permission == 'granted') return true;
    if (web.Notification.permission == 'denied') return false;
    final answer = await web.Notification.requestPermission().toDart;
    return answer.toDart == 'granted';
  }

  @override
  Future<void> show({required int id, required String title, required String body, String payload = ''}) async {
    if (!await allowed()) return;
    _shown.remove(id)?.close();
    final notification = web.Notification(
      title,
      web.NotificationOptions(body: body, tag: '$id', icon: 'icons/Icon-192.png'),
    );
    notification.onclick = ((web.Event _) {
      web.window.focus();
      notification.close();
      _onTap?.call(payload);
    }).toJS;
    _shown[id] = notification;
  }
}
