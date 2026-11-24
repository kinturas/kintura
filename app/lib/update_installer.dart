import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

enum InstallResult {
  /// Android shows its dialog to install over this version.
  started,

  /// The app may not install apps yet: the settings for that are open, then try again.
  permission,
  failed,
}

/// Downloads a new APK into the cache and hands it to Android to install, on Android
/// only; see UpdateInstaller.kt.
class UpdateInstaller {
  UpdateInstaller({MethodChannel? channel, http.Client? client})
    : _channel = channel ?? const MethodChannel('de.kintura.app/update'),
      _client = client ?? http.Client();

  final MethodChannel _channel;
  final http.Client _client;
  bool _busy = false;

  /// Fetches [url] as [fileName], unless an earlier tap already did, and opens the dialog
  /// to install it. [onProgress] hears 0 to 1, or null while the size is not known.
  Future<InstallResult> install(String url, String fileName, {void Function(double? progress)? onProgress}) async {
    if (_busy) return InstallResult.failed;
    _busy = true;
    try {
      final dir = await _channel.invokeMethod<String>('dir');
      if (dir == null) return InstallResult.failed;
      final file = File('$dir/$fileName');
      if (!file.existsSync()) {
        // Older downloads are of no use any more.
        for (final old in Directory(dir).listSync().whereType<File>()) {
          old.deleteSync();
        }
        if (!await _download(url, file, onProgress)) return InstallResult.failed;
      }
      final result = await _channel.invokeMethod<String>('install', {'path': file.path});
      return result == 'permission' ? InstallResult.permission : InstallResult.started;
    } catch (_) {
      return InstallResult.failed;
    } finally {
      _busy = false;
    }
  }

  /// Into a .part first, so that a broken download is never taken for a whole one.
  Future<bool> _download(String url, File file, void Function(double?)? onProgress) async {
    final part = File('${file.path}.part');
    try {
      final response = await _client.send(http.Request('GET', Uri.parse(url))).timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) return false;
      final total = response.contentLength;
      var received = 0;
      onProgress?.call(total == null ? null : 0);
      final sink = part.openWrite();
      try {
        await for (final chunk in response.stream.timeout(const Duration(seconds: 30))) {
          sink.add(chunk);
          received += chunk.length;
          if (total != null && total > 0) onProgress?.call(received / total);
        }
      } finally {
        await sink.close();
      }
      if (total != null && received != total) return false;
      part.renameSync(file.path);
      return true;
    } catch (_) {
      return false;
    } finally {
      if (part.existsSync()) part.deleteSync();
    }
  }
}
