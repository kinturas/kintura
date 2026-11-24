import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kintura/api.dart';
import 'package:kintura/live_updates.dart';
import 'package:kintura/notifications/activity_notifier.dart';
import 'package:kintura/notifications/push.dart';
import 'package:kintura/notifications/system_notifications.dart';
import 'package:kintura/session.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'widget_test.dart' show FakeBackend, MemoryTokens;

class _FakeNotifications implements SystemNotifications {
  bool permitted = true;
  final shown = <(int, String, String)>[];

  @override
  bool get supported => true;

  @override
  Future<void> init(void Function(String payload) onTap) async {}

  @override
  Future<bool> allowed() async => permitted;

  @override
  Future<bool> requestPermission() async => permitted;

  @override
  Future<void> show({required int id, required String title, required String body, String payload = ''}) async =>
      shown.add((id, title, body));
}

int _minute = 0;

/// An entry of Aktuelles, each one later than the one before.
Map<String, Object?> _entry(String id, {bool own = false, bool isNew = true, String family = 'f1'}) => {
  'id': id,
  'family_id': family,
  'own': own,
  'new': isNew && !own,
  'kind': 'items_added',
  'ref_id': 's1',
  'title': 'Wocheneinkauf',
  'names': ['Milch $id'],
  'count': 1,
  'updated_at': DateTime.utc(2026, 11, 23, 10, _minute++).toIso8601String(),
  'actor_id': own ? 'u1' : 'u2',
  'actor_name': own ? 'Anna' : 'Ben',
};

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  group('Benachrichtigungen für Aktuelles', () {
    late FakeBackend backend;
    late AppSession session;
    late _FakeNotifications notifications;
    late ActivityNotifier notifier;

    Future<void> start(WidgetTester tester, {bool enabledBefore = false}) async {
      SharedPreferences.setMockInitialValues({if (enabledBefore) 'activity_notifications': true});
      backend = FakeBackend()..activities = [_entry('a0')];
      session = AppSession(api: ApiClient(client: backend.client, baseUrl: 'http://test'), tokens: MemoryTokens()..token = 't1');
      await session.start();
      notifications = _FakeNotifications();
      notifier = ActivityNotifier(session: session, notifications: notifications);
      await notifier.start();
      addTearDown(notifier.dispose);
      await tester.pump(const Duration(seconds: 2));
    }

    Future<void> changed(WidgetTester tester) async {
      session.live.emit(const LiveEvent('f1', 'shopping'));
      await tester.pump(const Duration(seconds: 2));
    }

    void background(WidgetTester tester) => tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    void front(WidgetTester tester) => tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    testWidgets('melden neue Nachrichten anderer, nicht eigene und nicht schon gelesene', (tester) async {
      await start(tester, enabledBefore: true);
      Map<String, Object?> chat(String id, String name, String body, {bool own = false, int unread = 1, String kind = 'group'}) =>
          {
            'id': id,
            'family_id': 'f1',
            'kind': kind,
            'name': name,
            'unread': unread,
            'archived': false,
            'last_message': {
              'body': body,
              'created_at': DateTime.utc(2026, 11, 24, 10, _minute++).toIso8601String(),
              'sender_name': own ? 'Anna' : 'Ben',
              'own': own,
              'deleted': false,
              'photos': 0,
              'documents': 0,
            },
          };
      backend.chats = [chat('c1', 'Urlaub', 'Vorher')];
      session.live.emit(const LiveEvent('f1', 'messages'));
      await tester.pump(const Duration(seconds: 2));
      // A chat new since the first look counts; this one is about what comes next.
      notifications.shown.clear();
      background(tester);
      addTearDown(() => front(tester));

      backend.chats = [
        chat('c1', 'Urlaub', 'Ans Meer!'),
        chat('c2', 'Ben', 'Kommst du?', kind: 'direct'),
        chat('c3', 'Eigenes', 'Von mir', own: true, unread: 0),
        chat('c4', 'Gelesen', 'Schon gesehen', unread: 0),
      ];
      session.live.emit(const LiveEvent('f1', 'messages'));
      await tester.pump(const Duration(seconds: 2));
      expect(notifications.shown.map((n) => (n.$2, n.$3)), [('Urlaub', 'Ben: Ans Meer!'), ('Ben', 'Kommst du?')]);
    });

    testWidgets('melden Neues anderer, solange die App im Hintergrund ist', (tester) async {
      await start(tester);
      expect(notifier.enabled.value, isFalse);
      expect(await notifier.setEnabled(true), isTrue);
      await tester.pump(const Duration(seconds: 2));
      background(tester);
      addTearDown(() => front(tester));

      // What was there before is not told; what is new, and not one's own, is.
      backend.activities = [_entry('a2'), _entry('a1', own: true), ...backend.activities];
      await changed(tester);
      expect(notifications.shown.map((n) => n.$3), ['Ben hat Milch a2 auf „Wocheneinkauf“ gesetzt.']);
      expect(notifications.shown.single.$2, 'Kintura');

      // Nothing new: nothing told again.
      await changed(tester);
      expect(notifications.shown, hasLength(1));

      // In front, the app shows it itself, also later.
      front(tester);
      backend.activities = [_entry('a3'), ...backend.activities];
      await changed(tester);
      background(tester);
      await changed(tester);
      expect(notifications.shown, hasLength(1));

      // Turned off: nothing.
      await notifier.setEnabled(false);
      backend.activities = [_entry('a4'), ...backend.activities];
      await changed(tester);
      expect(notifications.shown, hasLength(1));
    });

    group('auf Android mit Firebase', () {
      const channel = MethodChannel('de.kintura.app/push');
      late List<String> calls;
      late bool opened;

      setUp(() {
        calls = [];
        opened = false;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return switch (call.method) {
            'available' => true,
            'token' => 'tok-1',
            'openedFrom' => opened,
            _ => null,
          };
        });
      });
      tearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      });

      Future<void> startWithPush(WidgetTester tester, {bool server = true, bool enabledBefore = true}) async {
        SharedPreferences.setMockInitialValues({if (enabledBefore) 'activity_notifications': true});
        backend = FakeBackend()
          ..activities = [_entry('a0')]
          ..pushServer = server;
        session = AppSession(api: ApiClient(client: backend.client, baseUrl: 'http://test'), tokens: MemoryTokens()..token = 't1');
        await session.start();
        notifications = _FakeNotifications();
        notifier = ActivityNotifier(session: session, notifications: notifications, push: PushMessaging());
        await notifier.start();
        addTearDown(notifier.dispose);
        await tester.pump(const Duration(seconds: 2));
      }

      final android = TargetPlatformVariant.only(TargetPlatform.android);

      testWidgets('meldet das Gerät beim Server an, der dann schickt, auch bei geschlossener App', (tester) async {
        await startWithPush(tester);
        expect(notifier.canPush, isTrue);
        expect(notifier.pushing, isTrue);
        expect(backend.writes['PUT /api/me/push-device'], {'token': 'tok-1', 'platform': 'android'});

        // The app shows none itself then, not twice.
        background(tester);
        addTearDown(() => front(tester));
        backend.activities = [_entry('a1'), ...backend.activities];
        await changed(tester);
        expect(notifications.shown, isEmpty);

        // Turned off: the server forgets the device, and so does Firebase.
        await notifier.setEnabled(false);
        expect(notifier.pushing, isFalse);
        expect(backend.writes.containsKey('DELETE /api/me/push-device'), isTrue);
        expect(calls, contains('deleteToken'));
      }, variant: android);

      testWidgets('ohne Firebase auf dem Server bleibt es bei den eigenen Benachrichtigungen', (tester) async {
        await startWithPush(tester, server: false);
        expect(notifier.pushing, isFalse);
        background(tester);
        addTearDown(() => front(tester));
        backend.activities = [_entry('a1'), ...backend.activities];
        await changed(tester);
        expect(notifications.shown, hasLength(1));
      }, variant: android);

      testWidgets('eine angetippte Push-Nachricht öffnet Aktuelles', (tester) async {
        opened = true;
        var opens = 0;
        SharedPreferences.setMockInitialValues({});
        backend = FakeBackend();
        session = AppSession(api: ApiClient(client: backend.client, baseUrl: 'http://test'), tokens: MemoryTokens()..token = 't1');
        await session.start();
        notifier = ActivityNotifier(session: session, notifications: _FakeNotifications(), push: PushMessaging(), onOpen: (_) => opens++);
        await notifier.start();
        addTearDown(notifier.dispose);
        // The frame after signing in.
        tester.binding.scheduleFrame();
        await tester.pump();
        expect(opens, 1);

        // And while the app runs.
        await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
          channel.name,
          channel.codec.encodeMethodCall(const MethodCall('opened')),
          (_) {},
        );
        expect(opens, 2);
      }, variant: android);
    });

    testWidgets('bleiben an, wie eingestellt, und aus, wenn das System sie nicht erlaubt', (tester) async {
      await start(tester, enabledBefore: true);
      expect(notifier.enabled.value, isTrue);

      notifications.permitted = false;
      await notifier.setEnabled(false);
      expect(await notifier.setEnabled(true), isFalse);
      expect(notifier.enabled.value, isFalse);
      expect((await SharedPreferences.getInstance()).getBool('activity_notifications'), isFalse);
    });
  });
}
