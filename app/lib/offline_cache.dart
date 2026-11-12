import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A server answer as it was last loaded.
class CachedResponse {
  const CachedResponse(this.body, this.savedAt);

  final String body;
  final DateTime savedAt;
}

/// Keeps the answers of GET requests on the device, so that the app can still
/// show them while the server cannot be reached. Changing anything always takes
/// the server.
abstract class ResponseCache {
  CachedResponse? read(String key);
  Future<void> write(String key, String body);
  Future<void> clear();
}

class MemoryResponseCache implements ResponseCache {
  final entries = <String, CachedResponse>{};

  @override
  CachedResponse? read(String key) => entries[key];

  @override
  Future<void> write(String key, String body) async => entries[key] = CachedResponse(body, DateTime.now());

  @override
  Future<void> clear() async => entries.clear();
}

/// Stores in the shared preferences, which on the web is the browser's local storage.
///
/// That holds only a few megabytes per site, so the oldest answers make way once
/// [maxChars] is reached.
class PrefsResponseCache implements ResponseCache {
  PrefsResponseCache._(this._prefs, this.maxChars) {
    for (final key in _prefs.getKeys()) {
      if (!key.startsWith(_prefix)) continue;
      final entry = _decode(_prefs.getString(key));
      if (entry == null) {
        _prefs.remove(key);
      } else {
        _entries[key.substring(_prefix.length)] = entry;
      }
    }
  }

  static const _prefix = 'response_cache:';

  static Future<PrefsResponseCache> open({int maxChars = 3000000}) async =>
      PrefsResponseCache._(await SharedPreferences.getInstance(), maxChars);

  final SharedPreferences _prefs;
  final int maxChars;
  final _entries = <String, CachedResponse>{};

  static CachedResponse? _decode(String? raw) {
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return CachedResponse(json['body'] as String, DateTime.parse(json['saved_at'] as String));
    } catch (_) {
      return null;
    }
  }

  @override
  CachedResponse? read(String key) => _entries[key];

  @override
  Future<void> write(String key, String body) async {
    // Most answers do not change between visits, and each write costs.
    if (_entries[key]?.body == body) return;
    if (body.length > maxChars) return;
    final entry = CachedResponse(body, DateTime.now());
    _entries[key] = entry;
    _evict();
    try {
      await _prefs.setString(
        _prefix + key,
        jsonEncode({'body': body, 'saved_at': entry.savedAt.toIso8601String()}),
      );
    } catch (_) {
      // Storage full or unavailable: the app works on, only without this answer offline.
      _entries.remove(key);
    }
  }

  void _evict() {
    var total = _entries.values.fold(0, (sum, entry) => sum + entry.body.length);
    if (total <= maxChars) return;
    final oldestFirst = _entries.entries.toList()..sort((a, b) => a.value.savedAt.compareTo(b.value.savedAt));
    for (final entry in oldestFirst) {
      if (total <= maxChars) break;
      total -= entry.value.body.length;
      _entries.remove(entry.key);
      _prefs.remove(_prefix + entry.key);
    }
  }

  @override
  Future<void> clear() async {
    for (final key in _entries.keys.toList()) {
      await _prefs.remove(_prefix + key);
    }
    _entries.clear();
  }
}
