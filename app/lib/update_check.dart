import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';
import 'reload_stub.dart' if (dart.library.js_interop) 'reload_web.dart';
import 'update_installer.dart';

/// Version of this build, in the form the server reports it (`1.2.3+45`).
/// Set with `--dart-define=APP_VERSION=...`, empty in development.
const appVersion = String.fromEnvironment('APP_VERSION');

/// The GitHub repository whose releases carry the Android and Windows builds, as
/// owner/name. Set with `--dart-define=RELEASES_REPO=...` for a fork.
const releasesRepo = String.fromEnvironment('RELEASES_REPO', defaultValue: 'kinturas/kintura');

/// The platform as the server and the releases name it: web, android, windows, …
String get appPlatform => kIsWeb ? 'web' : defaultTargetPlatform.name.toLowerCase();

/// The running app's check, for the about page; set in main, null in tests and before.
UpdateCheck? updateCheck;

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
  api.clientHeaders = {if (version.isNotEmpty) 'X-App-Version': version, 'X-App-Platform': appPlatform};
  return version;
}

/// A build for this platform on GitHub, from a tag like android-v1.2.3-7.
class AppRelease {
  const AppRelease({required this.version, required this.pageUrl, required this.downloadUrl});

  final (int, int, int, int) version;

  /// The release on GitHub, with its notes.
  final String pageUrl;

  /// The file to install: the APK on Android, the installer on Windows.
  final String downloadUrl;

  /// As the about page shows the own version: 1.2.3 (7).
  String get name => '${version.$1}.${version.$2}.${version.$3} (${version.$4})';
}

enum UpdateStatus {
  /// A development build, or no release for this platform: nothing to compare.
  unknown,
  upToDate,
  available,

  /// GitHub or the server did not answer.
  failed,
}

/// Notices when a newer version is there, and when this one is too old for the server.
///
/// The web app is replaced by deploying the server, but a loaded Flutter web app never
/// reloads by itself, so a tab or an installed app left open keeps the old version.
/// Android and Windows are released on GitHub ([releasesRepo]): the newest release for
/// the platform names the file to download. Asks on start, whenever the app comes back
/// to the foreground and every few minutes, GitHub at most every [githubInterval],
/// since it allows only 60 requests an hour without signing in.
class UpdateCheck {
  UpdateCheck({
    required this.api,
    this.version = appVersion,
    String? platform,
    http.Client? client,
    this.repo = releasesRepo,
    this.interval = const Duration(minutes: 15),
    this.githubInterval = const Duration(minutes: 10),
    this._installer,
  }) : platform = platform ?? appPlatform,
       _client = client ?? http.Client();

  final ApiClient api;

  /// Of this build (`1.2.3+45`); empty in development, where nothing is compared.
  final String version;
  final String platform;

  /// owner/name on GitHub.
  final String repo;
  final http.Client _client;
  final Duration interval;
  final Duration githubInterval;
  UpdateInstaller? _installer;

  /// True once a newer version is there; it does not stop the app.
  final available = ValueNotifier(false);

  /// The newest build for this platform on GitHub, once known.
  final latest = ValueNotifier<AppRelease?>(null);

  /// True while the new APK downloads; [progress] tells how far, null while not known.
  final downloading = ValueNotifier(false);
  final progress = ValueNotifier<double?>(null);

  /// True once this version is too old for the server: the app stops until updated.
  ValueNotifier<bool> get required => api.updateRequired;

  /// The website the server names for downloads, should GitHub not be reachable.
  String _website = '';
  DateTime? _githubAsked;
  Timer? _timer;
  AppLifecycleListener? _lifecycle;

  bool get isWeb => platform == 'web';

  /// Android downloads and installs the APK itself; Windows gets the installer in the browser.
  bool get installsItself => platform == 'android';

  /// What the buttons to update say.
  String get updateLabel => isWeb
      ? 'Neu laden'
      : installsItself
      ? 'Installieren'
      : 'Herunterladen';

  /// Whether this build can tell at all if it is the newest.
  bool get canCheck => parseVersion(version) != null;

  void start() {
    if (!canCheck) return;
    check();
    _timer = Timer.periodic(interval, (_) => check());
    _lifecycle = AppLifecycleListener(onResume: check);
  }

  /// Asks the server and, for Android and Windows, GitHub. With [force], as on the
  /// about page, GitHub is asked even if it was a moment ago.
  Future<UpdateStatus> check({bool force = false}) async {
    final own = parseVersion(version);
    if (own == null) return UpdateStatus.unknown;
    Map<String, dynamic>? server;
    try {
      final body = await api.get('/api/version');
      if (body is Map<String, dynamic>) server = body;
    } on ApiException {
      // Unreachable for now, the next check tries again.
    }
    if (server != null) {
      _website = server['download_url'] as String? ?? '';
      if (parseVersion(server['min_app_version'] as String? ?? '') case final min? when compareVersions(own, min) < 0) {
        required.value = true;
      }
    }
    if (isWeb) {
      if (server == null) return UpdateStatus.failed;
      final current = server['version'];
      if (current is String && current.isNotEmpty && current != 'dev' && current != version) available.value = true;
      return available.value ? UpdateStatus.available : UpdateStatus.upToDate;
    }
    final asked = _githubAsked;
    if (!force && asked != null && DateTime.now().difference(asked) < githubInterval) {
      return available.value ? UpdateStatus.available : UpdateStatus.upToDate;
    }
    final (answered, newest) = await _newestRelease();
    if (!answered) return UpdateStatus.failed;
    _githubAsked = DateTime.now();
    if (newest == null) return UpdateStatus.unknown;
    latest.value = newest;
    available.value = compareVersions(newest.version, own) > 0;
    return available.value ? UpdateStatus.available : UpdateStatus.upToDate;
  }

  /// The file of the build for this platform, as the deploy workflow names it.
  bool _isDownload(String name) => switch (platform) {
    'android' => name.endsWith('.apk'),
    'windows' => name.endsWith('-setup.exe'),
    _ => false,
  };

  /// The newest release for this platform on GitHub; answered is false if GitHub did not.
  Future<(bool, AppRelease?)> _newestRelease() async {
    try {
      final response = await _client
          .get(
            Uri.https('api.github.com', '/repos/$repo/releases', {'per_page': '50'}),
            headers: const {'Accept': 'application/vnd.github+json'},
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) return (false, null);
      AppRelease? newest;
      for (final entry in jsonDecode(utf8.decode(response.bodyBytes)) as List) {
        if (entry is! Map || entry['draft'] == true || entry['prerelease'] == true) continue;
        final tag = entry['tag_name'];
        if (tag is! String || !tag.startsWith('$platform-v')) continue;
        // The build number is optional: android-v1.2.3 or android-v1.2.3-7.
        final release = parseVersion(tag.substring('$platform-v'.length).replaceFirst('-', '+'));
        if (release == null || (newest != null && compareVersions(release, newest.version) <= 0)) continue;
        // Without its file, say while it is still uploading, a release is no use yet.
        final assets = (entry['assets'] as List? ?? const []).whereType<Map>();
        final url = assets.where((asset) => _isDownload('${asset['name']}')).firstOrNull?['browser_download_url'];
        if (url is! String) continue;
        newest = AppRelease(version: release, pageUrl: entry['html_url'] as String? ?? '', downloadUrl: url);
      }
      return (true, newest);
    } catch (_) {
      // GitHub unreachable or not as expected: no hint this time.
      return (false, null);
    }
  }

  /// Reloads the web app, installs the newest APK on Android, or downloads the newest
  /// installer in the browser. Either installs over this version and keeps the data.
  /// Returns what to tell if that did not work.
  Future<String?> update() async {
    if (isWeb) {
      reloadPage();
      return null;
    }
    if (latest.value == null) await check(force: true);
    final newest = latest.value;
    if (newest != null && installsItself) return _install(newest);
    final url = newest?.downloadUrl ?? (_website.isNotEmpty ? _website : 'https://github.com/$repo/releases');
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    return null;
  }

  Future<String?> _install(AppRelease release) async {
    if (downloading.value) return null;
    downloading.value = true;
    progress.value = null;
    try {
      final installer = _installer ??= UpdateInstaller();
      final fileName = Uri.parse(release.downloadUrl).pathSegments.last;
      final result = await installer.install(
        release.downloadUrl,
        fileName,
        onProgress: (value) => progress.value = value,
      );
      return switch (result) {
        InstallResult.started => null,
        InstallResult.permission =>
          'Erlaube Kintura in den Einstellungen, Apps zu installieren, und tippe dann noch einmal auf „Installieren“.',
        InstallResult.failed => 'Die neue Version ließ sich nicht herunterladen. Versuch es später noch einmal.',
      };
    } finally {
      downloading.value = false;
    }
  }

  /// Runs [update] from a button and tells in a snack bar if that did not work.
  Future<void> updateFrom(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final message = await update();
    if (message != null) messenger?.showSnackBar(SnackBar(content: Text(message)));
  }

  void dispose() {
    _timer?.cancel();
    _lifecycle?.dispose();
    available.dispose();
    latest.dispose();
    downloading.dispose();
    progress.dispose();
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
      listenable: Listenable.merge([check.available, check.required, check.latest, check.downloading, check.progress]),
      builder: (context, _) {
        if (check.required.value) return _UpdateRequiredPage(check: check);
        final available = check.available.value;
        final newest = check.latest.value;
        final downloading = check.downloading.value;
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
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                downloading
                                    ? 'Neue Version wird heruntergeladen …'
                                    : newest == null || check.isWeb
                                    ? 'Eine neue Version von Kintura ist da.'
                                    : 'Kintura ${newest.name} ist da.',
                                style: TextStyle(color: scheme.onPrimaryContainer),
                              ),
                              if (downloading)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: LinearProgressIndicator(value: check.progress.value),
                                ),
                            ],
                          ),
                        ),
                        TextButton(
                          onPressed: downloading ? null : () => check.updateFrom(context),
                          child: Text(check.updateLabel),
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
                    check.isWeb
                        ? 'Diese Version von Kintura ist zu alt für den Server. Lade die Seite neu, dann geht es weiter.'
                        : 'Diese Version von Kintura ist zu alt für den Server. Bitte installiere die neue Version, '
                              'deine Daten bleiben erhalten.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  if (check.downloading.value)
                    SizedBox(width: 240, child: LinearProgressIndicator(value: check.progress.value))
                  else
                    FilledButton.icon(
                      key: const Key('update-now'),
                      onPressed: () => check.updateFrom(context),
                      icon: Icon(check.isWeb ? Icons.refresh : Icons.download),
                      label: Text(
                        check.isWeb
                            ? 'Neu laden'
                            : check.installsItself
                            ? 'Neue Version installieren'
                            : 'Neue Version herunterladen',
                      ),
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

/// On the about page: asks for a newer version on a tap and offers to get it.
class UpdateTile extends StatefulWidget {
  const UpdateTile({super.key, required this.check});

  final UpdateCheck check;

  @override
  State<UpdateTile> createState() => _UpdateTileState();
}

class _UpdateTileState extends State<UpdateTile> {
  UpdateStatus? _status;
  bool _checking = false;

  UpdateCheck get _check => widget.check;

  @override
  void initState() {
    super.initState();
    // What the check in the background already found.
    if (_check.available.value) _status = UpdateStatus.available;
  }

  Future<void> _run() async {
    setState(() => _checking = true);
    final status = await _check.check(force: true);
    if (!mounted) return;
    setState(() {
      _checking = false;
      _status = status;
    });
  }

  String get _text {
    if (!_check.canCheck) return 'Entwicklungsversion, ohne Updates';
    if (_checking) return 'Wird geprüft …';
    final newest = _check.latest.value;
    return switch (_status) {
      null => 'Tippen, um nach einer neuen Version zu suchen',
      UpdateStatus.upToDate => 'Du hast die neueste Version.',
      UpdateStatus.available when newest != null && !_check.isWeb => 'Version ${newest.name} ist da.',
      UpdateStatus.available => 'Eine neue Version ist da.',
      UpdateStatus.unknown => 'Für diese Plattform gibt es keine Downloads.',
      UpdateStatus.failed => 'Die Suche hat nicht geklappt, versuch es später noch einmal.',
    };
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_check.downloading, _check.progress]),
      builder: (context, _) {
        if (_check.downloading.value) {
          return ListTile(
            key: const Key('about-update'),
            leading: const Icon(Icons.system_update_alt),
            title: const Text('Neue Version wird heruntergeladen …'),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(value: _check.progress.value),
            ),
          );
        }
        return ListTile(
          key: const Key('about-update'),
          leading: const Icon(Icons.system_update_alt),
          title: const Text('Nach Updates suchen'),
          subtitle: Text(_text),
          enabled: _check.canCheck,
          onTap: _checking ? null : _run,
          trailing: _checking
              ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2))
              : _status == UpdateStatus.available
              ? FilledButton(
                  key: const Key('about-update-download'),
                  onPressed: () => _check.updateFrom(context),
                  child: Text(_check.updateLabel),
                )
              : null,
        );
      },
    );
  }
}
