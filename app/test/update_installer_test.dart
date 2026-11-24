import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kintura/api.dart';
import 'package:kintura/update_check.dart';
import 'package:kintura/update_installer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('de.kintura.app/update');
  late Directory dir;
  late List<MethodCall> calls;
  late String answer;
  var downloads = 0;
  var status = 200;
  final apk = List<int>.generate(5000, (i) => i % 256);

  final client = MockClient.streaming((request, _) async {
    downloads++;
    return http.StreamedResponse(
      Stream.fromIterable([apk.sublist(0, 2000), apk.sublist(2000)]),
      status,
      contentLength: apk.length,
    );
  });

  setUp(() {
    dir = Directory.systemTemp.createTempSync('kintura-update');
    calls = [];
    answer = 'started';
    downloads = 0;
    status = 200;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'dir' ? dir.path : answer;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    dir.deleteSync(recursive: true);
  });

  test('lädt die APK herunter und öffnet den Dialog zum Installieren', () async {
    File('${dir.path}/kintura-0.0.15-1.apk').writeAsStringSync('alt');
    final progress = <double?>[];
    final result = await UpdateInstaller(
      client: client,
    ).install('https://x/kintura-0.0.16-3.apk', 'kintura-0.0.16-3.apk', onProgress: progress.add);
    expect(result, InstallResult.started);
    final file = File('${dir.path}/kintura-0.0.16-3.apk');
    expect(file.readAsBytesSync(), apk);
    expect(progress.first, 0);
    expect(progress.last, 1);
    expect(calls.last.method, 'install');
    expect(calls.last.arguments, {'path': file.path});
    // The older download is gone, no .part is left.
    expect(dir.listSync().map((f) => f.uri.pathSegments.last), ['kintura-0.0.16-3.apk']);
  });

  test('ohne Erlaubnis: Einstellungen, beim zweiten Mal ohne neuen Download', () async {
    final installer = UpdateInstaller(client: client);
    answer = 'permission';
    expect(await installer.install('https://x/a.apk', 'a.apk'), InstallResult.permission);
    answer = 'started';
    expect(await installer.install('https://x/a.apk', 'a.apk'), InstallResult.started);
    expect(downloads, 1);
  });

  test('ein fehlgeschlagener Download installiert nichts', () async {
    status = 404;
    expect(await UpdateInstaller(client: client).install('https://x/a.apk', 'a.apk'), InstallResult.failed);
    expect(calls.where((c) => c.method == 'install'), isEmpty);
    expect(dir.listSync(), isEmpty);
  });

  test('UpdateCheck installiert auf Android selbst und nennt Probleme', () async {
    final github = MockClient((request) async {
      if (request.url.host == 'api.github.com') {
        return http.Response(
          '[{"tag_name":"android-v0.0.16-3","assets":[{"name":"kintura-0.0.16-3.apk","browser_download_url":"https://x/kintura-0.0.16-3.apk"}]}]',
          200,
        );
      }
      return http.Response(
        '{"version":"0.0.16+50","min_app_version":"0.0.0","download_url":""}',
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final check = UpdateCheck(
      api: ApiClient(client: github, baseUrl: 'http://test'),
      version: '0.0.16+2',
      platform: 'android',
      client: github,
      installer: UpdateInstaller(client: client),
    );
    expect(check.updateLabel, 'Installieren');
    expect(await check.update(), isNull);
    expect(File('${dir.path}/kintura-0.0.16-3.apk').existsSync(), isTrue);
    expect(check.downloading.value, isFalse);

    answer = 'permission';
    expect(await check.update(), contains('Erlaube Kintura'));
  });
}
