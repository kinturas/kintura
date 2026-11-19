import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';
import 'reload_stub.dart' if (dart.library.js_interop) 'reload_web.dart';

/// Version of this build, in the form the server reports it (`1.2.3+45`).
/// Set with `--dart-define=APP_VERSION=...`, empty in development.
const appVersion = String.fromEnvironment('APP_VERSION');

/// The platform as the server and the releases name it: web, android, windows, …
String get appPlatform => kIsWeb ? 'web' : defaultTargetPlatform.name.toLowerCase();

/// Reads 1.2.3 with or without +build into (1, 2, 3, build); null for anything else.
(int, int, int, int)? parseVersion(String text) {
  final [core, ...rest] = text.trim().split('+');
  final parts = core.split('.');
  if (parts.length != 3) return null;
  final numbers = [for (final part in parts) int.tryParse(part)];
  if (numbers.contains(null)) return null;
  final build = rest.isEmpty ? 0 : int.tryParse(rest.first) ?? 0;
  return (numbers[0]!, numbers[1]!, numbers[2]!, build);
}

int compareVersions((int, int, int, int) a, (int, int, int, int) b) {
  for (final (x, y) in [(a.$1, b.$1), (a.$2, b.$2), (a.$3, b.$3), (a.$4, b.$4)]) {
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

/// Tells the server with every request which version of the app this is, so that it
/// can turn away one too old for it, see [ApiClient.updateRequired].
Future<String> identifyApp(ApiClient api) async {
  var version = appVersion;
  try {
    final info = await PackageInfo.fromPlatform();
    version = '${info.version}+${info.buildNumber}';
  } catch (_) {
    // Then the version given at build time, if any.
  }
  api.clientHeaders = {
    if (version.isNotEmpty) 'X-App-Version': version,
    'X-App-Platform': appPlatform,
  };
  return version;
}

/// Notices when a newer version is there, and when this one is too old for the server.
///
/// The web app is replaced by deploying the server, but a loaded Flutter web app never
/// reloads by itself, so a tab or an installed app left open keeps the old version.
/// Android and Windows are downloaded from the website: their newest builds are in its
/// releases.json. Asks on start, whenever the app comes back to the foreground and
/// every few minutes.
class UpdateCheck {
  UpdateCheck({
    required this.api,
    this.version = appVersion,
    String? platform,
    http.Client? client,
    this.interval = const Duration(minutes: 15),
  }) : platform = platform ?? appPlatform,
       _client = client ?? http.Client();

  final ApiClient api;

  /// Of this build (`1.2.3+45`); empty in development, where nothing is compared.
  final String version;
  final String platform;
  final http.Client _client;
  final Duration interval;

  /// True once a newer version is there; it does not stop the app.
  final available = ValueNotifier(false);

  /// Where Android and Windows get the new version; empty while the server names no website.
  final downloadUrl = ValueNotifier('');

  /// True once this version is too old for the server: the app stops until updated.
  ValueNotifier<bool> get required => api.updateRequired;

  Timer? _timer;
  AppLifecycleListener? _lifecycle;

  bool get _isWeb => platform == 'web';

  void start() {
    if (parseVersion(version) == null) return;
    check();
    _timer = Timer.periodic(interval, (_) => check());
    _lifecycle = AppLifecycleListener(onResume: check);
  }

  Future<void> check() async {
    final own = parseVersion(version);
    if (own == null) return;
    Map<String, dynamic> server;
    try {
      final body = await api.get('/api/version');
      if (body is! Map<String, dynamic>) return;
      server = body;
    } on ApiException {
      // Unreachable for now, the next check tries again.
      return;
    }
    downloadUrl.value = server['download_url'] as String? ?? '';
    if (parseVersion(server['min_app_version'] as String? ?? '') case final min? when compareVersions(own, min) < 0) {
      required.value = true;
    }
    if (available.value) return;
    if (_isWeb) {
      final current = server['version'];
      if (current is String && current.isNotEmpty && current != 'dev' && current != version) available.value = true;
    } else if (downloadUrl.value.isNotEmpty) {
      final newest = await _newestRelease();
      if (newest != null && compareVersions(newest, own) > 0) available.value = true;
    }
  }

  /// The newest build for this platform the website offers, from tags like android-v1.2.3-7.
  Future<(int, int, int, int)?> _newestRelease() async {
    try {
      final response = await _client.get(Uri.parse('${downloadUrl.value}/releases.json')).timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) return null;
      (int, int, int, int)? newest;
      for (final entry in jsonDecode(utf8.decode(response.bodyBytes)) as List) {
        final tag = (entry as Map)['tag'];
        if (tag is! String || !tag.startsWith('$platform-v')) continue;
        final rest = tag.substring('$platform-v'.length);
        // The build number is optional, as on the website: android-v1.2.3 or android-v1.2.3-7.
        final release = parseVersion(rest.replaceFirst('-', '+'));
        if (release != null && (newest == null || compareVersions(release, newest) > 0)) newest = release;
      }
      return newest;
    } catch (_) {
      // Website unreachable or not as expected: no hint this time.
      return null;
    }
  }

  /// Reloads the web app, or opens the website with the downloads.
  Future<void> update() async {
    if (_isWeb) {
      reloadPage();
    } else if (downloadUrl.value.isNotEmpty) {
      await launchUrl(Uri.parse(downloadUrl.value), mode: LaunchMode.externalApplication);
    }
  }

  bool get canUpdate => _isWeb || downloadUrl.value.isNotEmpty;

  void dispose() {
    _timer?.cancel();
    _lifecycle?.dispose();
    available.dispose();
    downloadUrl.dispose();
  }
}

/// Shows a bar above the app once a new version is available, and instead of the app
/// a page asking to update once this version is too old for the server.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key, required this.check, required this.child});

  final UpdateCheck check;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([check.available, check.required, check.downloadUrl]),
      builder: (context, _) {
        if (check.required.value) return _UpdateRequiredPage(check: check);
        final available = check.available.value && check.canUpdate;
        final scheme = Theme.of(context).colorScheme;
        return Column(
          children: [
            if (available)
              Material(
                key: const Key('update-banner'),
                color: scheme.primaryContainer,
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
                    child: Row(
                      children: [
                        Icon(Icons.system_update_alt, color: scheme.onPrimaryContainer),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Eine neue Version von Kintura ist da.',
                            style: TextStyle(color: scheme.onPrimaryContainer),
                          ),
                        ),
                        TextButton(
                          onPressed: check.update,
                          child: Text(check._isWeb ? 'Neu laden' : 'Herunterladen'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            Expanded(
              child: available
                  // The bar already keeps the top inset clear.
                  ? MediaQuery.removePadding(context: context, removeTop: true, child: child)
                  : child,
            ),
          ],
        );
      },
    );
  }
}

class _UpdateRequiredPage extends StatelessWidget {
  const _UpdateRequiredPage({required this.check});

  final UpdateCheck check;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      key: const Key('update-required'),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.system_update_alt, size: 56, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(height: 16),
                  Text('Update nötig', style: text.headlineSmall, textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  Text(
                    check._isWeb
                        ? 'Diese Version von Kintura ist zu alt für den Server. Lade die Seite neu, dann geht es weiter.'
                        : 'Diese Version von Kintura ist zu alt für den Server. Bitte installiere die neue Version, '
                              'deine Daten bleiben erhalten.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  if (check.canUpdate)
                    FilledButton.icon(
                      key: const Key('update-now'),
                      onPressed: check.update,
                      icon: Icon(check._isWeb ? Icons.refresh : Icons.download),
                      label: Text(check._isWeb ? 'Neu laden' : 'Neue Version herunterladen'),
                    )
                  else
                    Text(
                      'Die neue Version gibt es dort, wo du Kintura heruntergeladen hast.',
                      textAlign: TextAlign.center,
                      style: text.bodySmall,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
