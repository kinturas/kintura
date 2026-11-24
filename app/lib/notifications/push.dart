import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Where a tapped notification leads: Aktuelles, or a chat of Nachrichten.
@immutable
class OpenTarget {
  const OpenTarget.activities() : familyId = '', chatId = '';
  const OpenTarget.chat(this.familyId, this.chatId);

  /// From what MainActivity.kt passes on: a map, or true from older builds.
  factory OpenTarget.fromPush(Object? data) {
    if (data is Map && data['kind'] == 'message') {
      final family = data['family_id'] as String? ?? '';
      final chat = data['chat_id'] as String? ?? '';
      if (family.isNotEmpty && chat.isNotEmpty) return OpenTarget.chat(family, chat);
    }
    return const OpenTarget.activities();
  }

  /// From the payload of a notification of the app itself, see [payload].
  factory OpenTarget.fromPayload(String payload) {
    final parts = payload.split(':');
    if (parts.length == 3 && parts[0] == 'chat') return OpenTarget.chat(parts[1], parts[2]);
    return const OpenTarget.activities();
  }

  final String familyId;
  final String chatId;

  bool get isChat => chatId.isNotEmpty;

  String get payload => isChat ? 'chat:$familyId:$chatId' : '';

  @override
  bool operator ==(Object other) => other is OpenTarget && other.familyId == familyId && other.chatId == chatId;

  @override
  int get hashCode => Object.hash(familyId, chatId);
}

/// Push messages through Firebase Cloud Messaging, on Android only: the system shows
/// them by itself, also while the app is closed. See MainActivity.kt.
class PushMessaging {
  PushMessaging({MethodChannel? channel}) : _channel = channel ?? const MethodChannel('de.kintura.app/push');

  final MethodChannel _channel;

  /// Called when a push message is tapped while the app runs.
  void Function(OpenTarget target)? onOpened;

  /// Whether this device can get them: Android, with Firebase in the build.
  Future<bool> available() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'opened') onOpened?.call(OpenTarget.fromPush(call.arguments));
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

  /// Where a tapped push message that opened the app leads; null if none did. Only once.
  Future<OpenTarget?> openedFrom() async {
    try {
      final result = await _channel.invokeMethod<Object?>('openedFrom');
      if (result == null || result == false) return null;
      return OpenTarget.fromPush(result);
    } on Exception {
      return null;
    }
  }
}
