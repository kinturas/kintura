import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kintura/api.dart';
import 'package:kintura/update_check.dart';

/// A server and GitHub: GET /api/version and the releases, with the requests seen.
class _Fake {
  _Fake({this.serverVersion = '0.0.14+40', this.minApp = '0.0.0', this.releases = const []});

  String serverVersion;
  String minApp;

  /// Tags on GitHub, each with the file the deploy workflow uploads.
  List<String> releases;

  /// Tags released without their file yet.
  List<String> withoutFile = [];
  int githubStatus = 200;
  final seen = <http.BaseRequest>[];

  int get githubCalls => seen.where((r) => r.url.host == 'api.github.com').length;

  /// One release v1.2.3 holds both files, the older ones per platform one.
  static List<String> _files(String tag) {
    if (tag.startsWith('v')) {
      final version = tag.substring(1);
      return ['kintura-$version.apk', 'kintura-$version-windows-setup.exe'];
    }
    final version = tag.substring(tag.indexOf('-v') + 2);
    return [tag.startsWith('windows') ? 'kintura-$version-windows-setup.exe' : 'kintura-$version.apk'];
  }

  late final client = MockClient((request) async {
    seen.add(request);
    if (request.url.host == 'api.github.com') {
      expect(request.url.path, '/repos/kinturas/kintura/releases');
      final body = [
        for (final tag in releases)
          {
            'tag_name': tag,
            'draft': false,
            'prerelease': false,
            'html_url': 'https://github.com/kinturas/kintura/releases/tag/$tag',
            'assets': [
              if (!withoutFile.contains(tag))
                for (final file in _files(tag))
                  {'name': file, 'browser_download_url': 'https://github.com/download/$tag/$file'},
            ],
          },
        {'tag_name': 'web-v9.9.9', 'draft': false, 'prerelease': false, 'assets': const []},
      ];
      return http.Response.bytes(utf8.encode(jsonEncode(body)), githubStatus);
    }
    final body = switch (request.url.path) {
      '/api/version' => {'version': serverVersion, 'min_app_version': minApp, 'download_url': ''},
      '/api/me' => const {'error': 'Diese Version von Kintura ist zu alt.'},
      _ => const {},
    };
    final status = request.url.path == '/api/me' ? 426 : 200;
    return http.Response.bytes(utf8.encode(jsonEncode(body)), status, headers: {'content-type': 'application/json'});
  });

  ApiClient get api => ApiClient(client: client, baseUrl: 'http://test');
}

void main() {
  test('Versionen werden mit Build-Nummer verglichen', () {
    expect(parseVersion('1.2.3+45'), (1, 2, 3, 45));
    expect(parseVersion('1.2.3'), (1, 2, 3, 0));
    expect(parseVersion('1.2'), isNull);
    expect(parseVersion('dev'), isNull);
    expect(compareVersions(parseVersion('0.0.13+7')!, parseVersion('0.0.13+8')!), lessThan(0));
    expect(compareVersions(parseVersion('0.1.0+1')!, parseVersion('0.0.99+99')!), greaterThan(0));
    expect(compareVersions(parseVersion('1.10.0')!, parseVersion('1.9.0')!), greaterThan(0));
  });

  test('jede Anfrage nennt Version und Plattform, 426 heißt Update nötig', () async {
    final fake = _Fake();
    final api = fake.api..clientHeaders = const {'X-App-Version': '0.0.13+7', 'X-App-Platform': 'android'};
    await api.get('/api/version');
    expect(fake.seen.last.headers['X-App-Version'], '0.0.13+7');
    expect(fake.seen.last.headers['X-App-Platform'], 'android');

    expect(api.updateRequired.value, isFalse);
    await expectLater(api.get('/api/me'), throwsA(isA<ApiException>().having((e) => e.status, 'status', 426)));
    expect(api.updateRequired.value, isTrue);
  });

  group('Android und Windows', () {
    test('ein neuerer Release auf GitHub ist ein Hinweis, ein älterer nicht', () async {
      final fake = _Fake(releases: ['android-v0.0.13-7', 'windows-v0.0.14-9', 'android-v0.0.12-6']);
      final check = UpdateCheck(api: fake.api, version: '0.0.13+7', platform: 'android', client: fake.client);
      expect(await check.check(), UpdateStatus.upToDate);
      expect(check.available.value, isFalse);
      expect(check.latest.value?.name, '0.0.13 (7)');

      fake.releases = [...fake.releases, 'android-v0.0.13-8'];
      expect(await check.check(force: true), UpdateStatus.available);
      expect(check.available.value, isTrue);
      expect(check.required.value, isFalse);
      expect(check.latest.value?.name, '0.0.13 (8)');
      expect(check.latest.value?.downloadUrl, 'https://github.com/download/android-v0.0.13-8/kintura-0.0.13-8.apk');
    });

    test('Windows bekommt den Installer', () async {
      final fake = _Fake(releases: ['android-v0.0.15-1', 'windows-v0.0.14-9']);
      final check = UpdateCheck(api: fake.api, version: '0.0.13+7', platform: 'windows', client: fake.client);
      expect(await check.check(), UpdateStatus.available);
      expect(check.latest.value?.downloadUrl, endsWith('kintura-0.0.14-9-windows-setup.exe'));
    });

    test('ein Release v1.2.3 für alle: jede Plattform nimmt ihre Datei', () async {
      final fake = _Fake(releases: ['v0.0.17', 'android-v0.0.16-2', 'windows-v0.0.16-2', 'website-v0.0.12-5']);
      final android = UpdateCheck(api: fake.api, version: '0.0.16+2', platform: 'android', client: fake.client);
      expect(await android.check(), UpdateStatus.available);
      expect(android.latest.value?.name, '0.0.17');
      expect(android.latest.value?.downloadUrl, 'https://github.com/download/v0.0.17/kintura-0.0.17.apk');

      final windows = UpdateCheck(api: fake.api, version: '0.0.16+2', platform: 'windows', client: fake.client);
      expect(await windows.check(), UpdateStatus.available);
      expect(windows.latest.value?.downloadUrl, endsWith('/v0.0.17/kintura-0.0.17-windows-setup.exe'));

      // Built from that release: the build number is the count of commits, higher than 0.
      final current = UpdateCheck(api: fake.api, version: '0.0.17+130', platform: 'android', client: fake.client);
      expect(await current.check(), UpdateStatus.upToDate);
    });

    test('ein Release ohne Datei zählt noch nicht', () async {
      final fake = _Fake(releases: ['android-v0.0.13-7', 'android-v0.0.14-1'])..withoutFile = ['android-v0.0.14-1'];
      final check = UpdateCheck(api: fake.api, version: '0.0.13+7', platform: 'android', client: fake.client);
      expect(await check.check(), UpdateStatus.upToDate);
    });

    test('GitHub wird nur alle paar Minuten gefragt, außer von Hand', () async {
      final fake = _Fake(releases: ['android-v0.0.13-7']);
      final check = UpdateCheck(api: fake.api, version: '0.0.13+7', platform: 'android', client: fake.client);
      await check.check();
      await check.check();
      expect(fake.githubCalls, 1);
      await check.check(force: true);
      expect(fake.githubCalls, 2);
    });

    test('ohne Antwort von GitHub kein Hinweis, die Mindestversion gilt trotzdem', () async {
      final fake = _Fake(minApp: '0.1.0', releases: ['android-v9.9.9-99'])..githubStatus = 403;
      final check = UpdateCheck(api: fake.api, version: '0.0.13+7', platform: 'android', client: fake.client);
      expect(await check.check(), UpdateStatus.failed);
      expect(check.available.value, isFalse);
      expect(check.required.value, isTrue);
    });

    test('ein Entwicklungs-Build ohne Version vergleicht nichts', () async {
      final fake = _Fake(minApp: '9.0.0');
      final check = UpdateCheck(api: fake.api, version: '', platform: 'android', client: fake.client);
      expect(await check.check(), UpdateStatus.unknown);
      expect(check.required.value, isFalse);
      expect(fake.seen, isEmpty);
    });
  });

  test('Web: eine andere Version auf dem Server heißt neu laden', () async {
    final fake = _Fake(serverVersion: '0.0.13+40');
    final check = UpdateCheck(api: fake.api, version: '0.0.13+40', platform: 'web', client: fake.client);
    expect(await check.check(), UpdateStatus.upToDate);
    fake.serverVersion = '0.0.14+41';
    expect(await check.check(), UpdateStatus.available);
    // The web app never asks GitHub.
    expect(fake.githubCalls, 0);
  });

  Future<UpdateCheck> pumpBanner(WidgetTester tester, UpdateCheck check) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => UpdateBanner(check: check, child: child!),
        home: const Scaffold(body: Text('Die App')),
      ),
    );
    return check;
  }

  testWidgets('der Hinweis lässt die App benutzen, „Update nötig“ nicht', (tester) async {
    final fake = _Fake(releases: ['windows-v0.0.14-9']);
    final check = UpdateCheck(api: fake.api, version: '0.0.13+7', platform: 'windows', client: fake.client);
    await pumpBanner(tester, check);
    await tester.runAsync(check.check);
    await tester.pump();
    expect(find.byKey(const Key('update-banner')), findsOneWidget);
    expect(find.text('Kintura 0.0.14 (9) ist da.'), findsOneWidget);
    expect(find.text('Herunterladen'), findsOneWidget);
    expect(find.text('Die App'), findsOneWidget);

    check.required.value = true;
    await tester.pump();
    expect(find.byKey(const Key('update-required')), findsOneWidget);
    expect(find.text('Update nötig'), findsOneWidget);
    expect(find.text('Neue Version herunterladen'), findsOneWidget);
    expect(find.text('Die App'), findsNothing);
  });

  testWidgets('im Web heißt es neu laden', (tester) async {
    final fake = _Fake();
    final check = UpdateCheck(api: fake.api, version: '0.0.13+40', platform: 'web', client: fake.client);
    await pumpBanner(tester, check);
    check.required.value = true;
    await tester.pump();
    expect(find.textContaining('Lade die Seite neu'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Neu laden'), findsOneWidget);
  });

  group('Über: nach Updates suchen', () {
    Future<void> pumpTile(WidgetTester tester, UpdateCheck check) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: UpdateTile(check: check)),
      ),
    );

    Future<void> tapAndWait(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('about-update')));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }

    testWidgets('neueste Version', (tester) async {
      final fake = _Fake(releases: ['android-v0.0.13-7']);
      await pumpTile(tester, UpdateCheck(api: fake.api, version: '0.0.13+7', platform: 'android', client: fake.client));
      await tapAndWait(tester);
      expect(find.text('Du hast die neueste Version.'), findsOneWidget);
      expect(find.byKey(const Key('about-update-download')), findsNothing);
    });

    testWidgets('neue Version zum Herunterladen', (tester) async {
      final fake = _Fake(releases: ['android-v0.0.14-1']);
      await pumpTile(tester, UpdateCheck(api: fake.api, version: '0.0.13+7', platform: 'android', client: fake.client));
      await tapAndWait(tester);
      expect(find.text('Version 0.0.14 (1) ist da.'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Installieren'), findsOneWidget);
    });

    testWidgets('Entwicklungsversion', (tester) async {
      final fake = _Fake();
      await pumpTile(tester, UpdateCheck(api: fake.api, version: '', platform: 'android', client: fake.client));
      expect(find.text('Entwicklungsversion, ohne Updates'), findsOneWidget);
    });
  });
}
