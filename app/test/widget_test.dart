import 'dart:convert';

import 'package:kintura/api.dart';
import 'package:kintura/common.dart';
import 'package:kintura/main.dart';
import 'package:kintura/screens/calendar_views.dart';
import 'package:kintura/screens/event_detail_screen.dart';
import 'package:kintura/screens/event_edit_screen.dart';
import 'package:kintura/screens/login_screen.dart';
import 'package:kintura/screens/special_days_screen.dart';
import 'package:kintura/session.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';

class MemoryThemes implements ThemeStore {
  String? mode;
  bool broken = false;

  @override
  Future<String?> read() async {
    if (broken) throw Exception('kein Speicher');
    return mode;
  }

  @override
  Future<void> write(String value) async {
    if (broken) throw Exception('kein Speicher');
    mode = value;
  }
}

class MemoryTokens implements TokenStore {
  String? token;

  @override
  Future<String?> read() async => token;
  @override
  Future<void> write(String value) async => token = value;
  @override
  Future<void> clear() async => token = null;
}

const baseColors = [
  ('#D32F2F', 'Rot'),
  ('#FF7043', 'Koralle'),
  ('#F57C00', 'Orange'),
  ('#FDD835', 'Gelb'),
  ('#2E7D32', 'Grün'),
  ('#BBDEFB', 'Eisblau'),
  ('#1565C0', 'Blau'),
  ('#546E7A', 'Grau'),
];

/// In-memory stand-in for the auth part of the backend.
class FakeBackend {
  bool registered = false;
  final calls = <String>[];
  final ranges = <(DateTime, DateTime)>[];
  Map<String, dynamic>? registerBody;
  Map<String, dynamic>? createBody;
  Map<String, dynamic>? memberBody;
  Map<String, dynamic>? inviteBody;
  Map<String, Object?> profile = {
    'name': 'Anna',
    'family_role': '',
    'contact_email': '',
    'birthday': '',
    'fields': <Object>[],
  };
  final profileWrites = <Map<String, dynamic>>[];
  String email = 'anna@example.de';
  bool notifications = true;
  bool rejectEmail = false;
  Map<String, dynamic>? leaveBody;
  Map<String, dynamic>? managedBody;
  List<Map<String, Object>> former = [];
  bool managed = false;
  bool rejectCalendars = false;
  int loginCodesMade = 0;
  List<Map<String, Object>> invitations = [];
  int invitationResends = 0;
  bool invitationNeedsName = false;
  bool rejectResend = false;
  Map<String, dynamic>? invitationConfirmBody;
  final memberEmailRequests = <String>[];
  Map<String, Object?> memberProfile = {
    'name': 'Ben',
    'family_role': '',
    'contact_email': '',
    'birthday': '',
    'fields': <Object>[],
  };
  final emailRequests = <String>[];
  final feedback = <String>[];
  String familyType = 'family';
  String familyColor = '';

  /// The color of the family itself, unlike [familyColor], which is the user's in it.
  String headerColor = '';
  bool canChangeColor = true;
  bool rejectInvitation = false;
  bool rejectColors = false;
  int? feedEvents = 0;
  bool rejectPlaces = false;
  bool rejectFeeds = false;
  bool rejectPrefs = false;
  bool isAdmin = true;
  String role = 'manager';
  List<Map<String, Object>> extraFamilies = [];
  bool rejectUploads = false;
  final writes = <String, Object?>{};
  final placeQueries = <String>[];
  final uploads = <String>[];
  List<Map<String, Object?>> eventRows = [];

  /// What only comes with „Alle Einträge anzeigen“.
  List<Map<String, Object?>> hiddenEventRows = [];
  Map<String, Object?>? eventDetail;
  Map<String, Object?> calendarPrefs = {
    'week_numbers': false,
    'week_start': 'monday',
    'default_reminder': 0,
    'holiday_countries': ['DE'],
    'view': 'agenda',
    'calendar_color': '#BBDEFB',
  };
  final calendars = <Map<String, Object?>>[
    {'key': 'family', 'kind': 'family', 'name': 'Müller', 'subtitle': 'Standardkalender', 'enabled': true, 'color': '#BBDEFB', 'color_shared': true, 'shareable': true},
    {'key': 'tasks', 'kind': 'tasks', 'name': 'Geplante Aufgaben', 'subtitle': 'Aufgaben mit Datum', 'enabled': true, 'color': '#1565C0', 'color_shared': true, 'shareable': true},
    {'key': 'school', 'kind': 'school', 'name': 'Schulferien', 'subtitle': 'Kein Bundesland ausgewählt', 'enabled': true, 'color': '#F57C00', 'color_shared': true, 'shareable': true},
    {'key': 'holidays', 'kind': 'holidays', 'name': 'Feiertage', 'subtitle': 'Deutschland', 'enabled': true, 'color': '#2E7D32', 'color_shared': true, 'shareable': true},
  ];

  final customColors = <Map<String, Object>>[
    {'id': 'c1', 'color': '#A1B2C3', 'label': 'Nebel', 'used': false},
    {'id': 'c2', 'color': '#112233', 'label': 'Nacht', 'used': true},
  ];

  final categories = <Map<String, Object>>[
    {'id': 'k1', 'name': 'Allgemein', 'color': '#2E7D32'},
    {'id': 'k2', 'name': 'Wichtig', 'color': '#D32F2F'},
  ];

  Map<String, Object> get _family => {
    'id': 'f1',
    'name': 'Müller',
    'type': familyType,
    'role': role,
    'is_admin': isAdmin,
    'color': familyColor,
    'can_change_color': canChangeColor,
    'member_name': profile['name'] as String,
    'family_color': headerColor,
  };

  final members = <Map<String, Object>>[
    {'id': 'u1', 'name': 'Anna', 'email': 'a@example.de', 'role': 'manager', 'is_admin': true, 'color': ''},
    {'id': 'u2', 'name': 'Ben', 'email': 'b@example.de', 'role': 'restrict_user', 'is_admin': false, 'color': ''},
    {'id': 'u3', 'name': 'Cara', 'email': 'c@example.de', 'role': 'user', 'is_admin': false, 'color': ''},
  ];

  late final client = MockClient((request) async {
    calls.add(request.url.path);
    final isJson = request.headers['content-type']?.startsWith('application/json') ?? false;
    final body = isJson ? jsonDecode(request.body) : null;
    Object? response;
    switch (request.url.path) {
      case '/api/pages/impressum':
        response = {
          'slug': 'impressum',
          'title': 'Impressum',
          'content': '## Angaben gemäß § 5 DDG\n\nMax Muster\nTeststraße 1\n12345 Testort\n',
          'updated_at': '2026-11-10T12:00:00Z',
        };
      case '/api/pages/datenschutz':
        response = {
          'slug': 'datenschutz',
          'title': 'Datenschutzerklärung',
          'content':
              '## Verantwortlich\n\nMax Muster\nTeststraße 1\n\n## Hosting\n\nTesthoster GmbH und Testmail GmbH\n\n'
              '## Deine Rechte\n\nAuskunft und Löschung.\n',
          'updated_at': '2026-11-10T12:00:00Z',
        };
      case '/api/auth/request':
        response = {'request_id': 'r1'};
      case '/api/auth/poll':
        response = {'status': 'pending'};
      case '/api/auth/verify':
        if (body['code'] != '123456') {
          return _json({'error': 'Der Code ist falsch.'}, 400);
        }
        response = registered
            ? {'status': 'authenticated', 'token': 't1'}
            : {
                'status': 'registration_required',
                'email': 'anna@example.de',
                'invited_families': <String>[],
              };
      case '/api/auth/code':
        if (body['code'] != 'ABCD-EFGH-JKLM') {
          return _json({'error': 'Der Code ist ungültig oder abgelaufen.'}, 400);
        }
        registered = true;
        managed = true;
        email = '';
        response = {'status': 'authenticated', 'token': 't1'};
      case '/api/families/f1/members/u2/login-code':
        loginCodesMade++;
        response = {'code': 'WXYZ-2345-6789'};
      case '/api/auth/register':
        registerBody = body as Map<String, dynamic>;
        registered = true;
        response = {'status': 'authenticated', 'token': 't1'};
      case '/api/me':
        response = {
          'id': 'u1',
          'email': email,
          'name': 'Anna',
          'notifications': notifications,
          'managed': managed,
          'families': [if (leaveBody == null) _family, ...extraFamilies],
          'last_family_id': leaveBody == null ? 'f1' : null,
        };
      case '/api/families':
        createBody = body as Map<String, dynamic>;
        response = {'id': 'f2'};
      case '/api/families/f1':
        familyType = body['type'] as String;
        if (body['color'] case final String color) headerColor = color;
        response = <String, dynamic>{};
      case '/api/families/f1/colors' when request.method == 'GET':
        response = {
          'base': [
            for (final (color, label) in baseColors) {'color': color, 'label': label},
          ],
          'custom': customColors,
        };
      case '/api/families/f1/colors' ||
          '/api/families/f1/colors/c1' ||
          '/api/families/f1/colors/c2':
        if (rejectColors) return _json({'error': 'Diese Farbe gibt es bereits.'}, 409);
        writes['${request.method} ${request.url.path}'] = body;
        response = {'id': 'c3'};
      case '/api/families/f1/categories' when request.method == 'GET':
        response = {'categories': categories};
      case '/api/families/f1/categories' ||
          '/api/families/f1/categories/order' ||
          '/api/families/f1/categories/k1' ||
          '/api/families/f1/categories/k2':
        writes['${request.method} ${request.url.path}'] = body;
        response = {'id': 'k3'};
      case '/api/families/f1/color':
        familyColor = body['color'] as String;
        response = <String, dynamic>{};
      case '/api/families/f1/members' when request.method == 'POST':
        managedBody = body as Map<String, dynamic>;
        response = {'id': 'u9'};
      case '/api/families/f1/members':
        response = {'members': members, 'invitations': invitations, 'former': former};
      case '/api/families/f1/invitations/i1/resend':
        if (rejectResend) {
          return _json({'error': 'An diese Adresse gingen heute schon genug Einladungen. Bitte morgen erneut versuchen.'}, 429);
        }
        invitationResends++;
        response = <String, dynamic>{};
      case '/api/families/f1/invitations/i1/confirm':
        if (body['code'] != '123456') return _json({'error': 'Der Code ist falsch.'}, 400);
        if (invitationNeedsName && body['name'] == '') {
          response = {'status': 'name_required'};
        } else {
          invitationConfirmBody = body as Map<String, dynamic>;
          invitations = [];
          response = {'status': 'joined'};
        }
      case '/api/families/f1/former/u7':
        writes['${request.method} ${request.url.path}'] = body;
        former = [];
        response = <String, dynamic>{};
      case '/api/families/f1/members/u2/email':
        memberEmailRequests.add(body['email'] as String);
        response = <String, dynamic>{};
      case '/api/families/f1/members/u2/email/confirm':
        if (body['code'] != '123456') return _json({'error': 'Der Code ist falsch.'}, 400);
        members[1]['managed'] = false;
        members[1]['email'] = memberEmailRequests.last;
        response = <String, dynamic>{};
      case '/api/families/f1/members/u2/profile' when request.method == 'GET':
        response = memberProfile;
      case '/api/families/f1/members/u2/profile':
        memberProfile = (body as Map<String, dynamic>).cast<String, Object?>();
        response = <String, dynamic>{};
      case '/api/families/f1/members/u2':
        memberBody = body as Map<String, dynamic>;
        response = <String, dynamic>{};
      case '/api/families/f1/members/u2/color':
        members[1]['color'] = body['color'] as String;
        if (body['can_change_color'] != null) members[1]['can_change_color'] = body['can_change_color'] as bool;
        response = <String, dynamic>{};
      case '/api/families/f1/invitations':
        if (rejectInvitation) return _json({'error': 'Diese Person wurde bereits eingeladen.'}, 409);
        inviteBody = body as Map<String, dynamic>;
        response = {'id': 'i1', 'mail_sent': true};
      case '/api/timezones':
        response = {
          'default': 'Europe/Berlin',
          'zones': [
            {'id': 'America/New_York', 'label': 'Nordamerikanische Ostküsten-Normalzeit', 'offset': 'GMT-05:00'},
            {'id': 'Europe/Berlin', 'label': 'Mitteleuropäische Normalzeit', 'offset': 'GMT+01:00'},
          ],
        };
      case '/api/places':
        placeQueries.add(request.url.queryParameters['q']!);
        if (rejectPlaces) return _json({'error': 'Die Ortssuche ist gerade nicht erreichbar.'}, 502);
        response = {
          'places': [
            {'label': 'Marienplatz, 80331 München', 'lat': 48.137, 'lon': 11.575},
          ],
        };
      case '/api/families/f1/leave':
        leaveBody = body as Map<String, dynamic>;
        response = <String, dynamic>{};
      case '/api/me/email':
        if (rejectEmail) return _json({'error': 'Diese E-Mail-Adresse wird bereits verwendet.'}, 409);
        emailRequests.add(body['email'] as String);
        response = <String, dynamic>{};
      case '/api/me/email/confirm':
        if (body['code'] != '123456') return _json({'error': 'Der Code ist falsch.'}, 400);
        email = emailRequests.last;
        response = <String, dynamic>{};
      case '/api/me/notifications':
        notifications = body['enabled'] as bool;
        response = <String, dynamic>{};
      case '/api/feedback':
        feedback.add(body['text'] as String);
        response = <String, dynamic>{};
      case '/api/families/f1/profile' when request.method == 'GET':
        response = profile;
      case '/api/families/f1/profile':
        final saved = body as Map<String, dynamic>;
        profileWrites.add(saved);
        profile = saved;
        response = <String, dynamic>{};
      case '/api/families/f1/calendar-prefs' when request.method == 'GET':
        response = calendarPrefs;
      case '/api/families/f1/calendar-prefs' when rejectPrefs:
        return _json({'error': 'Speichern fehlgeschlagen'}, 500);
      case '/api/families/f1/calendar-prefs':
        writes['${request.method} ${request.url.path}'] = body;
        calendarPrefs = (body as Map).cast<String, Object?>();
        response = <String, dynamic>{};
      case '/api/families/f1/calendar-entries':
        final from = DateTime.parse(request.url.queryParameters['from']!);
        final to = DateTime.parse(request.url.queryParameters['to']!);
        ranges.add((from.toLocal(), to.toLocal()));
        response = [
          for (final row in [...eventRows, if (request.url.queryParameters['all'] == '1') ...hiddenEventRows])
            if (DateTime.parse(row['start_at'] as String).isBefore(to) && !DateTime.parse(row['end_at'] as String).isBefore(from))
              {'editable': true, 'source': 'family', 'source_name': 'Müller', ...row},
        ];
      case '/api/families/f1/calendars':
        response = {
          'calendars': calendars,
          'prefs': calendarPrefs,
          'countries': [
            {'code': 'DE', 'name': 'Deutschland'},
            {'code': 'AT', 'name': 'Österreich'},
          ],
          'states': [
            {'Code': 'DE-BY', 'Name': 'Bayern'},
            {'Code': 'DE-HE', 'Name': 'Hessen'},
          ],
          'cleanup_months': 12,
        };
      case '/api/families/f1/calendar-feeds/x/refresh':
        final events = feedEvents;
        if (events == null) return _json({'error': 'Der Kalender konnte nicht geladen werden.'}, 400);
        response = {'events': events};
      case '/api/families/f1/calendar-feeds' when rejectFeeds:
        return _json({'error': 'Unter dieser Adresse wurde kein Kalender gefunden.'}, 400);
      case '/api/families/f1/calendar-cleanup' || '/api/families/f1/calendar-feeds':
        writes['${request.method} ${request.url.path}'] = body;
        response = {'key': 'feed:x'};
      case final path when path.startsWith('/api/families/f1/calendars/'):
        if (rejectCalendars) return _json({'error': 'Speichern fehlgeschlagen'}, 400);
        writes['${request.method} $path'] = body;
        response = {'url': 'http://test/cal/abc.ics'};
      case '/api/families/f1/events' when request.method == 'GET':
        response = eventRows;
      case '/api/families/f1/events/e1' when request.method == 'GET':
        response = eventDetail;
      case '/api/families/f1/events/e1/ics':
        response = {'filename': 'termin.ics', 'content': 'BEGIN:VCALENDAR'};
      case '/api/families/f1/calendar-entries/ics':
        writes['${request.method} ${request.url.path}'] = body;
        response = {'filename': 'termin.ics', 'content': 'BEGIN:VCALENDAR'};
      case '/api/families/f1/events' ||
          '/api/families/f1/events/e1' ||
          '/api/families/f1/events/e1/creator' ||
          '/api/families/f1/events/e1/copy' ||
          '/api/families/f1/events/e1/comments':
        writes['${request.method} ${request.url.path}'] = body;
        response = {'id': 'e1'};
      case '/api/families/f1/events/e1/attachments':
        if (rejectUploads) return _json({'error': 'Speicher voll'}, 500);
        uploads.add(request.url.path);
        response = {'id': 'a9'};
      case '/api/families/f1/events/e1/attachments/a1':
        writes['${request.method} ${request.url.path}'] = body;
        response = <String, dynamic>{};
      default:
        return _json({'error': 'unerwartet: ${request.url.path}'}, 500);
    }
    return _json(response, 200);
  });

  static http.Response _json(Object? value, int status) => http.Response.bytes(
    utf8.encode(jsonEncode(value)),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

Future<AppSession> pumpApp(WidgetTester tester, FakeBackend backend, MemoryTokens tokens, {ThemeStore? themes}) async {
  tester.view.physicalSize = const Size(1000, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final session = AppSession(
    api: ApiClient(client: backend.client, baseUrl: 'http://test'),
    tokens: tokens,
    themes: themes,
  );
  await session.loadThemeMode();
  await session.start();
  await tester.pumpWidget(KinturaApp(session: session));
  await tester.pumpAndSettle();
  return session;
}

Future<void> enterEmailAndCode(WidgetTester tester, String code) async {
  await tester.enterText(find.byKey(const Key('email')), 'anna@example.de');
  await tester.tap(find.text('Weiter'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const Key('code')), code);
  await tester.tap(find.text('Anmelden'));
  await tester.pumpAndSettle();
}

Future<void> _openProfileEdit(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Profil'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('profile-tile')));
  await tester.pumpAndSettle();
}

/// Ends the poll timer, which otherwise outlives the test.
Future<void> disposeApp(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('de');
    LoginScreen.pollInterval = const Duration(hours: 1);
  });

  group('Termine', eventTests);
  group('Kalender', calendarTests);

  group('Alternative Anmeldung', () {
    const link = Key('alternative-login');
    const field = Key('login-code');

    Future<void> openDialog(WidgetTester tester, FakeBackend backend, MemoryTokens tokens) async {
      await pumpApp(tester, backend, tokens);
      await tester.tap(find.byKey(link));
      await tester.pumpAndSettle();
    }

    testWidgets('steht unter dem Button, ohne dass eine Adresse nötig ist', (tester) async {
      final tokens = MemoryTokens();
      await pumpApp(tester, FakeBackend(), tokens);
      expect(
        tester.getTopLeft(find.byKey(link)).dy,
        greaterThan(tester.getTopLeft(find.widgetWithText(FilledButton, 'Weiter')).dy),
      );
      await tester.tap(find.byKey(link));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AlertDialog, 'Alternative Anmeldung'), findsOneWidget);
      expect(find.text('Bitte eine E-Mail-Adresse eingeben'), findsNothing);
      await disposeApp(tester);
    });

    testWidgets('meldet mit dem Code an und schließt das Fenster', (tester) async {
      final backend = FakeBackend();
      final tokens = MemoryTokens();
      await openDialog(tester, backend, tokens);
      await tester.enterText(find.byKey(field), ' ABCD-EFGH-JKLM ');
      await tester.tap(find.widgetWithText(FilledButton, 'Anmelden'));
      await tester.pumpAndSettle();
      expect(tokens.token, 't1');
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Einstellungen'), findsOneWidget);
      await disposeApp(tester);
    });

    testWidgets('ein falscher oder fehlender Code bleibt im Fenster als Fehler stehen', (tester) async {
      final tokens = MemoryTokens();
      await openDialog(tester, FakeBackend(), tokens);
      await tester.tap(find.widgetWithText(FilledButton, 'Anmelden'));
      await tester.pumpAndSettle();
      expect(find.text('Bitte den Code eingeben'), findsOneWidget);

      await tester.enterText(find.byKey(field), 'FALSCH');
      await tester.tap(find.widgetWithText(FilledButton, 'Anmelden'));
      await tester.pumpAndSettle();
      expect(find.text('Der Code ist ungültig oder abgelaufen.'), findsOneWidget);
      expect(find.byKey(field), findsOneWidget);
      expect(tokens.token, isNull);

      await tester.tap(find.text('Abbrechen'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('email')), findsOneWidget);
      await disposeApp(tester);
    });

    testWidgets('angemeldet fehlt, was eine eigene Adresse braucht', (tester) async {
      final backend = FakeBackend()
        ..managed = true
        ..email = ''
        ..isAdmin = false;
      await pumpApp(tester, backend, MemoryTokens()..token = 't1');
      await tester.tap(find.byTooltip('Kreis wechseln'));
      await tester.pumpAndSettle();
      expect(find.text('Neuer Kreis'), findsNothing);
      Navigator.of(tester.element(find.byType(CheckedPopupMenuItem<String>))).pop();
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Profil'));
      await tester.pumpAndSettle();
      expect(find.text('Ohne E-Mail-Adresse'), findsOneWidget);
      expect(find.byKey(const Key('account-email')), findsNothing);
      expect(find.byKey(const Key('notifications')), findsNothing);

      await tester.tap(find.byKey(const Key('profile-tile')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('leave-family')), findsNothing);
      expect(find.byTooltip('Adresse aus der Registrierung einfügen'), findsNothing);
      await disposeApp(tester);
    });

    testWidgets('in der Mitgliederliste gibt es für sie kein Verlassen', (tester) async {
      final backend = FakeBackend()
        ..managed = true
        ..isAdmin = false;
      await pumpApp(tester, backend, MemoryTokens()..token = 't1');
      await tester.tap(find.text('Einstellungen'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.logout), findsNothing);
      await disposeApp(tester);
    });

    testWidgets('bleibt auf dem Handy bedienbar', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await openDialog(tester, FakeBackend(), MemoryTokens());
      expect(tester.takeException(), isNull);
      expect(find.byKey(field), findsOneWidget);
      await disposeApp(tester);
    });
  });

  testWidgets('neuer Benutzer: E-Mail, Code, Registrierung, Dashboard', (tester) async {
    final backend = FakeBackend();
    final tokens = MemoryTokens();
    await pumpApp(tester, backend, tokens);

    await enterEmailAndCode(tester, '123456');
    expect(find.text('Registrieren'), findsNWidgets(2));
    expect(find.text('anna@example.de'), findsOneWidget);

    // Family name and name are mandatory.
    await tester.tap(find.widgetWithText(FilledButton, 'Registrieren'));
    await tester.pumpAndSettle();
    expect(find.text('Bitte ausfüllen'), findsNWidgets(2));
    expect(backend.registerBody, isNull);

    await tester.enterText(find.byKey(const Key('name')), 'Anna');
    await tester.enterText(find.byKey(const Key('family')), 'Müller');
    await tester.tap(find.widgetWithText(FilledButton, 'Registrieren'));
    await tester.pumpAndSettle();

    expect(backend.registerBody, {
      'request_id': 'r1',
      'name': 'Anna',
      'family_name': 'Müller',
      'family_type': 'family',
    });
    expect(tokens.token, 't1');
    expect(find.text('Müller'), findsOneWidget);
    for (final area in [
      'Kalender',
      'Listen',
      'Dokumente',
      'Mahlzeiten',
      'Nachrichten',
      'Fotos',
      'Einstellungen',
      'Besondere Tage',
    ]) {
      expect(find.text(area), findsOneWidget, reason: area);
    }
    await disposeApp(tester);
  });

  group('noch nicht freigegebene Bereiche', () {
    Finder tile(String title) => find.ancestor(of: find.text(title), matching: find.byType(Card));

    testWidgets('zeigen „Kommt bald“ und öffnen sich nicht', (tester) async {
      await pumpApp(tester, FakeBackend(), MemoryTokens()..token = 't1');
      expect(find.text('Kommt bald'), findsNWidgets(6));
      for (final title in ['Listen', 'Dokumente', 'Mahlzeiten', 'Nachrichten', 'Fotos', 'Besondere Tage']) {
        expect(find.descendant(of: tile(title), matching: find.text('Kommt bald')), findsOneWidget, reason: title);
        await tester.tap(find.text(title));
        await tester.pumpAndSettle();
        expect(find.byType(BackButton), findsNothing, reason: title);
      }

      // The label sits at the top right of the tile.
      final card = tester.getRect(tile('Fotos'));
      final label = tester.getRect(find.descendant(of: tile('Fotos'), matching: find.text('Kommt bald')));
      expect(label.center.dx, greaterThan(card.center.dx));
      expect(label.center.dy, lessThan(card.center.dy));
      expect(tester.takeException(), isNull);
      await disposeApp(tester);
    });

    testWidgets('Kalender und Einstellungen sind frei', (tester) async {
      await pumpApp(tester, FakeBackend(), MemoryTokens()..token = 't1');
      for (final title in ['Kalender', 'Einstellungen']) {
        expect(find.descendant(of: tile(title), matching: find.text('Kommt bald')), findsNothing, reason: title);
        await tester.tap(find.text(title));
        await tester.pumpAndSettle();
        expect(find.byType(BackButton), findsOneWidget, reason: title);
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
      }
      await disposeApp(tester);
    });
  });

  testWidgets('bekannter Benutzer landet ohne Registrierung im Dashboard', (tester) async {
    final backend = FakeBackend()..registered = true;
    await pumpApp(tester, backend, MemoryTokens());
    await enterEmailAndCode(tester, '123456');
    expect(backend.calls, isNot(contains('/api/auth/register')));
    expect(find.text('Hallo Anna'), findsOneWidget);
    await disposeApp(tester);
  });

  testWidgets('falscher Code zeigt die Serverfehlermeldung', (tester) async {
    await pumpApp(tester, FakeBackend()..registered = true, MemoryTokens());
    await enterEmailAndCode(tester, '000000');
    expect(find.text('Der Code ist falsch.'), findsOneWidget);
    await disposeApp(tester);
  });

  testWidgets('gespeicherte Sitzung überspringt die Anmeldung', (tester) async {
    await pumpApp(tester, FakeBackend(), MemoryTokens()..token = 't1');
    expect(find.text('Hallo Anna'), findsOneWidget);
  });

  testWidgets('Registrierung übernimmt den gewählten Typ und seine Begriffe', (tester) async {
    final backend = FakeBackend();
    await pumpApp(tester, backend, MemoryTokens());
    await enterEmailAndCode(tester, '123456');
    expect(find.text('Name der Familie'), findsOneWidget);

    await tester.tap(find.byKey(const Key('family-type')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Freundeskreis').last);
    await tester.pumpAndSettle();
    expect(find.text('Name des Freundeskreises'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('name')), 'Anna');
    await tester.enterText(find.byKey(const Key('family')), 'Stammtisch');
    await tester.tap(find.widgetWithText(FilledButton, 'Registrieren'));
    await tester.pumpAndSettle();
    expect(backend.registerBody!['family_type'], 'friends');
    await disposeApp(tester);
  });

  for (final (type, chat, settings) in [
    ('family', 'Familien-Chat', 'Familie'),
    ('friends', 'Freundeskreis-Chat', 'Freundeskreis'),
    ('relatives', 'Verwandtschafts-Chat', 'Verwandtschaft'),
    ('workgroup', 'Arbeitsgruppen-Chat', 'Arbeitsgruppe'),
  ]) {
    testWidgets('Dashboard nutzt die Begriffe des Typs $type', (tester) async {
      final backend = FakeBackend()..familyType = type;
      await pumpApp(tester, backend, MemoryTokens()..token = 't1');
      expect(find.text(chat), findsOneWidget);
      expect(find.text(settings), findsOneWidget);
    });
  }

  testWidgets('Typ in den Einstellungen ändern aktualisiert das Dashboard', (tester) async {
    final backend = FakeBackend();
    await pumpApp(tester, backend, MemoryTokens()..token = 't1');
    expect(find.text('Familien-Chat'), findsOneWidget);

    await tester.tap(find.text('Einstellungen'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(Tab, 'Familie'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FamilyTypeField));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Arbeitsgruppe').last);
    await tester.pumpAndSettle();
    expect(find.text('Name der Arbeitsgruppe'), findsOneWidget);
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();

    expect(backend.familyType, 'workgroup');
    expect(find.widgetWithText(Tab, 'Arbeitsgruppe'), findsOneWidget);
    expect(find.text('Gespeichert'), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Arbeitsgruppen-Chat'), findsOneWidget);
    expect(find.text('Familien-Chat'), findsNothing);
  });

  testWidgets('neuer Kreis schickt den gewählten Typ', (tester) async {
    final backend = FakeBackend();
    await pumpApp(tester, backend, MemoryTokens()..token = 't1');

    await tester.tap(find.text('Müller'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Neuer Kreis'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FamilyTypeField));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Verwandtschaft').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Oma und Opa');
    await tester.tap(find.text('Anlegen'));
    await tester.pumpAndSettle();

    expect(backend.createBody, {
      'name': 'Oma und Opa',
      'type': 'relatives',
    });
  });

  test('Initialen', () {
    expect(initials('Anna'), 'A');
    expect(initials('anna maria müller'), 'AM');
    expect(initials('  Özlem   Yilmaz '), 'ÖY');
    expect(initials('   '), '?');
  });

  testWidgets('Profil-Button zeigt Initialen und öffnet das Profil', (tester) async {
    final backend = FakeBackend();
    await pumpApp(tester, backend, MemoryTokens()..token = 't1');
    expect(find.widgetWithText(CircleAvatar, 'A'), findsOneWidget);

    await tester.tap(find.byTooltip('Profil'));
    await tester.pumpAndSettle();
    expect(find.text('Dein Profil im Kreis Müller'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('profile-tile')), matching: find.text('anna@example.de')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('profile-tile')), matching: find.byIcon(Icons.edit_outlined)), findsOneWidget);
    // All of that moved to the page behind it.
    expect(find.text('Geburtstag'), findsNothing);
    expect(find.text('Profilfarbe'), findsNothing);
  });

  group('Einstellungen im Profil', () {
    Future<FakeBackend> open(WidgetTester tester, [FakeBackend? given]) async {
      final backend = given ?? FakeBackend();
      await pumpApp(tester, backend, MemoryTokens()..token = 't1');
      await tester.tap(find.byTooltip('Profil'));
      await tester.pumpAndSettle();
      return backend;
    }

    testWidgets('stehen in der gewünschten Reihenfolge nach dem Kreis-Profil', (tester) async {
      await open(tester);
      double top(String text) => tester.getTopLeft(find.text(text).first).dy;
      final order = [
        'Dein Profil im Kreis Müller',
        'E-Mail-Adresse',
        'Mitteilungen erhalten',
        'Benachrichtigungen verwalten',
        'Dunkelmodus automatisch',
        'Hilfe',
        'Feedback',
        'Sprache',
        'Über',
      ];
      for (var i = 1; i < order.length; i++) {
        expect(top(order[i]), greaterThan(top(order[i - 1])), reason: order[i]);
      }
      await disposeApp(tester);
    });

    testWidgets('was später kommt, ist ausgegraut', (tester) async {
      await open(tester);
      for (final title in ['Benachrichtigungen verwalten', 'Hilfe', 'Sprache']) {
        expect(tester.widget<ListTile>(find.widgetWithText(ListTile, title)).enabled, isFalse, reason: title);
      }
      expect(find.text('Kommt später'), findsNWidgets(3));
      await disposeApp(tester);
    });

    testWidgets('Mitteilungen lassen sich ausschalten', (tester) async {
      final backend = await open(tester);
      SwitchListTile tile() => tester.widget<SwitchListTile>(find.byKey(const Key('notifications')));
      expect(tile().value, isTrue);
      await tester.tap(find.byKey(const Key('notifications')));
      await tester.pumpAndSettle();
      expect(backend.notifications, isFalse);
      expect(tile().value, isFalse);
      await disposeApp(tester);
    });

    group('E-Mail-Adresse ändern', () {
      Future<void> openDialog(WidgetTester tester) async {
        await tester.tap(find.byKey(const Key('account-email')));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
      }

      testWidgets('geht über einen Code an die neue Adresse', (tester) async {
        final backend = await open(tester);
        await openDialog(tester);
        await tester.enterText(find.byKey(const Key('new-email')), ' neu@example.de ');
        await tester.tap(find.text('Code senden'));
        await tester.pumpAndSettle();
        expect(backend.emailRequests, ['neu@example.de']);
        expect(find.textContaining('neu@example.de'), findsOneWidget);
        expect(backend.email, 'anna@example.de');

        await tester.enterText(find.byKey(const Key('email-code')), '123456');
        await tester.tap(find.text('Bestätigen'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.text('Deine E-Mail-Adresse wurde geändert.'), findsOneWidget);
        expect(find.descendant(of: find.byKey(const Key('account-email')), matching: find.text('neu@example.de')), findsOneWidget);
        await disposeApp(tester);
      });

      testWidgets('eine vergebene Adresse bleibt im Dialog als Fehler stehen', (tester) async {
        final backend = await open(tester, FakeBackend()..rejectEmail = true);
        await openDialog(tester);
        await tester.enterText(find.byKey(const Key('new-email')), 'taken@example.de');
        await tester.tap(find.text('Code senden'));
        await tester.pumpAndSettle();
        expect(find.text('Diese E-Mail-Adresse wird bereits verwendet.'), findsOneWidget);
        expect(find.byKey(const Key('new-email')), findsOneWidget);
        expect(find.byKey(const Key('email-code')), findsNothing);
        expect(backend.email, 'anna@example.de');
        await disposeApp(tester);
      });

      testWidgets('ein falscher Code lässt den Dialog offen', (tester) async {
        final backend = await open(tester);
        await openDialog(tester);
        await tester.enterText(find.byKey(const Key('new-email')), 'neu@example.de');
        await tester.tap(find.text('Code senden'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const Key('email-code')), '000000');
        await tester.tap(find.text('Bestätigen'));
        await tester.pumpAndSettle();
        expect(find.text('Der Code ist falsch.'), findsOneWidget);
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(backend.email, 'anna@example.de');
        await disposeApp(tester);
      });
    });

    group('Feedback', () {
      Future<void> openFeedback(WidgetTester tester) async {
        await tester.tap(find.text('Feedback'));
        await tester.pumpAndSettle();
        expect(find.widgetWithText(AppBar, 'Feedback'), findsOneWidget);
      }

      testWidgets('wird von einer eigenen Seite verschickt', (tester) async {
        final backend = await open(tester);
        await openFeedback(tester);
        await tester.enterText(find.byKey(const Key('feedback-text')), ' Tolle App ');
        await tester.tap(find.text('Senden'));
        await tester.pumpAndSettle();
        expect(backend.feedback, ['Tolle App']);
        expect(find.widgetWithText(AppBar, 'Feedback'), findsNothing);
        expect(find.text('Danke für dein Feedback!'), findsOneWidget);
        await disposeApp(tester);
      });

      testWidgets('braucht einen Text', (tester) async {
        final backend = await open(tester);
        await openFeedback(tester);
        await tester.tap(find.text('Senden'));
        await tester.pumpAndSettle();
        expect(find.text('Bitte einen Text eingeben'), findsOneWidget);
        expect(backend.feedback, isEmpty);
        await disposeApp(tester);
      });
    });

    testWidgets('Über zeigt Version und Copyright und führt zur Datenschutzerklärung', (tester) async {
      PackageInfo.setMockInitialValues(
        appName: 'Kintura',
        packageName: 'kintura',
        version: '1.2.3',
        buildNumber: '45',
        buildSignature: '',
      );
      await open(tester);
      await tester.ensureVisible(find.text('Über'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Über'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Über'), findsOneWidget);
      expect(find.text('1.2.3 (45)'), findsOneWidget);
      expect(find.textContaining('©'), findsOneWidget);

      await tester.tap(find.text('Datenschutzerklärung'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Datenschutzerklärung'), findsOneWidget);
      expect(find.text('Deine Rechte'), findsOneWidget);
      expect(find.textContaining('Teststraße 1'), findsOneWidget);
      await disposeApp(tester);
    });

    testWidgets('Impressum und Datenschutz sind schon vor der Anmeldung erreichbar', (tester) async {
      await pumpApp(tester, FakeBackend(), MemoryTokens());

      await tester.tap(find.byKey(const Key('login-imprint')));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Impressum'), findsOneWidget);
      expect(find.textContaining('Max Muster'), findsOneWidget);
      expect(find.textContaining('12345 Testort'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('login-privacy')));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Datenschutzerklärung'), findsOneWidget);
      expect(find.textContaining('Testhoster GmbH'), findsOneWidget);
      expect(find.textContaining('Testmail GmbH'), findsOneWidget);
      await disposeApp(tester);
    });
  });

  group('Profil bearbeiten', () {
    Future<void> openEdit(WidgetTester tester, FakeBackend backend) async {
      await pumpApp(tester, backend, MemoryTokens()..token = 't1');
      await _openProfileEdit(tester);
    }

    Future<void> addField(WidgetTester tester, String label) async {
      await tester.ensureVisible(find.byKey(const Key('add-profile-field')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('add-profile-field')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(MenuItemButton, label));
      await tester.pumpAndSettle();
    }

    TextField labelled(WidgetTester tester, String label) => tester.widget<TextField>(find.widgetWithText(TextField, label));

    testWidgets('öffnet eine eigene Seite und speichert alles mit dem Haken', (tester) async {
      final backend = FakeBackend();
      await openEdit(tester, backend);
      expect(find.widgetWithText(AppBar, 'Profil bearbeiten'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.widget<TextField>(find.byKey(const Key('profile-name'))).controller!.text, 'Anna');
      expect(find.text('Familienrolle'), findsOneWidget);
      expect(find.text('E-Mail-Adresse'), findsOneWidget);
      expect(find.text('Geburtstag'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('profile-name')), ' Mama ');
      await tester.enterText(find.byKey(const Key('profile-family-role')), 'Mutter');
      await tester.enterText(find.byKey(const Key('profile-contact-email')), 'mama@example.de');
      expect(backend.profileWrites, isEmpty);

      await tester.tap(find.byTooltip('Speichern'));
      await tester.pumpAndSettle();
      expect(backend.profileWrites.single, {
        'name': 'Mama',
        'family_role': 'Mutter',
        'contact_email': 'mama@example.de',
        'birthday': '',
        'fields': <Object>[],
      });

      // Back on the profile, under the new name, and greeted with it.
      expect(find.widgetWithText(AppBar, 'Profil'), findsOneWidget);
      expect(find.text('Mama'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('Hallo Mama'), findsOneWidget);
      await disposeApp(tester);
    });

    testWidgets('der Name ist Pflicht', (tester) async {
      final backend = FakeBackend();
      await openEdit(tester, backend);
      expect(find.text('Name *'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('profile-name')), '   ');
      await tester.tap(find.byTooltip('Speichern'));
      await tester.pumpAndSettle();
      expect(find.text('Bitte einen Namen eingeben'), findsOneWidget);
      expect(find.widgetWithText(AppBar, 'Profil bearbeiten'), findsOneWidget);
      expect(backend.profileWrites, isEmpty);
      await disposeApp(tester);
    });

    testWidgets('die Adresse aus der Registrierung lässt sich einfügen', (tester) async {
      final backend = FakeBackend();
      await openEdit(tester, backend);
      await tester.tap(find.byTooltip('Adresse aus der Registrierung einfügen'));
      await tester.pump();
      expect(tester.widget<TextField>(find.byKey(const Key('profile-contact-email'))).controller!.text, 'anna@example.de');

      await tester.tap(find.byTooltip('Speichern'));
      await tester.pumpAndSettle();
      expect(backend.profileWrites.single['contact_email'], 'anna@example.de');
      await disposeApp(tester);
    });

    group('Kreis verlassen', () {
      Future<void> tapLeave(WidgetTester tester) async {
        await tester.ensureVisible(find.byKey(const Key('leave-family')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('leave-family')));
        await tester.pumpAndSettle();
      }

      void onlyMe(FakeBackend backend) => backend.members.removeRange(1, backend.members.length);

      testWidgets('steht ganz unten in Rot', (tester) async {
        await openEdit(tester, FakeBackend());
        final tile = find.byKey(const Key('leave-family'));
        await tester.ensureVisible(tile);
        await tester.pumpAndSettle();
        expect(find.descendant(of: tile, matching: find.text('Den Kreis Müller verlassen')), findsOneWidget);
        expect(find.descendant(of: tile, matching: find.byIcon(Icons.chevron_right)), findsOneWidget);
        final context = tester.element(tile);
        expect(tester.widget<ListTile>(tile).textColor, Theme.of(context).colorScheme.error);
        expect(tester.getTopLeft(tile).dy, greaterThan(tester.getTopLeft(find.text('Profilfarbe')).dy));
        await disposeApp(tester);
      });

      for (final (label, delete) in [('Nur verlassen', false), ('Verlassen und alle Daten löschen', true)]) {
        testWidgets('„$label“ ohne Admin-Flag führt zurück ins Dashboard', (tester) async {
          final backend = FakeBackend()..isAdmin = false;
          await openEdit(tester, backend);
          await tapLeave(tester);
          expect(find.text('Müller verlassen?'), findsOneWidget);
          for (final button in ['Verlassen und alle Daten löschen', 'Nur verlassen', 'Abbrechen']) {
            expect(find.widgetWithText(TextButton, button), findsOneWidget, reason: button);
          }
          expect(backend.leaveBody, isNull);

          await tester.tap(find.widgetWithText(TextButton, label));
          await tester.pumpAndSettle();
          expect(backend.leaveBody, {'delete_data': delete});
          expect(find.byType(BackButton), findsNothing);
          expect(find.text('Du hast Müller verlassen.'), findsOneWidget);
          await disposeApp(tester);
        });
      }

      testWidgets('Abbrechen lässt alles, wie es ist', (tester) async {
        final backend = FakeBackend()..isAdmin = false;
        await openEdit(tester, backend);
        await tapLeave(tester);
        await tester.tap(find.widgetWithText(TextButton, 'Abbrechen'));
        await tester.pumpAndSettle();
        expect(backend.leaveBody, isNull);
        expect(find.widgetWithText(AppBar, 'Profil bearbeiten'), findsOneWidget);
        await disposeApp(tester);
      });

      testWidgets('der letzte Admin mit weiteren Mitgliedern kann nicht verlassen', (tester) async {
        final backend = FakeBackend();
        await openEdit(tester, backend);
        await tapLeave(tester);
        expect(find.text('Du bist der letzte Admin'), findsOneWidget);
        expect(find.textContaining('Mache zuerst ein anderes Mitglied zum Admin'), findsOneWidget);
        expect(find.textContaining('keine E-Mail-Adresse'), findsNothing);
        expect(find.textContaining('Verlassen und alle'), findsNothing);
        expect(find.text('Nur verlassen'), findsNothing);
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        expect(backend.leaveBody, isNull);
        await disposeApp(tester);
      });

      testWidgets('der letzte Admin muss auch Ehemalige erst endgültig löschen', (tester) async {
        final backend = FakeBackend()
          ..former = [
            {'id': 'u7', 'name': 'Dora', 'email': 'd@example.de', 'color': '', 'left_at': '2026-01-01T10:00:00Z'},
          ];
        onlyMe(backend);
        await openEdit(tester, backend);
        await tapLeave(tester);
        expect(find.text('Du bist der letzte Admin'), findsOneWidget);
        expect(find.textContaining('endgültig'), findsOneWidget);
        expect(find.text('Nur verlassen'), findsNothing);
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        expect(backend.leaveBody, isNull);
        await disposeApp(tester);
      });

      testWidgets('mit einem weiteren Admin stören Ehemalige nicht', (tester) async {
        final backend = FakeBackend()
          ..former = [
            {'id': 'u7', 'name': 'Dora', 'email': 'd@example.de', 'color': '', 'left_at': '2026-01-01T10:00:00Z'},
          ];
        backend.members[1]['is_admin'] = true;
        await openEdit(tester, backend);
        await tapLeave(tester);
        expect(find.text('Nur verlassen'), findsOneWidget);
        await disposeApp(tester);
      });

      testWidgets('bleiben nur Benutzer ohne E-Mail, sagt der Hinweis, was stattdessen geht', (tester) async {
        final backend = FakeBackend();
        backend.members[1]['managed'] = true;
        backend.members[2]['managed'] = true;
        await openEdit(tester, backend);
        await tapLeave(tester);
        expect(find.text('Du bist der letzte Admin'), findsOneWidget);
        expect(find.textContaining('keine E-Mail-Adresse'), findsOneWidget);
        expect(find.textContaining('oder lösche sie'), findsOneWidget);
        expect(find.textContaining('Mache zuerst'), findsNothing);
        expect(find.text('Nur verlassen'), findsNothing);
        await disposeApp(tester);
      });

      testWidgets('ist noch jemand mit E-Mail dabei, bleibt es beim üblichen Hinweis', (tester) async {
        final backend = FakeBackend();
        backend.members[1]['managed'] = true;
        await openEdit(tester, backend);
        await tapLeave(tester);
        expect(find.textContaining('Mache zuerst ein anderes Mitglied zum Admin'), findsOneWidget);
        expect(find.textContaining('keine E-Mail-Adresse'), findsNothing);
        await disposeApp(tester);
      });

      testWidgets('mit einem weiteren Admin geht es', (tester) async {
        final backend = FakeBackend();
        backend.members[1]['is_admin'] = true;
        await openEdit(tester, backend);
        await tapLeave(tester);
        expect(find.text('Du bist der letzte Admin'), findsNothing);
        expect(find.text('Nur verlassen'), findsOneWidget);
        await disposeApp(tester);
      });

      testWidgets('das letzte Mitglied erfährt, dass danach niemand mehr Zugang hat', (tester) async {
        final backend = FakeBackend();
        onlyMe(backend);
        await openEdit(tester, backend);
        await tapLeave(tester);
        expect(find.textContaining('niemand mehr Zugang'), findsOneWidget);
        expect(find.textContaining('Support'), findsOneWidget);
        await tester.tap(find.widgetWithText(TextButton, 'Nur verlassen'));
        await tester.pumpAndSettle();
        expect(backend.leaveBody, {'delete_data': false});
        // Without any circle there is the page for that.
        expect(find.text('Hallo Anna'), findsNothing);
        await disposeApp(tester);
      });

      testWidgets('auf dem Handy passen die drei Buttons in den Dialog', (tester) async {
        await openEdit(tester, FakeBackend()..isAdmin = false);
        tester.view.physicalSize = const Size(320, 640);
        await tester.pumpAndSettle();
        await tester.dragUntilVisible(find.byKey(const Key('leave-family')), find.byType(ListView), const Offset(0, -300));
        await tester.pumpAndSettle();
        await tapLeave(tester);
        expect(find.widgetWithText(TextButton, 'Abbrechen'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await disposeApp(tester);
      });
    });

    testWidgets('außerhalb einer Familie heißt die Rolle anders', (tester) async {
      await openEdit(tester, FakeBackend()..familyType = 'workgroup');
      expect(find.text('Rolle im Kreis'), findsOneWidget);
      expect(find.text('Familienrolle'), findsNothing);
      await disposeApp(tester);
    });

    testWidgets('alle Feldarten stehen zur Wahl, mehrfach und entfernbar', (tester) async {
      final backend = FakeBackend();
      await openEdit(tester, backend);

      await tester.tap(find.byKey(const Key('add-profile-field')));
      await tester.pumpAndSettle();
      for (final label in ['Telefon', 'E-Mail', 'Handy', 'Telefon Arbeit', 'Sonstige', 'Adresse']) {
        expect(find.widgetWithText(MenuItemButton, label), findsOneWidget, reason: label);
      }
      await tester.tap(find.widgetWithText(MenuItemButton, 'Telefon'));
      await tester.pumpAndSettle();

      await addField(tester, 'Telefon');
      await addField(tester, 'Adresse');
      await addField(tester, 'Handy');
      expect(find.byTooltip('Feld entfernen'), findsNWidgets(4));

      final phones = find.widgetWithText(TextField, 'Telefon');
      await tester.enterText(phones.first, ' 111 ');
      await tester.enterText(phones.last, '222');
      expect(labelled(tester, 'Adresse').maxLines, 4);
      await tester.enterText(find.widgetWithText(TextField, 'Adresse'), 'Weg 1');

      // Handy stays empty and the second number goes again.
      await tester.tap(find.byTooltip('Feld entfernen').at(1));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Feld entfernen'), findsNWidgets(3));
      expect(tester.takeException(), isNull);

      await tester.tap(find.byTooltip('Speichern'));
      await tester.pumpAndSettle();
      expect(backend.profileWrites.single['fields'], [
        {'kind': 'phone', 'value': '111'},
        {'kind': 'address', 'value': 'Weg 1'},
        {'kind': 'mobile', 'value': ''},
      ]);
      await disposeApp(tester);
    });

    testWidgets('gespeicherte Felder sind beim nächsten Mal wieder da', (tester) async {
      final backend = FakeBackend()
        ..profile = {
          'name': 'Mama',
          'family_role': 'Mutter',
          'contact_email': 'mama@example.de',
          'birthday': '1980-05-01',
          'fields': [
            {'kind': 'work_phone', 'value': '333'},
          ],
        };
      await openEdit(tester, backend);
      expect(labelled(tester, 'Familienrolle').controller!.text, 'Mutter');
      expect(labelled(tester, 'E-Mail-Adresse').controller!.text, 'mama@example.de');
      expect(labelled(tester, 'Telefon Arbeit').controller!.text, '333');
      expect(find.text('01.05.1980'), findsOneWidget);
      await disposeApp(tester);
    });

    testWidgets('Zurück fragt nur nach, wenn sich etwas geändert hat', (tester) async {
      final backend = FakeBackend();
      await openEdit(tester, backend);
      final question = find.text('Änderungen verwerfen?');

      // An empty field is nothing to lose.
      await addField(tester, 'Telefon');
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(question, findsNothing);
      expect(find.widgetWithText(AppBar, 'Profil'), findsOneWidget);

      await tester.tap(find.byKey(const Key('profile-tile')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('profile-family-role')), 'Mutter');
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(question, findsOneWidget);
      await tester.tap(find.text('Weiter bearbeiten'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Profil bearbeiten'), findsOneWidget);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Verwerfen'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Profil'), findsOneWidget);
      expect(backend.profileWrites, isEmpty);
      await disposeApp(tester);
    });
  });

  test('Farbwerte bleiben beim Umwandeln gleich', () {
    expect(toHexColor(parseHexColor('#0A1B2C')), '#0A1B2C');
  });

  test('Text bleibt auf hellen und dunklen Farben lesbar', () {
    expect(readableOn(parseHexColor('#FDD835')), Colors.black);
    expect(readableOn(parseHexColor('#1565C0')), Colors.white);
  });

  testWidgets('Farbe im Profil gilt für den Kreis und färbt den Button im Dashboard', (tester) async {
    final backend = FakeBackend();
    await pumpApp(tester, backend, MemoryTokens()..token = 't1');
    await _openProfileEdit(tester);
    expect(find.text('Profilfarbe'), findsOneWidget);
    expect(find.text('Diese Angaben gelten im Kreis Müller.'), findsOneWidget);
    expect(find.text('Stammfarben'), findsNothing);
    expect(find.text('Eigene Farben'), findsNothing);

    // One list: no color first, the colors of the family last.
    final order = tester
        .widgetList<Tooltip>(find.descendant(of: find.byType(ColorChooser), matching: find.byType(Tooltip)))
        .map((tooltip) => tooltip.message)
        .toList();
    expect(order, ['Keine Farbe', for (final (_, name) in baseColors) name, 'Nebel', 'Nacht']);

    await tester.tap(find.byTooltip('Blau'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(ColorChooser), matching: find.byIcon(Icons.check)), findsOneWidget);

    // Like everything else on this page it counts with saving.
    expect(backend.familyColor, '');
    await tester.tap(find.byTooltip('Speichern'));
    await tester.pumpAndSettle();
    expect(backend.familyColor, '#1565C0');
    expect(
      tester.widget<CircleAvatar>(find.byType(CircleAvatar)).backgroundColor,
      parseHexColor('#1565C0'),
    );

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(
      tester.widget<CircleAvatar>(find.byType(CircleAvatar)).backgroundColor,
      parseHexColor('#1565C0'),
    );
  });

  testWidgets('im Profil lässt sich auch keine Farbe wählen', (tester) async {
    final backend = FakeBackend()..familyColor = '#1565C0';
    await pumpApp(tester, backend, MemoryTokens()..token = 't1');
    await _openProfileEdit(tester);

    await tester.tap(find.byTooltip('Keine Farbe'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Speichern'));
    await tester.pumpAndSettle();

    expect(backend.familyColor, '');
    expect(tester.widget<CircleAvatar>(find.byType(CircleAvatar)).backgroundColor, isNull);
  });

  testWidgets('die Kopfzeile im Profil folgt der Profilfarbe', (tester) async {
    final backend = FakeBackend();
    await pumpApp(tester, backend, MemoryTokens()..token = 't1');
    await _openProfileEdit(tester);
    AppBar editBar() => tester.widget<AppBar>(find.widgetWithText(AppBar, 'Profil bearbeiten'));
    expect(editBar().backgroundColor, isNull);

    // While editing it shows the choice at once.
    await tester.tap(find.byTooltip('Keine Farbe'));
    await tester.pumpAndSettle();
    expect(editBar().backgroundColor, isNull);
    await tester.tap(find.byTooltip('Blau'));
    await tester.pumpAndSettle();
    expect(editBar().backgroundColor, parseHexColor('#1565C0'));
    expect(editBar().foregroundColor, Colors.white);

    await tester.tap(find.byTooltip('Speichern'));
    await tester.pumpAndSettle();
    final bar = tester.widget<AppBar>(find.widgetWithText(AppBar, 'Profil'));
    expect(bar.backgroundColor, parseHexColor('#1565C0'));
    expect(bar.foregroundColor, Colors.white);
  });

  for (final (width, rows) in [(1000.0, 1), (360.0, 2)]) {
    testWidgets('Farben brechen bei Breite $width bei Bedarf um', (tester) async {
      await pumpApp(tester, FakeBackend(), MemoryTokens()..token = 't1');
      tester.view.physicalSize = Size(width, 1400);
      await tester.pumpAndSettle();
      await _openProfileEdit(tester);

      Offset at(String name) => tester.getTopLeft(find.byTooltip(name));
      final tops = {for (final (_, name) in baseColors) at(name).dy};
      expect(tops.length, rows);

      expect(tester.getSize(find.byTooltip('Rot')), const Size(44, 44));
      expect(at('Koralle').dx - at('Rot').dx, 58);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('ohne gewählte Farbe bleibt der Button in der Standardfarbe', (tester) async {
    await pumpApp(tester, FakeBackend(), MemoryTokens()..token = 't1');
    expect(tester.widget<CircleAvatar>(find.byType(CircleAvatar)).backgroundColor, isNull);
  });

  group('Design', () {
    Brightness brightness(WidgetTester tester) => Theme.of(tester.element(find.byType(Scaffold).last)).brightness;
    Future<void> openProfile(WidgetTester tester) async {
      await tester.tap(find.byTooltip('Profil'));
      await tester.pumpAndSettle();
    }

    final automatic = find.byKey(const Key('dark-automatic'));
    final manual = find.byKey(const Key('dark-mode'));

    testWidgets('Automatisch ist Vorgabe und folgt dem Gerät', (tester) async {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      await pumpApp(tester, FakeBackend(), MemoryTokens()..token = 't1', themes: MemoryThemes());
      expect(brightness(tester), Brightness.dark);

      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pumpAndSettle();
      expect(brightness(tester), Brightness.light);

      await openProfile(tester);
      expect(tester.widget<SwitchListTile>(automatic).value, isTrue);
      expect(manual, findsNothing);
    });

    testWidgets('von Hand übernimmt es erst den Stand und gilt dann gegen das Gerät', (tester) async {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      final themes = MemoryThemes();
      await pumpApp(tester, FakeBackend(), MemoryTokens()..token = 't1', themes: themes);
      await openProfile(tester);

      // Nothing jumps when taking over by hand.
      await tester.tap(automatic);
      await tester.pumpAndSettle();
      expect(brightness(tester), Brightness.dark);
      expect(themes.mode, 'dark');
      expect(tester.widget<SwitchListTile>(manual).value, isTrue);

      await tester.tap(manual);
      await tester.pumpAndSettle();
      expect(brightness(tester), Brightness.light);
      expect(themes.mode, 'light');

      // Back to following the device.
      await tester.tap(automatic);
      await tester.pumpAndSettle();
      expect(brightness(tester), Brightness.dark);
      expect(themes.mode, 'system');
      expect(manual, findsNothing);

      await tester.tap(automatic);
      await tester.pumpAndSettle();
      await tester.tap(manual);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Abmelden'));
      await tester.pumpAndSettle();
      expect(brightness(tester), Brightness.light);
    });

    testWidgets('die Wahl gilt beim nächsten Start wieder', (tester) async {
      await pumpApp(tester, FakeBackend(), MemoryTokens()..token = 't1', themes: MemoryThemes()..mode = 'dark');
      expect(brightness(tester), Brightness.dark);
    });

    testWidgets('ein unbekannter oder nicht lesbarer Wert startet automatisch', (tester) async {
      final unknown = await pumpApp(tester, FakeBackend(), MemoryTokens()..token = 't1', themes: MemoryThemes()..mode = 'lila');
      expect(unknown.themeMode.value, ThemeMode.system);
      final themes = MemoryThemes()..broken = true;
      final broken = await pumpApp(tester, FakeBackend(), MemoryTokens()..token = 't1', themes: themes);
      expect(broken.themeMode.value, ThemeMode.system);

      // Without a place to keep it, it still holds for now.
      await broken.setThemeMode(ThemeMode.dark);
      await tester.pumpAndSettle();
      expect(brightness(tester), Brightness.dark);
    });

    testWidgets('die Auswahl passt auf ein schmales Handy', (tester) async {
      await pumpApp(tester, FakeBackend(), MemoryTokens()..token = 't1', themes: MemoryThemes());
      await openProfile(tester);
      tester.view.physicalSize = const Size(320, 800);
      await tester.pumpAndSettle();
      await tester.dragUntilVisible(automatic, find.byType(ListView), const Offset(0, -200));
      await tester.pumpAndSettle();
      await tester.tap(automatic);
      await tester.pumpAndSettle();
      await tester.dragUntilVisible(manual, find.byType(ListView), const Offset(0, -200));
      await tester.pumpAndSettle();
      await tester.tap(manual);
      await tester.pumpAndSettle();
      expect(brightness(tester), Brightness.dark);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('Abmelden steht ganz unten im Profil und nicht im Dashboard', (tester) async {
    final tokens = MemoryTokens()..token = 't1';
    await pumpApp(tester, FakeBackend(), tokens);
    expect(find.text('Abmelden'), findsNothing);
    expect(find.byTooltip('Abmelden'), findsNothing);

    await tester.tap(find.byTooltip('Profil'));
    await tester.pumpAndSettle();
    expect(
      tester.getBottomLeft(find.widgetWithText(ListTile, 'Abmelden')).dy,
      tester.getSize(find.byType(Scaffold).last).height,
    );

    await tester.tap(find.text('Abmelden'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('email')), findsOneWidget);
    expect(tokens.token, isNull);
    await disposeApp(tester);
  });

  Future<void> openSettings(WidgetTester tester, FakeBackend backend) async {
    await pumpApp(tester, backend, MemoryTokens()..token = 't1');
    await tester.tap(find.text('Einstellungen'));
    await tester.pumpAndSettle();
  }

  Future<void> chooseRole(WidgetTester tester, String label) async {
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  testWidgets('Einstellungen haben die Reiter Mitglieder und Kreistyp', (tester) async {
    await openSettings(tester, FakeBackend()..familyType = 'workgroup');
    expect(find.byType(Tab), findsNWidgets(4));
    expect(find.widgetWithText(Tab, 'Mitglieder'), findsOneWidget);
    expect(find.widgetWithText(Tab, 'Arbeitsgruppe'), findsOneWidget);
    expect(find.widgetWithText(Tab, 'Kategorien'), findsOneWidget);
    expect(find.widgetWithText(Tab, 'Farben'), findsOneWidget);
    expect(find.widgetWithText(Tab, 'Farbverwaltung'), findsNothing);
    expect(find.widgetWithText(Tab, 'Benutzer'), findsNothing);

    // Mitglieder no longer shows the family itself.
    expect(find.text('Ben'), findsOneWidget);
    expect(find.text('Arbeitsgruppe'), findsOneWidget);
    expect(find.text('Müller'), findsNothing);

    await tester.tap(find.widgetWithText(Tab, 'Arbeitsgruppe'));
    await tester.pumpAndSettle();
    expect(find.text('Ben'), findsNothing);
    expect(find.text('Name der Arbeitsgruppe'), findsOneWidget);
    expect(find.text('Müller'), findsOneWidget);
  });

  testWidgets('Farbe des Kreises färbt den Kopf des Dashboards', (tester) async {
    final backend = FakeBackend();
    await pumpApp(tester, backend, MemoryTokens()..token = 't1');
    Color? header() => tester.widget<AppBar>(find.byType(AppBar).first).backgroundColor;
    expect(header(), isNull);

    await tester.tap(find.text('Einstellungen'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(Tab, 'Familie'));
    await tester.pumpAndSettle();
    final chooser = find.byKey(const Key('family-color'));
    await tester.tap(find.descendant(of: chooser, matching: find.byTooltip('Blau')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();
    expect(backend.headerColor, '#1565C0');

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(header(), parseHexColor('#1565C0'));
    expect(tester.widget<AppBar>(find.byType(AppBar).first).foregroundColor, Colors.white);
  });

  testWidgets('ohne Admin-Flag ist der Reiter des Kreises nur lesbar', (tester) async {
    await openSettings(tester, FakeBackend()..isAdmin = false);
    await tester.tap(find.widgetWithText(Tab, 'Familie'));
    await tester.pumpAndSettle();

    expect(find.text('Müller'), findsOneWidget);
    expect(find.byType(FamilyTypeField), findsNothing);
    expect(find.text('Speichern'), findsNothing);
  });

  group('Seitenbreite', () {
    Future<void> setWidth(WidgetTester tester, double width) async {
      tester.view.physicalSize = Size(width, 1400);
      await tester.pumpAndSettle();
    }

    testWidgets('alle Seiten bleiben auf breiten Monitoren zentriert gleich breit', (tester) async {
      await pumpApp(tester, FakeBackend(), MemoryTokens()..token = 't1');
      await setWidth(tester, 2000);

      void expectPage() {
        final page = find.byType(Scaffold).last;
        expect(tester.getSize(page), const Size(960, 1400));
        expect(tester.getTopLeft(page).dx, 520);
      }

      expectPage();
      await tester.tap(find.byTooltip('Profil'));
      await tester.pumpAndSettle();
      expectPage();
      // The footer of the page keeps to the same width.
      final logout = find.widgetWithText(ListTile, 'Abmelden');
      expect(tester.getSize(logout).width, 960);
      expect(tester.getTopLeft(logout).dx, 520);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Einstellungen'));
      await tester.pumpAndSettle();
      expectPage();
    });

    testWidgets('schmale Bildschirme nutzen die volle Breite', (tester) async {
      await pumpApp(tester, FakeBackend(), MemoryTokens()..token = 't1');
      await setWidth(tester, 500);
      expect(tester.getSize(find.byType(Scaffold).last), const Size(500, 1400));
    });
  });

  group('Reiter der Einstellungen', () {
    Future<void> openArea(WidgetTester tester, FakeBackend backend, String area) async {
      await openSettings(tester, backend);
      await tester.tap(find.widgetWithText(Tab, area));
      await tester.pumpAndSettle();
    }

    FilledButton saveButton(WidgetTester tester) =>
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Speichern'));

    testWidgets('alle Reiter bleiben auf schmalen Bildschirmen erreichbar', (tester) async {
      await pumpApp(tester, FakeBackend()..familyType = 'relatives', MemoryTokens()..token = 't1');
      tester.view.physicalSize = const Size(360, 1400);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Einstellungen'));
      await tester.pumpAndSettle();

      for (final area in ['Kategorien', 'Farben']) {
        await tester.ensureVisible(find.widgetWithText(Tab, area));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(Tab, area));
        await tester.pumpAndSettle();
      }
      expect(find.text('Stammfarben'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    group('Farben', () {
      testWidgets('sind gruppiert, Stammfarben lassen sich nicht ändern', (tester) async {
        await openArea(tester, FakeBackend(), 'Farben');

        expect(find.text('Eigene Farben'), findsOneWidget);
        expect(find.text('Stammfarben'), findsOneWidget);
        expect(
          tester.getTopLeft(find.text('Nebel')).dy,
          lessThan(tester.getTopLeft(find.text('Stammfarben')).dy),
        );
        expect(
          tester.getTopLeft(find.text('Rot')).dy,
          greaterThan(tester.getTopLeft(find.text('Stammfarben')).dy),
        );

        final base = find.widgetWithText(ListTile, 'Rot');
        expect(find.descendant(of: base, matching: find.byType(IconButton)), findsNothing);
        await tester.tap(find.text('Rot'));
        await tester.pumpAndSettle();
        expect(find.text('Farbe ändern'), findsNothing);
      });

      testWidgets('nur ungenutzte eigene Farben lassen sich löschen', (tester) async {
        final backend = FakeBackend();
        await openArea(tester, backend, 'Farben');

        final used = find.widgetWithText(ListTile, 'Nacht');
        expect(find.descendant(of: used, matching: find.byTooltip('Löschen')), findsNothing);
        expect(find.descendant(of: used, matching: find.byTooltip('Wird verwendet')), findsOneWidget);

        final unused = find.widgetWithText(ListTile, 'Nebel');
        await tester.tap(find.descendant(of: unused, matching: find.byTooltip('Löschen')));
        await tester.pumpAndSettle();
        expect(find.text('„Nebel“ löschen?'), findsOneWidget);
        await tester.tap(find.widgetWithText(FilledButton, 'Löschen'));
        await tester.pumpAndSettle();

        expect(backend.writes.keys, ['DELETE /api/families/f1/colors/c1']);
      });

      testWidgets('neue Farbe mit Text und Farbwert anlegen', (tester) async {
        final backend = FakeBackend();
        await openArea(tester, backend, 'Farben');

        await tester.tap(find.text('Farbe hinzufügen'));
        await tester.pumpAndSettle();
        expect(saveButton(tester).onPressed, isNull);

        await tester.enterText(find.byKey(const Key('color-label')), '  Wolke ');
        await tester.enterText(find.byKey(const Key('color-hex')), '#12345');
        await tester.pumpAndSettle();
        expect(saveButton(tester).onPressed, isNull);

        await tester.enterText(find.byKey(const Key('color-hex')), '#123456');
        await tester.pumpAndSettle();
        final preview = tester.widget<Container>(find.byKey(const Key('color-preview')));
        expect((preview.decoration! as BoxDecoration).color, parseHexColor('#123456'));

        await tester.tap(find.text('Speichern'));
        await tester.pumpAndSettle();
        expect(backend.writes['POST /api/families/f1/colors'], {'color': '#123456', 'label': 'Wolke'});
      });

      testWidgets('Schieberegler setzen den Farbwert', (tester) async {
        await openArea(tester, FakeBackend(), 'Farben');
        await tester.tap(find.text('Farbe hinzufügen'));
        await tester.pumpAndSettle();

        String hex() => tester.widget<TextField>(find.byKey(const Key('color-hex'))).controller!.text;
        final before = hex();
        await tester.drag(find.byType(Slider).first, const Offset(60, 0));
        await tester.pumpAndSettle();
        expect(hex(), isNot(before));
        expect(RegExp(r'^#[0-9A-F]{6}$').hasMatch(hex()), isTrue, reason: hex());
      });

      testWidgets('eigene Farbe im Dialog ändern', (tester) async {
        final backend = FakeBackend();
        await openArea(tester, backend, 'Farben');

        await tester.tap(find.text('Nacht'));
        await tester.pumpAndSettle();
        expect(find.text('Farbe ändern'), findsOneWidget);
        expect(tester.widget<TextField>(find.byKey(const Key('color-hex'))).controller!.text, '#112233');
        await tester.enterText(find.byKey(const Key('color-label')), 'Mitternacht');
        await tester.tap(find.text('Speichern'));
        await tester.pumpAndSettle();

        expect(backend.writes['PUT /api/families/f1/colors/c2'], {'color': '#112233', 'label': 'Mitternacht'});
      });

      testWidgets('abgelehnte Farbe zeigt die Meldung', (tester) async {
        final backend = FakeBackend()..rejectColors = true;
        await openArea(tester, backend, 'Farben');

        await tester.tap(find.text('Farbe hinzufügen'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const Key('color-label')), 'Wolke');
        await tester.pumpAndSettle();
        await tester.tap(find.text('Speichern'));
        await tester.pumpAndSettle();

        expect(find.text('Diese Farbe gibt es bereits.'), findsOneWidget);
      });

      testWidgets('ohne Admin-Flag nur lesbar', (tester) async {
        await openArea(tester, FakeBackend()..isAdmin = false, 'Farben');

        expect(find.text('Nebel'), findsOneWidget);
        expect(find.text('Farbe hinzufügen'), findsNothing);
        expect(find.byIcon(Icons.edit_outlined), findsNothing);
        expect(find.byTooltip('Löschen'), findsNothing);
        await tester.tap(find.text('Nebel'));
        await tester.pumpAndSettle();
        expect(find.text('Farbe ändern'), findsNothing);
      });
    });

    group('Mitglieder', () {
      testWidgets('Admin weist eine Farbe aus der Tabelle zu und entfernt sie', (tester) async {
        final backend = FakeBackend();
        backend.members[1]['color'] = '#D32F2F';
        await openSettings(tester, backend);

        final ben = find.widgetWithText(ListTile, 'Ben');
        expect(
          tester
              .widget<CircleAvatar>(find.descendant(of: ben, matching: find.byType(CircleAvatar)))
              .backgroundColor,
          parseHexColor('#D32F2F'),
        );

        await tester.tap(find.text('Ben'));
        await tester.pumpAndSettle();
        expect(find.text('Profilfarbe'), findsOneWidget);
        expect(find.text('Stammfarben'), findsNothing);
        expect(find.text('Eigene Farben'), findsNothing);
        expect(find.descendant(of: find.byType(ColorChooser), matching: find.byIcon(Icons.check)), findsOneWidget);

        // The same list as in the profile.
        final order = tester
            .widgetList<Tooltip>(find.descendant(of: find.byType(ColorChooser), matching: find.byType(Tooltip)))
            .map((tooltip) => tooltip.message)
            .toList();
        expect(order, ['Keine Farbe', for (final (_, name) in baseColors) name, 'Nebel', 'Nacht']);

        // Only saving counts.
        await tester.tap(find.byTooltip('Nebel'));
        await tester.pumpAndSettle();
        expect(backend.members[1]['color'], '#D32F2F');
        await tester.tap(find.byTooltip('Speichern'));
        await tester.pumpAndSettle();
        expect(backend.members[1]['color'], '#A1B2C3');
        expect(find.text('Profilfarbe'), findsNothing);

        await tester.tap(find.text('Ben'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Keine Farbe'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Speichern'));
        await tester.pumpAndSettle();
        expect(backend.members[1]['color'], '');
      });

      testWidgets('Zurück lässt die Farbe unverändert', (tester) async {
        final backend = FakeBackend();
        backend.members[1]['color'] = '#D32F2F';
        await openSettings(tester, backend);

        await tester.tap(find.text('Ben'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.widgetWithText(AppBar, 'Ben'), findsOneWidget);
        await tester.tap(find.byTooltip('Nebel'));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(backend.members[1]['color'], '#D32F2F');
        expect(backend.memberBody, isNull);
      });

      testWidgets('ohne geänderte Farbe bleibt es bei Rolle und Admin-Flag', (tester) async {
        final backend = FakeBackend();
        backend.members[1]['color'] = '#D32F2F';
        await openSettings(tester, backend);
        await tester.tap(find.text('Ben'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Speichern'));
        await tester.pumpAndSettle();
        expect(backend.memberBody, isNotNull);
        expect(backend.members[1].containsKey('can_change_color'), isFalse);
      });

      testWidgets('Admin legt fest, ob das Mitglied die Farbe selbst ändern darf', (tester) async {
        final backend = FakeBackend();
        await openSettings(tester, backend);

        await tester.tap(find.text('Ben'));
        await tester.pumpAndSettle();
        expect(tester.widget<SwitchListTile>(find.byKey(const Key('can-change-color'))).value, isTrue);
        await tester.tap(find.byKey(const Key('can-change-color')));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Speichern'));
        await tester.pumpAndSettle();
        expect(backend.members[1]['can_change_color'], isFalse);

        // It stays as it was saved.
        await tester.tap(find.text('Ben'));
        await tester.pumpAndSettle();
        expect(tester.widget<SwitchListTile>(find.byKey(const Key('can-change-color'))).value, isFalse);
      });

      testWidgets('ohne Admin-Flag nur lesbar', (tester) async {
        await openSettings(tester, FakeBackend()..isAdmin = false);

        expect(find.text('Mitglied einladen'), findsNothing);
        await tester.tap(find.text('Ben'));
        await tester.pumpAndSettle();
        expect(find.text('Profilfarbe'), findsNothing);
      });
    });

    group('Kategorien', () {
      testWidgets('zeigen nur die Liste, ohne „Keine Kategorie“', (tester) async {
        await openArea(tester, FakeBackend(), 'Kategorien');

        expect(find.text('Keine Kategorie'), findsNothing);
        expect(tester.getTopLeft(find.text('Allgemein')).dy, lessThan(tester.getTopLeft(find.text('Wichtig')).dy));
      });

      testWidgets('genutzte Kategorie lässt sich nicht löschen', (tester) async {
        final backend = FakeBackend();
        backend.categories[1]['used'] = true;
        await openArea(tester, backend, 'Kategorien');

        expect(find.byTooltip('Wird von Terminen verwendet'), findsOneWidget);
        expect(find.byTooltip('Löschen'), findsOneWidget);
      });

      testWidgets('neue Kategorie ohne Farbe anlegen', (tester) async {
        final backend = FakeBackend();
        await openArea(tester, backend, 'Kategorien');

        await tester.tap(find.text('Kategorie hinzufügen'));
        await tester.pumpAndSettle();
        expect(saveButton(tester).onPressed, isNull);
        await tester.enterText(find.byType(TextField), ' Schule ');
        await tester.pumpAndSettle();
        await tester.tap(find.text('Speichern'));
        await tester.pumpAndSettle();

        expect(backend.writes['POST /api/families/f1/categories'], {'name': 'Schule', 'color': ''});
      });

      testWidgets('Kategorie ändern und ihre Farbe entfernen', (tester) async {
        final backend = FakeBackend();
        await openArea(tester, backend, 'Kategorien');

        await tester.tap(find.text('Wichtig'));
        await tester.pumpAndSettle();
        expect(find.text('Kategorie ändern'), findsOneWidget);
        await tester.enterText(find.byType(TextField), 'Dringend');
        await tester.tap(find.byTooltip('Keine Farbe'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Speichern'));
        await tester.pumpAndSettle();

        expect(backend.writes['PUT /api/families/f1/categories/k2'], {'name': 'Dringend', 'color': ''});
      });

      testWidgets('Kategorie entfernen', (tester) async {
        final backend = FakeBackend();
        await openArea(tester, backend, 'Kategorien');

        await tester.tap(find.descendant(of: find.widgetWithText(ListTile, 'Wichtig'), matching: find.byTooltip('Löschen')));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Löschen'));
        await tester.pumpAndSettle();

        expect(backend.writes.keys, ['DELETE /api/families/f1/categories/k2']);
      });

      testWidgets('Reihenfolge per Drag and Drop ändern', (tester) async {
        final backend = FakeBackend();
        await openArea(tester, backend, 'Kategorien');

        final row = tester.getSize(find.byKey(const ValueKey('k1'))).height;
        final gesture = await tester.startGesture(tester.getCenter(find.byIcon(Icons.drag_handle).first));
        await tester.pump(const Duration(milliseconds: 100));
        for (var i = 0; i < 8; i++) {
          await gesture.moveBy(Offset(0, row / 5));
          await tester.pump(const Duration(milliseconds: 50));
        }
        await tester.pump(const Duration(milliseconds: 500));
        await gesture.up();
        await tester.pumpAndSettle();

        expect(backend.writes['PUT /api/families/f1/categories/order'], {
          'ids': ['k2', 'k1'],
        });
        expect(tester.getTopLeft(find.text('Wichtig')).dy, lessThan(tester.getTopLeft(find.text('Allgemein')).dy));
      });

      testWidgets('ohne Admin-Flag nur lesbar', (tester) async {
        await openArea(tester, FakeBackend()..isAdmin = false, 'Kategorien');

        expect(find.text('Allgemein'), findsOneWidget);
        expect(find.text('Kategorie hinzufügen'), findsNothing);
        expect(find.byIcon(Icons.drag_handle), findsNothing);
        expect(find.byTooltip('Löschen'), findsNothing);
      });
    });
  });

  testWidgets('Einstellungen enthalten weder Profil noch Abmelden', (tester) async {
    await openSettings(tester, FakeBackend());
    expect(find.text('Profil'), findsNothing);
    expect(find.text('Abmelden'), findsNothing);
    expect(find.text('anna@example.de'), findsNothing);
  });

  test('unbekannter Typ gilt als Familie', () {
    final family = Family.fromJson({'id': 'f', 'name': 'F', 'type': 'neu', 'role': 'user', 'is_admin': false, 'color': ''});
    expect(family.type, FamilyType.family);
  });

  for (final (type, manager, user, restricted) in [
    ('family', 'Eltern', 'Erwachsenes Kind', 'Kind'),
    ('friends', 'Manager', 'User', 'Restricted'),
    ('relatives', 'Manager', 'User', 'Restricted'),
    ('workgroup', 'Manager', 'User', 'Restricted'),
  ]) {
    testWidgets('Rollennamen beim Typ $type', (tester) async {
      await openSettings(tester, FakeBackend()..familyType = type);
      expect(find.text('$manager (Admin)'), findsOneWidget);
      expect(find.text(restricted), findsOneWidget);
      expect(find.text(user), findsOneWidget);
    });
  }

  testWidgets('Admin ändert Rolle und Admin-Flag eines Mitglieds', (tester) async {
    final backend = FakeBackend();
    await openSettings(tester, backend);

    await tester.tap(find.text('Ben'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kind').last);
    await tester.pumpAndSettle();
    expect(find.text('Gast'), findsNothing);
    await tester.tap(find.text('Erwachsenes Kind').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Speichern'));
    await tester.pumpAndSettle();

    expect(backend.memberBody, {'role': 'user', 'is_admin': true});
  });

  testWidgets('Einladung schickt Rolle und Admin-Flag', (tester) async {
    final backend = FakeBackend()..familyType = 'workgroup';
    await openSettings(tester, backend);

    await tester.tap(find.text('Mitglied einladen'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.widgetWithText(AppBar, 'Mitglied einladen'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'd@example.de');
    await chooseRole(tester, 'User');
    await tester.tap(find.byTooltip('Einladen'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Mitglied einladen'), findsNothing);

    expect(backend.inviteBody, {
      'email': 'd@example.de',
      'role': 'user',
      'is_admin': false,
      'color': '',
      'can_change_color': true,
    });
  });

  testWidgets('Einladung legt auch Profilfarbe und das Recht fest, sie zu ändern', (tester) async {
    final backend = FakeBackend();
    await openSettings(tester, backend);

    await tester.tap(find.text('Mitglied einladen'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'd@example.de');
    await chooseRole(tester, 'Kind');
    expect(find.text('Profilfarbe'), findsOneWidget);
    await tester.ensureVisible(find.byTooltip('Blau'));
    await tester.tap(find.byTooltip('Blau'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('can-change-color')));
    await tester.tap(find.byKey(const Key('can-change-color')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Einladen'));
    await tester.pumpAndSettle();

    expect(backend.inviteBody?['color'], '#1565C0');
    expect(backend.inviteBody?['can_change_color'], isFalse);
  });

  group('Mitglieder, die den Kreis verlassen haben', () {
    FakeBackend withFormer() => FakeBackend()
      ..former = [
        {'id': 'u7', 'name': 'Dora', 'email': 'd@example.de', 'color': '#1565C0', 'left_at': '2026-01-01T10:00:00Z'},
      ];
    Finder entry() => find.byKey(const Key('former-u7'));

    testWidgets('stehen als gelöscht markiert in der Liste', (tester) async {
      await openSettings(tester, withFormer());
      expect(find.descendant(of: entry(), matching: find.text('Dora')), findsOneWidget);
      expect(find.descendant(of: entry(), matching: find.text('Gelöscht · d@example.de')), findsOneWidget);
      // Tapping the entry itself does nothing, it is no member any more.
      await tester.tap(find.text('Dora'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Dora'), findsNothing);
      await disposeApp(tester);
    });

    testWidgets('lassen sich wieder einladen, mit Adresse und Farbe von früher', (tester) async {
      final backend = withFormer();
      await openSettings(tester, backend);
      await tester.tap(find.descendant(of: entry(), matching: find.byTooltip('Wieder einladen')));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Mitglied einladen'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField).first).controller!.text, 'd@example.de');

      // The role still has to be chosen, the past does not decide it.
      await tester.tap(find.byTooltip('Einladen'));
      await tester.pumpAndSettle();
      expect(find.text('Bitte eine Rolle auswählen'), findsOneWidget);
      await chooseRole(tester, 'Kind');
      await tester.tap(find.byTooltip('Einladen'));
      await tester.pumpAndSettle();
      expect(backend.inviteBody, {
        'email': 'd@example.de',
        'role': 'restrict_user',
        'is_admin': false,
        'color': '#1565C0',
        'can_change_color': true,
      });
      await disposeApp(tester);
    });

    testWidgets('lassen sich nach Rückfrage endgültig löschen', (tester) async {
      final backend = withFormer();
      await openSettings(tester, backend);
      await tester.tap(find.descendant(of: entry(), matching: find.byTooltip('Endgültig löschen')));
      await tester.pumpAndSettle();
      expect(find.text('Dora endgültig löschen?'), findsOneWidget);
      expect(find.textContaining('nicht wiederherstellen'), findsOneWidget);
      await tester.tap(find.text('Abbrechen'));
      await tester.pumpAndSettle();
      expect(backend.writes, isEmpty);

      await tester.tap(find.descendant(of: entry(), matching: find.byTooltip('Endgültig löschen')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Löschen'));
      await tester.pumpAndSettle();
      expect(backend.writes.keys, ['DELETE /api/families/f1/former/u7']);
      expect(entry(), findsNothing);
      await disposeApp(tester);
    });
  });

  group('Benutzer ohne E-Mail', () {
    Future<void> openMember(WidgetTester tester, FakeBackend backend) async {
      backend.members[1]['managed'] = true;
      backend.members[1]['email'] = '';
      await openSettings(tester, backend);
      await tester.tap(find.text('Ben'));
      await tester.pumpAndSettle();
    }

    testWidgets('lassen sich mit Name und Rolle hinzufügen, die Pflicht sind', (tester) async {
      final backend = FakeBackend();
      await openSettings(tester, backend);
      expect(find.text('Mitglied einladen'), findsOneWidget);
      await tester.tap(find.text('Benutzer hinzufügen'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Benutzer hinzufügen'), findsOneWidget);
      expect(find.text('Admin'), findsNothing);
      expect(find.textContaining('E-Mail-Adresse *'), findsNothing);

      await tester.tap(find.byTooltip('Hinzufügen'));
      await tester.pumpAndSettle();
      expect(find.text('Bitte einen Namen eingeben'), findsOneWidget);
      expect(find.text('Bitte eine Rolle auswählen'), findsOneWidget);
      expect(backend.managedBody, isNull);

      await tester.enterText(find.byKey(const Key('managed-name')), ' Lina ');
      await chooseRole(tester, 'Kind');
      await tester.tap(find.byTooltip('Blau'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Hinzufügen'));
      await tester.pumpAndSettle();
      expect(backend.managedBody, {
        'name': 'Lina',
        'role': 'restrict_user',
        'color': '#1565C0',
        'can_change_color': true,
      });
      expect(find.widgetWithText(AppBar, 'Benutzer hinzufügen'), findsNothing);
      await disposeApp(tester);
    });

    testWidgets('Entfernen löscht endgültig, ein bloßes Verlassen gibt es nicht', (tester) async {
      final backend = FakeBackend();
      backend.members[1]['managed'] = true;
      await openSettings(tester, backend);
      await tester.tap(find.descendant(of: find.widgetWithText(ListTile, 'Ben'), matching: find.byTooltip('Entfernen')));
      await tester.pumpAndSettle();
      expect(find.text('Ben endgültig löschen?'), findsOneWidget);
      expect(find.textContaining('nicht wiederherstellen'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Löschen'), findsOneWidget);
      expect(find.text('Nur verlassen'), findsNothing);
      await disposeApp(tester);
    });

    testWidgets('ein Mitglied mit E-Mail wird weiter nur entfernt', (tester) async {
      await openSettings(tester, FakeBackend());
      await tester.tap(find.descendant(of: find.widgetWithText(ListTile, 'Ben'), matching: find.byTooltip('Entfernen')));
      await tester.pumpAndSettle();
      expect(find.textContaining('endgültig'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Entfernen'), findsOneWidget);
      await disposeApp(tester);
    });

    testWidgets('ohne Admin-Rechte gibt es den Button nicht', (tester) async {
      await openSettings(tester, FakeBackend()..isAdmin = false);
      expect(find.text('Benutzer hinzufügen'), findsNothing);
      await disposeApp(tester);
    });

    testWidgets('zeigen in der Liste, dass sie keine E-Mail haben', (tester) async {
      final backend = FakeBackend();
      backend.members[1]['managed'] = true;
      await openSettings(tester, backend);
      expect(find.text('Kind · ohne E-Mail'), findsOneWidget);
      await disposeApp(tester);
    });

    testWidgets('haben einen Block Verwaltung nach der Profilfarbe, und kein Admin-Flag', (tester) async {
      await openMember(tester, FakeBackend());
      expect(find.text('Verwaltung'), findsOneWidget);
      expect(find.text('Admin'), findsNothing);
      final lock = tester.getTopLeft(find.byKey(const Key('can-change-color'))).dy;
      expect(tester.getTopLeft(find.text('Verwaltung')).dy, greaterThan(lock));
      expect(find.byKey(const Key('member-add-email')), findsOneWidget);
      expect(find.byKey(const Key('member-edit-profile')), findsOneWidget);
      await disposeApp(tester);
    });

    testWidgets('Mitglieder mit E-Mail haben keinen Block Verwaltung', (tester) async {
      await openSettings(tester, FakeBackend());
      await tester.tap(find.text('Ben'));
      await tester.pumpAndSettle();
      expect(find.text('Verwaltung'), findsNothing);
      expect(find.byKey(const Key('member-add-email')), findsNothing);
      expect(find.byKey(const Key('member-edit-profile')), findsNothing);
      await disposeApp(tester);
    });

    testWidgets('E-Mail hinzufügen geht über Adresse und Code', (tester) async {
      final backend = FakeBackend();
      await openMember(tester, backend);
      await tester.tap(find.byKey(const Key('member-add-email')));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AlertDialog, 'E-Mail hinzufügen'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('new-email')), ' lina@example.de ');
      await tester.tap(find.text('Code senden'));
      await tester.pumpAndSettle();
      expect(backend.memberEmailRequests, ['lina@example.de']);

      await tester.enterText(find.byKey(const Key('email-code')), '000000');
      await tester.tap(find.text('Bestätigen'));
      await tester.pumpAndSettle();
      expect(find.text('Der Code ist falsch.'), findsOneWidget);
      expect(backend.members[1]['managed'], isTrue);

      await tester.enterText(find.byKey(const Key('email-code')), '123456');
      await tester.tap(find.text('Bestätigen'));
      await tester.pumpAndSettle();
      expect(backend.members[1]['managed'], isFalse);
      expect(find.text('Ben kann sich jetzt anmelden.'), findsOneWidget);
      // Back in the list, where nothing is left to look after.
      expect(find.text('Verwaltung'), findsNothing);
      expect(find.widgetWithText(Tab, 'Mitglieder'), findsOneWidget);
      await disposeApp(tester);
    });

    testWidgets('Anmeldecode erstellen steht nach Profil bearbeiten und zeigt den Code', (tester) async {
      final backend = FakeBackend();
      await openMember(tester, backend);
      await tester.ensureVisible(find.byKey(const Key('member-login-code')));
      await tester.pumpAndSettle();
      expect(backend.loginCodesMade, 0);
      expect(
        tester.getTopLeft(find.byKey(const Key('member-login-code'))).dy,
        greaterThan(tester.getTopLeft(find.byKey(const Key('member-edit-profile'))).dy),
      );

      await tester.tap(find.byKey(const Key('member-login-code')));
      await tester.pumpAndSettle();
      expect(backend.loginCodesMade, 1);
      expect(find.text('WXYZ-2345-6789'), findsOneWidget);
      expect(find.textContaining('Er gilt einmal'), findsOneWidget);
      expect(find.textContaining('„Alternative Anmeldung“'), findsOneWidget);

      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await tester.tap(find.text('Kopieren'));
      await tester.pumpAndSettle();
      expect(copied, 'WXYZ-2345-6789');
      expect(find.text('Kopiert'), findsOneWidget);

      await tester.tap(find.text('Fertig'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      // Still on the member's page, where it may be needed again.
      expect(find.byKey(const Key('member-login-code')), findsOneWidget);
      await disposeApp(tester);
    });

    testWidgets('Mitglieder mit E-Mail bekommen keinen Anmeldecode', (tester) async {
      await openSettings(tester, FakeBackend());
      await tester.tap(find.text('Ben'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('member-login-code')), findsNothing);
      await disposeApp(tester);
    });

    testWidgets('Profil bearbeiten führt auf die Seite des eigenen Profils, aber für dieses Mitglied', (tester) async {
      final backend = FakeBackend();
      backend.memberProfile['name'] = 'Ben';
      backend.memberProfile['family_role'] = 'Sohn';
      await openMember(tester, backend);
      await tester.tap(find.byKey(const Key('member-edit-profile')));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Profil bearbeiten'), findsOneWidget);
      expect(tester.widget<TextField>(find.byKey(const Key('profile-family-role'))).controller!.text, 'Sohn');
      expect(find.byKey(const Key('leave-family')), findsNothing);
      expect(find.byTooltip('Adresse aus der Registrierung einfügen'), findsNothing);

      await tester.enterText(find.byKey(const Key('profile-name')), 'Benedikt');
      await tester.tap(find.byTooltip('Blau'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Speichern'));
      await tester.pumpAndSettle();
      expect(backend.memberProfile['name'], 'Benedikt');
      expect(backend.members[1]['color'], '#1565C0');
      // The own profile stays as it was.
      expect(backend.profileWrites, isEmpty);
      expect(backend.familyColor, '');
      expect(find.widgetWithText(Tab, 'Mitglieder'), findsOneWidget);
      await disposeApp(tester);
    });
  });

  testWidgets('die Rolle ist beim Einladen Pflicht und nicht vorbelegt', (tester) async {
    final backend = FakeBackend();
    await openSettings(tester, backend);
    await tester.tap(find.text('Mitglied einladen'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'd@example.de');
    expect(find.text('Rolle *'), findsOneWidget);
    expect(tester.widget<DropdownButton<String>>(find.byType(DropdownButton<String>)).value, isNull);
    expect(find.text('Bitte eine Rolle auswählen'), findsNothing);

    await tester.tap(find.byTooltip('Einladen'));
    await tester.pumpAndSettle();
    expect(find.text('Bitte eine Rolle auswählen'), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'Mitglied einladen'), findsOneWidget);
    expect(backend.inviteBody, isNull);

    await chooseRole(tester, 'Erwachsenes Kind');
    expect(find.text('Bitte eine Rolle auswählen'), findsNothing);
    await tester.tap(find.byTooltip('Einladen'));
    await tester.pumpAndSettle();
    expect(backend.inviteBody?['role'], 'user');
    expect(find.widgetWithText(AppBar, 'Mitglied einladen'), findsNothing);
  });

  testWidgets('die E-Mail-Adresse ist beim Einladen Pflicht', (tester) async {
    final backend = FakeBackend();
    await openSettings(tester, backend);
    await tester.tap(find.text('Mitglied einladen'));
    await tester.pumpAndSettle();
    expect(find.text('E-Mail-Adresse *'), findsOneWidget);
    expect(find.text('Bitte eine E-Mail-Adresse eingeben'), findsNothing);

    // Everything that is missing is named at once.
    await tester.tap(find.byTooltip('Einladen'));
    await tester.pumpAndSettle();
    expect(find.text('Bitte eine E-Mail-Adresse eingeben'), findsOneWidget);
    expect(find.text('Bitte eine Rolle auswählen'), findsOneWidget);
    expect(backend.inviteBody, isNull);

    // Spaces are no address.
    await chooseRole(tester, 'Kind');
    await tester.enterText(find.byType(TextField).first, '   ');
    await tester.pumpAndSettle();
    expect(find.text('Bitte eine E-Mail-Adresse eingeben'), findsNothing);
    await tester.tap(find.byTooltip('Einladen'));
    await tester.pumpAndSettle();
    expect(find.text('Bitte eine E-Mail-Adresse eingeben'), findsOneWidget);
    expect(find.text('Bitte eine Rolle auswählen'), findsNothing);
    expect(find.widgetWithText(AppBar, 'Mitglied einladen'), findsOneWidget);
    expect(backend.inviteBody, isNull);

    await tester.enterText(find.byType(TextField).first, ' d@example.de ');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Einladen'));
    await tester.pumpAndSettle();
    expect(backend.inviteBody?['email'], 'd@example.de');
    expect(find.widgetWithText(AppBar, 'Mitglied einladen'), findsNothing);
  });

  group('offene Einladungen', () {
    List<Map<String, Object>> open() => [
      {'id': 'i1', 'email': 'neu@example.de', 'role': 'user', 'is_admin': false, 'color': '', 'can_change_color': true},
    ];
    const resend = Key('invitation-resend-i1');
    const enterCode = Key('invitation-enter-code-i1');

    testWidgets('lassen sich erneut senden', (tester) async {
      final backend = FakeBackend()..invitations = open();
      await openSettings(tester, backend);
      await tester.tap(find.byKey(resend));
      await tester.pumpAndSettle();
      expect(backend.invitationResends, 1);
      expect(find.text('Einladung an neu@example.de gesendet.'), findsOneWidget);
      // Still waiting for the person.
      expect(find.text('neu@example.de'), findsOneWidget);
      await disposeApp(tester);
    });

    testWidgets('sagen, wenn zu viele Mails gingen', (tester) async {
      final backend = FakeBackend()
        ..invitations = open()
        ..rejectResend = true;
      await openSettings(tester, backend);
      await tester.tap(find.byKey(resend));
      await tester.pumpAndSettle();
      expect(find.textContaining('schon genug Einladungen'), findsOneWidget);
      expect(find.text('Einladung an neu@example.de gesendet.'), findsNothing);
      await disposeApp(tester);
    });

    testWidgets('mit vorhandenem Konto reicht der Code', (tester) async {
      final backend = FakeBackend()..invitations = open();
      await openSettings(tester, backend);
      await tester.tap(find.byKey(enterCode));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('invitation-code')), '000000');
      await tester.tap(find.text('Bestätigen'));
      await tester.pumpAndSettle();
      expect(find.text('Der Code ist falsch.'), findsOneWidget);
      expect(backend.invitationConfirmBody, isNull);

      await tester.enterText(find.byKey(const Key('invitation-code')), ' 123456 ');
      await tester.tap(find.text('Bestätigen'));
      await tester.pumpAndSettle();
      expect(backend.invitationConfirmBody?['code'], '123456');
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('neu@example.de wurde aufgenommen.'), findsOneWidget);
      expect(find.byKey(enterCode), findsNothing);
      await disposeApp(tester);
    });

    testWidgets('ohne Konto fragt der Dialog nach dem richtigen Code auch den Namen', (tester) async {
      final backend = FakeBackend()
        ..invitations = open()
        ..invitationNeedsName = true;
      await openSettings(tester, backend);
      await tester.tap(find.byKey(enterCode));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('invitation-name')), findsNothing);

      await tester.enterText(find.byKey(const Key('invitation-code')), '123456');
      await tester.tap(find.text('Bestätigen'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('invitation-name')), findsOneWidget);
      expect(backend.invitationConfirmBody, isNull);

      await tester.tap(find.text('Bestätigen'));
      await tester.pumpAndSettle();
      expect(find.text('Bitte gib einen Namen an.'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('invitation-name')), ' Neu ');
      await tester.tap(find.text('Bestätigen'));
      await tester.pumpAndSettle();
      expect(backend.invitationConfirmBody, {'code': '123456', 'name': 'Neu'});
      expect(find.byType(AlertDialog), findsNothing);
      await disposeApp(tester);
    });

    testWidgets('bleiben auf dem Handy bedienbar', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final backend = FakeBackend()..invitations = open();
      await openSettings(tester, backend);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(enterCode));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('invitation-code')), findsOneWidget);
      await tester.tap(find.text('Abbrechen'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(resend));
      await tester.pumpAndSettle();
      expect(backend.invitationResends, 1);
      await disposeApp(tester);
    });
  });

  testWidgets('eine abgelehnte Einladung lässt die Seite mit allen Eingaben offen', (tester) async {
    final backend = FakeBackend()..rejectInvitation = true;
    await openSettings(tester, backend);
    await tester.tap(find.text('Mitglied einladen'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'd@example.de');
    await chooseRole(tester, 'Kind');
    await tester.tap(find.byTooltip('Einladen'));
    await tester.pumpAndSettle();

    expect(find.text('Diese Person wurde bereits eingeladen.'), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'Mitglied einladen'), findsOneWidget);
    expect(find.text('d@example.de'), findsOneWidget);
  });

  testWidgets('die Einladung bleibt auf dem Handy bedienbar', (tester) async {
    await openSettings(tester, FakeBackend());
    tester.view.physicalSize = const Size(360, 640);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mitglied einladen'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('can-change-color')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('can-change-color')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Einladen'), findsOneWidget);
  });

  group('Profilfarbe gesperrt', () {
    Future<FakeBackend> openProfile(WidgetTester tester, {required bool isAdmin}) async {
      final backend = FakeBackend()
        ..isAdmin = isAdmin
        ..canChangeColor = false
        ..familyColor = '#1565C0';
      await pumpApp(tester, backend, MemoryTokens()..token = 't1');
      await _openProfileEdit(tester);
      return backend;
    }

    testWidgets('das Mitglied sieht die Farbe, kann sie aber nicht ändern', (tester) async {
      await openProfile(tester, isAdmin: false);
      expect(find.text('Profilfarbe'), findsOneWidget);
      expect(find.text('Deine Profilfarbe kann nur ein Admin ändern.'), findsOneWidget);
      expect(find.byType(ColorChooser), findsNothing);
    });

    testWidgets('für Admins gilt die Sperre nicht', (tester) async {
      await openProfile(tester, isAdmin: true);
      expect(find.byType(ColorChooser), findsOneWidget);
      expect(find.text('Deine Profilfarbe kann nur ein Admin ändern.'), findsNothing);
    });
  });

  testWidgets('ohne Admin-Flag keine Verwaltung in den Einstellungen', (tester) async {
    final backend = FakeBackend()..isAdmin = false;
    await openSettings(tester, backend);

    expect(find.text('Mitglied einladen'), findsNothing);
    await tester.tap(find.text('Ben'));
    await tester.pumpAndSettle();
    expect(find.text('Speichern'), findsNothing);
    // Without the flag one can leave, but not remove others.
    expect(find.byTooltip('Familie verlassen'), findsOneWidget);
    expect(find.byTooltip('Entfernen'), findsNothing);
  });

  testWidgets('Admin kann nicht austreten und sich das Flag nicht entziehen', (tester) async {
    await openSettings(tester, FakeBackend());

    expect(find.byTooltip('Familie verlassen'), findsNothing);
    expect(find.byTooltip('Entfernen'), findsNWidgets(2));

    await tester.tap(find.text('Anna').last);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile).first).onChanged, isNull);
    expect(find.text('Du kannst dir die Admin-Rechte nicht selbst entziehen.'), findsOneWidget);
  });

  group('besondere Tage', () {
    final today = DateTime(2026, 11, 2);

    test('jährlicher Tag rollt ins nächste Jahr', () {
      expect(nextOccurrence(DateTime(1990, 3, 1), true, today), DateTime(2027, 3, 1));
      expect(nextOccurrence(DateTime(1990, 12, 24), true, today), DateTime(2026, 12, 24));
      expect(nextOccurrence(DateTime(1990, 11, 2), true, today), today);
    });

    test('einmaliger Tag bleibt auf seinem Datum', () {
      expect(nextOccurrence(DateTime(2020, 3, 1), false, today), DateTime(2020, 3, 1));
    });

    test('Countdown', () {
      expect(countdown(today, today), 'Heute');
      expect(countdown(DateTime(2026, 11, 3), today), 'Morgen');
      expect(countdown(DateTime(2026, 11, 12), today), 'In 10 Tagen');
      expect(countdown(DateTime(2020, 1, 1), today), 'Vorbei');
    });
  });
}

const _eventsPath = '/api/families/f1/events';

Future<void> _openNewEvent(WidgetTester tester, FakeBackend backend) async {
  await pumpApp(tester, backend, MemoryTokens()..token = 't1');
  await tester.tap(find.text('Kalender'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('calendar-add')));
  await tester.pumpAndSettle();
}

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _pickOption(WidgetTester tester, Key dropdown, String option) async {
  await tester.tap(find.byKey(dropdown));
  await tester.pumpAndSettle();
  await tester.tap(find.text(option).last);
  await tester.pumpAndSettle();
}

Future<void> _save(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Speichern'));
  await tester.pumpAndSettle();
}

Map<String, Object?> _detail([Map<String, Object?> extra = const {}]) => {
  'id': 'e1',
  'title': 'Zahnarzt',
  'description': 'Notiz',
  'start_at': '2026-01-05T09:00:00Z',
  'end_at': '2026-01-05T10:00:00Z',
  'start_local': '2026-01-05T15:30',
  'end_local': '2026-01-05T16:30',
  'all_day': false,
  'timezone': 'America/New_York',
  'recurrence': null,
  'participants_all': false,
  'participant_ids': ['u2'],
  'visibility': 'participants',
  'category_id': 'k2',
  'category_name': 'Wichtig',
  'color': '#D32F2F',
  'location': 'Praxis',
  'reminders': [15],
  'attachments': [
    {'id': 'a1', 'name': 'plan.pdf', 'size': 2048},
  ],
  ...extra,
};

void eventTests() {
  testWidgets('neuer Termin öffnet eine ganze Seite mit den Vorgaben', (tester) async {
    final backend = FakeBackend();
    await _openNewEvent(tester, backend);

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Neuer Termin'), findsOneWidget);
    expect(find.text('Mitteleuropäische Normalzeit GMT+01:00'), findsOneWidget);
    expect(find.text('Niemals'), findsOneWidget);
    expect(find.text('Keine Erinnerung'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('event-title')), 'Elternabend');
    await _save(tester);

    final body = backend.writes['POST $_eventsPath'] as Map<String, dynamic>;
    expect(body['title'], 'Elternabend');
    expect(body['timezone'], 'Europe/Berlin');
    expect(body['participants_all'], true);
    expect(body['participant_ids'], isEmpty);
    expect(body['visibility'], 'all');
    expect(body['category_id'], '');
    expect(body['recurrence'], isNull);
    expect(body['reminders'], isEmpty);
    expect(body['location'], '');
    expect(body['start_local'], matches(RegExp(r'^\d{4}-\d\d-\d\dT12:00$')));
    expect(find.text('Neuer Termin'), findsNothing);
    await disposeApp(tester);
  });

  testWidgets('Zeitzone wird im Dialog gewählt', (tester) async {
    final backend = FakeBackend();
    await _openNewEvent(tester, backend);

    await tester.tap(find.byKey(const Key('event-timezone')));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Suchen'), 'york');
    await tester.pumpAndSettle();
    expect(find.text('Mitteleuropäische Normalzeit'), findsNothing);
    await tester.tap(find.text('Nordamerikanische Ostküsten-Normalzeit'));
    await tester.pumpAndSettle();
    expect(find.text('Nordamerikanische Ostküsten-Normalzeit GMT-05:00'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('event-title')), 'T');
    await _save(tester);
    expect((backend.writes['POST $_eventsPath'] as Map)['timezone'], 'America/New_York');
    await disposeApp(tester);
  });

  testWidgets('Teilnehmer: Alle ist Vorgabe, einzelne schließen Alle aus', (tester) async {
    final backend = FakeBackend();
    await _openNewEvent(tester, backend);
    await tester.enterText(find.byKey(const Key('event-title')), 'T');

    // Everyone off and on again falls back to all, so nobody is never sent.
    await _tapVisible(tester, find.byKey(const Key('participant-u2')));
    await _tapVisible(tester, find.byKey(const Key('participant-u3')));
    await _tapVisible(tester, find.byKey(const Key('participant-u3')));
    await _tapVisible(tester, find.byKey(const Key('participant-u2')));
    await _save(tester);
    expect((backend.writes['POST $_eventsPath'] as Map)['participants_all'], true);
    await disposeApp(tester);
  });

  testWidgets('Teilnehmer einzeln wählen und Sichtbarkeit einschränken', (tester) async {
    final backend = FakeBackend();
    await _openNewEvent(tester, backend);
    // The longer label has to fit on a phone as well.
    tester.view.physicalSize = const Size(360, 1400);
    await tester.pumpAndSettle();
    expect(find.text('Teilnehmer'), findsOneWidget);
    expect(find.text('Beteiligte'), findsNothing);
    await tester.enterText(find.byKey(const Key('event-title')), 'T');

    await _tapVisible(tester, find.byKey(const Key('participant-u3')));
    await _tapVisible(tester, find.text('Dich und Teilnehmer'));
    await _save(tester);

    final body = backend.writes['POST $_eventsPath'] as Map;
    expect(body['participants_all'], false);
    expect(body['participant_ids'], ['u3']);
    expect(body['visibility'], 'participants');
    await disposeApp(tester);
  });

  testWidgets('Kategorie wählen, ohne Auswahl bleibt der Termin ohne Kategorie', (tester) async {
    final backend = FakeBackend();
    await _openNewEvent(tester, backend);
    await tester.enterText(find.byKey(const Key('event-title')), 'T');

    expect(find.text('Keine Kategorie'), findsNothing);
    await _tapVisible(tester, find.byKey(const Key('category-k2')));
    await _save(tester);
    expect((backend.writes['POST $_eventsPath'] as Map)['category_id'], 'k2');
    await disposeApp(tester);
  });

  testWidgets('gewählte Kategorie lässt sich wieder abwählen', (tester) async {
    final backend = FakeBackend();
    await _openNewEvent(tester, backend);
    await tester.enterText(find.byKey(const Key('event-title')), 'T');

    await _tapVisible(tester, find.byKey(const Key('category-k2')));
    await _tapVisible(tester, find.byKey(const Key('category-k2')));
    await _save(tester);
    expect((backend.writes['POST $_eventsPath'] as Map)['category_id'], '');
    await disposeApp(tester);
  });

  group('Wiederholen', () {
    Future<Map> saveRule(WidgetTester tester, FakeBackend backend) async {
      await tester.enterText(find.byKey(const Key('event-title')), 'T');
      await _save(tester);
      return (backend.writes['POST $_eventsPath'] as Map)['recurrence'] as Map;
    }

    for (final (option, rule) in [
      ('Täglich', {'freq': 'day', 'interval': 1}),
      ('Jeden Wochentag', {'freq': 'week', 'interval': 1, 'weekdays': [1, 2, 3, 4, 5]}),
      ('Jede Woche', {'freq': 'week', 'interval': 1}),
      ('Alle 2 Wochen', {'freq': 'week', 'interval': 2}),
      ('Jeden Monat', {'freq': 'month', 'interval': 1}),
      ('Jedes Jahr', {'freq': 'year', 'interval': 1}),
    ]) {
      testWidgets(option, (tester) async {
        final backend = FakeBackend();
        await _openNewEvent(tester, backend);
        await _tapVisible(tester, find.byKey(const Key('event-recurrence')));
        await tester.tap(find.text(option));
        await tester.pumpAndSettle();
        expect(await saveRule(tester, backend), rule);
        await disposeApp(tester);
      });
    }

    Future<void> openCustom(WidgetTester tester, FakeBackend backend) async {
      await _openNewEvent(tester, backend);
      await _tapVisible(tester, find.byKey(const Key('event-recurrence')));
      await tester.tap(find.text('Individuell'));
      await tester.pumpAndSettle();
    }

    testWidgets('individuell: Wochentage an- und abwählen, keiner ist nicht erlaubt', (tester) async {
      final backend = FakeBackend();
      await openCustom(tester, backend);
      final today = DateTime.now().weekday;
      final other = today == 1 ? 2 : 1;

      await tester.enterText(find.byKey(const Key('recurrence-interval')), '3');
      await tester.tap(find.byKey(Key('weekday-$today')));
      await tester.pumpAndSettle();
      FilledButton accept() => tester.widget(find.widgetWithText(FilledButton, 'Übernehmen'));
      expect(accept().onPressed, isNull);

      await tester.tap(find.byKey(Key('weekday-$other')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Übernehmen'));
      await tester.pumpAndSettle();
      expect(await saveRule(tester, backend), {'freq': 'week', 'interval': 3, 'weekdays': [other]});
      await disposeApp(tester);
    });

    testWidgets('individuell: ungültige Anzahl sperrt', (tester) async {
      await openCustom(tester, FakeBackend());
      await tester.enterText(find.byKey(const Key('recurrence-interval')), '0');
      await tester.pumpAndSettle();
      final accept = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Übernehmen'));
      expect(accept.onPressed, isNull);
      await disposeApp(tester);
    });

    testWidgets('individuell: Monat am Tag', (tester) async {
      final backend = FakeBackend();
      await openCustom(tester, backend);
      await _pickOption(tester, const Key('recurrence-unit'), 'Monate');
      await tester.enterText(find.byKey(const Key('recurrence-interval')), '2');
      // The menu only builds entries near the current value, which is today.
      final today = DateTime.now().day;
      final day = today > 1 ? today - 1 : 2;
      await _pickOption(tester, const Key('month-day'), '$day');
      await tester.tap(find.text('Übernehmen'));
      await tester.pumpAndSettle();
      expect(find.text('Alle 2 Monate am $day.'), findsOneWidget);
      expect(await saveRule(tester, backend), {'freq': 'month', 'interval': 2, 'month_day': day});
      await disposeApp(tester);
    });

    testWidgets('individuell: Monat am ersten Wochentag', (tester) async {
      final backend = FakeBackend();
      await openCustom(tester, backend);
      await _pickOption(tester, const Key('recurrence-unit'), 'Monate');
      await tester.tap(find.byKey(const Key('month-by-weekday')));
      await tester.pumpAndSettle();
      await _pickOption(tester, const Key('month-weekday'), 'Mittwoch');
      await tester.tap(find.text('Übernehmen'));
      await tester.pumpAndSettle();
      expect(find.text('Jeden Monat am ersten Mittwoch'), findsOneWidget);
      expect(await saveRule(tester, backend), {'freq': 'month', 'interval': 1, 'month_week': 1, 'month_weekday': 3});
      await disposeApp(tester);
    });
  });

  group('Erinnerung', () {
    Future<void> openReminderChoice(WidgetTester tester) async {
      await _tapVisible(tester, find.text('Erinnerung hinzufügen'));
    }

    Future<Object?> savedReminders(WidgetTester tester, FakeBackend backend) async {
      await tester.enterText(find.byKey(const Key('event-title')), 'T');
      await _save(tester);
      return (backend.writes['POST $_eventsPath'] as Map)['reminders'];
    }

    testWidgets('Auswahl zeigt alle Vorgaben, weitere kommt sortiert dazu', (tester) async {
      final backend = FakeBackend();
      await _openNewEvent(tester, backend);
      await openReminderChoice(tester);
      expect(find.text('Keine Erinnerung'), findsNWidgets(2), reason: 'auf der Seite und im Dialog');
      for (final label in [
        '5 Minuten vorher',
        '15 Minuten vorher',
        '30 Minuten vorher',
        '1 Stunde vorher',
        '2 Stunden vorher',
        '1 Tag vorher',
        '2 Tage vorher',
        'Individuell',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      await tester.tap(find.text('1 Tag vorher'));
      await tester.pumpAndSettle();
      await openReminderChoice(tester);
      await tester.tap(find.text('5 Minuten vorher'));
      await tester.pumpAndSettle();
      expect(await savedReminders(tester, backend), [5, 1440]);
      await disposeApp(tester);
    });

    testWidgets('einzeln entfernen und doppelte zusammenfassen', (tester) async {
      final backend = FakeBackend();
      await _openNewEvent(tester, backend);
      for (var i = 0; i < 2; i++) {
        await openReminderChoice(tester);
        await tester.tap(find.text('30 Minuten vorher').last);
        await tester.pumpAndSettle();
      }
      expect(find.text('30 Minuten vorher'), findsOneWidget);

      await _tapVisible(tester, find.byTooltip('Erinnerung entfernen'));
      expect(find.text('Keine Erinnerung'), findsOneWidget);
      expect(await savedReminders(tester, backend), isEmpty);
      await disposeApp(tester);
    });

    testWidgets('„Keine Erinnerung“ entfernt alle', (tester) async {
      final backend = FakeBackend();
      await _openNewEvent(tester, backend);
      await openReminderChoice(tester);
      await tester.tap(find.text('1 Tag vorher'));
      await tester.pumpAndSettle();
      await openReminderChoice(tester);
      await tester.tap(find.text('Keine Erinnerung'));
      await tester.pumpAndSettle();
      expect(await savedReminders(tester, backend), isEmpty);
      await disposeApp(tester);
    });

    testWidgets('individuell startet bei 10 und kennt die Einheiten', (tester) async {
      final backend = FakeBackend();
      await _openNewEvent(tester, backend);
      await openReminderChoice(tester);
      await tester.tap(find.text('Individuell'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, '10'), findsOneWidget);
      await _pickOption(tester, const Key('reminder-unit'), 'Stunden vorher');
      await tester.enterText(find.byKey(const Key('reminder-count')), '3');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hinzufügen'));
      await tester.pumpAndSettle();
      expect(find.text('3 Stunden vorher'), findsOneWidget);
      expect(await savedReminders(tester, backend), [180]);
      await disposeApp(tester);
    });
  });

  testWidgets('Ort suchen, frei eingeben und entfernen', (tester) async {
    final backend = FakeBackend();
    await _openNewEvent(tester, backend);

    await _tapVisible(tester, find.text('Ort hinzufügen'));
    await tester.enterText(find.byKey(const Key('place-query')), 'Marienplatz');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(backend.placeQueries, ['Marienplatz']);
    await tester.tap(find.text('Marienplatz, 80331 München'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('In Google Maps öffnen'), findsOneWidget);
    expect(find.byKey(const Key('place-map')), findsOneWidget);

    await _tapVisible(tester, find.byTooltip('Ort entfernen'));
    expect(find.byKey(const Key('place-map')), findsNothing);
    await _tapVisible(tester, find.text('Ort hinzufügen'));
    await tester.enterText(find.byKey(const Key('place-query')), 'bei Oma');
    await tester.pumpAndSettle();
    await tester.tap(find.text('„bei Oma“ übernehmen'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('place-map')), findsNothing);

    await tester.enterText(find.byKey(const Key('event-title')), 'T');
    await _save(tester);
    final body = backend.writes['POST $_eventsPath'] as Map;
    expect(body['location'], 'bei Oma');
    expect(body['location_lat'], isNull);
    await disposeApp(tester);
  });

  testWidgets('Ortssuche wartet die Tipp-Pause ab und braucht 3 Zeichen', (tester) async {
    final backend = FakeBackend();
    await _openNewEvent(tester, backend);
    await _tapVisible(tester, find.text('Ort hinzufügen'));

    await tester.enterText(find.byKey(const Key('place-query')), 'Ma');
    await tester.pump(const Duration(milliseconds: 600));
    expect(backend.placeQueries, isEmpty);

    await tester.enterText(find.byKey(const Key('place-query')), 'Mar');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.enterText(find.byKey(const Key('place-query')), 'Mari');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(backend.placeQueries, ['Mari']);
    expect(find.text('Marienplatz, 80331 München'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('place-query')), 'M');
    await tester.pumpAndSettle();
    expect(find.text('Marienplatz, 80331 München'), findsNothing);

    // Enter does not wait.
    await tester.enterText(find.byKey(const Key('place-query')), 'Isar');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(backend.placeQueries, ['Mari', 'Isar']);
    await tester.pump(const Duration(milliseconds: 600));
    expect(backend.placeQueries, ['Mari', 'Isar']);
    await disposeApp(tester);
  });

  testWidgets('ausgefallene Ortssuche meldet sich im Dialog, freier Text geht weiter', (tester) async {
    final backend = FakeBackend()..rejectPlaces = true;
    await _openNewEvent(tester, backend);
    await _tapVisible(tester, find.text('Ort hinzufügen'));
    await tester.enterText(find.byKey(const Key('place-query')), 'Marienplatz');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.text('Die Ortssuche ist gerade nicht erreichbar.'), findsOneWidget);
    expect(find.text('„Marienplatz“ übernehmen'), findsOneWidget);
    await disposeApp(tester);
  });

  testWidgets('Karte zeigt die Kachel des Orts, Koordinaten werden gespeichert und bleiben', (tester) async {
    final backend = FakeBackend();
    await _openNewEvent(tester, backend);
    await _tapVisible(tester, find.text('Ort hinzufügen'));
    await tester.enterText(find.byKey(const Key('place-query')), 'Marienplatz');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Marienplatz, 80331 München'));
    await tester.pumpAndSettle();

    final urls = [
      for (final image in tester.widgetList<Image>(find.descendant(of: find.byKey(const Key('place-map')), matching: find.byType(Image))))
        (image.image as NetworkImage).url,
    ];
    expect(urls, contains('https://tile.openstreetmap.org/15/17437/11371.png'));
    expect(find.text('© OpenStreetMap'), findsOneWidget);

    // Taking over the unchanged text is no reason to lose the map.
    await _tapVisible(tester, find.text('Marienplatz, 80331 München'));
    await tester.tap(find.text('„Marienplatz, 80331 München“ übernehmen'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('place-map')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('event-title')), 'T');
    await _save(tester);
    final body = backend.writes['POST $_eventsPath'] as Map;
    expect(body['location_lat'], 48.137);
    expect(body['location_lon'], 11.575);
    await disposeApp(tester);
  });

  testWidgets('Anhänge gehen erst nach dem Termin hoch, Fehler legt keinen zweiten an', (tester) async {
    final backend = FakeBackend()..rejectUploads = true;
    final original = EventEditScreen.pickFiles;
    addTearDown(() => EventEditScreen.pickFiles = original);
    EventEditScreen.pickFiles = () async => [PickedFile('plan.txt', Uint8List.fromList([1, 2, 3]))];
    await _openNewEvent(tester, backend);

    await tester.enterText(find.byKey(const Key('event-title')), 'T');
    await _tapVisible(tester, find.text('Anhang hinzufügen'));
    expect(find.text('plan.txt'), findsOneWidget);
    expect(backend.uploads, isEmpty);

    await _save(tester);
    expect(find.text('Neuer Termin'), findsOneWidget, reason: 'bleibt offen');
    expect(find.text('plan.txt'), findsOneWidget);

    backend.writes.clear();
    backend.rejectUploads = false;
    await _save(tester);
    expect(backend.writes.keys, ['PUT $_eventsPath/e1']);
    expect(backend.uploads, ['$_eventsPath/e1/attachments']);
    expect(find.text('Neuer Termin'), findsNothing);
    await disposeApp(tester);
  });

  testWidgets('zu große Datei wird abgelehnt', (tester) async {
    final backend = FakeBackend();
    final original = EventEditScreen.pickFiles;
    addTearDown(() => EventEditScreen.pickFiles = original);
    EventEditScreen.pickFiles = () async => [PickedFile('riesig.bin', Uint8List(maxUploadBytes + 1))];
    await _openNewEvent(tester, backend);
    await _tapVisible(tester, find.text('Anhang hinzufügen'));
    expect(find.text('riesig.bin ist größer als 25 MB.'), findsOneWidget);
    expect(find.byTooltip('Anhang entfernen'), findsNothing);
    await disposeApp(tester);
  });

  group('bestehender Termin', () {
    Future<void> openExisting(
      WidgetTester tester,
      FakeBackend backend, [
      Map<String, Object?> extra = const {},
    ]) async {
      final now = DateTime.now().toUtc();
      final detail = _detail(extra);
      backend
        ..eventDetail = detail
        ..eventRows = [
          {...detail, 'start_at': now.toIso8601String(), 'end_at': now.add(const Duration(minutes: 1)).toIso8601String()},
        ];
      await pumpApp(tester, backend, MemoryTokens()..token = 't1');
      await tester.tap(find.text('Kalender'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Zahnarzt'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Bearbeiten'));
      await tester.pumpAndSettle();
    }

    group('Zurück', () {
      Future<void> goBack(WidgetTester tester) async {
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
      }

      final question = find.text('Änderungen verwerfen?');
      final newEvent = find.widgetWithText(AppBar, 'Neuer Termin');

      testWidgets('ohne Änderung geht es direkt zurück', (tester) async {
        await _openNewEvent(tester, FakeBackend());
        await goBack(tester);
        expect(question, findsNothing);
        expect(newEvent, findsNothing);
        await disposeApp(tester);
      });

      testWidgets('mit Änderung fragt es: weiter bearbeiten behält alles, verwerfen geht zurück', (tester) async {
        final backend = FakeBackend();
        await _openNewEvent(tester, backend);
        await tester.enterText(find.byKey(const Key('event-title')), 'Zahnarzt');
        await goBack(tester);
        expect(question, findsOneWidget);

        await tester.tap(find.text('Weiter bearbeiten'));
        await tester.pumpAndSettle();
        expect(question, findsNothing);
        expect(newEvent, findsOneWidget);
        expect(tester.widget<TextField>(find.byKey(const Key('event-title'))).controller!.text, 'Zahnarzt');

        await goBack(tester);
        await tester.tap(find.text('Verwerfen'));
        await tester.pumpAndSettle();
        expect(newEvent, findsNothing);
        expect(backend.writes, isEmpty);
        await disposeApp(tester);
      });

      testWidgets('was wieder zurückgenommen wurde, zählt nicht als Änderung', (tester) async {
        await _openNewEvent(tester, FakeBackend());
        await tester.enterText(find.byKey(const Key('event-title')), 'Zahnarzt');
        await tester.enterText(find.byKey(const Key('event-title')), '');
        await _tapVisible(tester, find.byKey(const Key('participant-u3')));
        await _tapVisible(tester, find.byKey(const Key('participant-all')));
        await goBack(tester);
        expect(question, findsNothing);
        expect(newEvent, findsNothing);
        await disposeApp(tester);
      });

      testWidgets('Speichern fragt nicht', (tester) async {
        final backend = FakeBackend();
        await _openNewEvent(tester, backend);
        await tester.enterText(find.byKey(const Key('event-title')), 'Zahnarzt');
        await _save(tester);
        expect(question, findsNothing);
        expect(newEvent, findsNothing);
        expect(backend.writes.keys, ['POST $_eventsPath']);
        await disposeApp(tester);
      });
    });

    const creator = {'created_by': 'u2', 'creator_name': 'Ben'};
    Finder creatorText(String name) => find.text('Ersteller: $name', findRichText: true);

    testWidgets('Manager ohne Admin-Flag übergibt den Termin auf eigener Seite, es gilt mit Speichern', (tester) async {
      final backend = FakeBackend()..isAdmin = false;
      await openExisting(tester, backend, creator);
      expect(creatorText('Ben'), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(const Key('event-creator'))).dy,
        greaterThan(tester.getTopLeft(find.text('Sichtbar für')).dy),
      );

      await _tapVisible(tester, find.byKey(const Key('event-creator')));
      expect(find.widgetWithText(AppBar, 'Ersteller ändern'), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('creator-u2')), matching: find.byIcon(Icons.check)), findsOneWidget);
      await tester.tap(find.byKey(const Key('creator-u1')));
      await tester.pumpAndSettle();

      expect(creatorText('Anna'), findsOneWidget);
      expect(backend.writes.keys, isEmpty);
      await _save(tester);
      expect(backend.writes.keys, ['PUT $_eventsPath/e1', 'PUT $_eventsPath/e1/creator']);
      expect(backend.writes['PUT $_eventsPath/e1/creator'], {'user_id': 'u1'});
      await disposeApp(tester);
    });

    testWidgets('derselbe Ersteller gewählt schickt nichts extra', (tester) async {
      final backend = FakeBackend();
      await openExisting(tester, backend, creator);
      await _tapVisible(tester, find.byKey(const Key('event-creator')));
      await tester.tap(find.byKey(const Key('creator-u2')));
      await tester.pumpAndSettle();
      await _save(tester);
      expect(backend.writes.keys, ['PUT $_eventsPath/e1']);
      await disposeApp(tester);
    });

    testWidgets('ohne Manager-Rolle steht der Ersteller nur da, auch für Admins', (tester) async {
      await openExisting(tester, FakeBackend()..role = 'user', creator);
      expect(creatorText('Ben'), findsOneWidget);
      await _tapVisible(tester, find.byKey(const Key('event-creator')));
      expect(find.text('Ersteller ändern'), findsNothing);
      await disposeApp(tester);
    });

    testWidgets('ein ausgetretener Ersteller heißt Unbekannt', (tester) async {
      await openExisting(tester, FakeBackend(), {'created_by': 'weg', 'creator_name': ''});
      expect(creatorText('Unbekannt'), findsOneWidget);
      await disposeApp(tester);
    });

    testWidgets('neuer Termin nennt einen selbst als Ersteller und schickt ohne Änderung nichts extra', (tester) async {
      final backend = FakeBackend();
      await _openNewEvent(tester, backend);
      expect(creatorText('Anna'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('event-title')), 'T');
      await _save(tester);
      expect(backend.writes.keys, ['POST $_eventsPath']);
      await disposeApp(tester);
    });

    testWidgets('beim Anlegen lässt sich der Termin gleich übergeben', (tester) async {
      final backend = FakeBackend()..isAdmin = false;
      await _openNewEvent(tester, backend);
      await tester.enterText(find.byKey(const Key('event-title')), 'T');
      await _tapVisible(tester, find.byKey(const Key('event-creator')));
      await tester.tap(find.byKey(const Key('creator-u3')));
      await tester.pumpAndSettle();
      expect(creatorText('Cara'), findsOneWidget);
      await _save(tester);
      expect(backend.writes.keys, ['POST $_eventsPath', 'PUT $_eventsPath/e1/creator']);
      expect(backend.writes['PUT $_eventsPath/e1/creator'], {'user_id': 'u3'});
      await disposeApp(tester);
    });

    testWidgets('beim Anlegen steht der Ersteller ohne Manager-Rolle nur da', (tester) async {
      final backend = FakeBackend()
        ..isAdmin = false
        ..role = 'user';
      await _openNewEvent(tester, backend);
      expect(creatorText('Anna'), findsOneWidget);
      await _tapVisible(tester, find.byKey(const Key('event-creator')));
      expect(find.text('Ersteller ändern'), findsNothing);
      await tester.enterText(find.byKey(const Key('event-title')), 'T');
      await _save(tester);
      expect(backend.writes.keys, ['POST $_eventsPath']);
      await disposeApp(tester);
    });

    testWidgets('zeigt die gespeicherte Zeit der Zeitzone und speichert unverändert', (tester) async {
      final backend = FakeBackend();
      await openExisting(tester, backend);
      expect(find.text('15:30'), findsOneWidget);
      expect(find.text('Nordamerikanische Ostküsten-Normalzeit GMT-05:00'), findsOneWidget);
      expect(find.text('15 Minuten vorher'), findsOneWidget);
      expect(find.text('30 Minuten vorher'), findsNothing);
      expect(find.text('Praxis'), findsOneWidget);
      expect(find.text('plan.pdf'), findsOneWidget);

      await _save(tester);
      final body = backend.writes['PUT $_eventsPath/e1'] as Map;
      expect(body['start_local'], '2026-01-05T15:30');
      expect(body['timezone'], 'America/New_York');
      expect(body['participants_all'], false);
      expect(body['participant_ids'], ['u2']);
      expect(body['visibility'], 'participants');
      expect(body['category_id'], 'k2');
      expect(body['reminders'], [15]);
      expect(body['location'], 'Praxis');
      await disposeApp(tester);
    });

    testWidgets('entfernter Anhang geht erst beim Speichern weg', (tester) async {
      final backend = FakeBackend();
      await openExisting(tester, backend);
      await _tapVisible(tester, find.byTooltip('Anhang entfernen'));
      expect(find.text('plan.pdf'), findsNothing);
      expect(backend.writes, isEmpty);
      await _save(tester);
      expect(backend.writes.keys, contains('DELETE $_eventsPath/e1/attachments/a1'));
      await disposeApp(tester);
    });

    testWidgets('die Kopfleiste hat die Farbe des Termins, einen Haken und kein Löschen', (tester) async {
      await openExisting(tester, FakeBackend(), {'color': '#D32F2F'});
      final bar = tester.widget<AppBar>(find.widgetWithText(AppBar, 'Termin').last);
      expect(bar.backgroundColor, parseHexColor('#D32F2F'));
      expect(bar.foregroundColor, Colors.white);
      expect(find.descendant(of: find.byType(AppBar).last, matching: find.byIcon(Icons.check)), findsOneWidget);
      expect(find.text('Speichern'), findsNothing);
      expect(find.byTooltip('Löschen'), findsNothing);
      await disposeApp(tester);
    });

    group('Kopfleiste folgt der Auswahl', () {
      Color? color(WidgetTester tester) => tester.widget<AppBar>(find.widgetWithText(AppBar, 'Neuer Termin')).backgroundColor;
      const calendar = '#BBDEFB';

      testWidgets('Mitglied, zweites Mitglied und Alle', (tester) async {
        final backend = FakeBackend();
        backend.members[1]['color'] = '#1565C0';
        await _openNewEvent(tester, backend);
        expect(color(tester), parseHexColor(calendar));
        expect(find.byTooltip('Speichern'), findsOneWidget);

        await _tapVisible(tester, find.byKey(const Key('participant-u2')));
        expect(color(tester), parseHexColor('#1565C0'));
        expect(tester.widget<AppBar>(find.widgetWithText(AppBar, 'Neuer Termin')).foregroundColor, Colors.white);

        // Only the one person the event is for gives it a color.
        await _tapVisible(tester, find.byKey(const Key('participant-u3')));
        expect(color(tester), parseHexColor(calendar));
        await _tapVisible(tester, find.byKey(const Key('participant-u3')));
        expect(color(tester), parseHexColor('#1565C0'));

        await _tapVisible(tester, find.byKey(const Key('participant-all')));
        expect(color(tester), parseHexColor(calendar));
        await disposeApp(tester);
      });

      testWidgets('ein Mitglied ohne Farbe ändert nichts', (tester) async {
        await _openNewEvent(tester, FakeBackend());
        await _tapVisible(tester, find.byKey(const Key('participant-u3')));
        expect(color(tester), parseHexColor(calendar));
        await disposeApp(tester);
      });

      testWidgets('die Kategorie geht vor, aber nur mit Farbe', (tester) async {
        final backend = FakeBackend();
        backend.members[1]['color'] = '#1565C0';
        backend.categories[0]['color'] = '';
        await _openNewEvent(tester, backend);
        await _tapVisible(tester, find.byKey(const Key('participant-u2')));

        await _tapVisible(tester, find.byKey(const Key('category-k2')));
        expect(color(tester), parseHexColor('#D32F2F'));

        await _tapVisible(tester, find.byKey(const Key('category-k1')));
        expect(color(tester), parseHexColor('#1565C0'));
        await disposeApp(tester);
      });

      testWidgets('auch beim Bearbeiten', (tester) async {
        final backend = FakeBackend();
        backend.members[2]['color'] = '#1565C0';
        await openExisting(tester, backend, {'category_id': null, 'participant_ids': ['u3']});
        AppBar bar() => tester.widget<AppBar>(find.widgetWithText(AppBar, 'Termin').last);
        expect(bar().backgroundColor, parseHexColor('#1565C0'));
        await _tapVisible(tester, find.byKey(const Key('category-k2')));
        expect(bar().backgroundColor, parseHexColor('#D32F2F'));
        await disposeApp(tester);
      });
    });

    testWidgets('Sichtbarkeit heißt beim Bearbeiten Teilnehmer und Ersteller, beim Anlegen Dich und Teilnehmer', (tester) async {
      await openExisting(tester, FakeBackend());
      expect(find.text('Teilnehmer und Ersteller'), findsOneWidget);
      expect(find.text('Dich und Teilnehmer'), findsNothing);
      await disposeApp(tester);

      await _openNewEvent(tester, FakeBackend());
      expect(find.text('Dich und Teilnehmer'), findsOneWidget);
      expect(find.text('Teilnehmer und Ersteller'), findsNothing);
      await disposeApp(tester);
    });

    testWidgets('Serie warnt im Menü, dass alle Termine verschwinden', (tester) async {
      await openExisting(tester, FakeBackend(), {
        'recurrence': {'freq': 'day', 'interval': 1},
      });
      expect(find.text('Täglich'), findsOneWidget);
      await tester.tap(find.byType(BackButton).last);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Mehr'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Löschen'));
      await tester.pumpAndSettle();
      expect(find.text('Alle Termine dieser Serie löschen?'), findsOneWidget);
      await disposeApp(tester);
    });
  });

  test('Beschriftungen von Erinnerung und Wiederholung', () {
    expect(reminderLabel(1), '1 Minute vorher');
    expect(reminderLabel(90), '90 Minuten vorher');
    expect(reminderLabel(60), '1 Stunde vorher');
    expect(reminderLabel(2880), '2 Tage vorher');
    expect(recurrenceLabel(null), 'Niemals');
    expect(recurrenceLabel({'freq': 'day', 'interval': 4}), 'Alle 4 Tage');
    expect(recurrenceLabel({'freq': 'week', 'interval': 1, 'weekdays': [1, 2, 3, 4, 5]}), 'Jeden Wochentag');
    expect(recurrenceLabel({'freq': 'week', 'interval': 2, 'weekdays': [3]}), 'Alle 2 Wochen am Mi');
    expect(recurrenceLabel({'freq': 'month', 'interval': 1, 'month_week': -1, 'month_weekday': 5}), 'Jeden Monat am letzten Freitag');
    expect(recurrenceLabel({'freq': 'year', 'interval': 1}), 'Jedes Jahr');
  });
}

Future<void> _openCalendar(WidgetTester tester, FakeBackend backend) async {
  await pumpApp(tester, backend, MemoryTokens()..token = 't1');
  await tester.tap(find.text('Kalender'));
  await tester.pumpAndSettle();
}

Future<void> _pickView(WidgetTester tester, String label) async {
  await tester.tap(find.byTooltip('Ansicht'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<void> _openManage(WidgetTester tester, FakeBackend backend) async {
  await _openCalendar(tester, backend);
  await tester.tap(find.byTooltip('Kalender verwalten'));
  await tester.pumpAndSettle();
}

/// Turns the mouse wheel over the weeks by about one month; a positive [months] goes on.
Future<void> _wheelMonth(WidgetTester tester, int months) async {
  final scroller = find.byType(WeekScroller);
  final pointer = TestPointer(1, PointerDeviceKind.mouse);
  await tester.sendEventToBinding(pointer.hover(tester.getCenter(scroller)));
  await tester.sendEventToBinding(pointer.scroll(Offset(0, months * tester.getSize(scroller).height / 6 * 4.4)));
  await tester.pumpAndSettle();
}

/// The calendar behind the panel stays in the tree and has a scrollable of its own.
Future<void> _scrollPanel(WidgetTester tester, Finder finder) =>
    tester.scrollUntilVisible(finder, 200, scrollable: find.descendant(of: find.byKey(const Key('calendar-panel')), matching: find.byType(Scrollable)).first);

Map<String, Object?> _entry(String title, DateTime start, {bool editable = true, String color = '#D32F2F', bool allDay = false}) {
  final end = start.add(const Duration(hours: 1));
  return {
    ..._detail({'title': title, 'id': 'e1'}),
    'start_at': start.toUtc().toIso8601String(),
    'end_at': end.toUtc().toIso8601String(),
    'start_local': _localText(start),
    'end_local': _localText(end),
    'all_day': allDay,
    'editable': editable,
    'color': color,
    'source_name': editable ? 'Müller' : 'Schulferien',
  };
}

String _localText(DateTime date) => date.toIso8601String().substring(0, 16);

void calendarTests() {
  group('Ansichten', () {
    testWidgets('Tagebuch ist Vorgabe, die Auswahl wird gespeichert', (tester) async {
      final backend = FakeBackend();
      await _openCalendar(tester, backend);
      expect(find.text('Keine Termine an diesem Tag.'), findsOneWidget);

      await tester.tap(find.byTooltip('Ansicht'));
      await tester.pumpAndSettle();
      for (final label in ['Tagebuch', 'Tag', '3 Tage', 'Woche', 'Monat']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      await tester.tap(find.text('Woche'));
      await tester.pumpAndSettle();

      expect(find.text('Keine Termine an diesem Tag.'), findsNothing);
      expect(find.byType(TimeGridView), findsOneWidget);
      expect((backend.writes['PUT /api/families/f1/calendar-prefs'] as Map)['view'], 'week');
      await disposeApp(tester);
    });

    testWidgets('gespeicherte Ansicht gilt beim nächsten Öffnen', (tester) async {
      final backend = FakeBackend();
      backend.calendarPrefs['view'] = 'month';
      await _openCalendar(tester, backend);
      expect(find.byType(MonthView), findsOneWidget);
      await disposeApp(tester);
    });

    for (final (label, columns) in [('Tag', 1), ('3 Tage', 3), ('Woche', 7)]) {
      testWidgets('$label zeigt $columns Spalten mit dem Termin', (tester) async {
        final backend = FakeBackend();
        final now = DateTime.now();
        backend.eventRows = [_entry('Zahnarzt', DateTime(now.year, now.month, now.day, 10))];
        await _openCalendar(tester, backend);
        await _pickView(tester, label);
        expect(tester.widget<TimeGridView>(find.byType(TimeGridView)).days, hasLength(columns));
        expect(find.text('Zahnarzt'), findsOneWidget);
        await disposeApp(tester);
      });
    }

    testWidgets('Monat zeigt Titel, Tag antippen öffnet die Tagesansicht', (tester) async {
      final backend = FakeBackend();
      final now = DateTime.now();
      backend.eventRows = [_entry('Zahnarzt', DateTime(now.year, now.month, now.day, 10))];
      await _openCalendar(tester, backend);
      await _pickView(tester, 'Monat');
      expect(find.text('Zahnarzt'), findsOneWidget);

      await tester.tap(find.byKey(ValueKey(DateTime(now.year, now.month, now.day))));
      await tester.pumpAndSettle();
      expect(find.byType(TimeGridView), findsOneWidget);
      await disposeApp(tester);
    });

      testWidgets('Monat: Scrollen wechselt ihn und lädt, der Titel wählt einen Tag', (tester) async {
      final backend = FakeBackend();
      backend.calendarPrefs['view'] = 'month';
      final now = DateTime.now();
      await _openCalendar(tester, backend);
      expect(find.byTooltip('Weiter'), findsNothing);
      // The months next to it are there before they come into view.
      final range = backend.ranges.last;
      expect(range.$1.isBefore(DateTime(now.year, now.month - 1, 2)), isTrue);
      expect(range.$2.isAfter(DateTime(now.year, now.month + 2)), isTrue);
      backend.ranges.clear();
      await _wheelMonth(tester, 1);
      expect(find.text(DateFormat('MMMM yyyy', 'de').format(DateTime(now.year, now.month + 1))), findsOneWidget);
      expect(backend.ranges, hasLength(1));
      await disposeApp(tester);
    });

    testWidgets('Tag und Woche behalten die Pfeile, weil Scrollen dort die Stunden bewegt', (tester) async {
      await _openCalendar(tester, FakeBackend());
      for (final view in ['Tag', '3 Tage', 'Woche']) {
        await _pickView(tester, view);
        expect(find.byTooltip('Weiter'), findsOneWidget, reason: view);
      }
      await disposeApp(tester);
    });

    testWidgets('Blättern fragt den neuen Bereich ab', (tester) async {
      final backend = FakeBackend();
      await _openCalendar(tester, backend);
      await _pickView(tester, 'Tag');
      backend.calls.clear();
      await tester.tap(find.byTooltip('Weiter'));
      await tester.pumpAndSettle();
      expect(backend.calls, ['/api/families/f1/calendar-entries']);
      await disposeApp(tester);
    });

    testWidgets('Wochennummer erscheint nur mit Einstellung und nicht im Tagebuch', (tester) async {
      final backend = FakeBackend();
      backend.calendarPrefs['week_numbers'] = true;
      await _openCalendar(tester, backend);
      expect(find.textContaining('KW'), findsNothing);
      await _pickView(tester, 'Tag');
      expect(find.text('KW ${isoWeekNumber(DateTime.now())}'), findsOneWidget);
      await disposeApp(tester);
    });

    testWidgets('Wochenbeginn Sonntag dreht die Kopfzeile', (tester) async {
      final backend = FakeBackend();
      backend.calendarPrefs['week_start'] = 'sunday';
      await _openCalendar(tester, backend);
      expect(tester.getTopLeft(find.text('So')).dx, lessThan(tester.getTopLeft(find.text('Mo')).dx));
      await disposeApp(tester);
    });

    group('Tagebuch', () {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      DateTime inDays(int days) => DateTime(today.year, today.month, today.day + days, 10);
      List<Map<String, Object?>> rows(Map<String, int> titles) => [
        for (final entry in titles.entries) {..._entry(entry.key, inDays(entry.value)), 'id': entry.key},
      ];
      double topOf(WidgetTester tester, Finder finder) => tester.getTopLeft(finder).dy;
      Finder list() => find.byType(CustomScrollView);

      testWidgets('startet beim heutigen Tag, frühere stehen darüber, spätere darunter', (tester) async {
        final backend = FakeBackend()..eventRows = rows({'Gestern': -1, 'Heute früh': 0, 'Morgen': 1});
        await _openCalendar(tester, backend);

        final top = tester.getTopLeft(list()).dy;
        expect(find.textContaining('Heute, '), findsOneWidget);
        expect(topOf(tester, find.textContaining('Heute, ')), closeTo(top + 16, 1));
        expect(find.text('Heute früh'), findsOneWidget);
        expect(find.text('Morgen'), findsOneWidget);
        expect(topOf(tester, find.text('Morgen')), greaterThan(topOf(tester, find.text('Heute früh'))));

        // Earlier days wait above the top of the list.
        await tester.drag(list(), const Offset(0, 300));
        await tester.pumpAndSettle();
        expect(find.text('Gestern'), findsOneWidget);
        expect(topOf(tester, find.text('Gestern')), lessThan(topOf(tester, find.text('Heute früh'))));
        await disposeApp(tester);
      });

      testWidgets('die Liste folgt dem angetippten Tag, ohne etwas nachzuladen', (tester) async {
        final target = inDays(3);
        final backend = FakeBackend()..eventRows = rows({'Später': 3});
        await _openCalendar(tester, backend);
        backend.ranges.clear();

        // The grid shows six weeks, so the day may only be on the next page.
        final cell = find.byKey(ValueKey(DateTime(target.year, target.month, target.day)));
        if (cell.evaluate().isEmpty) await _wheelMonth(tester, 1);
        await tester.tap(cell);
        await tester.pumpAndSettle();

        final top = tester.getTopLeft(list()).dy;
        expect(topOf(tester, find.textContaining(weekdayDateFormat.format(target))), closeTo(top + 16, 1));
        expect(backend.ranges, isEmpty);
        await disposeApp(tester);
      });

      testWidgets('der Monat folgt der Liste beim Scrollen, und Heute holt ihn zurück', (tester) async {
        final backend = FakeBackend()..eventRows = [
          for (var i = 0; i < 80; i++) {..._entry('Termin $i', inDays(i * 3)), 'id': 'e$i'},
        ];
        await _openCalendar(tester, backend);
        final thisMonth = DateFormat('MMMM yyyy', 'de').format(now);
        expect(find.text(thisMonth), findsOneWidget);

        for (var i = 0; i < 8; i++) {
          await tester.drag(list(), const Offset(0, -600));
          await tester.pumpAndSettle();
        }
        expect(find.text(thisMonth), findsNothing);
        // The top of the list and the month above it tell the same date.
        final top = tester.getTopLeft(list()).dy;
        final day = (tester.widgetList<Text>(find.descendant(of: list(), matching: find.byType(Text))).map((text) => text.data ?? ''))
            .firstWhere((text) => text.contains(', ') && text.contains('.'));
        expect(tester.getTopLeft(find.text(day)).dy, lessThan(top + 200));
        final month = tester.widgetList<Text>(find.byType(Text)).map((text) => text.data ?? '').firstWhere((text) => RegExp(r'^\p{L}+ \d{4}$', unicode: true).hasMatch(text));
        expect(day, contains(month.split(' ').first));

        await tester.tap(find.byKey(const Key('calendar-today')));
        await tester.pumpAndSettle();
        expect(find.text(thisMonth), findsOneWidget);
        expect(find.textContaining('Heute, '), findsOneWidget);
        await disposeApp(tester);
      });

      testWidgets('am Anfang der Liste zeigt der Monat den ersten Tag', (tester) async {
        final backend = FakeBackend()..eventRows = rows({'Lange her': -70});
        await _openCalendar(tester, backend);
        await tester.drag(list(), const Offset(0, 3000));
        await tester.pumpAndSettle();
        expect(find.text('Lange her'), findsOneWidget);
        expect(find.text(DateFormat('MMMM yyyy', 'de').format(inDays(-70))), findsOneWidget);
        await disposeApp(tester);
      });

      testWidgets('Wochen laufen frei und rasten nicht ein, der Titel folgt der Mitte, ohne Pfeile', (tester) async {
        await _openCalendar(tester, FakeBackend());
        String month(int delta) => DateFormat('MMMM yyyy', 'de').format(DateTime(now.year, now.month + delta));
        expect(find.byIcon(Icons.chevron_right), findsNothing);
        expect(find.byIcon(Icons.chevron_left), findsNothing);
        expect(find.text(month(0)), findsOneWidget);

        await _wheelMonth(tester, 1);
        expect(find.text(month(1)), findsOneWidget);
        await _wheelMonth(tester, -2);
        expect(find.text(month(-1)), findsOneWidget);
        await _wheelMonth(tester, 1);
        expect(find.text(month(0)), findsOneWidget);

        // It stays where it is let go, between two weeks and with the next month in view.
        final scroller = find.byType(WeekScroller);
        final top = tester.getTopLeft(scroller).dy;
        await tester.drag(scroller, const Offset(0, -130));
        await tester.pumpAndSettle();
        final firstOfNext = find.byKey(ValueKey(DateTime(now.year, now.month + 1, 1)));
        final y = tester.getTopLeft(firstOfNext).dy - top;
        expect(y % 40, isNot(closeTo(0, 0.5)), reason: 'kein Einrasten');
        expect(y, lessThan(tester.getSize(scroller).height));
        expect(find.byKey(ValueKey(DateTime(now.year, now.month, 15))), findsOneWidget);

        // Momentum carries on, and the title still follows.
        await tester.fling(scroller, const Offset(0, -150), 2000);
        await tester.pumpAndSettle();
        expect(find.text(month(0)), findsNothing);
        await disposeApp(tester);
      });

      testWidgets('Tag von außen zieht die Wochen mit, danach folgt der Titel wieder dem Scrollen', (tester) async {
        final backend = FakeBackend();
        await _openCalendar(tester, backend);
        for (var i = 0; i < 3; i++) {
          await _wheelMonth(tester, 1);
        }
        await tester.tap(find.byKey(const Key('calendar-today')));
        await tester.pumpAndSettle();
        final thisMonth = DateFormat('MMMM yyyy', 'de').format(now);
        expect(find.text(thisMonth), findsOneWidget);
        expect(find.byKey(ValueKey(DateTime(now.year, now.month, now.day))), findsOneWidget);

        await _wheelMonth(tester, 1);
        expect(find.text(DateFormat('MMMM yyyy', 'de').format(DateTime(now.year, now.month + 1))), findsOneWidget);
        await disposeApp(tester);
      });

      testWidgets('Klick auf den Titel wählt einen Tag, die Liste geht dorthin', (tester) async {
        final backend = FakeBackend();
        await _openCalendar(tester, backend);
        await tester.tap(find.byKey(const Key('calendar-title')));
        await tester.pumpAndSettle();
        expect(find.text('Tag auswählen'), findsWidgets);
        final day = now.day == 15 ? 16 : 15;
        await tester.tap(find.descendant(of: find.byType(DatePickerDialog), matching: find.text('$day')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        final target = DateTime(now.year, now.month, day);
        expect(find.textContaining(weekdayDateFormat.format(target)), findsOneWidget);
        expect(topOf(tester, find.textContaining(weekdayDateFormat.format(target))), closeTo(tester.getTopLeft(list()).dy + 16, 1));
        await disposeApp(tester);
      });

      testWidgets('wenige Termine pro Monat: ein Monatswechsel lädt nicht Jahre im Voraus', (tester) async {
        final backend = FakeBackend()..eventRows = [
          for (var i = 0; i < 200; i++) {..._entry('Selten $i', inDays(i * 40)), 'id': 's$i'},
        ];
        await _openCalendar(tester, backend);
        final opened = backend.ranges.length;
        await _wheelMonth(tester, 1);
        await _wheelMonth(tester, 1);
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        expect(backend.ranges.length - opened, lessThanOrEqualTo(3));
        await disposeApp(tester);
      });

      testWidgets('Einträge sind in ihrer Farbe gefärbt, mit lesbarem Text und ohne Punkt in der Liste', (tester) async {
        final backend = FakeBackend()..eventRows = [
          {..._entry('Dunkel', inDays(0), color: '#1565C0'), 'id': 'd'},
          {..._entry('Hell', inDays(1), color: '#FDD835'), 'id': 'h'},
        ];
        await _openCalendar(tester, backend);
        for (final (title, color, text) in [('Dunkel', '#1565C0', Colors.white), ('Hell', '#FDD835', Colors.black)]) {
          final tile = find.widgetWithText(ListTile, title);
          expect(tester.widget<ListTile>(tile).textColor, text, reason: title);
          // On a surface of its own, or tiles scrolled out of the list would show over the month.
          expect(tester.widget<ListTile>(tile).tileColor, isNull, reason: title);
          final surface = tester.widget<Material>(find.ancestor(of: tile, matching: find.byType(Material)).first);
          expect(surface.color, parseHexColor(color), reason: title);
        }
        expect(find.descendant(of: list(), matching: find.byType(EventDot)), findsNothing);
        // The month above still marks its days.
        expect(find.descendant(of: find.byType(WeekScroller), matching: find.byType(EventDot)), findsWidgets);
        await disposeApp(tester);
      });

      testWidgets('die Uhrzeit steht neben der Farbe und öffnet den Termin genauso', (tester) async {
        final backend = FakeBackend()..eventRows = [
          {..._entry('Termin', inDays(0), editable: false, color: '#1565C0'), 'id': 't'},
        ];
        await _openCalendar(tester, backend);

        final time = find.descendant(of: list(), matching: find.text(timeFormat.format(inDays(0))));
        final tile = find.widgetWithText(ListTile, 'Termin');
        expect(find.descendant(of: tile, matching: find.byWidget(tester.widget(time))), findsNothing);
        expect(tester.getTopRight(time).dx, lessThanOrEqualTo(tester.getTopLeft(tile).dx));

        await tester.tap(time);
        await tester.pumpAndSettle();
        expect(find.widgetWithText(AppBar, 'Termin'), findsOneWidget);
        await disposeApp(tester);
      });

      testWidgets('ein großer Sprung in der Liste nimmt die Wochen mit', (tester) async {
        final far = DateTime(now.year, now.month - 7, 12);
        final backend = FakeBackend()..eventRows = [
          {..._entry('Weit zurück', DateTime(far.year, far.month, far.day, 9)), 'id': 'far'},
          {..._entry('Danach', DateTime(far.year, far.month + 1, 20, 9)), 'id': 'then'},
        ];
        await _openCalendar(tester, backend);
        final title = DateFormat('MMMM yyyy', 'de').format(far);

        final pointer = TestPointer(1, PointerDeviceKind.mouse);
        await tester.sendEventToBinding(pointer.hover(tester.getCenter(list())));
        await tester.sendEventToBinding(pointer.scroll(const Offset(0, -500)));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pumpAndSettle();

        expect(find.text(title), findsOneWidget, reason: 'Titel');
        final cell = find.byKey(ValueKey(DateTime(far.year, far.month, far.day)));
        expect(cell, findsOneWidget, reason: 'die Woche ist im Raster');
        final box = tester.getRect(find.byType(WeekScroller));
        expect(box.contains(tester.getCenter(cell)), isTrue, reason: 'und sichtbar');
        await disposeApp(tester);
      });

      testWidgets('Tage anderer Jahre nennen das Jahr', (tester) async {
        final backend = FakeBackend()..eventRows = rows({'Nächstes Jahr': DateTime(now.year + 1, 1, 15).difference(today).inDays});
        await _openCalendar(tester, backend);
        final next = DateTime(now.year + 1, 1, 15);
        await tester.scrollUntilVisible(find.text('Nächstes Jahr'), 300, scrollable: find.descendant(of: list(), matching: find.byType(Scrollable)).first);
        expect(find.text('${weekdayDateFormat.format(next)} ${now.year + 1}'), findsOneWidget);
        expect(find.textContaining('Heute, ${weekdayDateFormat.format(today)}'), findsAny);
        await disposeApp(tester);
      });

      testWidgets('lädt beim Scrollen nach und findet Termine außerhalb des ersten Bereichs', (tester) async {
        final backend = FakeBackend()..eventRows = [
          for (var i = 0; i < 80; i++) {..._entry('Termin $i', inDays(i * 3)), 'id': 'e$i'},
          {..._entry('Weit weg', inDays(320)), 'id': 'far'},
        ];
        await _openCalendar(tester, backend);
        final firstRange = backend.ranges.first;
        expect(firstRange.$2.difference(firstRange.$1).inDays, lessThan(370));
        expect(firstRange.$1.isBefore(today), isTrue);
        expect(firstRange.$2.isAfter(today), isTrue);

        await tester.scrollUntilVisible(find.text('Weit weg'), 400, scrollable: find.descendant(of: list(), matching: find.byType(Scrollable)).first);
        await tester.pumpAndSettle();
        expect(find.text('Weit weg'), findsOneWidget);
        expect(backend.ranges.length, greaterThan(1));
        await disposeApp(tester);
      });

      testWidgets('leerer Kalender hört auf zu laden, und „Weiter suchen“ schaut weiter', (tester) async {
        final backend = FakeBackend();
        await _openCalendar(tester, backend);
        final loaded = backend.ranges.length;
        expect(loaded, lessThanOrEqualTo(5));
        await tester.pump(const Duration(seconds: 1));
        expect(backend.ranges.length, loaded);

        expect(find.textContaining('Keine weiteren Termine bis'), findsOneWidget);
        await tester.tap(find.text('Weiter suchen').last);
        await tester.pumpAndSettle();
        expect(backend.ranges.length, greaterThan(loaded));
        await disposeApp(tester);
      });

      testWidgets('lange Termine stehen einmal, der Starttag der Liste nennt sie trotzdem', (tester) async {
        final begin = DateTime(today.year, today.month, today.day - 2);
        final end = DateTime(today.year, today.month, today.day + 5, 23, 59);
        final backend = FakeBackend()..eventRows = [
          {
            ..._entry('Ferien', begin, allDay: true, editable: false),
            'end_at': end.toUtc().toIso8601String(),
            'end_local': _localText(end),
          },
          {..._entry('Später', inDays(1)), 'id': 'later'},
        ];
        await _openCalendar(tester, backend);
        expect(find.text('Ferien'), findsOneWidget);
        expect(find.textContaining('bis ${dateFormat.format(end)}'), findsOneWidget);

        // Once more at the day it starts on, above the start of the list.
        await tester.drag(list(), const Offset(0, 400));
        await tester.pumpAndSettle();
        expect(find.text('Ferien'), findsNWidgets(2));
        await disposeApp(tester);
      });

      testWidgets('neuer Termin nach dem Bearbeiten lädt den ganzen Bereich neu', (tester) async {
        final backend = FakeBackend()..eventRows = rows({'Morgen': 1});
        await _openCalendar(tester, backend);
        backend.ranges.clear();
        await tester.tap(find.byKey(const Key('calendar-add')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const Key('event-title')), 'T');
        await _save(tester);
        await tester.pumpAndSettle();
        expect(backend.ranges, isNotEmpty);
        expect(find.text('Morgen'), findsOneWidget);
        await disposeApp(tester);
      });

      testWidgets('Heute springt zurück, auch aus einem anderen Bereich', (tester) async {
        final backend = FakeBackend()..eventRows = rows({'Heute früh': 0});
        await _openCalendar(tester, backend);
        for (var i = 0; i < 12; i++) {
          await _wheelMonth(tester, 1);
        }
        expect(find.text('Heute früh'), findsNothing);
        await tester.tap(find.byKey(const Key('calendar-today')));
        await tester.pumpAndSettle();
        expect(find.text('Heute früh'), findsOneWidget);
        await disposeApp(tester);
      });
    });

    group('Fußleiste', () {
      final now = DateTime.now();
      DateTime at(int hour) => DateTime(now.year, now.month, now.day, hour);
      List<Map<String, Object?>> rows() => [
        {..._entry('Für alle', at(8)), 'id': 'a', 'source': 'family', 'participants_all': true, 'participant_ids': <String>[]},
        {..._entry('Nur Ben', at(9)), 'id': 'b', 'source': 'family', 'participants_all': false, 'participant_ids': ['u2']},
        {..._entry('Nur Cara', at(10)), 'id': 'c', 'source': 'family', 'participants_all': false, 'participant_ids': ['u3']},
        {..._entry('Ferien', at(11)), 'id': 'd', 'source': 'school', 'participants_all': false},
      ];
      Future<void> openFilter(WidgetTester tester) async {
        await tester.tap(find.byKey(const Key('calendar-members')));
        await tester.pumpAndSettle();
      }
      Future<void> toggle(WidgetTester tester, String name) async {
        await tester.tap(find.widgetWithText(CheckboxListTile, name));
        await tester.pumpAndSettle();
      }
      Future<void> back(WidgetTester tester) async {
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
      }

      testWidgets('hat Heute, Hinzufügen und Mitgliederfilter in jeder Ansicht', (tester) async {
        await _openCalendar(tester, FakeBackend());
        for (final view in ['Tagebuch', 'Tag', 'Monat']) {
          await _pickView(tester, view);
          expect(find.descendant(of: find.byType(BottomAppBar), matching: find.byType(Text)), findsNWidgets(3));
          for (final label in ['Hinzufügen', 'Mitgliederfilter']) {
            expect(find.text(label), findsOneWidget, reason: '$view: $label');
          }
          expect(find.byType(FloatingActionButton), findsNothing);
        }
        expect(find.byTooltip('Heute'), findsNothing);
        await disposeApp(tester);
      });

      testWidgets('Filter zeigt nur Termine der Gewählten und blendet andere Kalender aus', (tester) async {
        final backend = FakeBackend()..eventRows = rows();
        await _openCalendar(tester, backend);
        for (final title in ['Für alle', 'Nur Ben', 'Nur Cara', 'Ferien']) {
          expect(find.text(title), findsOneWidget, reason: title);
        }
        expect(find.descendant(of: find.byKey(const Key('calendar-members')), matching: find.text('3')), findsNothing);

        await openFilter(tester);
        expect(find.widgetWithText(AppBar, 'Mitgliederfilter'), findsOneWidget);
        await toggle(tester, 'Anna');
        await toggle(tester, 'Cara');
        await back(tester);

        expect(find.text('Für alle'), findsOneWidget);
        expect(find.text('Nur Ben'), findsOneWidget);
        expect(find.text('Nur Cara'), findsNothing);
        expect(find.text('Ferien'), findsNothing);
        expect(find.descendant(of: find.byKey(const Key('calendar-members')), matching: find.text('1')), findsOneWidget);

        // It holds in the other views and asks the backend for nothing new.
        await _pickView(tester, 'Tag');
        expect(find.text('Nur Ben'), findsOneWidget);
        expect(find.text('Nur Cara'), findsNothing);
        expect(find.text('Ferien'), findsNothing);
        await _pickView(tester, 'Monat');
        expect(find.text('Nur Cara'), findsNothing);
        expect(find.text('Ferien'), findsNothing);
        await disposeApp(tester);
      });

      testWidgets('niemand gewählt lässt nur gemeinsame Termine, alle hebt den Filter auf', (tester) async {
        final backend = FakeBackend()..eventRows = rows();
        await _openCalendar(tester, backend);
        await openFilter(tester);
        await tester.tap(find.byKey(const Key('members-all')));
        await tester.pumpAndSettle();
        await back(tester);
        expect(find.text('Nur Ben'), findsNothing);
        expect(find.text('Nur Cara'), findsNothing);
        expect(find.text('Ferien'), findsNothing);
        expect(find.text('Für alle'), findsOneWidget);

        await openFilter(tester);
        await tester.tap(find.byKey(const Key('members-all')));
        await tester.pumpAndSettle();
        await back(tester);
        expect(find.text('Nur Ben'), findsOneWidget);
        expect(find.text('Ferien'), findsOneWidget);
        expect(find.descendant(of: find.byKey(const Key('calendar-members')), matching: find.byType(Text)), findsOneWidget);
        await disposeApp(tester);
      });

      testWidgets('Manager können alle Einträge anzeigen und bearbeiten, die Mitglieder verschwinden dabei', (tester) async {
        final backend = FakeBackend()
          ..isAdmin = false
          ..eventRows = rows()
          ..eventDetail = _detail({'title': 'Geheim'})
          ..hiddenEventRows = [
            {..._entry('Geheim', at(12)), 'id': 'e1', 'source': 'family', 'participants_all': false, 'participant_ids': ['u2']},
          ];
        await _openCalendar(tester, backend);
        expect(find.text('Geheim'), findsNothing);

        await openFilter(tester);
        await toggle(tester, 'Cara');
        await tester.tap(find.byKey(const Key('show-all-entries')));
        await tester.pumpAndSettle();
        expect(find.widgetWithText(CheckboxListTile, 'Ben'), findsNothing);
        expect(find.byKey(const Key('members-all')), findsNothing);
        await back(tester);

        // It replaces the member filter instead of adding to it.
        for (final title in ['Geheim', 'Nur Cara', 'Ferien']) {
          expect(find.text(title), findsOneWidget, reason: title);
        }
        expect(find.descendant(of: find.byKey(const Key('calendar-members')), matching: find.text('Alle')), findsOneWidget);

        // What is hidden otherwise opens like any other event.
        await tester.tap(find.text('Geheim'));
        await tester.pumpAndSettle();
        expect(find.byTooltip('Bearbeiten'), findsOneWidget);
        await back(tester);

        await openFilter(tester);
        await tester.tap(find.byKey(const Key('show-all-entries')));
        await tester.pumpAndSettle();
        expect(find.widgetWithText(CheckboxListTile, 'Ben'), findsOneWidget);
        await back(tester);
        expect(find.text('Geheim'), findsNothing);
        await disposeApp(tester);
      });

      for (final (type, heading, other) in [
        ('family', 'Nur für Eltern', 'Nur für Manager'),
        ('workgroup', 'Nur für Manager', 'Nur für Eltern'),
      ]) {
        testWidgets('„Alle Einträge anzeigen“ steht zuerst unter „$heading“ beim Typ $type', (tester) async {
          final backend = FakeBackend()..familyType = type;
          await _openCalendar(tester, backend);
          await openFilter(tester);
          expect(find.text(heading), findsOneWidget);
          expect(find.text(other), findsNothing);
          expect(find.textContaining('Nur bei Bedarf aktivieren'), findsOneWidget);

          final list = find.descendant(of: find.byType(ListView), matching: find.byType(Text));
          expect(tester.widget<Text>(list.first).data, heading);
          expect(
            tester.getBottomLeft(find.byKey(const Key('show-all-entries'))).dy,
            lessThanOrEqualTo(tester.getTopLeft(find.byKey(const Key('members-all'))).dy),
          );

          // Without the members it stays reachable, to switch it off again.
          await tester.tap(find.byKey(const Key('show-all-entries')));
          await tester.pumpAndSettle();
          expect(find.text(heading), findsOneWidget);
          expect(tester.widget<SwitchListTile>(find.byKey(const Key('show-all-entries'))).value, isTrue);
          await disposeApp(tester);
        });
      }

      testWidgets('ohne Manager-Rolle fehlt der Bereich ganz, auch für Admins', (tester) async {
        final backend = FakeBackend()..role = 'user';
        await _openCalendar(tester, backend);
        await openFilter(tester);
        expect(find.byKey(const Key('show-all-entries')), findsNothing);
        expect(find.text('Nur für Eltern'), findsNothing);
        expect(find.text('Nur für Manager'), findsNothing);
        expect(find.textContaining('Nur bei Bedarf'), findsNothing);
        expect(find.byKey(const Key('members-all')), findsOneWidget);
        await disposeApp(tester);
      });

      testWidgets('ein Filter, der eine endlose Serie versteckt, lädt nicht endlos nach', (tester) async {
        final backend = FakeBackend()..eventRows = [
          for (var i = 0; i < 400; i++)
            {..._entry('Serie', DateTime(now.year, now.month, now.day + i * 3, 9)), 'id': 'd$i', 'source': 'family', 'participants_all': false, 'participant_ids': ['u2']},
        ];
        await _openCalendar(tester, backend);
        await openFilter(tester);
        await toggle(tester, 'Ben');
        await back(tester);
        final loaded = backend.ranges.length;
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        expect(backend.ranges.length, loaded);
        expect(find.textContaining('Keine weiteren Termine bis'), findsOneWidget);
        await disposeApp(tester);
      });
    });

    testWidgets('Termine anderer Kalender lassen sich nur lesen', (tester) async {
      final backend = FakeBackend();
      final now = DateTime.now();
      backend.eventRows = [
        {..._entry('Herbstferien', DateTime(now.year, now.month, now.day), editable: false, allDay: true), 'source': 'school'},
      ];
      await _openCalendar(tester, backend);
      await tester.tap(find.text('Herbstferien'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.widgetWithText(AppBar, 'Termin'), findsOneWidget);
      expect(find.text('Schulferien'), findsOneWidget);
      expect(find.textContaining('ganztägig'), findsOneWidget);
      // Neither editing nor comments or participants: nothing of that exists here.
      expect(find.byTooltip('Bearbeiten'), findsNothing);
      expect(find.byKey(const Key('event-comment')), findsNothing);
      expect(find.byIcon(Icons.people_outline), findsNothing);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('Herbstferien'), findsOneWidget);
      await disposeApp(tester);
    });

    group('Menü anderer Kalender', () {
      final now = DateTime.now();
      final start = DateTime(now.year, now.month, now.day, 9);
      Future<FakeBackend> open(WidgetTester tester, [Map<String, Object?> extra = const {}]) async {
        final backend = FakeBackend()
          ..eventRows = [
            {
              ..._entry('Probe', start, editable: false),
              'source': 'feed:x',
              'timezone': 'Europe/Berlin',
              'visibility': null,
              'description': '',
              'location': 'Halle',
              ...extra,
            },
          ];
        await _openCalendar(tester, backend);
        await tester.tap(find.text('Probe'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Mehr'));
        await tester.pumpAndSettle();
        return backend;
      }

      testWidgets('hat nur Duplikat und Teilen', (tester) async {
        await open(tester);
        expect(find.text('Duplikat'), findsOneWidget);
        expect(find.text('Teilen'), findsOneWidget);
        for (final item in ['In mehrere Termine kopieren', 'In anderen Kreis kopieren', 'Löschen']) {
          expect(find.text(item), findsNothing, reason: item);
        }
        await disposeApp(tester);
      });

      testWidgets('Duplikat legt erst mit Speichern einen Termin im Standardkalender an', (tester) async {
        final backend = await open(tester);
        await tester.tap(find.text('Duplikat'));
        await tester.pumpAndSettle();
        expect(find.byType(DatePickerDialog), findsOneWidget);
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        expect(find.widgetWithText(AppBar, 'Neuer Termin'), findsOneWidget);
        expect(backend.writes, isEmpty);

        await _save(tester);
        expect(backend.writes.keys, ['POST $_eventsPath']);
        final body = backend.writes['POST $_eventsPath'] as Map;
        expect(body['title'], 'Probe');
        expect(body['location'], 'Halle');
        expect(body['start_local'], _localText(start));
        expect(body['end_local'], _localText(start.add(const Duration(hours: 1))));
        expect(body['timezone'], 'Europe/Berlin');
        expect(body['participants_all'], true);
        expect(body['visibility'], 'all');
        expect(body['reminders'], isEmpty);
        expect(body['category_id'], '');
        expect(find.text('Termin dupliziert'), findsOneWidget);
        await disposeApp(tester);
      });

      testWidgets('ein Duplikat ohne Speichern legt nichts an', (tester) async {
        final backend = await open(tester);
        await tester.tap(find.text('Duplikat'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Abbrechen'));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(find.text('Änderungen verwerfen?'), findsNothing);
        expect(backend.writes, isEmpty);
        await disposeApp(tester);
      });

      testWidgets('was privat war, bleibt beim Duplikat privat', (tester) async {
        final backend = await open(tester, {'visibility': 'participants'});
        await tester.tap(find.text('Duplikat'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        await _save(tester);
        final body = backend.writes['POST $_eventsPath'] as Map;
        expect(body['visibility'], 'participants');
        expect(body['participants_all'], false);
        expect(body['participant_ids'], ['u1']);
        await disposeApp(tester);
      });

      testWidgets('Teilen gibt diesen Termin als ICS-Datei weiter', (tester) async {
        final shared = <(String, String)>[];
        final original = EventDetailScreen.shareFile;
        EventDetailScreen.shareFile = (name, content) async => shared.add((name, content));
        addTearDown(() => EventDetailScreen.shareFile = original);
        final backend = await open(tester);
        await tester.tap(find.text('Teilen'));
        await tester.pumpAndSettle();
        expect(shared, [('termin.ics', 'BEGIN:VCALENDAR')]);
        final body = backend.writes['POST /api/families/f1/calendar-entries/ics'] as Map;
        expect(body['title'], 'Probe');
        expect(body['all_day'], false);
        expect(body['start_at'], start.toUtc().toIso8601String());
        await disposeApp(tester);
      });
    });

    group('Seite Termin', () {
      final now = DateTime.now();
      final start = DateTime(now.year, now.month, now.day, 9);
      Map<String, Object?> row([Map<String, Object?> extra = const {}]) => {
        ..._entry('Zahnarzt', start, color: '#1565C0'),
        'id': 'e1',
        'source': 'family',
        ...extra,
      };
      Future<FakeBackend> open(WidgetTester tester, [Map<String, Object?> extra = const {}]) async {
        final backend = FakeBackend()
          ..eventRows = [row(extra)]
          ..eventDetail = {...row(extra), 'participant_ids': ['u2', 'u3'], 'participants_all': false};
        await _openCalendar(tester, backend);
        await tester.tap(find.text('Zahnarzt'));
        await tester.pumpAndSettle();
        return backend;
      }
      Future<void> menu(WidgetTester tester, String item) async {
        await tester.tap(find.byTooltip('Mehr'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(item));
        await tester.pumpAndSettle();
      }

      testWidgets('zeigt alles in einer Karte, die Kopfleiste trägt die Farbe des Termins', (tester) async {
        await open(tester, {
          'updated_at': start.toUtc().toIso8601String(),
          'updated_by_name': 'Ben',
        });
        expect(find.widgetWithText(AppBar, 'Termin'), findsOneWidget);
        expect(find.byType(BackButton), findsOneWidget);
        expect(find.byTooltip('Bearbeiten'), findsOneWidget);

        final bar = tester.widget<AppBar>(find.widgetWithText(AppBar, 'Termin'));
        expect(bar.backgroundColor, parseHexColor('#1565C0'));
        expect(bar.foregroundColor, Colors.white);
        final title = tester.widget<Text>(find.text('Zahnarzt'));
        expect(title.style?.color, isNot(Colors.white));
        expect(title.style?.fontWeight, FontWeight.bold);

        final day = dateFormat.format(start);
        expect(find.text('$day, 09:00 – 10:00'), findsOneWidget);
        expect(find.text('Ben, Cara'), findsOneWidget);
        expect(find.text('Müller'), findsOneWidget);
        expect(find.text('Standardkalender'), findsOneWidget);
        expect(find.text('15 Minuten vorher'), findsOneWidget);
        expect(find.text('Zuletzt geändert am $day um 09:00 von Ben'), findsOneWidget);
        await disposeApp(tester);
      });

      testWidgets('zeigt den Ersteller nach der Erinnerung', (tester) async {
        await open(tester, {'creator_name': 'Ben', 'location': 'Praxis'});
        double top(String text) => tester.getTopLeft(find.text(text)).dy;
        expect(top('Ersteller: Ben'), greaterThan(top('15 Minuten vorher')));
        expect(top('Ersteller: Ben'), lessThan(top('Praxis')));
        await disposeApp(tester);
      });

      testWidgets('ohne Ersteller bleibt die Zeile weg', (tester) async {
        await open(tester, {'creator_name': ''});
        expect(find.textContaining('Ersteller:'), findsNothing);
        await disposeApp(tester);
      });

      testWidgets('Termine anderer lassen sich nicht ändern, aber ansehen, kommentieren und kopieren', (tester) async {
        final backend = await open(tester, {'editable': false});
        expect(find.byTooltip('Bearbeiten'), findsNothing);
        // Everything else on the page stays, unlike for other calendars.
        expect(find.text('Ben, Cara'), findsOneWidget);
        expect(find.text('15 Minuten vorher'), findsOneWidget);
        expect(find.byKey(const Key('event-comment')), findsOneWidget);

        await tester.tap(find.byTooltip('Mehr'));
        await tester.pumpAndSettle();
        expect(find.text('Duplikat'), findsOneWidget);
        expect(find.text('In mehrere Termine kopieren'), findsOneWidget);
        expect(find.text('Teilen'), findsOneWidget);
        expect(find.text('Löschen'), findsNothing);
        await tester.tap(find.text('Teilen'));
        await tester.pumpAndSettle();
        // Shared as the event it is, not as a loose entry of another calendar.
        expect(backend.calls, contains('$_eventsPath/e1/ics'));
        await disposeApp(tester);
      });

      testWidgets('Kommentare stehen unten und lassen sich schreiben', (tester) async {
        final backend = await open(tester, {
          'comments': [
            {'id': 'k1', 'body': 'Schon erledigt', 'author_name': 'Ben', 'created_at': start.toUtc().toIso8601String()},
          ],
        });
        expect(find.text('Schon erledigt'), findsOneWidget);
        expect(find.textContaining('Ben · '), findsOneWidget);

        // Nothing goes out without text.
        await tester.tap(find.byTooltip('Kommentar senden'));
        await tester.pumpAndSettle();
        expect(backend.writes, isEmpty);

        await tester.enterText(find.byKey(const Key('event-comment')), ' Danke ');
        await tester.tap(find.byTooltip('Kommentar senden'));
        await tester.pumpAndSettle();
        expect(backend.writes['POST $_eventsPath/e1/comments'], {'body': 'Danke'});
        expect(tester.widget<TextField>(find.byKey(const Key('event-comment'))).controller!.text, isEmpty);
        await disposeApp(tester);
      });

      testWidgets('die Kommentarzeile bleibt fest unten, auch bei vielen Kommentaren', (tester) async {
        await open(tester, {
          'comments': [
            for (var i = 0; i < 60; i++)
              {'id': 'k$i', 'body': 'Kommentar $i', 'author_name': 'Ben', 'created_at': start.toUtc().toIso8601String()},
          ],
        });
        final height = tester.getSize(find.byType(Scaffold).last).height;
        final field = find.byKey(const Key('event-comment'));
        expect(tester.getBottomLeft(field).dy, closeTo(height - 8, 1));

        await tester.drag(find.byType(ListView), const Offset(0, -800));
        await tester.pumpAndSettle();
        expect(tester.getBottomLeft(field).dy, closeTo(height - 8, 1));
        await disposeApp(tester);
      });

      testWidgets('Umschalt + Enter schickt den Kommentar ab, Enter allein nicht', (tester) async {
        final backend = await open(tester);
        await tester.tap(find.byKey(const Key('event-comment')));
        await tester.pump();
        await tester.enterText(find.byKey(const Key('event-comment')), 'Danke');

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(backend.writes, isEmpty);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pumpAndSettle();
        expect(backend.writes['POST $_eventsPath/e1/comments'], {'body': 'Danke'});
        expect(tester.widget<TextField>(find.byKey(const Key('event-comment'))).controller!.text, isEmpty);
        await disposeApp(tester);
      });

      testWidgets('Duplikat fragt nach dem Tag und legt erst mit Speichern einen neuen Eintrag an', (tester) async {
        final backend = await open(tester);
        final loads = backend.ranges.length;
        await menu(tester, 'Duplikat');
        expect(find.byType(DatePickerDialog), findsOneWidget);
        expect(find.widgetWithText(AppBar, 'Neuer Termin'), findsOneWidget);

        final day = now.day == 15 ? 16 : 15;
        await tester.tap(find.descendant(of: find.byType(DatePickerDialog), matching: find.text('$day')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        expect(backend.writes, isEmpty);

        // A form to start from, without what stays with the original.
        expect(tester.widget<TextField>(find.byKey(const Key('event-title'))).controller!.text, 'Zahnarzt');
        expect(find.byTooltip('Löschen'), findsNothing);
        expect(find.text('plan.pdf'), findsNothing);

        await _save(tester);
        expect(backend.writes.keys, ['POST $_eventsPath']);
        final body = backend.writes['POST $_eventsPath'] as Map;
        expect(body['title'], 'Zahnarzt');
        expect(body['start_local'], _localText(DateTime(start.year, start.month, day, 9)));
        expect(body['end_local'], _localText(DateTime(start.year, start.month, day, 10)));
        expect(body['reminders'], [15]);
        expect(find.text('Termin dupliziert'), findsOneWidget);
        expect(backend.ranges.length, greaterThan(loads));
        // Back on the page of the original.
        expect(find.widgetWithText(AppBar, 'Termin'), findsOneWidget);
        await disposeApp(tester);
      });

      testWidgets('Duplikat ohne Speichern legt nichts an', (tester) async {
        final backend = await open(tester);
        await menu(tester, 'Duplikat');
        // Without a day the form starts with the one of the original.
        await tester.tap(find.text('Abbrechen'));
        await tester.pumpAndSettle();
        expect(find.widgetWithText(AppBar, 'Neuer Termin'), findsOneWidget);
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(backend.writes, isEmpty);
        expect(find.text('Termin dupliziert'), findsNothing);
        expect(find.widgetWithText(AppBar, 'Termin'), findsOneWidget);
        await disposeApp(tester);
      });

      testWidgets('In mehrere Termine kopieren wählt bis zu 10 Tage', (tester) async {
        final backend = await open(tester);
        await menu(tester, 'In mehrere Termine kopieren');
        expect(find.widgetWithText(FilledButton, 'Kopieren'), findsOneWidget);
        expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Kopieren')).onPressed, isNull);

        final first = startOfWeek(DateTime(start.year, start.month), DateTime.monday);
        Finder day(int index) => find.byKey(Key('copy-day-${dateKey(DateTime(first.year, first.month, first.day + index))}'));
        for (var i = 0; i < 11; i++) {
          await tester.tap(day(i));
          await tester.pump();
        }
        expect(find.text('10 von 10 Tagen gewählt'), findsOneWidget);

        // Taking one back counts as well.
        await tester.tap(day(0));
        await tester.pump();
        expect(find.text('9 von 10 Tagen gewählt'), findsOneWidget);
        await tester.tap(find.widgetWithText(FilledButton, 'Kopieren'));
        await tester.pumpAndSettle();

        final days = (backend.writes['POST $_eventsPath/e1/copy'] as Map)['days'] as List;
        expect(days.length, 9);
        expect(days.first, dateKey(DateTime(first.year, first.month, first.day + 1)));
        expect(find.text('9 Termine kopiert'), findsOneWidget);
        await disposeApp(tester);
      });

      testWidgets('Abbrechen beim Kopieren schickt nichts', (tester) async {
        final backend = await open(tester);
        await menu(tester, 'In mehrere Termine kopieren');
        await tester.tap(find.text('Abbrechen'));
        await tester.pumpAndSettle();
        expect(backend.writes, isEmpty);
        await disposeApp(tester);
      });

      testWidgets('In anderen Kreis kopieren gibt es nur mit einem anderen Kreis', (tester) async {
        await open(tester);
        await tester.tap(find.byTooltip('Mehr'));
        await tester.pumpAndSettle();
        expect(find.text('In anderen Kreis kopieren'), findsNothing);
        for (final item in ['Duplikat', 'In mehrere Termine kopieren', 'Teilen', 'Löschen']) {
          expect(find.text(item), findsOneWidget, reason: item);
        }
        await disposeApp(tester);
      });

      testWidgets('In anderen Kreis kopieren fragt nach dem Kreis', (tester) async {
        final backend = FakeBackend()
          ..extraFamilies = [
            {'id': 'f2', 'name': 'Freunde', 'type': 'friends', 'role': 'user', 'is_admin': false, 'color': ''},
          ]
          ..eventRows = [row()]
          ..eventDetail = row();
        await _openCalendar(tester, backend);
        await tester.tap(find.text('Zahnarzt'));
        await tester.pumpAndSettle();
        await menu(tester, 'In anderen Kreis kopieren');
        await tester.tap(find.byKey(const Key('copy-family-f2')));
        await tester.pumpAndSettle();
        expect(backend.writes['POST $_eventsPath/e1/copy'], {'family_id': 'f2'});
        expect(find.text('In „Freunde“ kopiert'), findsOneWidget);
        await disposeApp(tester);
      });

      testWidgets('Teilen gibt die ICS-Datei weiter', (tester) async {
        final shared = <(String, String)>[];
        final original = EventDetailScreen.shareFile;
        EventDetailScreen.shareFile = (name, content) async => shared.add((name, content));
        addTearDown(() => EventDetailScreen.shareFile = original);
        await open(tester);
        await menu(tester, 'Teilen');
        expect(shared, [('termin.ics', 'BEGIN:VCALENDAR')]);
        await disposeApp(tester);
      });

      testWidgets('Löschen fragt nach und geht zurück in den Kalender', (tester) async {
        final backend = await open(tester);
        await menu(tester, 'Löschen');
        expect(find.text('Termin löschen?'), findsOneWidget);
        expect(backend.writes, isEmpty);
        await tester.tap(find.widgetWithText(FilledButton, 'Löschen'));
        await tester.pumpAndSettle();
        expect(backend.writes.keys, ['DELETE $_eventsPath/e1']);
        expect(find.widgetWithText(AppBar, 'Termin'), findsNothing);
        await disposeApp(tester);
      });

      testWidgets('nach dem Bearbeiten zeigt die Seite den neuen Stand', (tester) async {
        final backend = await open(tester);
        await tester.tap(find.byTooltip('Bearbeiten'));
        await tester.pumpAndSettle();
        backend
          ..eventRows = [row({'title': 'Kieferorthopäde', 'color': '#FDD835'})]
          ..eventDetail = row({'title': 'Kieferorthopäde'});
        await _save(tester);
        expect(find.widgetWithText(AppBar, 'Termin'), findsOneWidget);
        expect(find.text('Kieferorthopäde'), findsOneWidget);
        final bar = tester.widget<AppBar>(find.widgetWithText(AppBar, 'Termin'));
        expect(bar.backgroundColor, parseHexColor('#FDD835'));
        expect(bar.foregroundColor, Colors.black);
        await disposeApp(tester);
      });

      testWidgets('ein Termin, der nicht mehr an seinem Tag liegt, führt zurück in den Kalender', (tester) async {
        final backend = await open(tester);
        await tester.tap(find.byTooltip('Bearbeiten'));
        await tester.pumpAndSettle();
        backend.eventRows = [];
        await _save(tester);
        expect(find.widgetWithText(AppBar, 'Termin'), findsNothing);
        await disposeApp(tester);
      });
    });
  });

  group('Wochen', () {
    Future<void> pumpWeeks(WidgetTester tester, DateTime selected, List<DateTime> reports) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 240,
            child: WeekScroller(
              selected: selected,
              firstWeekday: DateTime.monday,
              onDay: reports.add,
              builder: (context, weekStart, month) => Text('${weekStart.year}-${weekStart.month}-${weekStart.day}', key: ValueKey(weekStart)),
            ),
          ),
        ),
      ),
    );

    // The very first change must count, before anything else has been read.
    testWidgets('folgen schon der allerersten Änderung von außen', (tester) async {
      final reports = <DateTime>[];
      await pumpWeeks(tester, DateTime(2026, 11, 4), reports);
      expect(find.byKey(ValueKey(DateTime(2026, 11, 2))), findsOneWidget);

      await pumpWeeks(tester, DateTime(2026, 4, 6), reports);
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey(DateTime(2026, 4, 6))), findsOneWidget);
      expect(find.byKey(ValueKey(DateTime(2026, 11, 2))), findsNothing);
      expect(reports, isEmpty, reason: 'was von außen kommt, wird nicht zurückgemeldet');
      await disposeApp(tester);
    });

    testWidgets('melden den Monat in der Mitte und folgen später demselben Tag von außen', (tester) async {
      final reports = <DateTime>[];
      await pumpWeeks(tester, DateTime(2026, 11, 4), reports);
      await tester.drag(find.byType(WeekScroller), const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(reports, [DateTime(2026, 12, 1)]);

      // Away from the day it reported, then back to exactly that one.
      await pumpWeeks(tester, DateTime(2026, 11, 4), reports);
      await tester.pumpAndSettle();
      await pumpWeeks(tester, DateTime(2027, 6, 1), reports);
      await tester.pumpAndSettle();
      await pumpWeeks(tester, DateTime(2026, 12, 1), reports);
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey(DateTime(2026, 11, 30))), findsOneWidget);
      await disposeApp(tester);
    });
  });

  test('Kalenderwochen und Wochenanfang', () {
    expect(isoWeekNumber(DateTime(2026, 1, 1)), 1);
    expect(isoWeekNumber(DateTime(2027, 1, 1)), 53);
    expect(isoWeekNumber(DateTime(2024, 12, 30)), 1);
    expect(isoWeekNumber(DateTime(2026, 11, 3)), 45);
    expect(startOfWeek(DateTime(2026, 11, 3), DateTime.monday), DateTime(2026, 11, 2));
    expect(startOfWeek(DateTime(2026, 11, 3), DateTime.sunday), DateTime(2026, 11, 1));
    expect(startOfWeek(DateTime(2026, 11, 1), DateTime.sunday), DateTime(2026, 11, 1));
    expect(orderedWeekdays(DateTime.sunday).first, 'So');
  });

  test('überlappende Termine teilen sich die Breite', () {
    CalendarEntry at(int hour, int minutes) => CalendarEntry(_entry('T', DateTime(2026, 3, 10, hour, minutes)));
    final placed = layoutDay([at(9, 0), at(9, 30), at(14, 0)], DateTime(2026, 3, 10));
    expect(placed.map((item) => item.lanes), [2, 2, 1]);
    expect(placed.map((item) => item.lane), [0, 1, 0]);
    expect(placed.first.startMinute, 540);

    // Anything of a day or longer belongs above the hours.
    final long = CalendarEntry({..._entry('T', DateTime(2026, 3, 10, 12)), 'end_at': DateTime(2026, 3, 13, 12).toUtc().toIso8601String()});
    expect(long.spansDays, isTrue);
    expect(layoutDay([long], DateTime(2026, 3, 11)), isEmpty);

    // A timed event across midnight is cut off at the day.
    final late = CalendarEntry(_entry('T', DateTime(2026, 3, 10, 23, 30)));
    expect(layoutDay([late], DateTime(2026, 3, 10)).single.endMinute, 1440);
    expect(layoutDay([late], DateTime(2026, 3, 11)).single.startMinute, 0);
  });

  group('Kalender verwalten', () {
    testWidgets('zeigt Kalender, Verbindungen und Einstellungen', (tester) async {
      await _openManage(tester, FakeBackend());
      for (final text in ['Meine Kalender', 'Müller', 'Standardkalender', 'Geplante Aufgaben', 'Schulferien', 'Kalender verbinden']) {
        expect(find.text(text), findsOneWidget, reason: text);
      }
      await _scrollPanel(tester, find.text('Kalenderbereinigung'));
      for (final text in ['Google', 'Outlook', 'Kalender-URL', 'Ereignisse aus ICS importieren', 'Einstellungen', 'Wochennummer anzeigen', 'Wochenbeginn', 'Standard-Erinnerung']) {
        expect(find.text(text), findsOneWidget, reason: text);
      }
      // The countries belong to the holiday calendar.
      expect(find.text('Gesetzliche Feiertage'), findsNothing);
      expect(find.byKey(const Key('holiday-countries')), findsNothing);
      // What comes later cannot be tapped yet.
      expect(tester.widget<ListTile>(find.widgetWithText(ListTile, 'Google')).enabled, isFalse);
      expect(tester.widget<ListTile>(find.widgetWithText(ListTile, 'Outlook')).enabled, isFalse);
      await disposeApp(tester);
    });

    // Pages are centered at 960, so on a wide window the right edge is that of the page.
    for (final (width, panel, right) in [(1000.0, 420.0, 980.0), (360.0, 316.8, 360.0)]) {
      testWidgets('gleitet bei Breite $width von rechts herein und lässt den Kalender sichtbar', (tester) async {
        await _openCalendar(tester, FakeBackend());
        tester.view.physicalSize = Size(width, 800);
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Kalender verwalten'));
        await tester.pumpAndSettle();

        final box = tester.getRect(find.byKey(const Key('calendar-panel')));
        expect(box.width, closeTo(panel, 0.01));
        expect(box.right, right);

        // The calendar behind it stays in place and is back after closing.
        await tester.tap(find.byType(CloseButton));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('calendar-panel')), findsNothing);
        expect(find.byTooltip('Kalender verwalten'), findsOneWidget);

        await tester.tap(find.byTooltip('Kalender verwalten'));
        await tester.pumpAndSettle();
        await tester.tapAt(Offset(box.left - 10, 400));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('calendar-panel')), findsNothing);
        await disposeApp(tester);
      });
    }

    testWidgets('Wochenbeginn kürzt die Tage auf dem Handy und speichert weiter', (tester) async {
      final backend = FakeBackend();
      await _openCalendar(tester, backend);
      tester.view.physicalSize = const Size(360, 800);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Kalender verwalten'));
      await tester.pumpAndSettle();
      await _scrollPanel(tester, find.byKey(const Key('week-start')));

      expect(find.text('Montag'), findsNothing);
      await tester.tap(find.descendant(of: find.byKey(const Key('week-start')), matching: find.text('So')));
      await tester.pumpAndSettle();
      expect((backend.writes['PUT /api/families/f1/calendar-prefs'] as Map)['week_start'], 'sunday');
      await disposeApp(tester);
    });

    testWidgets('Haken schaltet einen Kalender ab und lässt die Farbe des Kreises in Ruhe', (tester) async {
      final backend = FakeBackend();
      await _openManage(tester, backend);
      await tester.tap(find.descendant(of: find.byKey(const Key('calendar-tasks')), matching: find.byType(Checkbox)));
      await tester.pumpAndSettle();
      expect(backend.writes['PUT /api/families/f1/calendars/tasks'], {'enabled': false, 'regions': <String>[]});
      await disposeApp(tester);
    });

    group('Farbe ohne Rolle Manager', () {
      testWidgets('lässt sich nur ansehen, Bundesländer bleiben wählbar', (tester) async {
        final backend = FakeBackend()..role = 'user';
        await _openManage(tester, backend);
        await tester.tap(find.text('Schulferien'));
        await tester.pumpAndSettle();
        expect(find.byType(ColorChooser), findsNothing);
        expect(find.text('Die Farbe gilt für alle im Kreis. Ändern können sie nur Eltern.'), findsOneWidget);

        await tester.tap(find.byKey(const Key('school-states')));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(CheckboxListTile, 'Hessen'));
        await tester.pumpAndSettle();
        expect(backend.writes['PUT /api/families/f1/calendars/school'], {'enabled': true, 'regions': ['DE-HE']});
        await disposeApp(tester);
      });

      testWidgets('auch Admin-Rechte ändern daran nichts', (tester) async {
        final backend = FakeBackend()
          ..role = 'user'
          ..isAdmin = true;
        await _openManage(tester, backend);
        await tester.tap(find.text('Geplante Aufgaben'));
        await tester.pumpAndSettle();
        expect(find.byType(ColorChooser), findsNothing);
        await disposeApp(tester);
      });

      testWidgets('bei einem eigenen Kalender per URL bleibt sie wählbar', (tester) async {
        final backend = FakeBackend()..role = 'user';
        backend.calendars.add({
          'key': 'feed:x', 'kind': 'feed', 'name': 'Abfall', 'subtitle': 'Kalender-URL', 'enabled': true,
          'color': '#00897B', 'color_shared': false, 'shareable': false, 'url': 'https://example.de/a.ics',
        });
        await _openManage(tester, backend);
        await tester.tap(find.text('Abfall'));
        await tester.pumpAndSettle();
        expect(find.byType(ColorChooser), findsOneWidget);
        expect(find.textContaining('gilt für alle'), findsNothing);
        await disposeApp(tester);
      });
    });

    testWidgets('Manager erfahren, dass die Farbe für alle gilt', (tester) async {
      await _openManage(tester, FakeBackend());
      await tester.tap(find.text('Geplante Aufgaben'));
      await tester.pumpAndSettle();
      expect(find.text('Die Farbe gilt für alle im Kreis.'), findsOneWidget);
      expect(find.byType(ColorChooser), findsOneWidget);
      await disposeApp(tester);
    });

    testWidgets('Farbe: eine Liste ohne Überschriften, die eigenen Farben am Ende', (tester) async {
      final backend = FakeBackend();
      await _openManage(tester, backend);
      await tester.tap(find.text('Geplante Aufgaben'));
      await tester.pumpAndSettle();
      expect(find.text('Stammfarben'), findsNothing);
      expect(find.text('Eigene Farben'), findsNothing);
      expect(find.byTooltip('Keine Farbe'), findsNothing);
      final order = tester
          .widgetList<Tooltip>(find.descendant(of: find.byType(ColorChooser), matching: find.byType(Tooltip)))
          .map((tooltip) => tooltip.message)
          .toList();
      expect(order.first, baseColors.first.$2);
      expect(order.indexOf('Nebel'), greaterThan(order.indexOf(baseColors.last.$2)));

      await tester.tap(find.byTooltip('Gelb'));
      await tester.pumpAndSettle();
      expect((backend.writes['PUT /api/families/f1/calendars/tasks'] as Map)['color'], '#FDD835');

      await tester.ensureVisible(find.byTooltip('Nebel'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Nebel'));
      await tester.pumpAndSettle();
      expect((backend.writes['PUT /api/families/f1/calendars/tasks'] as Map)['color'], isNot('#FDD835'));
      await disposeApp(tester);
    });

    testWidgets('Schulferien: Bundesländer wählen', (tester) async {
      final backend = FakeBackend();
      await _openManage(tester, backend);
      await tester.tap(find.text('Schulferien'));
      await tester.pumpAndSettle();
      // A point of its own, like the countries of the holidays.
      expect(find.byType(CheckboxListTile), findsNothing);
      expect(find.text('Kein Bundesland ausgewählt'), findsOneWidget);
      await tester.tap(find.byKey(const Key('school-states')));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Bundesländer'), findsOneWidget);
      await tester.tap(find.widgetWithText(CheckboxListTile, 'Hessen'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(CheckboxListTile, 'Bayern'));
      await tester.pumpAndSettle();
      expect((backend.writes['PUT /api/families/f1/calendars/school'] as Map)['regions'], ['DE-BY', 'DE-HE']);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('Bayern, Hessen'), findsOneWidget);
      await disposeApp(tester);
    });

    testWidgets('Schulferien: fehlgeschlagenes Speichern nimmt den Haken zurück', (tester) async {
      final backend = FakeBackend()..rejectCalendars = true;
      await _openManage(tester, backend);
      await tester.tap(find.text('Schulferien'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('school-states')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(CheckboxListTile, 'Hessen'));
      await tester.pumpAndSettle();
      expect(tester.widget<CheckboxListTile>(find.widgetWithText(CheckboxListTile, 'Hessen')).value, isFalse);
      await disposeApp(tester);
    });

    testWidgets('Bundesländer und Länder stehen an erster Stelle, vor der Farbe', (tester) async {
      await _openManage(tester, FakeBackend());
      for (final (name, heading) in [('Schulferien', 'Bundesländer'), ('Feiertage', 'Länder')]) {
        await tester.tap(find.text(name));
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(find.text(heading)).dy, lessThan(tester.getTopLeft(find.text('Farbe')).dy));
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
      }
      await disposeApp(tester);
    });

    testWidgets('die Freigabe steht auch bei Schulferien und Feiertagen', (tester) async {
      final backend = FakeBackend();
      await _openManage(tester, backend);
      for (final name in ['Schulferien', 'Feiertage']) {
        await tester.tap(find.text(name));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.text('Link erstellen'), 200);
        expect(find.text('Kalenderfreigabe'), findsOneWidget);
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
      }
      await disposeApp(tester);
    });

    group('Rolle Kind', () {
      testWidgets('schaltet Kalender nur an und aus, ihre Seiten öffnen sich nicht', (tester) async {
        final backend = FakeBackend()..role = 'restrict_user';
        await _openManage(tester, backend);
        for (final key in ['calendar-family', 'calendar-tasks']) {
          expect(find.descendant(of: find.byKey(Key(key)), matching: find.byIcon(Icons.chevron_right)), findsNothing);
        }
        await tester.tap(find.text('Geplante Aufgaben'));
        await tester.pumpAndSettle();
        expect(find.text('Farbe'), findsNothing);
        expect(find.byKey(const Key('calendar-tasks')), findsOneWidget);

        await tester.tap(find.descendant(of: find.byKey(const Key('calendar-tasks')), matching: find.byType(Checkbox)));
        await tester.pumpAndSettle();
        expect(backend.writes['PUT /api/families/f1/calendars/tasks'], {'enabled': false, 'regions': <String>[]});
        await disposeApp(tester);
      });

      testWidgets('wählt bei den Schulferien die Bundesländer, aber nicht die Farbe', (tester) async {
        final backend = FakeBackend()..role = 'restrict_user';
        await _openManage(tester, backend);
        expect(find.descendant(of: find.byKey(const Key('calendar-school')), matching: find.byIcon(Icons.chevron_right)), findsOneWidget);
        await tester.tap(find.text('Schulferien'));
        await tester.pumpAndSettle();
        expect(find.text('Farbe'), findsNothing);
        expect(find.byType(ColorChooser), findsNothing);
        expect(find.textContaining('gilt für alle'), findsNothing);
        // The holidays say nothing about the family, so they can be shared.
        expect(find.text('Kalenderfreigabe'), findsOneWidget);

        await tester.tap(find.byKey(const Key('school-states')));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(CheckboxListTile, 'Hessen'));
        await tester.pumpAndSettle();
        expect(backend.writes['PUT /api/families/f1/calendars/school'], {'enabled': true, 'regions': ['DE-HE']});
        await disposeApp(tester);
      });

      testWidgets('kann keinen Kalender per Adresse einbinden', (tester) async {
        await _openManage(tester, FakeBackend()..role = 'restrict_user');
        expect(find.text('Kalender-URL'), findsNothing);
        await disposeApp(tester);
      });

      testWidgets('andere Rollen öffnen die Seiten wie bisher', (tester) async {
        await _openManage(tester, FakeBackend()..role = 'user');
        expect(find.text('Kalender-URL'), findsOneWidget);
        await tester.tap(find.text('Geplante Aufgaben'));
        await tester.pumpAndSettle();
        expect(find.text('Farbe'), findsOneWidget);
        await disposeApp(tester);
      });
    });

    testWidgets('Freigabe ist ausgeblendet, wenn das Backend sie nicht anbietet', (tester) async {
      final backend = FakeBackend()..role = 'user';
      backend.calendars[0]['shareable'] = false;
      await _openManage(tester, backend);
      await tester.tap(find.text('Müller'));
      await tester.pumpAndSettle();
      expect(find.text('Farbe'), findsOneWidget);
      expect(find.text('Kalenderfreigabe'), findsNothing);
      expect(find.text('Link erstellen'), findsNothing);
      await disposeApp(tester);
    });

    testWidgets('Freigabe: Link erstellen, dann kopieren, senden und löschen', (tester) async {
      final backend = FakeBackend();
      await _openManage(tester, backend);
      await tester.tap(find.text('Müller'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Link erstellen'), 200);

      expect(find.byTooltip('Link kopieren'), findsNothing);
      await tester.tap(find.text('Link erstellen'));
      await tester.pumpAndSettle();
      expect(find.text('http://test/cal/abc.ics'), findsOneWidget);
      expect(find.byTooltip('Link kopieren'), findsOneWidget);
      expect(find.byTooltip('Link senden'), findsOneWidget);

      await tester.tap(find.byTooltip('Link löschen'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Löschen'));
      await tester.pumpAndSettle();
      expect(backend.writes.keys, contains('DELETE /api/families/f1/calendars/family/share'));
      expect(find.text('Link erstellen'), findsOneWidget);
      await disposeApp(tester);
    });

    testWidgets('Kalender ohne Freigabe bieten keine an', (tester) async {
      final backend = FakeBackend();
      backend.calendars.add({
        'key': 'feed:x', 'kind': 'feed', 'name': 'Abfall', 'subtitle': 'Kalender-URL', 'enabled': true,
        'color': '#00897B', 'color_shared': false, 'shareable': false, 'url': 'https://example.de/a.ics',
      });
      await _openManage(tester, backend);
      await tester.tap(find.text('Abfall'));
      await tester.pumpAndSettle();
      expect(find.text('Kalenderfreigabe'), findsNothing);
      await disposeApp(tester);
    });

    testWidgets('Kalender-URL hinzufügen', (tester) async {
      final backend = FakeBackend();
      await _openManage(tester, backend);
      await _scrollPanel(tester, find.text('Kalender-URL'));
      await tester.tap(find.text('Kalender-URL'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Kalender-URL'), findsOneWidget);
      expect(find.byType(BackButton), findsOneWidget);
      FilledButton add() => tester.widget(find.widgetWithText(FilledButton, 'Hinzufügen'));
      expect(add().onPressed, isNull);

      await tester.enterText(find.byKey(const Key('feed-name')), 'Verein');
      await tester.enterText(find.byKey(const Key('feed-url')), 'webcal://example.de/a.ics');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hinzufügen'));
      await tester.pumpAndSettle();
      expect(backend.writes['POST /api/families/f1/calendar-feeds'], {'name': 'Verein', 'url': 'webcal://example.de/a.ics'});
      expect(find.byKey(const Key('feed-name')), findsNothing);
      expect(find.byKey(const Key('calendar-panel')), findsOneWidget);
      await disposeApp(tester);
    });

    testWidgets('abgelehnte Kalender-URL bleibt zum Korrigieren stehen und meldet sich', (tester) async {
      final backend = FakeBackend()..rejectFeeds = true;
      await _openManage(tester, backend);
      await _scrollPanel(tester, find.text('Kalender-URL'));
      await tester.tap(find.text('Kalender-URL'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('feed-name')), 'Verein');
      await tester.enterText(find.byKey(const Key('feed-url')), 'https://example.de/falsch');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hinzufügen'));
      await tester.pumpAndSettle();
      expect(find.text('Unter dieser Adresse wurde kein Kalender gefunden.'), findsOneWidget);
      expect(find.text('https://example.de/falsch'), findsOneWidget);
      await disposeApp(tester);
    });

    for (final (events, message) in [
      (0, 'Aktualisiert, der Kalender enthält keine Termine.'),
      (1, 'Aktualisiert, der Kalender enthält 1 Termin.'),
      (5, 'Aktualisiert, der Kalender enthält 5 Termine.'),
      (null, 'Der Kalender konnte nicht geladen werden.'),
    ]) {
      testWidgets('Kalender-URL jetzt aktualisieren meldet: $message', (tester) async {
        final backend = FakeBackend()..feedEvents = events;
        backend.calendars.add({
          'key': 'feed:x', 'kind': 'feed', 'name': 'Abfall', 'subtitle': 'Kalender-URL', 'enabled': true,
          'color': '#00897B', 'shareable': false, 'url': 'https://example.de/a.ics',
        });
        await _openManage(tester, backend);
        await tester.tap(find.text('Abfall'));
        await tester.pumpAndSettle();
        // The selectable address brings a scrollable of its own.
        await tester.scrollUntilVisible(find.text('Jetzt aktualisieren'), 200, scrollable: find.byType(Scrollable).first);
        await tester.tap(find.text('Jetzt aktualisieren'));
        await tester.pumpAndSettle();
        expect(find.text(message), findsOneWidget);
        await disposeApp(tester);
      });
    }

    testWidgets('Einstellungen werden gespeichert', (tester) async {
      final backend = FakeBackend();
      await _openManage(tester, backend);
      const prefsPath = 'PUT /api/families/f1/calendar-prefs';

      // These two change right in the panel.
      await _scrollPanel(tester, find.byKey(const Key('week-numbers')));
      await tester.tap(find.byKey(const Key('week-numbers')));
      await tester.pumpAndSettle();
      expect((backend.writes[prefsPath] as Map)['week_numbers'], true);
      expect(find.byKey(const Key('calendar-panel')), findsOneWidget);

      await _scrollPanel(tester, find.text('Sonntag'));
      await tester.tap(find.text('Sonntag'));
      await tester.pumpAndSettle();
      expect((backend.writes[prefsPath] as Map)['week_start'], 'sunday');
      expect(find.byKey(const Key('calendar-panel')), findsOneWidget);

      await _scrollPanel(tester, find.byKey(const Key('default-reminder')));
      expect(find.text('Keine Erinnerung'), findsOneWidget);
      await tester.tap(find.byKey(const Key('default-reminder')));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Standard-Erinnerung'), findsOneWidget);
      expect(find.byType(BackButton), findsOneWidget);
      await tester.tap(find.text('30 Minuten vorher'));
      await tester.pumpAndSettle();
      expect((backend.writes[prefsPath] as Map)['default_reminder'], 30);
      expect(find.byKey(const Key('calendar-panel')), findsOneWidget);
      expect(find.widgetWithText(AppBar, 'Standard-Erinnerung'), findsNothing);
      await disposeApp(tester);
    });

    testWidgets('Feiertage: fehlgeschlagenes Speichern nimmt den Haken zurück und meldet sich', (tester) async {
      final backend = FakeBackend()..rejectPrefs = true;
      await _openManage(tester, backend);
      await tester.tap(find.text('Feiertage'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('holiday-countries')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(CheckboxListTile, 'Österreich'));
      await tester.pumpAndSettle();
      expect(tester.widget<CheckboxListTile>(find.widgetWithText(CheckboxListTile, 'Österreich')).value, isFalse);
      expect(find.text('Speichern fehlgeschlagen'), findsOneWidget);
      await disposeApp(tester);
    });

    group('Feiertage: Länder', () {
      const prefsPath = 'PUT /api/families/f1/calendar-prefs';

      Future<void> openCountries(WidgetTester tester) async {
        await tester.tap(find.text('Feiertage'));
        await tester.pumpAndSettle();
        expect(find.text('Länder'), findsOneWidget);
        expect(find.text('Deutschland'), findsOneWidget);
        await tester.tap(find.byKey(const Key('holiday-countries')));
        await tester.pumpAndSettle();
        expect(find.widgetWithText(AppBar, 'Gesetzliche Feiertage'), findsOneWidget);
      }

      testWidgets('werden auf der Seite des Kalenders gewählt und gelten sofort', (tester) async {
        final backend = FakeBackend();
        await _openManage(tester, backend);
        await openCountries(tester);
        await tester.tap(find.widgetWithText(CheckboxListTile, 'Österreich'));
        await tester.pumpAndSettle();
        expect((backend.writes[prefsPath] as Map)['holiday_countries'], ['AT', 'DE']);

        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(find.text('Deutschland, Österreich'), findsOneWidget);
        await disposeApp(tester);
      });

      testWidgets('auch die Rolle Kind kommt dorthin, ohne Farbe', (tester) async {
        final backend = FakeBackend()..role = 'restrict_user';
        await _openManage(tester, backend);
        expect(find.descendant(of: find.byKey(const Key('calendar-holidays')), matching: find.byIcon(Icons.chevron_right)), findsOneWidget);
        await tester.tap(find.text('Feiertage'));
        await tester.pumpAndSettle();
        expect(find.text('Farbe'), findsNothing);
        expect(find.byType(ColorChooser), findsNothing);
        await tester.tap(find.byKey(const Key('holiday-countries')));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(CheckboxListTile, 'Österreich'));
        await tester.pumpAndSettle();
        expect((backend.writes[prefsPath] as Map)['holiday_countries'], ['AT', 'DE']);
        await disposeApp(tester);
      });

      testWidgets('alle abwählen lässt den Kalender stehen und sagt, dass kein Land gewählt ist', (tester) async {
        final backend = FakeBackend();
        await _openManage(tester, backend);
        await openCountries(tester);
        await tester.tap(find.widgetWithText(CheckboxListTile, 'Deutschland'));
        await tester.pumpAndSettle();
        expect((backend.writes[prefsPath] as Map)['holiday_countries'], <String>[]);
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(find.text('Länder'), findsOneWidget);
        expect(find.text('Kein Land ausgewählt'), findsOneWidget);
        // Everything else of the calendar stays, with the link that may exist.
        expect(find.text('Farbe'), findsOneWidget);
        await tester.scrollUntilVisible(find.text('Kalenderfreigabe'), 200);
        expect(find.text('Kalenderfreigabe'), findsOneWidget);
        await disposeApp(tester);
      });

      testWidgets('ohne Land steht der Kalender in der Liste und führt zur Auswahl, auch für die Rolle Kind', (tester) async {
        final backend = FakeBackend()..role = 'restrict_user';
        backend.calendars.firstWhere((calendar) => calendar['kind'] == 'holidays')['subtitle'] = 'Kein Land ausgewählt';
        backend.calendarPrefs['holiday_countries'] = <String>[];
        await _openManage(tester, backend);
        expect(find.descendant(of: find.byKey(const Key('calendar-holidays')), matching: find.text('Kein Land ausgewählt')), findsOneWidget);
        await tester.tap(find.text('Feiertage'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('holiday-countries')));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(CheckboxListTile, 'Deutschland'));
        await tester.pumpAndSettle();
        expect((backend.writes[prefsPath] as Map)['holiday_countries'], ['DE']);
        await disposeApp(tester);
      });
    });

    testWidgets('kürzere Bereinigung fragt nach, weil sie endgültig löscht', (tester) async {
      final backend = FakeBackend();
      await _openManage(tester, backend);
      await _scrollPanel(tester, find.byKey(const Key('cleanup')));
      expect(find.text('1 Jahr'), findsOneWidget);

      await tester.tap(find.byKey(const Key('cleanup')));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Kalenderbereinigung'), findsOneWidget);
      await tester.tap(find.text('3 Monate'));
      await tester.pumpAndSettle();
      expect(find.textContaining('endgültig gelöscht'), findsOneWidget);
      await tester.tap(find.text('Abbrechen'));
      await tester.pumpAndSettle();
      expect(backend.writes.containsKey('PUT /api/families/f1/calendar-cleanup'), isFalse);
      expect(find.widgetWithText(AppBar, 'Kalenderbereinigung'), findsOneWidget);

      await tester.tap(find.text('3 Monate'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Übernehmen'));
      await tester.pumpAndSettle();
      expect(backend.writes['PUT /api/families/f1/calendar-cleanup'], {'months': 3});
      expect(find.widgetWithText(AppBar, 'Kalenderbereinigung'), findsNothing);
      await disposeApp(tester);
    });

    testWidgets('längere Bereinigung braucht keine Rückfrage, ohne Admin geht nichts', (tester) async {
      final backend = FakeBackend();
      await _openManage(tester, backend);
      await _scrollPanel(tester, find.byKey(const Key('cleanup')));
      await tester.tap(find.byKey(const Key('cleanup')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('2 Jahre'));
      await tester.pumpAndSettle();
      expect(backend.writes['PUT /api/families/f1/calendar-cleanup'], {'months': 24});
      await disposeApp(tester);

      final member = FakeBackend()..isAdmin = false;
      await _openManage(tester, member);
      await _scrollPanel(tester, find.byKey(const Key('cleanup')));
      await tester.tap(find.byKey(const Key('cleanup')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Admins des Kreises'), findsOneWidget);
      await tester.tap(find.text('2 Jahre'));
      await tester.pumpAndSettle();
      expect(member.writes.containsKey('PUT /api/families/f1/calendar-cleanup'), isFalse);
      await disposeApp(tester);
    });
  });

  testWidgets('Standard-Erinnerung gilt für neue Termine', (tester) async {
    final backend = FakeBackend();
    backend.calendarPrefs['default_reminder'] = 30;
    await _openNewEvent(tester, backend);
    expect(find.text('30 Minuten vorher'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('event-title')), 'T');
    await _save(tester);
    expect((backend.writes['POST $_eventsPath'] as Map)['reminders'], [30]);
    await disposeApp(tester);
  });

  testWidgets('Geburtstag im Profil setzen und entfernen', (tester) async {
    final backend = FakeBackend()..profile['birthday'] = '1990-03-14';
    await pumpApp(tester, backend, MemoryTokens()..token = 't1');
    await _openProfileEdit(tester);
    expect(find.text('14.03.1990'), findsOneWidget);
    await tester.tap(find.byTooltip('Datum entfernen'));
    await tester.pumpAndSettle();
    expect(find.text('Kein Datum'), findsOneWidget);
    await tester.tap(find.byTooltip('Speichern'));
    await tester.pumpAndSettle();
    expect(backend.profile['birthday'], '');
    await disposeApp(tester);
  });
}
