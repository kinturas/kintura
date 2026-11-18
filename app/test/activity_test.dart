import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kintura/api.dart';
import 'package:kintura/live_updates.dart';
import 'package:kintura/screens/activity_screen.dart';
import 'package:kintura/session.dart';

import 'widget_test.dart' show FakeBackend, MemoryTokens, disposeApp, pumpApp;

Map<String, Object?> _activity(String id, String kind, String title, {bool isNew = false, List<String> names = const []}) => {
  'id': id,
  'kind': kind,
  'ref_id': kind.startsWith('event') ? 'e1' : 's1',
  'title': title,
  'names': names,
  'count': names.isEmpty ? 1 : names.length,
  'updated_at': DateTime.now().toUtc().subtract(const Duration(minutes: 5)).toIso8601String(),
  'actor_id': 'u2',
  'actor_name': 'Ben',
  'new': isNew,
};

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  group('Sätze', () {
    test('jede Art hat ihren Satz', () {
      String text(String kind, {List<String> names = const [], int? count}) => activityText({
        'kind': kind,
        'actor_name': 'Ben',
        'title': 'X',
        'names': names,
        'count': count ?? names.length,
      });
      expect(text('event_added'), 'Ben hat dich zum Termin „X“ hinzugefügt.');
      expect(text('event_changed'), 'Ben hat den Termin „X“ geändert.');
      expect(text('list_added'), 'Ben hat dich zur Einkaufsliste „X“ hinzugefügt.');
      expect(text('items_added', names: ['Milch']), 'Ben hat Milch auf „X“ gesetzt.');
      expect(
        text('items_added', names: ['A', 'B', 'C', 'D', 'E'], count: 7),
        'Ben hat 7 Artikel auf „X“ gesetzt: A, B, C, D und 3 weitere.',
      );
      expect(activityText({'kind': 'neu', 'actor_name': ''}), 'Jemand hat etwas geändert.');
    });

    test('Zeiten wie man sie sagt', () {
      final now = DateTime(2026, 11, 18, 15, 0);
      expect(activityTime(now.subtract(const Duration(seconds: 20)), now: now), 'gerade eben');
      expect(activityTime(now.subtract(const Duration(minutes: 7)), now: now), 'vor 7 Min.');
      expect(activityTime(now.subtract(const Duration(hours: 3)), now: now), 'vor 3 Std.');
      expect(activityTime(DateTime(2026, 11, 17, 9, 5), now: now), 'gestern, 09:05');
      expect(upcomingTime({'start_local': '2026-11-18T18:30', 'all_day': false}, now: now), 'Heute, 18:30');
      expect(upcomingTime({'start_local': '2026-11-19T00:00', 'all_day': true}, now: now), 'Morgen, ganztägig');
      expect(upcomingTime({'start_local': '2026-11-20T09:00', 'all_day': false}, now: now), 'Fr., 20.11., 09:00');
    });
  });

  group('Aktuelles', () {
    testWidgets('zeigt Termine, Ereignisse in Seiten und die Zahl der ungelesenen', (tester) async {
      final backend = FakeBackend()
        ..activitiesUnread = 2
        ..upcoming = [
          {
            'id': 'e1', 'title': 'Zahnarzt', 'start_local': '2099-01-01T10:00', 'end_local': '2099-01-01T11:00',
            'all_day': false, 'location': 'Praxis', 'color': '#3567B5',
          },
        ]
        ..activities = [
          _activity('a1', 'items_added', 'Wocheneinkauf', isNew: true, names: ['Milch', 'Brot']),
          _activity('a2', 'event_added', 'Zahnarzt', isNew: true),
          _activity('a3', 'list_all', 'Baumarkt'),
        ];
      await pumpApp(tester, backend, MemoryTokens()..token = 't1');
      expect(find.text('Aktuelles'), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('activities-unread')), matching: find.text('2')), findsOneWidget);

      await tester.tap(find.text('Aktuelles'));
      await tester.pumpAndSettle();
      expect(find.text('Zahnarzt'), findsOneWidget);
      expect(find.textContaining('Praxis'), findsOneWidget);
      expect(find.text('Ben hat 2 Artikel auf „Wocheneinkauf“ gesetzt: Milch, Brot.'), findsOneWidget);
      expect(find.text('Ben hat dich zum Termin „Zahnarzt“ hinzugefügt.'), findsOneWidget);
      expect(find.textContaining('Baumarkt'), findsNothing);
      expect(backend.calls, contains('/api/families/f1/activities/seen'));

      await tester.tap(find.byKey(const Key('activities-more')));
      await tester.pumpAndSettle();
      expect(find.text('Ben hat die Einkaufsliste „Baumarkt“ für alle angelegt.'), findsOneWidget);
      expect(find.byKey(const Key('activities-more')), findsNothing);

      // Read, so the number goes.
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('activities-unread')), findsNothing);
      expect(tester.takeException(), isNull);
      await disposeApp(tester);
    });

    testWidgets('ein Eintrag zu einer Einkaufsliste öffnet sie', (tester) async {
      final backend = FakeBackend()..activities = [_activity('a1', 'items_added', 'Wocheneinkauf', names: ['Milch'])];
      await pumpApp(tester, backend, MemoryTokens()..token = 't1');
      await tester.tap(find.text('Aktuelles'));
      await tester.pumpAndSettle();
      expect(find.text('Noch nichts. Hier steht, wenn dich jemand zu einem Termin oder einer Einkaufsliste '
          'hinzufügt oder etwas daran ändert.'), findsNothing);
      expect(find.text('In den nächsten 7 Tagen hast du keine Termine.'), findsOneWidget);
      await tester.tap(find.text('Ben hat Milch auf „Wocheneinkauf“ gesetzt.'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('shopping-search')), findsOneWidget);
      await disposeApp(tester);
    });

    testWidgets('eine Änderung vom Server lädt neu, ohne zu fragen', (tester) async {
      final backend = FakeBackend();
      final session = await pumpApp(tester, backend, MemoryTokens()..token = 't1');
      await tester.tap(find.text('Aktuelles'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Noch nichts.'), findsOneWidget);

      backend.activities = [_activity('a1', 'event_changed', 'Grillen', isNew: true)];
      // Another family, or an area that tells nothing new here: no reload.
      final before = backend.calls.where((c) => c == '/api/families/f1/activities').length;
      session.live.emit(const LiveEvent('f2', 'calendar'));
      await tester.pump(const Duration(seconds: 1));
      expect(backend.calls.where((c) => c == '/api/families/f1/activities').length, before);

      session.live.emit(const LiveEvent('f1', 'calendar'));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('Ben hat den Termin „Grillen“ geändert.'), findsOneWidget);
      await disposeApp(tester);
    });
  });

  group('Live', () {
    liveConnectionTests();
    testWidgets('die Einkaufsliste lädt bei einer Änderung neu', (tester) async {
      final backend = FakeBackend();
      final session = await pumpApp(tester, backend, MemoryTokens()..token = 't1');
      await tester.tap(find.text('Einkaufen'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Wocheneinkauf'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('article-Käse')), findsNothing);

      backend.shoppingItems.add({
        'id': 'i9', 'name': 'Käse', 'amount': '', 'note': '', 'urgency': '', 'done': false, 'photo_ids': <String>[],
      });
      session.live.emit(const LiveEvent('f1', 'shopping'));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('article-Käse')), findsOneWidget);
      await disposeApp(tester);
    });

    test('nur Änderungen der Familie und der Bereiche, dazu jedes Neu-Abgleichen', () async {
      final live = LiveUpdates();
      final got = <String>[];
      final sub = live.of('f1', {'shopping'}).listen((e) => got.add('${e.family}/${e.topic}'));
      live
        ..emit(const LiveEvent('f1', 'shopping'))
        ..emit(const LiveEvent('f1', 'calendar'))
        ..emit(const LiveEvent('f2', 'shopping'))
        ..emit(LiveEvent.resync);
      await Future<void>.delayed(Duration.zero);
      expect(got, ['f1/shopping', '/resync']);
      await sub.cancel();
    });
  });
}

void liveConnectionTests() {
  testWidgets('die Verbindung liest Nachrichten und verbindet nach einem Abbruch neu', (tester) async {
    final backend = FakeBackend();
    final session = AppSession(
      api: ApiClient(client: backend.client, baseUrl: 'http://test'),
      tokens: MemoryTokens()..token = 't1',
    );
    await session.start();
    expect(session.status, SessionStatus.signedIn);

    final requests = <http.BaseRequest>[];
    final connection = LiveConnection(
      session: session,
      client: () => MockClient.streaming((request, _) async {
        requests.add(request);
        return http.StreamedResponse(
          Stream.value(utf8.encode(': verbunden\n\ndata: {"family":"f1","topic":"shopping"}\n\ndata: kaputt\n\n')),
          200,
        );
      }),
    );
    final got = <String>[];
    final sub = session.live.events.listen((e) => got.add(e.topic));
    connection.start();
    await tester.pump();
    await tester.pump();
    expect(requests.single.url.path, '/api/live');
    expect(requests.single.headers['Authorization'], 'Bearer t1');
    expect(got, ['shopping']);

    // The stream ended: again after a while, and what was missed meanwhile is caught up.
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.pump();
    expect(requests, hasLength(2));
    expect(got, ['shopping', 'resync', 'shopping']);

    connection.dispose();
    unawaited(sub.cancel());
    await tester.pump(const Duration(minutes: 2));
    expect(session.live.connected.value, isFalse);
    expect(requests, hasLength(2));
  });
}
