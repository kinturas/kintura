import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kintura/api.dart';
import 'package:kintura/live_updates.dart';
import 'package:kintura/screens/activity_screen.dart';
import 'package:kintura/session.dart';

import 'widget_test.dart' show FakeBackend, MemoryTokens, calendarEntryRow, disposeApp, eventDetailRow, pumpApp;

Map<String, Object?> _activity(
  String id,
  String kind,
  String title, {
  bool isNew = false,
  List<String> names = const [],
  String family = 'f1',
  bool own = false,
}) => {
  'id': id,
  'family_id': family,
  'own': own,
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

    test('was man selbst getan hat', () {
      String own(String kind, {List<String> names = const [], int? count}) => activityText({
        'kind': kind,
        'own': true,
        'actor_name': 'Anna',
        'title': 'X',
        'names': names,
        'count': count ?? names.length,
      });
      expect(own('items_added', names: ['Milch']), 'Du hast Milch auf „X“ gesetzt.');
      expect(own('items_added', names: ['Milch', 'Brot']), 'Du hast 2 Artikel auf „X“ gesetzt: Milch, Brot.');
      expect(own('event_added', names: ['Ben']), 'Du hast Ben zum Termin „X“ hinzugefügt.');
      expect(own('event_removed', names: ['Ben', 'Cara']), 'Du hast Ben und Cara aus dem Termin „X“ herausgenommen.');
      expect(own('list_added', names: ['Ben', 'Cara'], count: 4), 'Du hast Ben, Cara und 2 weitere zur Einkaufsliste „X“ hinzugefügt.');
      expect(own('list_readable', names: ['Ben']), 'Du hast Ben die Einkaufsliste „X“ zum Ansehen freigegeben.');
      expect(own('event_all'), 'Du hast den Termin „X“ für alle angelegt.');
      expect(own('list_deleted'), 'Du hast die Einkaufsliste „X“ gelöscht.');
      expect(own('items_done', names: ['Milch']), 'Du hast Milch auf „X“ abgehakt.');
      expect(own('event_comment', names: ['Bin dabei']), 'Du hast den Termin „X“ kommentiert: „Bin dabei“.');
      expect(own('list_comment', names: ['Bringe Salat']), 'Du hast die Einkaufsliste „X“ kommentiert: „Bringe Salat“.');
      expect(
        activityText({'kind': 'list_comment', 'actor_name': 'Ben', 'title': 'X', 'names': ['Super'], 'count': 1}),
        'Ben hat die Einkaufsliste „X“ kommentiert: „Super“.',
      );
      expect(
        activityText({'kind': 'event_comment', 'actor_name': 'Ben', 'title': 'X', 'names': ['Komme später'], 'count': 1}),
        'Ben hat den Termin „X“ kommentiert: „Komme später“.',
      );
      expect(activityText({'kind': 'event_comment', 'actor_name': 'Ben', 'title': 'X'}), 'Ben hat den Termin „X“ kommentiert.');

      // Changed and deleted comments.
      expect(own('event_comment_edited', names: ['Bin später da']),
          'Du hast deinen Kommentar zum Termin „X“ bearbeitet: „Bin später da“.');
      expect(own('list_comment_deleted'), 'Du hast deinen Kommentar zur Einkaufsliste „X“ gelöscht.');
      expect(own('event_comment_deleted', names: ['Ben']), 'Du hast den Kommentar von Ben zum Termin „X“ gelöscht.');
      expect(
        activityText({'kind': 'list_comment_edited', 'actor_name': 'Ben', 'title': 'X', 'names': ['Doch Käse'], 'count': 1}),
        'Ben hat einen Kommentar zur Einkaufsliste „X“ bearbeitet: „Doch Käse“.',
      );
      expect(
        activityText({'kind': 'event_comment_deleted', 'actor_name': 'Ben', 'title': 'X', 'names': <String>[], 'count': 0}),
        'Ben hat einen Kommentar zum Termin „X“ gelöscht.',
      );
      expect(
        activityText({'kind': 'list_comment_deleted', 'actor_name': 'Anna', 'title': 'X', 'names': ['Ben'], 'count': 1}),
        'Anna hat den Kommentar von Ben zur Einkaufsliste „X“ gelöscht.',
      );
      expect(
        activityText({'kind': 'items_done', 'actor_name': 'Ben', 'title': 'X', 'names': ['Milch', 'Brot'], 'count': 2}),
        'Ben hat 2 Artikel auf „X“ abgehakt: Milch, Brot.',
      );
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
    testWidgets('zeigt Termine, die letzten Ereignisse und die Zahl der ungelesenen', (tester) async {
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
          for (var i = 4; i <= 25; i++) _activity('a$i', 'list_deleted', 'Liste $i'),
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
      expect(backend.calls, contains('/api/activities/seen'));
      // One circle only: neither filter nor labels.
      expect(find.byKey(const Key('activities-filter')), findsNothing);
      expect(find.byKey(const ValueKey('circle-f1')), findsNothing);

      // Twenty here, the rest on a page of its own.
      expect(backend.activityQueries, contains('limit=20'));
      await tester.scrollUntilVisible(find.byKey(const Key('activities-more')), 200);
      expect(find.byKey(const ValueKey('activity-a20')), findsOneWidget);
      expect(find.byKey(const ValueKey('activity-a21')), findsNothing);
      await tester.tap(find.byKey(const Key('activities-more')));
      await tester.pumpAndSettle();
      expect(find.text('Letzte Ereignisse'), findsOneWidget);
      expect(backend.activityQueries, contains('limit=100'));
      await tester.scrollUntilVisible(find.byKey(const ValueKey('activity-a25')), 200);
      expect(find.text('Ben hat die Einkaufsliste „Liste 25“ gelöscht.'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      // Read, so the number goes.
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('activities-unread')), findsNothing);
      expect(tester.takeException(), isNull);
      await disposeApp(tester);
    });

    testWidgets('ein Kommentar zu einer Einkaufsliste öffnet die Kommentare', (tester) async {
      final backend = FakeBackend()
        ..activities = [_activity('a1', 'list_comment', 'Wocheneinkauf', names: ['Bitte Käse'])]
        ..shoppingComments.add({
          'id': 'c0', 'body': 'Bitte Käse', 'created_at': '2026-11-22T09:00:00Z', 'author_id': 'u2', 'author_name': 'Ben',
        });
      await pumpApp(tester, backend, MemoryTokens()..token = 't1');
      await tester.tap(find.text('Aktuelles'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ben hat die Einkaufsliste „Wocheneinkauf“ kommentiert: „Bitte Käse“.'));
      await tester.pumpAndSettle();
      expect(find.text('Kommentare: Wocheneinkauf'), findsOneWidget);
      expect(find.text('Bitte Käse'), findsOneWidget);

      // Back leads to the list, not to Aktuelles.
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('Kommentare: Wocheneinkauf'), findsNothing);
      expect(find.byKey(const Key('shopping-search')), findsOneWidget);
      await disposeApp(tester);
    });

    testWidgets('ein Eintrag zu einer Einkaufsliste öffnet sie', (tester) async {
      final backend = FakeBackend()..activities = [_activity('a1', 'items_added', 'Wocheneinkauf', names: ['Milch'])];
      await pumpApp(tester, backend, MemoryTokens()..token = 't1');
      await tester.tap(find.text('Aktuelles'));
      await tester.pumpAndSettle();
      expect(find.text('Noch nichts. Hier steht, wenn dich jemand zu einem Termin oder einer Einkaufsliste '
          'hinzufügt oder etwas daran ändert.'), findsNothing);
      expect(find.text('Es stehen keine Termine für dich an.'), findsOneWidget);
      expect(find.byKey(const Key('upcoming-all')), findsNothing);
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
      // An area that tells nothing new here: no reload.
      final before = backend.calls.where((c) => c == '/api/activities').length;
      session.live.emit(const LiveEvent('f1', 'other'));
      await tester.pump(const Duration(seconds: 1));
      expect(backend.calls.where((c) => c == '/api/activities').length, before);

      // All circles are in view, so another one counts as well.
      session.live.emit(const LiveEvent('f2', 'calendar'));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('Ben hat den Termin „Grillen“ geändert.'), findsOneWidget);
      await disposeApp(tester);
    });

    testWidgets('das Kreis-Menü zeigt je Kreis, was es Neues gibt', (tester) async {
      final backend = FakeBackend()
        ..extraFamilies.add({'id': 'f2', 'name': 'Kegelclub', 'type': 'friends', 'role': 'user', 'is_admin': false, 'color': ''})
        ..extraFamilies.add({'id': 'f3', 'name': 'Chor', 'type': 'friends', 'role': 'user', 'is_admin': false, 'color': ''})
        ..activitiesUnread = 2
        ..unreadElsewhere = {'f2': 3, 'f3': 0};
      await pumpApp(tester, backend, MemoryTokens()..token = 't1');
      // The tile counts all circles.
      expect(find.descendant(of: find.byKey(const Key('activities-unread')), matching: find.text('5')), findsOneWidget);

      await tester.tap(find.byTooltip('Kreis wechseln'));
      await tester.pumpAndSettle();
      expect(find.descendant(of: find.byKey(const Key('circle-unread-f1')), matching: find.text('2')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('circle-unread-f2')), matching: find.text('3')), findsOneWidget);
      expect(find.byKey(const Key('circle-unread-f3')), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      // Read in Aktuelles: gone everywhere.
      await tester.tap(find.text('Aktuelles'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Kreis wechseln'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('circle-unread-f2')), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await disposeApp(tester);
    });

    testWidgets('alle Kreise mit ihrem Namen, oder nur der aktuelle', (tester) async {
      final backend = FakeBackend()
        ..extraFamilies.add({
          'id': 'f2', 'name': 'Kegelclub', 'type': 'friends', 'role': 'user', 'is_admin': false, 'color': '',
          'family_color': '#7B4FB0',
        })
        ..activities = [
          _activity('a1', 'items_added', 'Vereinsheim', names: ['Bier'], family: 'f2'),
          _activity('a2', 'items_added', 'Wocheneinkauf', names: ['Milch'], own: true),
        ];
      await pumpApp(tester, backend, MemoryTokens()..token = 't1');
      await tester.tap(find.text('Aktuelles'));
      await tester.pumpAndSettle();
      expect(find.text('Ben hat Bier auf „Vereinsheim“ gesetzt.'), findsOneWidget);
      expect(find.text('Du hast Milch auf „Wocheneinkauf“ gesetzt.'), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('circle-f2')), matching: find.text('Kegelclub')), findsOneWidget);
      expect(find.byKey(const ValueKey('circle-f1')), findsOneWidget);
      final label = tester.widget<Container>(find.byKey(const ValueKey('circle-f2')));
      expect((label.decoration! as BoxDecoration).color, const Color(0xFF7B4FB0));
      expect(backend.activityQueries.where((q) => q.contains('family=')), isEmpty);

      await tester.tap(find.byKey(const Key('activities-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(CheckedPopupMenuItem<bool>, 'Nur Müller'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Vereinsheim'), findsNothing);
      expect(find.text('Du hast Milch auf „Wocheneinkauf“ gesetzt.'), findsOneWidget);
      expect(find.byKey(const ValueKey('circle-f1')), findsNothing);
      expect(backend.activityQueries, contains('family=f1'));

      // Back to all, for the tests after this one.
      await tester.tap(find.byKey(const Key('activities-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(CheckedPopupMenuItem<bool>, 'Alle Kreise'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Vereinsheim'), findsOneWidget);
      await disposeApp(tester);
    });

    testWidgets('ein Eintrag zu einem Termin öffnet ihn, ein gelöschter nicht', (tester) async {
      final start = DateTime.now().add(const Duration(days: 3));
      final row = calendarEntryRow('Zahnarzt', DateTime(start.year, start.month, start.day, 10));
      final backend = FakeBackend()
        ..eventRows = [row]
        ..eventDetail = eventDetailRow({'start_at': row['start_at'], 'end_at': row['end_at']})
        ..activities = [
          _activity('a1', 'event_changed', 'Zahnarzt'),
          _activity('a2', 'event_deleted', 'Grillen'),
        ];
      await pumpApp(tester, backend, MemoryTokens()..token = 't1');
      await tester.tap(find.text('Aktuelles'));
      await tester.pumpAndSettle();
      expect(tester.widget<ListTile>(find.byKey(const ValueKey('activity-a2'))).onTap, isNull);

      await tester.tap(find.text('Ben hat den Termin „Zahnarzt“ geändert.'));
      await tester.pumpAndSettle();
      expect(backend.calls, containsAllInOrder(['/api/families/f1/events/e1', '/api/families/f1/calendar-entries']));
      expect(find.text('Ben hat den Termin „Zahnarzt“ geändert.'), findsNothing);
      expect(find.text('Zahnarzt'), findsWidgets);
      expect(tester.takeException(), isNull);
      await disposeApp(tester);
    });

    testWidgets('die nächsten fünf Termine, alle auf eigener Seite, jeder öffnet sich', (tester) async {
      final start = DateTime.now().add(const Duration(days: 1));
      final row = calendarEntryRow('Zahnarzt', DateTime(start.year, start.month, start.day, 10));
      final backend = FakeBackend()
        ..eventRows = [row]
        ..eventDetail = eventDetailRow()
        ..upcoming = [
          {...row, 'family_id': 'f1'},
          for (var i = 2; i <= 7; i++)
            {
              'id': 'e$i', 'family_id': 'f1', 'title': 'Termin $i',
              'start_at': start.add(Duration(days: i)).toUtc().toIso8601String(),
              'end_at': start.add(Duration(days: i, hours: 1)).toUtc().toIso8601String(),
              'start_local': start.add(Duration(days: i)).toIso8601String().substring(0, 16),
              'end_local': start.add(Duration(days: i, hours: 1)).toIso8601String().substring(0, 16),
              'all_day': false, 'location': '', 'color': '',
            },
        ];
      await pumpApp(tester, backend, MemoryTokens()..token = 't1');
      await tester.tap(find.text('Aktuelles'));
      await tester.pumpAndSettle();
      expect(find.text('Termin 5'), findsOneWidget);
      expect(find.text('Termin 6'), findsNothing);

      await tester.tap(find.byKey(const Key('upcoming-all')));
      await tester.pumpAndSettle();
      expect(find.text('Bevorstehende Termine'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Termin 7'), 100);
      expect(find.text('Termin 7'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Zahnarzt'));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('/api/families/f1/calendar-entries'));
      expect(find.text('Aktuelles'), findsNothing);
      expect(find.text('Zahnarzt'), findsWidgets);
      expect(tester.takeException(), isNull);
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
