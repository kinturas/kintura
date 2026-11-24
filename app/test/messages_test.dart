import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kintura/notifications/push.dart';
import 'package:kintura/screens/chat_screen.dart';
import 'package:kintura/screens/event_edit_screen.dart' show PickedFile;
import 'package:kintura/screens/messages_screen.dart';

import 'widget_test.dart' show FakeBackend, MemoryTokens, disposeApp, pumpApp;

Map<String, Object?> _chat(
  String id,
  String name, {
  String kind = 'group',
  int unread = 0,
  bool archived = false,
  bool canWrite = true,
  String last = '',
  String sender = 'Ben',
}) => {
  'id': id,
  'family_id': 'f1',
  'kind': kind,
  'name': name,
  'color': kind == 'group' ? '#3567B5' : '',
  'assignees_all': false,
  'assignee_ids': ['u2'],
  'visibility': 'participants',
  'category_id': '',
  'category_name': '',
  'category_color': '',
  'archived': archived,
  'unread': unread,
  'can_write': canWrite,
  'can_edit': kind == 'group' && canWrite,
  'last_message': last.isEmpty
      ? null
      : {
          'body': last,
          'created_at': DateTime.now().toUtc().toIso8601String(),
          'sender_id': 'u2',
          'sender_name': sender,
          'own': false,
          'deleted': false,
          'photos': 0,
          'documents': 0,
        },
};

Map<String, Object?> _message(String id, String body, {bool own = false, List<Map<String, Object?>> files = const []}) => {
  'id': id,
  'sender_id': own ? 'u1' : 'u2',
  'sender_name': own ? 'Anna' : 'Ben',
  'sender_color': '',
  'body': body,
  'created_at': DateTime.now().toUtc().toIso8601String(),
  'deleted': false,
  'own': own,
  'can_delete': own,
  'attachments': files,
};

Future<FakeBackend> _openMessages(WidgetTester tester, [List<Map<String, Object?>> chats = const []]) async {
  final backend = FakeBackend()..chats = [...chats];
  await pumpApp(tester, backend, MemoryTokens()..token = 't1');
  await tester.tap(find.text('Nachrichten'));
  await tester.pumpAndSettle();
  return backend;
}

void main() {
  tearDown(() => messagesOfAllCircles.value = false);

  testWidgets('die Kachel steht gleich nach Aktuelles und zählt Ungelesenes', (tester) async {
    final backend = FakeBackend()..chats = [_chat('c1', 'Urlaub', unread: 3, last: 'Wohin?')];
    await pumpApp(tester, backend, MemoryTokens()..token = 't1');
    final cards = tester.widgetList<Card>(find.byType(Card)).toList();
    expect(find.descendant(of: find.byWidget(cards[0]), matching: find.text('Aktuelles')), findsOneWidget);
    expect(find.descendant(of: find.byWidget(cards[1]), matching: find.text('Nachrichten')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('messages-unread')), matching: find.text('3')), findsOneWidget);
    await disposeApp(tester);
  });

  testWidgets('die Liste filtert nach Ungelesenen und Gruppen, Archiviertes hat eine eigene Seite', (tester) async {
    final backend = await _openMessages(tester, [
      _chat('c1', 'Ben', kind: 'direct', unread: 2, last: 'Kommst du?'),
      _chat('c2', 'Urlaub', last: 'Ans Meer!'),
      _chat('c3', 'Alter Kram', archived: true, last: 'Vorbei'),
    ]);
    expect(find.text('Ben'), findsOneWidget);
    expect(find.text('Urlaub'), findsOneWidget);
    expect(find.text('Alter Kram'), findsNothing);
    // In a group with who wrote it.
    expect(find.text('Ben: Ans Meer!'), findsOneWidget);
    expect(find.text('Kommst du?'), findsOneWidget);
    expect(find.byKey(const Key('chat-unread-c1')), findsOneWidget);

    await tester.tap(find.byKey(const Key('chat-filter-unread')));
    await tester.pumpAndSettle();
    expect(find.text('Urlaub'), findsNothing);
    expect(find.text('Ben'), findsOneWidget);

    await tester.tap(find.byKey(const Key('chat-filter-groups')));
    await tester.pumpAndSettle();
    expect(find.text('Urlaub'), findsOneWidget);
    expect(find.text('Ben'), findsNothing);

    await tester.tap(find.byKey(const Key('chat-filter-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-archived')));
    await tester.pumpAndSettle();
    expect(find.text('Alter Kram'), findsOneWidget);
    expect(find.text('Urlaub'), findsNothing);
    expect(find.byKey(const Key('chat-new')), findsNothing);

    // Back into the list, for oneself.
    await tester.longPress(find.text('Alter Kram'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wieder in die Liste'));
    await tester.pumpAndSettle();
    expect(backend.writes['PUT archive'], {'archived': false});
    expect(tester.takeException(), isNull);
    await disposeApp(tester);
  });

  testWidgets('die Suche findet Chats beim Namen und Nachrichten beim Server', (tester) async {
    final backend = await _openMessages(tester, [
      _chat('c1', 'Urlaub', last: 'Ans Meer!'),
      _chat('c2', 'Einkauf', last: 'Milch'),
    ]);
    backend.chatSearch = [
      {
        'id': 'm7',
        'chat_id': 'c2',
        'family_id': 'f1',
        'body': 'Bring Sonnencreme mit',
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'sender_id': 'u2',
        'sender_name': 'Ben',
        'file_name': '',
        'own': false,
      },
    ];
    await tester.enterText(find.byKey(const Key('chat-search')), 'urla');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('Chats'), findsOneWidget);
    expect(find.text('Urlaub'), findsOneWidget);
    expect(find.text('Einkauf'), findsOneWidget);
    expect(find.text('Ben: Bring Sonnencreme mit'), findsOneWidget);
    // Filters wait until the search is cleared.
    expect(find.byKey(const Key('chat-filter-all')), findsNothing);
    await tester.tap(find.byTooltip('Suche leeren'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('chat-filter-all')), findsOneWidget);
    await disposeApp(tester);
  });

  testWidgets('eine Direktnachricht: Person wählen, schreiben, und gelesen ist sie auch', (tester) async {
    final backend = await _openMessages(tester);
    expect(find.textContaining('Noch keine Nachrichten'), findsOneWidget);
    await tester.tap(find.byKey(const Key('chat-new')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-new-direct')));
    await tester.pumpAndSettle();
    // Not oneself.
    expect(find.byKey(const ValueKey('chat-member-u1')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('chat-member-u2')));
    await tester.pumpAndSettle();
    expect(backend.writes['POST /api/families/f1/chats'], {'kind': 'direct', 'user_id': 'u2'});
    expect(backend.writes.containsKey('POST read'), isTrue);

    expect(tester.widget<IconButton>(find.byKey(const Key('chat-send'))).onPressed, isNull);
    await tester.enterText(find.byKey(const Key('chat-input')), '  Hallo Ben 👋 ');
    await tester.pump();
    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pumpAndSettle();
    expect(backend.writes['POST messages'], {'body': 'Hallo Ben 👋'});
    expect(find.text('Hallo Ben 👋'), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const Key('chat-input'))).controller!.text, isEmpty);

    // Emojis instead of the keyboard, and back.
    await tester.tap(find.byKey(const Key('chat-emoji')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Tastatur'), findsOneWidget);
    await tester.tap(find.byKey(const Key('chat-emoji')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Emojis'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await disposeApp(tester);
  });

  testWidgets('eine Gruppe mit Titel, Farbe, Betroffenen und Sichtbarkeit', (tester) async {
    final backend = await _openMessages(tester);
    await tester.tap(find.byKey(const Key('chat-new')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-new-group')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('chat-form-name')), 'Urlaub');
    await tester.tap(find.byKey(const ValueKey('chat-form-member-u2')));
    await tester.scrollUntilVisible(find.text('Jeden (lesend)'), 200, scrollable: find.byType(Scrollable).last);
    await tester.tap(find.text('Jeden (lesend)'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-form-save')));
    await tester.pumpAndSettle();
    expect(backend.writes['POST /api/families/f1/chats'], {
      'kind': 'group',
      'name': 'Urlaub',
      'color': '',
      'assignees_all': false,
      'assignee_ids': ['u2'],
      'visibility': 'all',
      'category_id': '',
    });
    // The new group opens.
    expect(find.byKey(const Key('chat-input')), findsOneWidget);
    expect(find.text('Urlaub'), findsWidgets);
    await disposeApp(tester);
  });

  testWidgets('eine lange Nachricht nimmt auch auf einem kleinen Bildschirm nie die ganze Breite ein', (tester) async {
    final backend = await _openMessages(tester, [_chat('c1', 'Urlaub', last: 'lang')]);
    // After the start, which sets a large window.
    tester.view.physicalSize = const Size(320, 640);
    await tester.pumpAndSettle();
    backend.chatMessages['c1'] = [
      _message('m1', 'Das ist eine sehr lange Nachricht, die über mehrere Zeilen geht und gern die ganze Breite hätte.'),
      _message('m2', 'Und eine eigene, ebenso lang, damit auch die rechte Seite frei bleibt, wie es sich gehört.', own: true),
      _message('m3', 'Ok', own: true),
      _message('m4', 'Ja'),
    ];
    await tester.tap(find.text('Urlaub'));
    await tester.pumpAndSettle();
    final others = tester.getRect(find.byKey(const ValueKey('chat-message-m1')));
    final own = tester.getRect(find.byKey(const ValueKey('chat-message-m2')));
    expect(others.width, lessThanOrEqualTo(320 * 0.8));
    expect(own.width, lessThanOrEqualTo(320 * 0.8));
    // Each on its side, the other side stays clear.
    expect(320 - others.right, greaterThan(40));
    expect(own.left, greaterThan(40));
    // Who wrote it, small at the left of the others' messages, not at one's own.
    final avatar = tester.getRect(find.byKey(const ValueKey('chat-avatar-m1')));
    expect(avatar.width, 24);
    expect(avatar.right, lessThanOrEqualTo(others.left));
    expect(avatar.bottom, lessThanOrEqualTo(others.bottom));
    expect(find.byKey(const ValueKey('chat-avatar-m2')), findsNothing);
    // A short one only as wide as its words, on its side.
    final short = tester.getRect(find.byKey(const ValueKey('chat-message-m3')));
    expect(short.width, lessThan(100));
    expect(short.right, greaterThan(300));
    expect(tester.getRect(find.byKey(const ValueKey('chat-message-m4'))).width, lessThan(100));
    // In a group the name above, in bold; not above one's own.
    expect(tester.widget<Text>(find.text('Ben').first).style?.fontWeight, FontWeight.w800);
    expect(find.text('Anna'), findsNothing);
    expect(tester.takeException(), isNull);
    await disposeApp(tester);
  });

  testWidgets('wer nur mitliest, hat kein Eingabefeld', (tester) async {
    final backend = await _openMessages(tester, [_chat('c1', 'Elternrat', canWrite: false, last: 'Treffen am Montag')]);
    backend.chatMessages['c1'] = [_message('m1', 'Treffen am Montag')];
    await tester.tap(find.text('Elternrat'));
    await tester.pumpAndSettle();
    expect(find.text('Treffen am Montag'), findsOneWidget);
    expect(find.byKey(const Key('chat-read-only')), findsOneWidget);
    expect(find.byKey(const Key('chat-input')), findsNothing);
    await disposeApp(tester);
  });

  testWidgets('Bilder und Dokumente kommen als eigene Nachrichten, eigene lassen sich löschen', (tester) async {
    ChatScreen.pickFiles = ({required bool pictures}) async => [PickedFile('plan.pdf', Uint8List.fromList([1, 2, 3]))];
    addTearDown(() => ChatScreen.pickFiles = ({required bool pictures}) async => []);
    final backend = await _openMessages(tester, [_chat('c1', 'Urlaub', last: 'Hier der Plan')]);
    backend.chatMessages['c1'] = [
      _message('m1', '', own: true, files: [
        {'id': 'f1', 'name': 'plan.pdf', 'mime': 'application/pdf', 'size': 2048, 'kind': 'document'},
      ]),
    ];
    await tester.tap(find.text('Urlaub'));
    await tester.pumpAndSettle();
    expect(find.text('plan.pdf'), findsOneWidget);
    expect(find.text('2 KB'), findsOneWidget);

    await tester.tap(find.byKey(const Key('chat-attach')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dokument'));
    await tester.pumpAndSettle();
    expect(backend.uploads, ['/api/families/f1/chats/c1/attachments']);

    await tester.longPress(find.byKey(const ValueKey('chat-message-m1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-message-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Löschen'));
    await tester.pumpAndSettle();
    expect(backend.writes.containsKey('DELETE messages/m1'), isTrue);
    expect(tester.takeException(), isNull);
    await disposeApp(tester);
  });

  testWidgets('mit allen Kreisen trägt jeder Chat seinen Kreis, mit einem Kreis gibt es keinen Filter', (tester) async {
    await _openMessages(tester, [_chat('c1', 'Urlaub', last: 'Ans Meer!')]);
    expect(find.byKey(const Key('messages-filter')), findsNothing);
    await disposeApp(tester);

    final backend = FakeBackend()
      ..extraFamilies.add({
        'id': 'f2', 'name': 'Kegelclub', 'type': 'friends', 'role': 'user', 'is_admin': false, 'color': '',
        'family_color': '#7B4FB0',
      })
      ..chats = [_chat('c1', 'Urlaub', last: 'Ans Meer!'), {..._chat('c2', 'Kegeln', last: 'Freitag?'), 'family_id': 'f2'}];
    await pumpApp(tester, backend, MemoryTokens()..token = 't1');
    await tester.tap(find.text('Nachrichten'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('circle-f2')), findsNothing);
    await tester.tap(find.byKey(const Key('messages-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CheckedPopupMenuItem<bool>, 'Alle Kreise'));
    await tester.pumpAndSettle();
    expect(messagesOfAllCircles.value, isTrue);
    expect(find.descendant(of: find.byKey(const ValueKey('circle-f2')), matching: find.text('Kegelclub')), findsOneWidget);
    expect(find.byKey(const ValueKey('circle-f1')), findsOneWidget);
    await disposeApp(tester);
  });

  test('eine Benachrichtigung führt zu Aktuelles oder zu einem Chat', () {
    expect(OpenTarget.fromPush(true), const OpenTarget.activities());
    expect(OpenTarget.fromPush({'kind': 'activity', 'family_id': 'f1', 'chat_id': ''}), const OpenTarget.activities());
    const chat = OpenTarget.chat('f1', 'c1');
    expect(OpenTarget.fromPush({'kind': 'message', 'family_id': 'f1', 'chat_id': 'c1'}), chat);
    expect(OpenTarget.fromPayload(chat.payload), chat);
    expect(OpenTarget.fromPayload('f1'), const OpenTarget.activities());
    expect(messagePreview({'body': 'Hallo\n  du', 'photos': 0}), 'Hallo du');
    expect(messagePreview({'body': '', 'photos': 1}), '📷 Bild');
    expect(messagePreview({'deleted': true, 'body': ''}), 'Nachricht gelöscht');
  });
}
