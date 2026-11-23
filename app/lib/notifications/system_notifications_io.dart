import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'system_notifications.dart';

SystemNotifications platformNotifications() => _PluginNotifications();

/// Through flutter_local_notifications: toasts on Windows, notifications on Android
/// and iOS.
class _PluginNotifications implements SystemNotifications {
  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  static const _channel = AndroidNotificationDetails(
    'activities',
    'Aktuelles',
    channelDescription: 'Was andere in deinen Kreisen neu gemacht haben',
    importance: Importance.defaultImportance,
  );

  @override
  bool get supported => Platform.isWindows || Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  @override
  Future<void> init(void Function(String payload) onTap) async {
    if (!supported || _ready) return;
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          // Asked for when the user turns them on, not at the start.
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
          macOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
          windows: WindowsInitializationSettings(
            appName: 'Kintura',
            appUserModelId: 'Kintura.Kintura.App',
            guid: '6f1c9a52-3e7d-4b8a-9c41-2d5e8f0a7b36',
          ),
        ),
        onDidReceiveNotificationResponse: (response) => onTap(response.payload ?? ''),
      );
      _ready = true;
    } catch (_) {
      // Without them the app works as before.
    }
  }

  @override
  Future<bool> allowed() async {
    if (!_ready) return false;
    if (Platform.isAndroid) {
      return await _plugin
              .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
              ?.areNotificationsEnabled() ??
          false;
    }
    // Elsewhere the system says no by itself, if the user turned them off there.
    return true;
  }

  @override
  Future<bool> requestPermission() async {
    if (!_ready) return false;
    try {
      if (Platform.isAndroid) {
        return await _plugin
                .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
                ?.requestNotificationsPermission() ??
            false;
      }
      if (Platform.isIOS) {
        return await _plugin
                .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
                ?.requestPermissions(alert: true, sound: true) ??
            false;
      }
      if (Platform.isMacOS) {
        return await _plugin
                .resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>()
                ?.requestPermissions(alert: true, sound: true) ??
            false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> show({required int id, required String title, required String body, String payload = ''}) async {
    if (!_ready) return;
    try {
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(
          android: _channel,
          iOS: DarwinNotificationDetails(),
          macOS: DarwinNotificationDetails(),
          windows: WindowsNotificationDetails(),
        ),
        payload: payload,
      );
    } catch (_) {
      // One that does not show is no reason to stop.
    }
  }
}
