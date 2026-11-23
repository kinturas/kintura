import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kintura/api.dart';
import 'package:kintura/live_updates.dart';
import 'package:kintura/notifications/activity_notifier.dart';
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
