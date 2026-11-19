import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kintura/api.dart';
import 'package:kintura/update_check.dart';

/// A server and a website: GET /api/version and releases.json, with the headers seen.
class _Fake {
  _Fake({this.serverVersion = '0.0.14+40', this.minApp = '0.0.0', this.website = 'https://kintura.test', this.releases = const []});

  String serverVersion;
  String minApp;
  String website;
  List<String> releases;
  final seen = <Map<String, String>>[];

  late final client = MockClient((request) async {
    seen.add(request.headers);
    final body = switch (request.url.path) {
      '/api/version' => {'version': serverVersion, 'min_app_version': minApp, 'download_url': website},
      '/releases.json' => [for (final tag in releases) {'tag': tag, 'published': '2026-11-01T00:00:00Z', 'asset': 'x'}],
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
    expect(fake.seen.last['X-App-Version'], '0.0.13+7');
    expect(fake.seen.last['X-App-Platform'], 'android');

    expect(api.updateRequired.value, isFalse);
    await expectLater(api.get('/api/me'), throwsA(isA<ApiException>().having((e) => e.status, 'status', 426)));
    expect(api.updateRequired.value, isTrue);
  });

  group('Android und Windows', () {
    test('eine neuere Version auf der Website ist ein Hinweis, eine ältere nicht', () async {
      final fake = _Fake(releases: ['android-v0.0.13-7', 'windows-v0.0.14-9', 'android-v0.0.12-6']);
      final check = UpdateCheck(api: fake.api, version: '0.0.13+7', platform: 'android', client: fake.client);
      await check.check();
      expect(check.available.value, isFalse);
      expect(check.downloadUrl.value, 'https://kintura.test');

      fake.releases = [...fake.releases, 'android-v0.0.13-8'];
      await check.check();
      expect(check.available.value, isTrue);
      expect(check.required.value, isFalse);
    });

    test('ohne Website kein Hinweis, die Mindestversion gilt trotzdem', () async {
      final fake = _Fake(website: '', minApp: '0.1.0', releases: ['android-v9.9.9-99']);
      final check = UpdateCheck(api: fake.api, version: '0.0.13+7', platform: 'android', client: fake.client);
      await check.check();
      expect(check.available.value, isFalse);
      expect(check.required.value, isTrue);
      expect(check.canUpdate, isFalse);
    });

    test('ein Entwicklungs-Build ohne Version vergleicht nichts', () async {
      final fake = _Fake(minApp: '9.0.0');
      final check = UpdateCheck(api: fake.api, version: '', platform: 'android', client: fake.client);
      await check.check();
      expect(check.required.value, isFalse);
      expect(fake.seen, isEmpty);
    });
  });

  test('Web: eine andere Version auf dem Server heißt neu laden', () async {
    final fake = _Fake(serverVersion: '0.0.13+40');
    final check = UpdateCheck(api: fake.api, version: '0.0.13+40', platform: 'web', client: fake.client);
    await check.check();
    expect(check.available.value, isFalse);
    fake.serverVersion = '0.0.14+41';
    await check.check();
    expect(check.available.value, isTrue);
    // The web app never asks the website.
    expect(fake.seen.length, 2);
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
}
