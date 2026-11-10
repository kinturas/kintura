import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

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
  ApiClient({http.Client? client, String baseUrl = defaultApiUrl})
    : _client = client ?? http.Client(),
      baseUrl = baseUrl.isEmpty ? Uri.base.origin : baseUrl;

  final http.Client _client;
  final String baseUrl;
  String? token;

  /// Called when the server rejects the session.
  void Function()? onUnauthorized;

  Map<String, String> get _authHeaders => {
    if (token != null) 'Authorization': 'Bearer $token',
  };

  Future<dynamic> get(String path) => _send('GET', path);
  Future<dynamic> post(String path, [Object? body]) =>
      _send('POST', path, body);
  Future<dynamic> put(String path, [Object? body]) => _send('PUT', path, body);
  Future<dynamic> delete(String path) => _send('DELETE', path);

  Future<dynamic> _send(String method, String path, [Object? body]) async {
    final request = http.Request(method, Uri.parse('$baseUrl$path'))
      ..headers.addAll(_authHeaders);
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final response = await _exchange(request, const Duration(seconds: 30));
    return response.body.isEmpty ? null : jsonDecode(response.body);
  }

  Future<Uint8List> getBytes(String path) async {
    final request = http.Request('GET', Uri.parse('$baseUrl$path'))
      ..headers.addAll(_authHeaders);
    final response = await _exchange(request, const Duration(minutes: 2));
    return response.bodyBytes;
  }

  Future<dynamic> upload(String path, String filename, Uint8List bytes) async {
    final request = http.MultipartRequest('POST', Uri.parse('$baseUrl$path'))
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
      throw ApiException(0, 'Der Server ist nicht erreichbar.');
    } on TimeoutException {
      throw ApiException(0, 'Der Server antwortet nicht.');
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return response;
    }
    if (response.statusCode == 401) {
      onUnauthorized?.call();
    }
    throw ApiException(response.statusCode, _errorMessage(response));
  }

  String _errorMessage(http.Response response) {
    try {
      return jsonDecode(utf8.decode(response.bodyBytes))['error'] as String;
    } catch (_) {
      return 'Unerwarteter Fehler (${response.statusCode}).';
    }
  }
}
