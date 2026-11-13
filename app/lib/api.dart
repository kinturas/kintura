import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'offline_cache.dart';

/// Base URL of the backend. Set with `--dart-define=APP_URL=https://...`.
/// The Android emulator reaches the host machine via http://10.0.2.2:8080.
/// Empty means the server that delivered the web app.
const defaultApiUrl = String.fromEnvironment(
  'APP_URL',
  defaultValue: 'http://localhost:8080',
);

class ApiException implements Exception {
  ApiException(this.status, this.message);

  /// HTTP status, or 0 if the server could not be reached.
  final int status;
  final String message;

  @override
  String toString() => message;
}

class ApiClient {
  ApiClient({http.Client? client, String baseUrl = defaultApiUrl, this.cache})
    : _client = client ?? http.Client(),
      baseUrl = baseUrl.isEmpty ? Uri.base.origin : baseUrl;

  final http.Client _client;
  final String baseUrl;
  String? token;

  /// Holds the answers of GET requests for when the server cannot be reached.
  /// Null keeps nothing.
  final ResponseCache? cache;

  /// True while the server cannot be reached: meanwhile GET requests answer
  /// from [cache]. The next request that gets through sets it back.
  final offline = ValueNotifier(false);

  /// Called when the server rejects the session.
  void Function()? onUnauthorized;

  Map<String, String> get _authHeaders => {
    if (token != null) 'Authorization': 'Bearer $token',
  };

  /// Answers from [cache] when the server cannot be reached and it holds [path].
  Future<dynamic> get(String path) async {
    final keep = cache != null && _cacheable(path);
    final cached = keep ? cache!.read(path) : null;
    final http.Response response;
    try {
      // With something to fall back on, waiting long for a dead server only delays it.
      response = await _exchange(
        _request('GET', path),
        cached == null ? const Duration(seconds: 30) : const Duration(seconds: 10),
      );
    } on ApiException catch (e) {
      if (e.status != 0 || !keep) rethrow;
      if (cached == null) {
        throw ApiException(0, 'Keine Verbindung zum Server, und diese Daten sind noch nicht auf dem Gerät gespeichert.');
      }
      return cached.body.isEmpty ? null : jsonDecode(cached.body);
    }
    if (keep) unawaited(cache!.write(path, response.body));
    return response.body.isEmpty ? null : jsonDecode(response.body);
  }

  /// Searches, the version check and exports make no sense from an old copy.
  static bool _cacheable(String path) =>
      !path.startsWith('/api/places') && !path.startsWith('/api/version') && !path.endsWith('/ics');

  Future<dynamic> post(String path, [Object? body]) =>
      _send('POST', path, body);
  Future<dynamic> put(String path, [Object? body]) => _send('PUT', path, body);
  Future<dynamic> delete(String path) => _send('DELETE', path);

  http.Request _request(String method, String path) =>
      http.Request(method, Uri.parse('$baseUrl$path'))..headers.addAll(_authHeaders);

  Future<dynamic> _send(String method, String path, [Object? body]) async {
    final request = _request(method, path);
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final response = await _exchange(request, const Duration(seconds: 30));
    return response.body.isEmpty ? null : jsonDecode(response.body);
  }

  Future<Uint8List> getBytes(String path) async {
    final response = await _exchange(_request('GET', path), const Duration(minutes: 2));
    return response.bodyBytes;
  }

  Future<dynamic> upload(String path, String filename, Uint8List bytes, {String method = 'POST'}) async {
    final request = http.MultipartRequest(method, Uri.parse('$baseUrl$path'))
      ..headers.addAll(_authHeaders)
      ..files.add(
        http.MultipartFile.fromBytes('file', bytes, filename: filename),
      );
    final response = await _exchange(request, const Duration(minutes: 5));
    return jsonDecode(response.body);
  }

  Future<http.Response> _exchange(
    http.BaseRequest request,
    Duration timeout,
  ) async {
    final http.Response response;
    try {
      response = await http.Response.fromStream(
        await _client.send(request),
      ).timeout(timeout);
    } on http.ClientException {
      throw _unreachable(request, 'Der Server ist nicht erreichbar.');
    } on TimeoutException {
      throw _unreachable(request, 'Der Server antwortet nicht.');
    }
    // A proxy answers like this for a server that is down. The backend's own 502,
    // for example from the place search, comes with a message and means it is up.
    if (const {502, 503, 504}.contains(response.statusCode) && _backendMessage(response) == null) {
      throw _unreachable(request, 'Der Server ist nicht erreichbar.');
    }
    offline.value = false;
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return response;
    }
    if (response.statusCode == 401) {
      onUnauthorized?.call();
    }
    throw ApiException(response.statusCode, _errorMessage(response));
  }

  ApiException _unreachable(http.BaseRequest request, String message) {
    offline.value = true;
    return ApiException(
      0,
      request.method == 'GET' ? message : '$message Speichern geht erst wieder mit Verbindung zum Server.',
    );
  }

  String? _backendMessage(http.Response response) {
    try {
      return jsonDecode(utf8.decode(response.bodyBytes))['error'] as String;
    } catch (_) {
      return null;
    }
  }

  String _errorMessage(http.Response response) =>
      _backendMessage(response) ?? 'Unerwarteter Fehler (${response.statusCode}).';
}
