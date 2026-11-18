import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kintura/shopping/shopping_catalog.dart';
import 'package:kintura/shopping/shopping_icons.dart';

import 'widget_test.dart' show FakeBackend, MemoryTokens, disposeApp, pumpApp;

Future<void> _openList(WidgetTester tester) async {
  await tester.tap(find.text('Einkaufen'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Wocheneinkauf'));
  await tester.pumpAndSettle();
}

Finder _tile(String name) => find.byKey(ValueKey('article-$name'));

Finder get _list => find.descendant(of: find.byType(RefreshIndicator), matching: find.byType(Scrollable)).first;

void main() {
  group('Katalog', () {
    test('jedes Symbol lässt sich zeichnen und jeder Artikel hat eins', () {
      for (final entry in shoppingIcons.entries) {
        expect(() => parseIconPath(entry.value), returnsNormally, reason: entry.key);
        expect(parseIconPath(entry.value).getBounds().isEmpty, isFalse, reason: entry.key);
      }
      for (final article in catalogArticles.values) {
        expect(shoppingIcons, contains(article.icon), reason: article.name);
        expect(shoppingCategories.map((c) => c.key), contains(article.category), reason: article.name);
      }
    });

    test('die Suche findet den Text überall im Namen, Anfänge zuerst', () {
      final names = searchArticles(catalogArticles.values, 'Bi').map((a) => a.name).toList();
      expect(names.take(3), ['Bier', 'Binden', 'Birnen']);
      expect(names, containsAll(['Kohlrabi', 'Kürbis', 'Glühbirne']));
      expect(searchArticles(catalogArticles.values, 'strasse'), isEmpty);
      expect(searchArticles(catalogArticles.values, 'süssk').single.name, 'Süßkartoffeln');
    });

    test('eigene Artikel beginnen groß und überschreiben den Katalog nicht', () {
      expect(capitalizedName('  bi  saft '), 'Bi saft');
      expect(capitalizedName('übertopf'), 'Übertopf');
      final articles = mergeArticles([
        {'name': 'Milch', 'custom': false, 'icon': 'water', 'category': ''},
        {'name': 'Übertopf', 'custom': true, 'icon': '', 'category': 'eigene'},
      ]);
      expect(articles['Milch']!.icon, 'water');
      expect(articles['Milch']!.category, 'milch_kaese');
      expect(articles['Übertopf']!.custom, isTrue);
    });
  });

  group('Einkaufen', () {
    testWidgets('zeigt die Listen mit einem Knopf für eine neue am Ende', (tester) async {
      final backend = FakeBackend();
      await pumpApp(tester, backend, MemoryTokens()..token = 't1');
      await tester.tap(find.text('Einkaufen'));
      await tester.pumpAndSettle();
      expect(find.text('Wocheneinkauf'), findsOneWidget);
      expect(find.text('1 Artikel offen · für alle sichtbar'), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(const Key('shopping-new-list'))).dy,
        greaterThan(tester.getBottomLeft(find.text('Wocheneinkauf')).dy),
      );

      await tester.tap(find.byKey(const Key('shopping-new-list')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('shopping-list-name')), 'Baumarkt');
      await tester.tap(find.text('Ben'));
      // For the people it concerns unless chosen otherwise.
      expect(find.text('Betrifft'), findsOneWidget);
      expect(find.text('Jeden (lesend)'), findsOneWidget);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Speichern'));
      await tester.pumpAndSettle();
      expect(backend.writes['POST lists'], {
        'name': 'Baumarkt',
        'color': '',
        'assignees_all': false,
        'assignee_ids': ['u2'],
        'visibility': 'participants',
        'category_id': '',
        'due_date': '',
      });
      expect(tester.takeException(), isNull);
      await disposeApp(tester);
    });

    testWidgets('Tippen hakt ab, legt wieder auf die Liste und legt aus der Suche eigene Artikel an', (tester) async {
      final backend = FakeBackend();
      await pumpApp(tester, backend, MemoryTokens()..token = 't1');
      await _openList(tester);

      // Open on the list, done among the recent ones.
      expect(find.text('Zuletzt verwendet'), findsOneWidget);
      expect(find.descendant(of: _tile('Milch'), matching: find.text('2 l')), findsOneWidget);
      expect(find.descendant(of: _tile('Milch'), matching: find.byIcon(Icons.priority_high)), findsOneWidget);
      await tester.tap(_tile('Milch'));
      await tester.pumpAndSettle();
      expect((backend.writes['PUT items/i1'] as Map)['done'], true);
      await tester.tap(_tile('Brot').first);
      await tester.pumpAndSettle();
      expect(backend.writes['POST lists/s1/items'], {'name': 'Brot'});

      await tester.enterText(find.byKey(const Key('shopping-search')), 'Bi');
      await tester.pumpAndSettle();
      for (final name in ['Birnen', 'Bier', 'Binden', 'Kohlrabi', 'Kürbis', 'Glühbirne']) {
        expect(_tile(name), findsOneWidget, reason: name);
      }
      expect(find.descendant(of: find.byKey(const Key('shopping-own-article')), matching: find.text('Bi')), findsOneWidget);
      await tester.tap(find.byKey(const Key('shopping-own-article')));
      await tester.pumpAndSettle();
      expect(backend.writes['POST articles'], {'name': 'Bi'});
      expect(backend.writes['POST lists/s1/items'], {'name': 'Bi'});
      expect(find.byKey(const Key('shopping-search')), findsOneWidget);
      expect(_tile('Bi'), findsOneWidget);

      // Typed in small letters, an own article starts with a capital.
      await tester.enterText(find.byKey(const Key('shopping-search')), 'übertopf');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(backend.writes['POST articles'], {'name': 'Übertopf'});
      expect(tester.takeException(), isNull);
      await disposeApp(tester);
    });

    testWidgets('die Kategorien klappen auf und legen Artikel auf die Liste', (tester) async {
      final backend = FakeBackend();
      await pumpApp(tester, backend, MemoryTokens()..token = 't1');
      await _openList(tester);
      expect(_tile('Bananen'), findsNothing);
      await tester.scrollUntilVisible(find.text('Obst & Gemüse'), 200, scrollable: _list);
      await tester.tap(find.text('Obst & Gemüse'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(_tile('Bananen'), 200, scrollable: _list);
      await tester.tap(_tile('Bananen'));
      await tester.pumpAndSettle();
      expect(backend.writes['POST lists/s1/items'], {'name': 'Bananen'});
      await disposeApp(tester);
    });

    testWidgets('langes Drücken öffnet den Artikel mit einem Feld für Menge und Beschreibung', (tester) async {
      final backend = FakeBackend();
      await pumpApp(tester, backend, MemoryTokens()..token = 't1');
      await _openList(tester);
      await tester.longPress(_tile('Milch'));
      await tester.pumpAndSettle();
      expect(find.text('Auf „Wocheneinkauf“'), findsOneWidget);
      expect(find.byTooltip('Artikel löschen'), findsNothing);
      // The icon of an article from the catalog stays as it is.
      expect(find.byKey(const Key('article-icon')), findsNothing);
      expect(find.text('Symbol ändern'), findsNothing);

      await tester.enterText(find.byKey(const Key('article-detail')), '3 l, laktosefrei');
      await tester.tap(find.byKey(const Key('urgency-offer')));
      await tester.tap(find.text('Speichern'));
      await tester.pumpAndSettle();

      expect(backend.writes['PUT articles'], isNull);
      expect(backend.writes['PUT items/i1'], {
        'amount': '3 l, laktosefrei',
        'note': '',
        'urgency': 'offer',
        'done': false,
        'list_id': 's1',
      });
      expect(find.byKey(const Key('shopping-search')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await disposeApp(tester);
    });

    testWidgets('zurück mit Änderungen fragt nach', (tester) async {
      final backend = FakeBackend();
      await pumpApp(tester, backend, MemoryTokens()..token = 't1');
      await _openList(tester);

      // Without changes it just goes back.
      await tester.longPress(_tile('Milch'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('Änderungen speichern?'), findsNothing);
      expect(find.byKey(const Key('shopping-search')), findsOneWidget);

      await tester.longPress(_tile('Milch'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('article-detail')), '1 l');
      await tester.pump();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('Änderungen speichern?'), findsOneWidget);
      await tester.tap(find.text('Weiter bearbeiten'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('article-detail')), findsOneWidget);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Verwerfen'));
      await tester.pumpAndSettle();
      expect(backend.writes['PUT items/i1'], isNull);
      expect(find.byKey(const Key('shopping-search')), findsOneWidget);

      await tester.longPress(_tile('Milch'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('article-detail')), '1 l');
      await tester.pump();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Speichern'));
      await tester.pumpAndSettle();
      expect((backend.writes['PUT items/i1'] as Map)['amount'], '1 l');
      expect(find.byKey(const Key('shopping-search')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await disposeApp(tester);
    });

    testWidgets('eigene Artikel bekommen ein Symbol aus der Suche nach Artikelnamen', (tester) async {
      final backend = FakeBackend()
        ..shoppingArticles = [
          {'name': 'Übertopf', 'custom': true, 'icon': '', 'category': 'eigene'},
        ];
      await pumpApp(tester, backend, MemoryTokens()..token = 't1');
      await _openList(tester);
      await tester.enterText(find.byKey(const Key('shopping-search')), 'Übert');
      await tester.pumpAndSettle();
      await tester.longPress(_tile('Übertopf'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('article-icon')));
      await tester.pumpAndSettle();
      expect(find.text('Symbol wählen'), findsOneWidget);
      expect(find.byKey(const Key('icon-letter')), findsOneWidget);

      await tester.enterText(find.byKey(const Key('icon-search')), 'milc');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('icon-milk')), findsOneWidget);
      expect(find.byKey(const Key('icon-apple')), findsNothing);
      await tester.enterText(find.byKey(const Key('icon-search')), 'xyzq');
      await tester.pumpAndSettle();
      expect(find.text('Kein Symbol gefunden. Versuche ein anderes Wort.'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('icon-search')), 'milc');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('icon-milk')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Speichern'));
      await tester.pumpAndSettle();
      expect(backend.writes['PUT articles'], {'name': 'Übertopf', 'icon': 'milk', 'category': 'eigene'});
      expect(tester.takeException(), isNull);
      await disposeApp(tester);
    });

    testWidgets('eigene Artikel lassen sich löschen', (tester) async {
      final backend = FakeBackend()
        ..shoppingArticles = [
          {'name': 'Übertopf', 'custom': true, 'icon': '', 'category': 'eigene'},
        ];
      await pumpApp(tester, backend, MemoryTokens()..token = 't1');
      await _openList(tester);
      await tester.scrollUntilVisible(find.text('Eigene Artikel'), 200, scrollable: _list);
      await tester.tap(find.text('Eigene Artikel'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(_tile('Übertopf'), 200, scrollable: _list);
      await tester.longPress(_tile('Übertopf'));
      await tester.pumpAndSettle();
      expect(find.text('Nicht auf der Liste'), findsOneWidget);
      await tester.tap(find.byTooltip('Artikel löschen'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Löschen'));
      await tester.pumpAndSettle();
      expect(backend.writes['DELETE articles'], {'name': 'Übertopf'});
      await disposeApp(tester);
    });

    testWidgets('eine Liste, die einen nicht betrifft, ist nur zum Ansehen', (tester) async {
      final backend = FakeBackend();
      backend.shoppingLists.first
        ..['can_write'] = false
        ..['can_edit'] = false
        ..['visibility'] = 'all';
      await pumpApp(tester, backend, MemoryTokens()..token = 't1');
      await tester.tap(find.text('Einkaufen'));
      await tester.pumpAndSettle();
      expect(find.textContaining('nur lesend'), findsOneWidget);
      expect(find.byTooltip('Liste bearbeiten'), findsNothing);
      await tester.tap(find.text('Wocheneinkauf'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('shopping-read-only')), findsOneWidget);
      expect(find.byKey(const Key('shopping-search')), findsNothing);
      expect(find.text('Zuletzt verwendet'), findsNothing);
      expect(find.text('Obst & Gemüse'), findsNothing);
      await tester.tap(_tile('Milch'));
      await tester.longPress(_tile('Milch'));
      await tester.pumpAndSettle();
      expect(backend.writes, isEmpty);
      expect(find.byKey(const Key('article-detail')), findsNothing);
      expect(find.textContaining('Diese Liste kannst du nur ansehen.'), findsWidgets);
      await disposeApp(tester);
    });

    testWidgets('zurück: aus der Liste aufs Dashboard, aus allen Listen in die Liste', (tester) async {
      final backend = FakeBackend();
      await pumpApp(tester, backend, MemoryTokens()..token = 't1');
      // Never chosen one: all lists, and back from there is the dashboard.
      await tester.tap(find.text('Einkaufen'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('shopping-new-list')), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('Hallo Anna'), findsOneWidget);

      // Chosen from all lists: back from the list is the dashboard, not all lists.
      await tester.tap(find.text('Einkaufen'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Wocheneinkauf'));
      await tester.pumpAndSettle();
      expect(backend.shoppingLast, 's1');
      expect(find.byKey(const Key('shopping-search')), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('Hallo Anna'), findsOneWidget);

      // From now on straight into the list; all lists and back is the list again.
      await tester.tap(find.text('Einkaufen'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('shopping-search')), findsOneWidget);
      await tester.tap(find.byKey(const Key('shopping-all-lists')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('shopping-new-list')), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('shopping-search')), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('Hallo Anna'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await disposeApp(tester);
    });

    testWidgets('in der Liste lässt sie sich bearbeiten, mit Kategorie und Fälligkeit', (tester) async {
      final backend = FakeBackend()..shoppingLast = 's1';
      await pumpApp(tester, backend, MemoryTokens()..token = 't1');
      await tester.tap(find.text('Einkaufen'));
      await tester.pumpAndSettle();
      final edit = find.byKey(const Key('shopping-edit-list'));
      final all = find.byKey(const Key('shopping-all-lists'));
      // Edit left of the button for all lists.
      expect(tester.getCenter(edit).dx, lessThan(tester.getCenter(all).dx));

      await tester.tap(edit);
      await tester.pumpAndSettle();
      expect(find.text('Kategorie'), findsOneWidget);
      expect(find.text('Fällig am'), findsOneWidget);
      await tester.tap(find.byKey(const Key('shopping-list-category')));
      await tester.pumpAndSettle();
      final category = find.byType(DropdownMenuItem<String>).last;
      final name = tester.widget<Text>(find.descendant(of: category, matching: find.byType(Text)).last).data;
      await tester.tap(category);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Speichern'));
      await tester.pumpAndSettle();
      final body = backend.writes['PUT lists/s1'] as Map;
      expect(body['category_id'], isNotEmpty, reason: name);
      expect(body['due_date'], '');
      // Back in the list.
      expect(find.byKey(const Key('shopping-search')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await disposeApp(tester);
    });

    testWidgets('ohne Bearbeitungsrecht kein Stift', (tester) async {
      final backend = FakeBackend()..shoppingLast = 's1';
      backend.shoppingLists.first['can_edit'] = false;
      await pumpApp(tester, backend, MemoryTokens()..token = 't1');
      await tester.tap(find.text('Einkaufen'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('shopping-edit-list')), findsNothing);
      expect(find.byKey(const Key('shopping-all-lists')), findsOneWidget);
      await disposeApp(tester);
    });
  });
}
