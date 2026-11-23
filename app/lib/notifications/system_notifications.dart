import 'system_notifications_io.dart' if (dart.library.js_interop) 'system_notifications_web.dart';

/// Notifications of the system: a toast on Windows, a notification on Android and
/// iOS, one of the browser on the web. They only come while the app runs.
abstract class SystemNotifications {
  /// The one of this platform.
  factory SystemNotifications() => platformNotifications();

  /// Whether the platform can show them at all.
  bool get supported;

  /// Sets up; [onTap] is called when one of them is tapped, with its payload.
  Future<void> init(void Function(String payload) onTap);

  /// Asks the user, if the system wants that; only after they tapped something,
  /// as browsers refuse it otherwise. Returns whether they may be shown.
  Future<bool> requestPermission();

  /// Whether they may be shown, without asking.
  Future<bool> allowed();

  /// Shows one; another with the same [id] replaces it.
  Future<void> show({required int id, required String title, required String body, String payload = ''});
}
