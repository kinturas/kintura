import 'package:flutter/material.dart';

/// A category of articles; the keys are the same as on the server.
class ShoppingCategory {
  const ShoppingCategory(this.key, this.label, this.icon);

  final String key;
  final String label;
  final IconData icon;
}

/// The own articles of a circle, unless one gave them another category.
const ownCategory = 'eigene';

const shoppingCategories = [
  ShoppingCategory('obst_gemuese', 'Obst & Gemüse', Icons.eco_outlined),
  ShoppingCategory('brot_gebaeck', 'Brot & Gebäck', Icons.bakery_dining_outlined),
  ShoppingCategory('milch_kaese', 'Milch & Käse', Icons.egg_outlined),
  ShoppingCategory('fleisch_fisch', 'Fleisch & Fisch', Icons.set_meal_outlined),
  ShoppingCategory('gewuerze_zutaten', 'Gewürze & Zutaten', Icons.soup_kitchen_outlined),
  ShoppingCategory('fertig_tiefkuehl', 'Fertig- & Tiefkühlprodukte', Icons.ac_unit),
  ShoppingCategory('getreide', 'Getreideprodukte', Icons.rice_bowl_outlined),
  ShoppingCategory('suesswaren_snacks', 'Süßwaren & Snacks', Icons.cookie_outlined),
  ShoppingCategory('getraenke', 'Getränke', Icons.local_drink_outlined),
  ShoppingCategory('haushalt', 'Haushalt', Icons.cleaning_services_outlined),
  ShoppingCategory('pflege_gesundheit', 'Pflege & Gesundheit', Icons.spa_outlined),
  ShoppingCategory('tierbedarf', 'Tierbedarf', Icons.pets_outlined),
  ShoppingCategory('baumarkt_garten', 'Baumarkt & Garten', Icons.yard_outlined),
  ShoppingCategory(ownCategory, 'Eigene Artikel', Icons.edit_note),
];

ShoppingCategory categoryOf(String key) =>
    shoppingCategories.firstWhere((c) => c.key == key, orElse: () => shoppingCategories.last);

/// An article as the app shows it: from the catalog, or one the circle made itself.
class Article {
  const Article(this.name, this.category, this.icon, {this.custom = false});

  final String name;
  final String category;

  /// A key of shoppingIcons; empty or unknown shows the first letter.
  final String icon;

  /// Made by the circle, and the only kind that can be deleted.
  final bool custom;

  Article copyWith({String? category, String? icon}) =>
      Article(name, category ?? this.category, icon ?? this.icon, custom: custom);
}

/// The articles every circle starts with, by category.
const _catalog = <String, Map<String, String>>{
  'obst_gemuese': {
    'Ananas': 'pineapple',
    'Äpfel': 'apple',
    'Aprikosen': 'peach',
    'Artischocken': 'salad',
    'Aubergine': 'eggplant',
    'Avocado': 'avocado',
    'Bananen': 'banana',
    'Basilikum': 'herbs',
    'Beeren': 'berries',
    'Birnen': 'pear',
    'Blumenkohl': 'broccoli',
    'Bohnen': 'peas',
    'Brokkoli': 'broccoli',
    'Brombeeren': 'berries',
    'Champignons': 'mushroom',
    'Cherrytomaten': 'tomato',
    'Chili': 'chili',
    'Datteln': 'olive',
    'Erbsen': 'peas',
    'Erdbeeren': 'strawberry',
    'Feigen': 'peach',
    'Fenchel': 'onion',
    'Frühlingszwiebeln': 'leek',
    'Gemüse': 'carrot',
    'Grapefruit': 'citrus',
    'Gurke': 'cucumber',
    'Heidelbeeren': 'berries',
    'Himbeeren': 'berries',
    'Ingwer': 'root',
    'Kaki': 'peach',
    'Karotten': 'carrot',
    'Kartoffeln': 'potato',
    'Kirschen': 'cherries',
    'Kiwi': 'kiwi',
    'Knoblauch': 'garlic',
    'Kohl': 'salad',
    'Kohlrabi': 'radish',
    'Koriander': 'herbs',
    'Kräuter': 'herbs',
    'Kürbis': 'pumpkin',
    'Lauch': 'leek',
    'Limette': 'lemon',
    'Mais': 'corn',
    'Mandarinen': 'citrus',
    'Mango': 'mango',
    'Melone': 'melon',
    'Nektarine': 'peach',
    'Obst': 'apple',
    'Orange': 'citrus',
    'Oregano': 'herbs',
    'Paprika': 'pepper',
    'Passionsfrucht': 'peach',
    'Petersilie': 'herbs',
    'Pfefferminze': 'herbs',
    'Pfirsich': 'peach',
    'Pflaumen': 'peach',
    'Pilze': 'mushroom',
    'Radieschen': 'radish',
    'Rhabarber': 'asparagus',
    'Römersalat': 'salad',
    'Rosmarin': 'herbs',
    'Rote Bete': 'radish',
    'Rucola': 'salad',
    'Salat': 'salad',
    'Salbei': 'herbs',
    'Schnittlauch': 'herbs',
    'Sellerie': 'asparagus',
    'Spargel': 'asparagus',
    'Spinat': 'salad',
    'Süßkartoffeln': 'potato',
    'Thymian': 'herbs',
    'Tomaten': 'tomato',
    'Trauben': 'grapes',
    'Wassermelone': 'melon',
    'Zitrone': 'lemon',
    'Zucchini': 'cucumber',
    'Zwiebeln': 'onion',
  },
  'brot_gebaeck': {
    'Baguette': 'baguette',
    'Blätterteig': 'croissant',
    'Brezeln': 'pretzel',
    'Brot': 'bread',
    'Brötchen': 'roll',
    'Croissant': 'croissant',
    'Knäckebrot': 'bread',
    'Kuchen': 'cake',
    'Lebkuchen': 'cookie',
    'Muffins': 'cupcake',
    'Toast': 'bread',
    'Torte': 'cake',
    'Waffeln': 'waffle',
  },
  'milch_kaese': {
    'Blauschimmelkäse': 'cheese',
    'Burrata': 'cheese',
    'Butter': 'butter',
    'Crème fraîche': 'cup',
    'Eier': 'egg',
    'Feta': 'cheese',
    'Fonduekäse': 'cheese',
    'Frischkäse': 'cup',
    'Gorgonzola': 'cheese',
    'Hüttenkäse': 'cup',
    'Joghurt': 'cup',
    'Käse': 'cheese',
    'Kräuterbutter': 'butter',
    'Margarine': 'butter',
    'Mascarpone': 'cup',
    'Milch': 'milk',
    'Mozzarella': 'cheese',
    'Parmesan': 'cheese',
    'Pudding': 'cup',
    'Quark': 'cup',
    'Raclettekäse': 'cheese',
    'Reibkäse': 'cheese',
    'Ricotta': 'cup',
    'Sahne': 'milk',
    'Sauerrahm': 'cup',
    'Sojamilch': 'milk',
    'Tofu': 'cube',
  },
  'fleisch_fisch': {
    'Aufschnitt': 'bacon',
    'Bratwurst': 'sausage',
    'Chicken Wings': 'drumstick',
    'Fisch': 'fish',
    'Fleisch': 'meat',
    'Frankfurter': 'sausage',
    'Garnelen': 'shrimp',
    'Hackfleisch': 'meat',
    'Hähnchen': 'drumstick',
    'Hähnchenbrust': 'drumstick',
    'Kalbfleisch': 'meat',
    'Lachs': 'fish',
    'Lamm': 'meat',
    'Mett': 'meat',
    'Muscheln': 'shell',
    'Rindergeschnetzeltes': 'meat',
    'Rindfleisch': 'meat',
    'Rohschinken': 'bacon',
    'Salami': 'sausage',
    'Sardellen': 'fish',
    'Schinken': 'bacon',
    'Schnitzel': 'meat',
    'Schweinefleisch': 'meat',
    'Speck': 'bacon',
    'Steak': 'meat',
    'Thunfisch': 'can',
    'Wurst': 'sausage',
  },
  'gewuerze_zutaten': {
    'Ahornsirup': 'oil',
    'Apfelmus': 'jar',
    'Backpulver': 'sack',
    'Balsamico': 'oil',
    'BBQ-Sauce': 'sauce',
    'Bratensauce': 'sauce',
    'Brühe': 'cube',
    'Dip': 'sauce',
    'Dosentomaten': 'can',
    'Essig': 'oil',
    'Essiggurken': 'jar',
    'Gelee': 'jar',
    'Getrocknete Tomaten': 'jar',
    'Hefe': 'cube',
    'Honig': 'jar',
    'Ketchup': 'sauce',
    'Kokosmilch': 'can',
    'Mandelmus': 'jar',
    'Marmelade': 'jar',
    'Mayonnaise': 'sauce',
    'Mehl': 'sack',
    'Nougatcreme': 'jar',
    'Öl': 'oil',
    'Oliven': 'olive',
    'Olivenöl': 'oil',
    'Paprikapulver': 'shaker',
    'Pastasauce': 'jar',
    'Pfefferkörner': 'shaker',
    'Pinienkerne': 'nut',
    'Preiselbeersauce': 'jar',
    'Puderzucker': 'sack',
    'Salatsauce': 'sauce',
    'Salz': 'shaker',
    'Semmelbrösel': 'sack',
    'Senf': 'sauce',
    'Silberzwiebeln': 'jar',
    'Sirup': 'oil',
    'Sojasauce': 'sauce',
    'Speisestärke': 'sack',
    'Tomatenmark': 'tube',
    'Tomatensauce': 'jar',
    'Vanillesauce': 'sauce',
    'Vanillezucker': 'sack',
    'Zimt': 'shaker',
    'Zucker': 'sack',
  },
  'fertig_tiefkuehl': {
    'Chinesisches Essen': 'takeaway',
    'Eis': 'icecream',
    'Fischstäbchen': 'fish',
    'Gemüse gefroren': 'snowflake',
    'Indisches Essen': 'takeaway',
    'Italienisches Essen': 'takeaway',
    'Kartoffelpüree': 'potato',
    'Knödel': 'potato',
    'Lasagne': 'dish',
    'Pizza': 'pizza',
    'Pizzateig': 'pizza',
    'Pommes frites': 'fries',
    'Suppe': 'soup',
    'Thailändisches Essen': 'takeaway',
  },
  'getreide': {
    'Basmatireis': 'rice',
    'Cornflakes': 'cereal',
    'Couscous': 'rice',
    'Getreideriegel': 'bar',
    'Gnocchi': 'pasta',
    'Grieß': 'sack',
    'Haferflocken': 'cereal',
    'Kichererbsen': 'peas',
    'Linsen': 'peas',
    'Müsli': 'cereal',
    'Nudeln': 'pasta',
    'Penne': 'pasta',
    'Reis': 'rice',
    'Risottoreis': 'rice',
    'Spaghetti': 'pasta',
  },
  'suesswaren_snacks': {
    'Chips': 'chips',
    'Dessert': 'cupcake',
    'Dörrobst': 'peach',
    'Erdnüsse': 'nut',
    'Haselnüsse': 'nut',
    'Kaugummi': 'candy',
    'Kekse': 'cookie',
    'Mandeln': 'nut',
    'Nüsse': 'nut',
    'Plätzchen': 'cookie',
    'Popcorn': 'popcorn',
    'Salzstangen': 'pretzel',
    'Schokolade': 'chocolate',
    'Snacks': 'chips',
    'Süßigkeiten': 'candy',
    'Tortilla-Chips': 'chips',
    'Walnüsse': 'nut',
  },
  'getraenke': {
    'Apfelsaft': 'juice',
    'Bier': 'beer',
    'Champagner': 'flute',
    'Cola': 'soda',
    'Cola light': 'soda',
    'Eistee': 'soda',
    'Energydrink': 'soda',
    'Fruchtsaft': 'juice',
    'Gin': 'liquor',
    'Kaffee': 'coffee',
    'Kakao': 'coffee',
    'Limonade': 'soda',
    'Limonade light': 'soda',
    'Mineralwasser': 'water',
    'Orangensaft': 'juice',
    'Rotwein': 'wine',
    'Rum': 'liquor',
    'Schnaps': 'liquor',
    'Sekt': 'flute',
    'Smoothie': 'juice',
    'Sportgetränk': 'water',
    'Tee': 'tea',
    'Tonic Water': 'water',
    'Wasser': 'water',
    'Weißwein': 'wine',
    'Whisky': 'liquor',
    'Wodka': 'liquor',
    'Zigaretten': 'cigarette',
  },
  'haushalt': {
    'Alufolie': 'foil',
    'Backpapier': 'foil',
    'Badreiniger': 'spray',
    'Batterien': 'battery',
    'Frischhaltefolie': 'foil',
    'Geschenk': 'gift',
    'Geschenkpapier': 'gift',
    'Geschirrsalz': 'detergent',
    'Geschirrtabs': 'tab',
    'Glasreiniger': 'spray',
    'Glühbirne': 'bulb',
    'Insektenschutzmittel': 'spraycan',
    'Kerzen': 'candle',
    'Klarspüler': 'detergent',
    'Küchenrolle': 'paper',
    'Müllsäcke': 'trashbag',
    'Putzmittel': 'spray',
    'Schwamm': 'sponge',
    'Servietten': 'tissue',
    'Spülmittel': 'detergent',
    'Streichhölzer': 'matches',
    'Strohhalme': 'straw',
    'Toilettenpapier': 'paper',
    'Toilettenreiniger': 'spray',
    'Töpfe': 'pot',
    'Waschmittel': 'detergent',
    'Weichspüler': 'detergent',
    'Zahnstocher': 'straw',
  },
  'pflege_gesundheit': {
    'Babynahrung': 'babybottle',
    'Binden': 'drop',
    'Bodylotion': 'pump',
    'Deo': 'spraycan',
    'Duschgel': 'pump',
    'Feuchttücher': 'tissue',
    'Gesichtscreme': 'cream',
    'Haargel': 'tube',
    'Haarspray': 'spraycan',
    'Haarspülung': 'pump',
    'Handcreme': 'tube',
    'Kondome': 'heart',
    'Kosmetiktücher': 'tissue',
    'Linsenmittel': 'drop',
    'Lippenpflege': 'tube',
    'Make-up-Entferner': 'swab',
    'Mundspülung': 'tooth',
    'Nagellack': 'nailpolish',
    'Nagellackentferner': 'nailpolish',
    'Pflaster': 'bandage',
    'Rasierer': 'razor',
    'Rasierklingen': 'razor',
    'Rasierschaum': 'spraycan',
    'Schmerzmittel': 'pill',
    'Seife': 'pump',
    'Shampoo': 'pump',
    'Sonnencreme': 'sun',
    'Tampons': 'drop',
    'Taschentücher': 'tissue',
    'Vitamine': 'pill',
    'Wattepads': 'swab',
    'Wattestäbchen': 'swab',
    'Windeln': 'diaper',
    'Zahnbürsten': 'tooth',
    'Zahnpasta': 'tooth',
    'Zahnseide': 'tooth',
  },
  'tierbedarf': {
    'Fischfutter': 'fish',
    'Hundefutter': 'paw',
    'Hundesnack': 'bone',
    'Katzenfutter': 'paw',
    'Katzensnack': 'paw',
    'Katzenstreu': 'sack',
    'Vogelfutter': 'bird',
  },
  'baumarkt_garten': {
    'Blumen': 'flower',
    'Blumenerde': 'plant',
    'Dünger': 'plant',
    'Gartenwerkzeug': 'trowel',
    'Gießkanne': 'wateringcan',
    'Grill': 'grill',
    'Holzkohle': 'grill',
    'Nägel': 'screw',
    'Pflanzen': 'plant',
    'Pinsel': 'brush',
    'Propangas': 'gas',
    'Rasenmäher': 'mower',
    'Saatgut': 'plant',
    'Schrauben': 'screw',
    'Sonnenschirm': 'umbrella',
  },
};

/// Every article of the catalog by name.
final Map<String, Article> catalogArticles = {
  for (final category in _catalog.entries)
    for (final article in category.value.entries) article.key: Article(article.key, category.key, article.value),
};

/// The articles of a circle: the catalog with what the circle changed, and its own,
/// from the rows of GET shopping/articles.
Map<String, Article> mergeArticles(List<dynamic> rows) {
  final articles = Map.of(catalogArticles);
  for (final row in rows.cast<Map<String, dynamic>>()) {
    final name = row['name'] as String;
    final icon = row['icon'] as String? ?? '';
    final category = row['category'] as String? ?? '';
    if (row['custom'] == true) {
      articles[name] = Article(name, category.isEmpty ? ownCategory : category, icon, custom: true);
    } else if (articles[name] case final article?) {
      articles[name] = article.copyWith(
        icon: icon.isEmpty ? null : icon,
        category: category.isEmpty ? null : category,
      );
    }
  }
  return articles;
}

/// What a name looks like for searching: lower case, without the difference of ß and ss.
String searchKey(String text) => text.toLowerCase().replaceAll('ß', 'ss').trim();

/// The articles whose name contains [query], those that start with it first.
List<Article> searchArticles(Iterable<Article> articles, String query) {
  final key = searchKey(query);
  if (key.isEmpty) return [];
  final found = articles.where((a) => searchKey(a.name).contains(key)).toList()
    ..sort((a, b) {
      final aStarts = searchKey(a.name).startsWith(key);
      final bStarts = searchKey(b.name).startsWith(key);
      if (aStarts != bStarts) return aStarts ? -1 : 1;
      return a.name.compareTo(b.name);
    });
  return found;
}

/// A new name as it is saved: trimmed, with a capital first letter.
String capitalizedName(String text) {
  final trimmed = text.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (trimmed.isEmpty) return trimmed;
  final first = String.fromCharCode(trimmed.runes.first);
  return first.toUpperCase() + trimmed.substring(first.length);
}
