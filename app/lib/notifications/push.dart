import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Push messages through Firebase Cloud Messaging, on Android only: the system shows
/// them by itself, also while the app is closed. See MainActivity.kt.
class PushMessaging {
  PushMessaging({MethodChannel? channel}) : _channel = channel ?? const MethodChannel('de.kintura.app/push');

  final MethodChannel _channel;

  /// Called when a push message is tapped while the app runs.
  VoidCallback? onOpened;

  /// Whether this device can get them: Android, with Firebase in the build.
  Future<bool> available() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'opened') onOpened?.call();
    });
    try {
      return await _channel.invokeMethod<bool>('available') ?? false;
    } on Exception {
      return false;
    }
  }

  /// The key of this device for the server, or null.
  Future<String?> token() async {
    try {
      return await _channel.invokeMethod<String>('token');
    } on Exception {
      return null;
    }
  }

  /// Forgets the key, so that nothing comes any more, even if the server still had it.
  Future<void> deleteToken() async {
    try {
      await _channel.invokeMethod<void>('deleteToken');
    } on Exception {
      // Then the server forgets it.
    }
  }

  /// Whether a tapped push message opened the app; only once.
  Future<bool> openedFrom() async {
    try {
      return await _channel.invokeMethod<bool>('openedFrom') ?? false;
    } on Exception {
      return false;
    }
  }
}
