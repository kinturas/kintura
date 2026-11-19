import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';

/// One article put on a list or checked off, as it waits to reach the server.
///
/// It names the article, not its entry: one put on the list offline has no id yet.
@immutable
class ShoppingChange {
  const ShoppingChange({
    required this.family,
    required this.list,
    required this.name,
    required this.done,
    this.newArticle = false,
  });

  final String family;
  final String list;
  final String name;

  /// Checked off, or else put (back) on the list.
  final bool done;

  /// An article of the circle's own, made on the device: the server makes it first.
  /// Its symbol, photos and the rest come later, with a connection.
  final bool newArticle;

  bool sameArticle(ShoppingChange other) => other.family == family && other.list == list && other.name == name;

  Map<String, Object> toJson() => {'family': family, 'list': list, 'name': name, 'done': done, 'new_article': newArticle};

  static ShoppingChange? fromJson(Object? json) {
    if (json is! Map) return null;
    final (family, list, name, done) = (json['family'], json['list'], json['name'], json['done']);
    if (family is! String || list is! String || name is! String || done is! bool) return null;
    return ShoppingChange(family: family, list: list, name: name, done: done, newArticle: json['new_article'] == true);
  }
}

/// Where the outbox keeps its changes, so that they outlast closing the app.
abstract class OutboxStore {
  String? read();
  Future<void> write(String? value);
}

class MemoryOutboxStore implements OutboxStore {
  String? value;

  @override
  String? read() => value;

  @override
  Future<void> write(String? value) async => this.value = value;
}

/// Keeps them in the shared preferences, which on the web is the browser's local storage.
class PrefsOutboxStore implements OutboxStore {
  PrefsOutboxStore._(this._prefs);

  static const _key = 'shopping_outbox';

  static Future<PrefsOutboxStore> open() async => PrefsOutboxStore._(await SharedPreferences.getInstance());

  final SharedPreferences _prefs;

  @override
  String? read() => _prefs.getString(_key);

  @override
  Future<void> write(String? value) => value == null ? _prefs.remove(_key) : _prefs.setString(_key, value);
}

/// Shopping goes on without a connection: putting articles on a list and checking them
/// off counts on the device at once, and reaches the server in order once it can be
/// reached again. Everything else in Einkaufen still takes the server.
///
/// Per article only the last change waits: it is the state wanted in the end. Who
/// else changed the article meanwhile is overruled by it, which for shopping is what
/// one wants; an article deleted meanwhile is not checked off again.
class ShoppingOutbox {
  ShoppingOutbox([OutboxStore? store]) : _store = store ?? MemoryOutboxStore() {
    try {
      final raw = _store.read();
      if (raw != null) {
        changes.value = [for (final json in jsonDecode(raw) as List) ?ShoppingChange.fromJson(json)];
      }
    } catch (_) {
      // Unreadable, as from an older version: nothing to send.
    }
  }

  final OutboxStore _store;

  /// What still waits, the oldest first.
  final changes = ValueNotifier<List<ShoppingChange>>(const []);

  Future<void>? _sending;

  int waitingFor(String family, String list) =>
      changes.value.where((c) => c.family == family && c.list == list).length;

  Future<void> put(ShoppingChange change) {
    // A new article checked off again offline is still to be made.
    final made = changes.value.any((c) => c.sameArticle(change) && c.newArticle);
    final next = made && !change.newArticle
        ? ShoppingChange(family: change.family, list: change.list, name: change.name, done: change.done, newArticle: true)
        : change;
    return _set([...changes.value.where((c) => !c.sameArticle(change)), next]);
  }

  /// The articles made on the device that the server does not know yet.
  Iterable<String> newArticles(String family) =>
      changes.value.where((c) => c.family == family && c.newArticle).map((c) => c.name);

  /// Shows [items] of a list as they will be once what waits has reached the server.
  List<Map<String, dynamic>> apply(String family, String list, List<Map<String, dynamic>> items) {
    final out = [for (final item in items) {...item}];
    for (final change in changes.value) {
      if (change.family != family || change.list != list) continue;
      final item = out.where((i) => i['name'] == change.name).firstOrNull;
      if (item != null) {
        item['done'] = change.done;
      } else if (!change.done) {
        out.add({
          'id': '',
          'name': change.name,
          'amount': '',
          'note': '',
          'urgency': '',
          'done': false,
          'photo_ids': <String>[],
        });
      }
    }
    return out;
  }

  /// Sends what waits, one after the other, and returns what the server refused.
  /// Without a connection it stops, and the rest waits for the next time.
  Future<List<String>> send(ApiClient api) async {
    // One sending at a time, or a change could go twice.
    while (_sending != null) {
      await _sending;
    }
    final done = Completer<void>();
    _sending = done.future;
    final refused = <String>[];
    try {
      while (changes.value.isNotEmpty) {
        final change = changes.value.first;
        final path = '/api/families/${change.family}/shopping/lists/${change.list}/items';
        try {
          if (change.newArticle) await _makeArticle(api, change);
          await api.post(change.done ? '$path/check' : path, {'name': change.name});
        } on ApiException catch (e) {
          // Unreachable, or signed out, which empties the outbox anyway.
          if (e.status == 0 || e.status == 401) break;
          // Refused for good, as for a list deleted meanwhile: trying again would not help.
          refused.add('„${change.name}“: ${e.message}');
        }
        // Changed again while on the way: the newer change stays and goes next.
        await _set([...changes.value.where((c) => !identical(c, change))]);
      }
    } finally {
      _sending = null;
      done.complete();
    }
    return refused;
  }

  /// Made by someone else meanwhile, or already on an earlier try that lost the
  /// connection before the article reached the list: then it is there, which is enough.
  static Future<void> _makeArticle(ApiClient api, ShoppingChange change) async {
    try {
      await api.post('/api/families/${change.family}/shopping/articles', {'name': change.name});
    } on ApiException catch (e) {
      if (e.status != 409) rethrow;
    }
  }

  /// For signing out: what waits belongs to the account.
  Future<void> clear() => _set(const []);

  Future<void> _set(List<ShoppingChange> next) async {
    changes.value = next;
    try {
      await _store.write(next.isEmpty ? null : jsonEncode([for (final c in next) c.toJson()]));
    } catch (_) {
      // Storage unavailable: it waits until the app closes.
    }
  }
}
