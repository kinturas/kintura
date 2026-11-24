import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

import '../api.dart';
import '../common.dart';
import '../live_updates.dart';
import '../session.dart';
import '../shopping/shopping_catalog.dart';
import '../shopping/shopping_icons.dart';
import '../shopping/shopping_outbox.dart';
import 'comment_tile.dart';

/// How urgent an article is, as the server keeps it; empty is no mark.
const _urgencies = {
  'urgent': ('Dringend', Icons.priority_high, Color(0xFFC62828)),
  'offer': ('Angebot', Icons.sell_outlined, Color(0xFF2E7D32)),
  'optional': ('Wenn’s passt', Icons.schedule, Color(0xFF6D6D6D)),
};

/// The color of a shopping list, or the one of the theme for a list without.
Color _listColor(BuildContext context, Map<String, dynamic> list) {
  final color = list['color'] as String? ?? '';
  return color.isEmpty ? Theme.of(context).colorScheme.primary : parseHexColor(color);
}

/// Einkaufen, as one page with two views: a list, or all lists.
///
/// It opens on [listId] if given, as from the calendar, else on the list one had open
/// last, else, as on the very first time, on all lists. Back from a list leaves the
/// page; back from all lists goes to the list one came from, and leaves the page only
/// when there is none.
class ShoppingScreen extends StatefulWidget {
  const ShoppingScreen({super.key, this.listId, this.showComments = false});

  final String? listId;

  /// Opens the comments of [listId] over the list.
  final bool showComments;

  @override
  State<ShoppingScreen> createState() => _ShoppingScreenState();
}

class _ShoppingScreenState extends State<ShoppingScreen> with LiveReload {
  final _view = GlobalKey<AsyncViewState<(List<dynamic>, List<dynamic>)>>();
  bool _started = false;
  bool _deciding = true;

  /// The list in view, or the one to go back to from all lists.
  Map<String, dynamic>? _current;
  bool _showsAll = false;

  /// The lists as last loaded, for moving articles and for coming back from all lists.
  List<dynamic> _lists = const [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    listenLive(const {'shopping'}, () => _view.currentState?.reload());
    _decide();
  }

  Future<void> _decide() async {
    final session = SessionScope.of(context);
    final base = '${session.familyPath}/shopping';
    try {
      final results = await Future.wait([
        if (widget.listId == null) session.api.get('$base/last'),
        session.api.get('$base/lists'),
      ]);
      final wanted = widget.listId ?? (results.first as Map<String, dynamic>?)?['list_id'] as String? ?? '';
      final lists = results.last as List;
      _keepOnDevice(session, lists);
      if (!mounted) return;
      setState(() {
        _lists = lists;
        _current = _find(lists, wanted);
        _showsAll = _current == null;
        _deciding = false;
      });
    } on ApiException {
      if (mounted) setState(() => _deciding = false);
    }
  }

  /// Loads every list and the articles behind the scenes, so that each list is on the
  /// device for shopping where there is no connection, not only the ones opened.
  static void _keepOnDevice(AppSession session, List<dynamic> lists) {
    if (session.api.offline.value || session.api.cache == null) return;
    final base = '${session.familyPath}/shopping';
    for (final path in ['$base/articles', for (final list in lists) '$base/lists/${(list as Map)['id']}/items']) {
      // What does not load now is simply not there offline.
      session.api.get(path).ignore();
    }
  }

  static Map<String, dynamic>? _find(List<dynamic> lists, String? id) =>
      lists.cast<Map<String, dynamic>>().where((l) => l['id'] == id).firstOrNull;

  /// Whether the comments asked for were shown; the list opened again does not open them.
  bool _commentsShown = false;

  void _showAll() => setState(() {
    _showsAll = true;
    _commentsShown = true;
  });

  void _show(Map<String, dynamic> list, List<dynamic> lists) => setState(() {
    _lists = lists;
    _current = list;
    _showsAll = false;
  });

  /// Back from all lists: to the list one came from, as it is now, if it is still there.
  void _back() {
    final list = _find(_lists, _current?['id'] as String?);
    if (list == null) {
      Navigator.of(context).pop();
    } else {
      _show(list, _lists);
    }
  }

  Future<void> _edit([Map<String, dynamic>? list]) async {
    final saved = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => _ListFormScreen(list: list)));
    if (saved == true) _view.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    if (_deciding) {
      return Scaffold(
        appBar: AppBar(title: const Text('Einkaufen')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_current case final list? when !_showsAll) {
      return ShoppingListScreen(
        key: ValueKey('shopping-list-${list['id']}'),
        list: list,
        lists: _lists,
        onShowLists: _showAll,
        // Only the first time; not again when coming back from all lists.
        showComments: widget.showComments && list['id'] == widget.listId && !_commentsShown,
      );
    }
    return PopScope(
      canPop: _current == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Einkaufen')),
        body: AsyncView<(List<dynamic>, List<dynamic>)>(
          key: _view,
          load: () async {
            final results = await Future.wait([
              session.api.get('${session.familyPath}/shopping/lists'),
              session.api.get('${session.familyPath}/members'),
            ]);
            _lists = results[0] as List;
            return (_lists, (results[1] as Map<String, dynamic>)['members'] as List);
          },
          builder: (context, data) {
            final (lists, members) = data;
            return RefreshIndicator(
              onRefresh: () async => _view.currentState?.reload(),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                children: [
                  if (lists.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 32),
                      child: EmptyHint(
                        icon: Icons.shopping_cart_outlined,
                        text: 'Noch keine Einkaufsliste. Lege die erste an.',
                      ),
                    ),
                  for (final list in lists.cast<Map<String, dynamic>>())
                    _ListCard(
                      list: list,
                      members: members,
                      onTap: () => _show(list, lists),
                      onEdit: list['can_edit'] == true ? () => _edit(list) : null,
                    ),
                  const SizedBox(height: 12),
                  Center(
                    child: OutlinedButton.icon(
                      key: const Key('shopping-new-list'),
                      icon: const Icon(Icons.add),
                      label: const Text('Neue Einkaufsliste'),
                      onPressed: () => _edit(),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ListCard extends StatelessWidget {
  const _ListCard({required this.list, required this.members, required this.onTap, this.onEdit});

  final Map<String, dynamic> list;
  final List<dynamic> members;
  final VoidCallback onTap;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final color = _listColor(context, list);
    final open = list['open_items'] as int? ?? 0;
    final ids = (list['assignee_ids'] as List? ?? const []).cast<String>();
    final assigned = [
      for (final m in members.cast<Map<String, dynamic>>())
        if (ids.contains(m['id'])) m,
    ];
    return Card(
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: InkWell(
        onTap: onTap,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 6, color: color),
              Expanded(
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: color,
                    foregroundColor: readableOn(color),
                    child: const Icon(Icons.shopping_cart_outlined),
                  ),
                  title: Text(list['name'] as String),
                  subtitle: Text(
                    [
                      open == 1 ? '1 Artikel offen' : '$open Artikel offen',
                      if (DateTime.tryParse(list['due_date'] as String? ?? '') case final due?)
                        'fällig ${dateFormat.format(due)}',
                      if ((list['category_name'] as String? ?? '').isNotEmpty) list['category_name'] as String,
                      if (list['can_write'] == false)
                        'nur lesend'
                      else if (list['visibility'] == 'all')
                        'für alle sichtbar',
                    ].join(' · '),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final m in assigned.take(3))
                        Padding(
                          padding: const EdgeInsets.only(left: 2),
                          child: UserAvatar(
                            m['name'] as String,
                            color: m['color'] as String? ?? '',
                            photo: m['avatar'] as String? ?? '',
                            radius: 12,
                          ),
                        ),
                      if (onEdit != null)
                        IconButton(
                          tooltip: 'Liste bearbeiten',
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: onEdit,
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A new shopping list, or the settings of one: name, color, the people it is for and
/// who may see it, as with events.
class _ListFormScreen extends StatefulWidget {
  const _ListFormScreen({this.list});

  final Map<String, dynamic>? list;

  @override
  State<_ListFormScreen> createState() => _ListFormScreenState();
}

class _ListFormScreenState extends State<_ListFormScreen> {
  late final _name = TextEditingController(text: widget.list?['name'] as String? ?? '');
  late String _color = widget.list?['color'] as String? ?? '';
  late bool _everyone = widget.list?['assignees_all'] as bool? ?? true;
  late final Set<String> _assignees = {...(widget.list?['assignee_ids'] as List? ?? const []).cast<String>()};
  late String _visibility = widget.list?['visibility'] as String? ?? 'participants';
  late String _category = widget.list?['category_id'] as String? ?? '';
  late DateTime? _due = DateTime.tryParse(widget.list?['due_date'] as String? ?? '');
  bool _saving = false;

  bool get _isNew => widget.list == null;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _toggle(String id) {
    setState(() {
      if (_everyone) {
        _everyone = false;
        _assignees
          ..clear()
          ..add(id);
      } else if (!_assignees.remove(id)) {
        _assignees.add(id);
      }
      if (_assignees.isEmpty) _everyone = true;
    });
  }

  Future<void> _save() async {
    final session = SessionScope.of(context);
    final navigator = Navigator.of(context);
    final body = {
      'name': _name.text.trim(),
      'color': _color,
      'assignees_all': _everyone,
      'assignee_ids': _everyone ? <String>[] : _assignees.toList(),
      'visibility': _visibility,
      'category_id': _category,
      'due_date': _due == null ? '' : dateKey(_due!),
    };
    setState(() => _saving = true);
    final ok = await guarded(context, () async {
      if (_isNew) {
        await session.api.post('${session.familyPath}/shopping/lists', body);
      } else {
        await session.api.put('${session.familyPath}/shopping/lists/${widget.list!['id']}', body);
      }
    });
    if (mounted) setState(() => _saving = false);
    if (ok) navigator.pop(true);
  }

  Future<void> _delete() async {
    final session = SessionScope.of(context);
    final navigator = Navigator.of(context);
    if (!await confirm(context, '„${widget.list!['name']}“ löschen?', message: 'Alle Artikel der Liste gehen mit.')) {
      return;
    }
    if (!mounted) return;
    final ok = await guarded(
      context,
      () => session.api.delete('${session.familyPath}/shopping/lists/${widget.list!['id']}'),
    );
    if (ok) navigator.pop(true);
  }

  Widget _section(String title, Widget child) => Padding(
    padding: const EdgeInsets.only(top: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        child,
      ],
    ),
  );

  Widget _personTile(String label, Widget avatar, bool selected, VoidCallback onTap) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: SizedBox(
          width: 64,
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: selected ? scheme.primary : Colors.transparent, width: 3),
                ),
                child: Opacity(opacity: selected ? 1 : 0.45, child: avatar),
              ),
              const SizedBox(height: 4),
              Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.labelSmall),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'Neue Einkaufsliste' : 'Liste bearbeiten'),
        actions: [
          if (!_isNew) IconButton(tooltip: 'Liste löschen', icon: const Icon(Icons.delete_outline), onPressed: _delete),
          TextButton(onPressed: _saving ? null : _save, child: const Text('Speichern')),
          const SizedBox(width: 8),
        ],
      ),
      body: AsyncView<(Map<String, dynamic>, List<dynamic>, List<dynamic>)>(
        load: () async {
          final results = await Future.wait([
            session.api.get('${session.familyPath}/colors'),
            session.api.get('${session.familyPath}/members'),
            session.api.get('${session.familyPath}/categories'),
          ]);
          return (
            results[0] as Map<String, dynamic>,
            (results[1] as Map<String, dynamic>)['members'] as List,
            (results[2] as Map<String, dynamic>)['categories'] as List,
          );
        },
        builder: (context, data) {
          final (colors, members, categories) = data;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 48),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 680),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        key: const Key('shopping-list-name'),
                        controller: _name,
                        autofocus: _isNew,
                        decoration: const InputDecoration(labelText: 'Name', hintText: 'z. B. Wocheneinkauf'),
                      ),
                      _section(
                        'Farbe',
                        ColorChooser(
                          colors: colors,
                          selected: _color,
                          singleList: true,
                          onSelected: (color) => setState(() => _color = color),
                        ),
                      ),
                      _section(
                        'Betrifft',
                        Wrap(
                          children: [
                            _personTile(
                              'Alle',
                              const CircleAvatar(radius: 18, child: Icon(Icons.groups)),
                              _everyone,
                              () => setState(() {
                                _everyone = true;
                                _assignees.clear();
                              }),
                            ),
                            for (final m in members.cast<Map<String, dynamic>>())
                              _personTile(
                                m['name'] as String,
                                UserAvatar(
                                  m['name'] as String,
                                  color: m['color'] as String? ?? '',
                                  photo: m['avatar'] as String? ?? '',
                                ),
                                !_everyone && _assignees.contains(m['id']),
                                () => _toggle(m['id'] as String),
                              ),
                          ],
                        ),
                      ),
                      _section(
                        'Kategorie',
                        DropdownButtonFormField<String>(
                          key: const Key('shopping-list-category'),
                          initialValue: categories.any((k) => k['id'] == _category) ? _category : '',
                          items: [
                            const DropdownMenuItem(value: '', child: Text('Keine')),
                            for (final k in categories.cast<Map<String, dynamic>>())
                              DropdownMenuItem(
                                value: k['id'] as String,
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.circle,
                                      size: 14,
                                      color: (k['color'] as String? ?? '').isEmpty
                                          ? Theme.of(context).colorScheme.primary
                                          : parseHexColor(k['color'] as String),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(k['name'] as String),
                                  ],
                                ),
                              ),
                          ],
                          onChanged: (value) => setState(() => _category = value ?? ''),
                        ),
                      ),
                      _section(
                        'Fällig am',
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            DateField(
                              key: const Key('shopping-list-due'),
                              label: 'Datum (optional)',
                              value: _due,
                              clearable: true,
                              onChanged: (date) => setState(() => _due = date),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Mit Datum steht die Liste im Kalender unter „Geplante Aufgaben“.',
                              style: Theme.of(
                                context,
                              ).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                      _section(
                        'Sichtbar für',
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SegmentedButton<String>(
                              segments: const [
                                ButtonSegment(value: 'participants', label: Text('Zugeteilte und Ersteller')),
                                ButtonSegment(value: 'all', label: Text('Jeden (lesend)')),
                              ],
                              selected: {_visibility},
                              onSelectionChanged: (value) => setState(() => _visibility = value.first),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _visibility == 'all'
                                  ? 'Alle im Kreis sehen die Liste. Ändern können sie nur die Personen, die sie betrifft.'
                                  : 'Nur die Personen, die sie betrifft, und wer sie angelegt hat, sehen und ändern die Liste.',
                              style: Theme.of(
                                context,
                              ).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// One shopping list: the articles on the list, the ones used lately and all articles
/// by category, with a search at the bottom. A tap puts an article on the list or checks it off,
/// a long press opens its page.
class ShoppingListScreen extends StatefulWidget {
  const ShoppingListScreen({
    super.key,
    required this.list,
    required this.lists,
    this.onShowLists,
    this.showComments = false,
  });

  final Map<String, dynamic> list;

  /// Opens the comments right away, over the list.
  final bool showComments;

  /// All lists one may see, to move articles between them.
  final List<dynamic> lists;

  /// Shows all lists instead of this one. Without it, as when opened from the
  /// overview, the button goes back there.
  final VoidCallback? onShowLists;

  @override
  State<ShoppingListScreen> createState() => _ShoppingListScreenState();
}

class _ShoppingListScreenState extends State<ShoppingListScreen> with LiveReload {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  Map<String, Article>? _articles;
  List<Map<String, dynamic>> _items = [];
  String? _error;
  final _expanded = <String>{};
  Timer? _timer;

  /// Pauses the regular reload while a page of an article is open.
  bool _paused = false;

  /// The list as last loaded; its name, color and rights change when it is edited.
  late Map<String, dynamic> _list = widget.list;

  String get _base => '${SessionScope.of(context).familyPath}/shopping';

  /// Kept, since the session is not to be looked up while the page is disposed.
  late final ShoppingOutbox _outbox = SessionScope.of(context).shopping;
  late final String _family = SessionScope.of(context).current!.id;
  int _waiting = 0;

  /// Whether to tell that changes wait for a connection. Not while they are only on
  /// their way, which takes a moment with every tap: the note would come and go and
  /// push the list down and up again.
  bool _showWaiting = false;

  /// Counts up with every change made here and every one that reached the server. An
  /// answer to a request from before is older than what shows, and is dropped.
  int _changes = 0;

  /// Once what waited has reached the server, the list shows the server's state again.
  void _outboxChanged() {
    final waiting = _outbox.waitingFor(_family, _list['id'] as String);
    final sent = waiting < _waiting;
    if (sent) _changes++;
    if (waiting != _waiting || (waiting == 0 && _showWaiting)) {
      setState(() {
        _waiting = waiting;
        if (waiting == 0) _showWaiting = false;
      });
    }
    if (sent) _load(articles: false);
  }

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _outbox.changes.addListener(_outboxChanged);
      _outboxChanged();
      // Waiting from before, as when the app was closed offline.
      if (_waiting > 0) setState(() => _showWaiting = true);
      _remember();
      _load();
      listenLive(const {'shopping'}, () {
        if (!_paused) _load();
      });
      // From a comment in Aktuelles: the comments over the list, so back leads here.
      if (widget.showComments) _showComments();
    });
    // Others shop with the same list. With a live connection the server tells of their
    // changes; without one this keeps it fresh.
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!_paused && !liveConnected) _load(articles: false);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _outbox.changes.removeListener(_outboxChanged);
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _load({bool articles = true}) async {
    final api = SessionScope.of(context).api;
    final base = _base;
    final changes = _changes;
    try {
      final results = await Future.wait([
        api.get('$base/lists/${_list['id']}/items'),
        if (articles || _articles == null) api.get('$base/articles'),
      ]);
      // Asked before the last change got through: it would show the list without it
      // for a moment. The load that came with the change follows.
      if (!mounted || (changes != _changes && _articles != null)) return;
      setState(() {
        // From the server or, offline, from the device: either way with what still waits.
        _items = _outbox.apply(_family, _list['id'] as String, (results[0] as List).cast<Map<String, dynamic>>());
        if (results.length > 1) _articles = mergeArticles(results[1] as List);
        // Made offline, the server does not know them yet. And entries whose article is
        // gone, left from before deleting took them along: own articles, so they can go.
        for (final name in [..._outbox.newArticles(_family), for (final item in _items) item['name'] as String]) {
          _articles?.putIfAbsent(name, () => Article(name, ownCategory, '', custom: true));
        }
        _error = null;
      });
    } on Exception catch (e) {
      if (mounted && _articles == null) setState(() => _error = e.toString());
    }
  }

  Map<String, dynamic>? _itemOf(String name) {
    for (final item in _items) {
      if (item['name'] == name) return item;
    }
    return null;
  }

  Article _articleOf(String name) =>
      _articles?[name] ?? catalogArticles[name] ?? Article(name, ownCategory, '', custom: true);

  bool _isOpen(String name) => _itemOf(name)?['done'] == false;

  /// Puts an article on the list, or back on it, or checks it off. It shows at once and
  /// counts on the device; without a connection it waits there for the server.
  Future<void> _set(String name, {required bool done, bool newArticle = false}) async {
    final session = SessionScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final change = ShoppingChange(
      family: _family,
      list: _list['id'] as String,
      name: name,
      done: done,
      newArticle: newArticle,
    );
    _changes++;
    await _outbox.put(change);
    if (!mounted) return;
    setState(() => _items = _outbox.apply(_family, _list['id'] as String, _items));
    final refused = await session.sendShopping();
    for (final message in refused) {
      messenger.showSnackBar(SnackBar(content: Text(message)));
    }
    if (!mounted) return;
    // Still there after sending: now it really waits for a connection.
    if (_outbox.waitingFor(_family, _list['id'] as String) > 0) setState(() => _showWaiting = true);
    await _load(articles: false);
  }

  Future<void> _add(String name) => _set(name, done: false);

  Future<void> _toggle(String name) => _set(name, done: _isOpen(name));

  /// Makes an article of the circle's own from what was typed, and puts it on the list.
  /// Offline too: the server makes it with the change, see [ShoppingChange.newArticle].
  Future<void> _addOwn(String text) async {
    final name = capitalizedName(text);
    if (name.isEmpty) return;
    setState(() => _articles?.putIfAbsent(name, () => Article(name, ownCategory, '', custom: true)));
    _search.clear();
    await _set(name, done: false, newArticle: true);
  }

  Future<void> _openArticle(String name) async {
    _paused = true;
    final lists = await _visibleLists();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _ArticleScreen(
          article: _articleOf(name),
          item: _itemOf(name),
          list: _list,
          lists: lists,
          articles: _articles?.values ?? catalogArticles.values,
        ),
      ),
    );
    _paused = false;
    if (mounted) await _load();
  }

  Future<List<dynamic>> _visibleLists() async {
    final session = SessionScope.of(context);
    try {
      return await session.api.get('$_base/lists') as List;
    } on Exception {
      return widget.lists;
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _listColor(context, _list);
    final articles = _articles;
    return Scaffold(
      appBar: AppBar(
        title: Text(_list['name'] as String),
        actions: [
          IconButton(
            key: const Key('shopping-comments'),
            tooltip: 'Kommentare',
            icon: Badge(
              isLabelVisible: (_list['comment_count'] as num? ?? 0) > 0,
              label: Text('${_list['comment_count'] ?? 0}'),
              child: const Icon(Icons.chat_bubble_outline),
            ),
            onPressed: _showComments,
          ),
          if (_list['can_edit'] == true)
            IconButton(
              key: const Key('shopping-edit-list'),
              tooltip: 'Liste bearbeiten',
              icon: const Icon(Icons.edit_outlined),
              onPressed: _editList,
            ),
          IconButton(
            key: const Key('shopping-all-lists'),
            tooltip: 'Alle Einkaufslisten',
            icon: const Icon(Icons.format_list_bulleted),
            onPressed: widget.onShowLists ?? () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: 4),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(4),
          child: Container(height: 4, color: color),
        ),
      ),
      body: articles == null
          ? Center(child: _error == null ? const CircularProgressIndicator() : Text(_error!))
          : Column(
              children: [
                if (_showWaiting && _waiting > 0)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Row(
                      key: const Key('shopping-waiting'),
                      children: [
                        Icon(Icons.cloud_off_outlined, size: 18, color: Theme.of(context).colorScheme.onSurfaceVariant),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _waiting == 1
                                ? '1 Änderung ist auf dem Gerät gespeichert und wartet auf Verbindung.'
                                : '$_waiting Änderungen sind auf dem Gerät gespeichert und warten auf Verbindung.',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                if (_readOnly)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Card(
                      key: const Key('shopping-read-only'),
                      elevation: 0,
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      child: const ListTile(
                        leading: Icon(Icons.visibility_outlined),
                        title: Text('Nur lesend'),
                        subtitle: Text(_readOnlyHint),
                      ),
                    ),
                  ),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: _load,
                    child: _search.text.trim().isEmpty ? _overview(articles) : _results(articles),
                  ),
                ),
                // At the bottom, where the thumb is; the keyboard pushes it up.
                if (!_readOnly)
                  SafeArea(
                    top: false,
                    minimum: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                    child: TextField(
                      key: const Key('shopping-search'),
                      controller: _search,
                      focusNode: _searchFocus,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        hintText: 'Ich möchte einkaufen …',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: _search.text.isEmpty
                            ? null
                            : IconButton(tooltip: 'Leeren', icon: const Icon(Icons.close), onPressed: _search.clear),
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                      onSubmitted: (text) {
                        final found = searchArticles(articles.values, text);
                        if (found.isNotEmpty && searchKey(found.first.name) == searchKey(text)) {
                          _search.clear();
                          _add(found.first.name);
                        } else if (text.trim().isNotEmpty) {
                          _addOwn(text);
                        }
                        _searchFocus.requestFocus();
                      },
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _results(Map<String, Article> articles) {
    final text = _search.text;
    final found = searchArticles(articles.values, text);
    final exact = found.any((a) => searchKey(a.name) == searchKey(text));
    final own = capitalizedName(text);
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
      children: [
        _Tiles([
          for (final article in found) _tile(article),
          if (!exact)
            _ArticleTile(
              key: const Key('shopping-own-article'),
              name: own,
              icon: '',
              onList: false,
              badge: Icons.add,
              onTap: () => _addOwn(text),
            ),
        ]),
      ],
    );
  }

  Widget _tile(Article article, {Map<String, dynamic>? item}) {
    final entry = item ?? _itemOf(article.name);
    final open = entry?['done'] == false;
    final urgency = _urgencies[entry?['urgency']];
    return _ArticleTile(
      key: ValueKey('article-${article.name}'),
      name: article.name,
      icon: article.icon,
      detail: open ? _detailOf(entry!) : '',
      onList: open,
      badge: open ? urgency?.$2 : null,
      badgeColor: urgency?.$3,
      hasPhotos: open && ((entry!['photo_ids'] as List?)?.isNotEmpty ?? false),
      onTap: () {
        if (_readOnly) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(const SnackBar(content: Text(_readOnlyHint)));
          return;
        }
        if (_search.text.isNotEmpty) _search.clear();
        _toggle(article.name);
      },
      onLongPress: _readOnly ? null : () => _openArticle(article.name),
    );
  }

  /// Tells the server this list was open last, for Einkaufen to come back to it.
  Future<void> _remember() async {
    final session = SessionScope.of(context);
    try {
      await session.api.put('$_base/last', {'list_id': _list['id']});
    } on ApiException {
      // Next time the overview comes first; nothing lost.
    }
  }

  Future<void> _showComments() async {
    final session = SessionScope.of(context);
    _paused = true;
    await Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => ShoppingCommentsScreen(list: _list)));
    _paused = false;
    if (!mounted) return;
    // For the number on the button.
    try {
      final lists = (await session.api.get('$_base/lists') as List).cast<Map<String, dynamic>>();
      final updated = lists.where((l) => l['id'] == _list['id']).firstOrNull;
      if (mounted && updated != null) setState(() => _list = updated);
    } on ApiException {
      // The number stays as it was.
    }
  }

  Future<void> _editList() async {
    final session = SessionScope.of(context);
    final saved = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => _ListFormScreen(list: _list)));
    if (saved != true || !mounted) return;
    List<dynamic>? lists;
    await guarded(context, () async {
      lists = await session.api.get('$_base/lists') as List;
    });
    if (!mounted || lists == null) return;
    final updated = lists!.cast<Map<String, dynamic>>().where((l) => l['id'] == _list['id']).firstOrNull;
    if (updated == null) {
      // Deleted, or no longer visible: back to all lists.
      (widget.onShowLists ?? () => Navigator.of(context).pop())();
      return;
    }
    setState(() => _list = updated);
  }

  /// Visible to everyone, but not for this user: looking only.
  bool get _readOnly => _list['can_write'] == false;

  static const _readOnlyHint = 'Diese Liste kannst du nur ansehen. Ändern können sie die Personen, die sie betrifft.';

  Widget _overview(Map<String, Article> articles) {
    final open = _items.where((i) => i['done'] == false).toList();
    final recent = _items.where((i) => i['done'] == true).take(30).toList();
    final byCategory = <String, List<Article>>{};
    for (final article in articles.values) {
      byCategory.putIfAbsent(article.category, () => []).add(article);
    }
    for (final list in byCategory.values) {
      list.sort((a, b) => a.name.compareTo(b.name));
    }
    final text = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
      children: [
        if (open.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text(
              _readOnly
                  ? 'Auf der Liste steht gerade nichts.'
                  : 'Die Liste ist leer. Suche unten oder tippe auf einen Artikel.',
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          )
        else
          _Tiles([for (final item in open) _tile(_articleOf(item['name'] as String), item: item)]),
        if (recent.isNotEmpty && !_readOnly) ...[
          _Header(icon: Icons.history, label: 'Zuletzt verwendet'),
          _Tiles([for (final item in recent) _tile(_articleOf(item['name'] as String), item: item)]),
        ],
        for (final category in _readOnly ? const <ShoppingCategory>[] : shoppingCategories)
          if (byCategory[category.key] case final list? when list.isNotEmpty) ...[
            _Header(
              icon: category.icon,
              label: category.label,
              count: list.where((a) => _isOpen(a.name)).length,
              expanded: _expanded.contains(category.key),
              onTap: () => setState(() {
                if (!_expanded.remove(category.key)) _expanded.add(category.key);
              }),
            ),
            if (_expanded.contains(category.key)) _Tiles([for (final article in list) _tile(article)]),
          ],
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.icon, required this.label, this.count = 0, this.expanded, this.onTap});

  final IconData icon;
  final String label;
  final int count;

  /// Null for a section that cannot be folded.
  final bool? expanded;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Row(
            children: [
              Icon(icon, size: 20, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(child: Text(label, style: Theme.of(context).textTheme.titleSmall)),
              if (count > 0)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Badge(label: Text('$count'), backgroundColor: scheme.primary, textColor: scheme.onPrimary),
                ),
              if (expanded != null) Icon(expanded! ? Icons.expand_less : Icons.expand_more),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tiles extends StatelessWidget {
  const _Tiles(this.children);

  final List<Widget> children;

  static const _spacing = 8.0;

  /// The block is as wide as the columns that fit and stands in the middle, so that
  /// what is left over is shared between left and right. A last row that is not full
  /// still starts on the left of the block, in line with the ones above.
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: LayoutBuilder(
      builder: (context, constraints) {
        const step = _ArticleTile.width + _spacing;
        final columns = ((constraints.maxWidth + _spacing) / step).floor().clamp(1, 1000);
        return Center(
          child: SizedBox(
            width: columns * step - _spacing,
            child: Wrap(spacing: _spacing, runSpacing: _spacing, children: children),
          ),
        );
      },
    ),
  );
}

/// Tile colors, the same on every list: grey for what is on the list, light green
/// for what can be added. Both with a dark or white text that reads well.
const _onListBackground = Color(0xFF5F6368);
const _onListForeground = Colors.white;
const _addBackground = Color(0xFFC8E6B5);
const _addBackgroundDark = Color(0xFFA9D48F);
const _addForeground = Color(0xFF173A0C);

class _ArticleTile extends StatelessWidget {
  static const width = 120.0;

  const _ArticleTile({
    super.key,
    required this.name,
    required this.icon,
    required this.onList,
    required this.onTap,
    this.onLongPress,
    this.detail = '',
    this.badge,
    this.badgeColor,
    this.hasPhotos = false,
  });

  final String name;
  final String icon;
  final String detail;

  /// On the list: grey. Otherwise light green, to be added with a tap.
  final bool onList;
  final IconData? badge;
  final Color? badgeColor;
  final bool hasPhotos;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final background = onList ? _onListBackground : (dark ? _addBackgroundDark : _addBackground);
    final foreground = onList ? _onListForeground : _addForeground;
    return SizedBox(
      width: width,
      height: 128,
      child: Material(
        color: background,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 10, 6, 8),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    ArticleIcon(icon: icon, name: name, size: 60, color: foreground),
                    const SizedBox(height: 8),
                    Text(
                      name,
                      maxLines: detail.isEmpty ? 2 : 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: Theme.of(
                        context,
                      ).textTheme.titleSmall?.copyWith(color: foreground, height: 1.15, fontWeight: FontWeight.w600),
                    ),
                    if (detail.isNotEmpty)
                      Text(
                        detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: Theme.of(
                          context,
                        ).textTheme.labelMedium?.copyWith(color: foreground.withValues(alpha: 0.85)),
                      ),
                  ],
                ),
              ),
              if (badge != null)
                Positioned(
                  top: 6,
                  right: 6,
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(color: badgeColor ?? _addForeground, shape: BoxShape.circle),
                    child: Icon(badge, size: 18, color: Colors.white),
                  ),
                ),
              if (hasPhotos)
                Positioned(top: 6, left: 4, child: Icon(Icons.photo_camera_outlined, size: 18, color: foreground)),
            ],
          ),
        ),
      ),
    );
  }
}

/// What is noted about an article on the list, in one text. Older entries may still
/// have it in two fields.
String _detailOf(Map<String, dynamic> item) => [
  item['amount'] as String? ?? '',
  item['note'] as String? ?? '',
].map((s) => s.trim()).where((s) => s.isNotEmpty).join(', ');

/// The page of an article: what to note about it on the list, its category, and for an
/// own article the icon, photos, another list for it, and deleting an own article.
class _ArticleScreen extends StatefulWidget {
  const _ArticleScreen({
    required this.article,
    required this.item,
    required this.list,
    required this.lists,
    required this.articles,
  });

  final Article article;
  final Map<String, dynamic>? item;
  final Map<String, dynamic> list;
  final List<dynamic> lists;

  /// All articles, to search icons by the names of the articles that use them.
  final Iterable<Article> articles;

  @override
  State<_ArticleScreen> createState() => _ArticleScreenState();
}

class _ArticleScreenState extends State<_ArticleScreen> {
  late Map<String, dynamic>? _item = widget.item == null ? null : Map.of(widget.item!);
  late final String _initialDetail = widget.item == null ? '' : _detailOf(widget.item!);
  late final _detail = TextEditingController(text: _initialDetail);
  late final String _initialUrgency = widget.item?['urgency'] as String? ?? '';
  late String _urgency = _initialUrgency;
  late String _icon = widget.article.icon;
  late String _category = widget.article.category;
  late String _listId = widget.list['id'] as String;
  bool _saving = false;

  String get _base => '${SessionScope.of(context).familyPath}/shopping';

  List<String> get _photos => ((_item?['photo_ids'] as List?) ?? const []).cast<String>();

  /// Photos are saved at once; everything else waits for "Speichern".
  bool get _changed =>
      _detail.text.trim() != _initialDetail ||
      _urgency != _initialUrgency ||
      _icon != widget.article.icon ||
      _category != widget.article.category ||
      _listId != widget.list['id'];

  @override
  void initState() {
    super.initState();
    _detail.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _detail.dispose();
    super.dispose();
  }

  /// Puts the article on the list first where something about it needs an entry.
  Future<Map<String, dynamic>?> _ensureItem() async {
    final item = _item;
    if (item != null && (item['id'] as String? ?? '').isNotEmpty) return item;
    final session = SessionScope.of(context);
    Map<String, dynamic>? created;
    await guarded(context, () async {
      final result = await session.api.post('$_base/lists/${widget.list['id']}/items', {'name': widget.article.name});
      created = {
        'id': (result as Map<String, dynamic>)['id'],
        'name': widget.article.name,
        'done': false,
        'photo_ids': <String>[],
      };
    });
    if (created != null && mounted) setState(() => _item = created);
    return created;
  }

  Future<void> _save() async {
    final session = SessionScope.of(context);
    final navigator = Navigator.of(context);
    setState(() => _saving = true);
    final ok = await guarded(context, () async {
      if (_icon != widget.article.icon || _category != widget.article.category) {
        await session.api.put('$_base/articles', {'name': widget.article.name, 'icon': _icon, 'category': _category});
      }
      final detail = _detail.text.trim();
      final details = detail != _initialDetail || _urgency != _initialUrgency;
      final moved = _listId != widget.list['id'];
      if (!details && !moved) return;
      final item = await _ensureItem();
      if (item == null) throw StateError('no item');
      await session.api.put('$_base/items/${item['id']}', {
        'amount': detail,
        'note': '',
        'urgency': _urgency,
        'done': item['done'] ?? false,
        'list_id': _listId,
      });
    });
    if (mounted) setState(() => _saving = false);
    if (ok) navigator.pop();
  }

  /// Asks what to do with changes not saved yet when leaving the page.
  Future<void> _leave() async {
    final navigator = Navigator.of(context);
    final choice = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Änderungen speichern?'),
        content: const Text('Du hast etwas geändert und noch nicht gespeichert.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Weiter bearbeiten')),
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Verwerfen')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Speichern')),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    if (choice) {
      await _save();
    } else {
      navigator.pop();
    }
  }

  Future<void> _remove() async {
    final item = _item;
    if (item == null) return;
    final session = SessionScope.of(context);
    final navigator = Navigator.of(context);
    final ok = await guarded(context, () => session.api.delete('$_base/items/${item['id']}'));
    if (ok) navigator.pop();
  }

  Future<void> _deleteArticle() async {
    final session = SessionScope.of(context);
    final navigator = Navigator.of(context);
    // Other lists the server checks.
    if (_item?['done'] == false) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '„${widget.article.name}“ steht auf der Liste. Nimm ihn erst herunter, dann lässt er sich löschen.',
          ),
        ),
      );
      return;
    }
    if (!await confirm(
      context,
      '„${widget.article.name}“ löschen?',
      message: 'Der Artikel wird ganz gelöscht, auch unter „Zuletzt verwendet“ auf allen Listen.',
    )) {
      return;
    }
    if (!mounted) return;
    final ok = await guarded(
      context,
      () => session.api.delete('$_base/articles?name=${Uri.encodeQueryComponent(widget.article.name)}'),
    );
    if (ok) navigator.pop();
  }

  Future<void> _pickIcon() async {
    final picked = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => _IconPickerScreen(name: widget.article.name, selected: _icon, articles: widget.articles),
      ),
    );
    if (picked != null && mounted) setState(() => _icon = picked);
  }

  Future<void> _addPhoto() async {
    final session = SessionScope.of(context);
    final files = await FilePicker.pickFiles(type: FileType.image);
    if (files.isEmpty || !mounted) return;
    final raw = await files.first.readAsBytes();
    final bytes = await compute(_shrinkPhoto, raw);
    if (!mounted) return;
    final item = await _ensureItem();
    if (item == null || !mounted) return;
    await guarded(context, () async {
      final result = await session.api.upload('$_base/items/${item['id']}/photos', 'foto.jpg', bytes);
      setState(
        () => _item = {
          ...item,
          'photo_ids': [..._photos, (result as Map<String, dynamic>)['id'] as String],
        },
      );
    });
  }

  Future<void> _showPhoto(String id) async {
    final session = SessionScope.of(context);
    final deleted = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => _PhotoScreen(path: '$_base/photos/$id', title: widget.article.name),
      ),
    );
    if (deleted != true || !mounted) return;
    final ok = await guarded(context, () => session.api.delete('$_base/photos/$id'));
    if (ok) setState(() => _item = {..._item!, 'photo_ids': _photos.where((p) => p != id).toList()});
  }

  Widget _section(String title, Widget child) => Padding(
    padding: const EdgeInsets.only(top: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        child,
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final article = widget.article;
    final onList = _item?['done'] == false;
    final otherLists = widget.lists.cast<Map<String, dynamic>>();
    final icon = Padding(
      padding: const EdgeInsets.all(16),
      child: ArticleIcon(icon: _icon, name: article.name, size: 56),
    );
    return PopScope(
      canPop: !_changed || _saving,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(article.name),
          actions: [
            if (article.custom)
              IconButton(tooltip: 'Artikel löschen', icon: const Icon(Icons.delete_outline), onPressed: _deleteArticle),
            TextButton(onPressed: _saving ? null : _save, child: const Text('Speichern')),
            const SizedBox(width: 8),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 48),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Material(
                          color: scheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(16),
                          child: article.custom
                              ? InkWell(
                                  key: const Key('article-icon'),
                                  borderRadius: BorderRadius.circular(16),
                                  onTap: _pickIcon,
                                  child: icon,
                                )
                              : icon,
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(article.name, style: Theme.of(context).textTheme.headlineSmall),
                              const SizedBox(height: 4),
                              Text(
                                onList ? 'Auf „${widget.list['name']}“' : 'Nicht auf der Liste',
                                style: TextStyle(color: scheme.onSurfaceVariant),
                              ),
                              if (article.custom)
                                TextButton.icon(
                                  style: TextButton.styleFrom(padding: EdgeInsets.zero),
                                  icon: const Icon(Icons.edit_outlined, size: 18),
                                  label: const Text('Symbol ändern'),
                                  onPressed: _pickIcon,
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    _section(
                      'Menge und Beschreibung',
                      TextField(
                        key: const Key('article-detail'),
                        controller: _detail,
                        minLines: 1,
                        maxLines: 4,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: const InputDecoration(hintText: 'z. B. 2 Packungen, laktosefrei'),
                      ),
                    ),
                    _section(
                      'Dringlichkeit',
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          ChoiceChip(
                            label: const Text('Normal'),
                            selected: _urgency.isEmpty,
                            onSelected: (_) => setState(() => _urgency = ''),
                          ),
                          for (final entry in _urgencies.entries)
                            ChoiceChip(
                              key: Key('urgency-${entry.key}'),
                              avatar: Icon(entry.value.$2, size: 18, color: entry.value.$3),
                              label: Text(entry.value.$1),
                              selected: _urgency == entry.key,
                              onSelected: (_) => setState(() => _urgency = entry.key),
                            ),
                        ],
                      ),
                    ),
                    _section(
                      'Kategorie',
                      DropdownButtonFormField<String>(
                        key: const Key('article-category'),
                        initialValue: _category,
                        items: [
                          for (final category in shoppingCategories)
                            if (category.key != ownCategory || article.custom)
                              DropdownMenuItem(value: category.key, child: Text(category.label)),
                        ],
                        onChanged: (value) => setState(() => _category = value ?? _category),
                      ),
                    ),
                    if (otherLists.length > 1)
                      _section(
                        'Liste',
                        DropdownButtonFormField<String>(
                          key: const Key('article-list'),
                          initialValue: _listId,
                          items: [
                            for (final list in otherLists)
                              DropdownMenuItem(
                                value: list['id'] as String,
                                child: Row(
                                  children: [
                                    Icon(Icons.circle, size: 14, color: _listColor(context, list)),
                                    const SizedBox(width: 8),
                                    Text(list['name'] as String),
                                  ],
                                ),
                              ),
                          ],
                          onChanged: (value) => setState(() => _listId = value ?? _listId),
                        ),
                      ),
                    _section(
                      'Fotos',
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final id in _photos) _PhotoThumb(path: '$_base/photos/$id', onTap: () => _showPhoto(id)),
                          if (_photos.length < 6)
                            SizedBox(
                              width: 88,
                              height: 88,
                              child: OutlinedButton(
                                key: const Key('article-add-photo'),
                                style: OutlinedButton.styleFrom(
                                  padding: EdgeInsets.zero,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                                onPressed: _addPhoto,
                                child: const Icon(Icons.add_a_photo_outlined),
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (_item != null && (_item!['id'] as String? ?? '').isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 32),
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.remove_shopping_cart_outlined),
                          label: const Text('Von der Liste entfernen'),
                          onPressed: _remove,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Picks an icon for an own article. The search finds icons by the names of the
/// articles that use them, so "Bier" finds the bottle and "Apfel" the apple.
/// Pops with the key of the icon, or an empty one for the first letter.
class _IconPickerScreen extends StatefulWidget {
  const _IconPickerScreen({required this.name, required this.selected, required this.articles});

  final String name;
  final String selected;
  final Iterable<Article> articles;

  @override
  State<_IconPickerScreen> createState() => _IconPickerScreenState();
}

class _IconPickerScreenState extends State<_IconPickerScreen> {
  final _search = TextEditingController();

  /// The names of the articles behind each icon, sorted.
  late final Map<String, List<String>> _names = () {
    final names = {for (final key in shoppingIcons.keys) key: <String>[]};
    for (final article in widget.articles) {
      names[article.icon]?.add(article.name);
    }
    for (final list in names.values) {
      list.sort();
    }
    return names;
  }();

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Widget _choice(String key, String label, Widget icon) {
    final scheme = Theme.of(context).colorScheme;
    final selected = key == widget.selected;
    return Material(
      color: selected ? scheme.primaryContainer : scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: Key(key.isEmpty ? 'icon-letter' : 'icon-$key'),
        onTap: () => Navigator.pop(context, key),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 10, 4, 6),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              icon,
              const SizedBox(height: 6),
              Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: selected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final query = searchKey(_search.text);
    final matches = <(String, String)>[];
    for (final MapEntry(key: key, value: names) in _names.entries) {
      if (query.isEmpty) {
        matches.add((key, names.isEmpty ? '' : names.first));
        continue;
      }
      // Names that start with the search first, then any that contain it.
      final hit =
          names.where((n) => searchKey(n).startsWith(query)).firstOrNull ??
          names.where((n) => searchKey(n).contains(query)).firstOrNull;
      if (hit != null) matches.add((key, hit));
    }
    if (query.isNotEmpty) {
      matches.sort((a, b) {
        final ap = searchKey(a.$2).startsWith(query) ? 0 : 1;
        final bp = searchKey(b.$2).startsWith(query) ? 0 : 1;
        return ap != bp ? ap - bp : a.$2.compareTo(b.$2);
      });
    }
    final iconColor = Theme.of(context).colorScheme.onSurface;
    return Scaffold(
      appBar: AppBar(title: const Text('Symbol wählen')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              key: const Key('icon-search'),
              controller: _search,
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'Symbol suchen, z. B. Apfel oder Flasche',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(tooltip: 'Leeren', icon: const Icon(Icons.close), onPressed: _search.clear),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          Expanded(
            child: matches.isEmpty
                ? const EmptyHint(icon: Icons.search_off, text: 'Kein Symbol gefunden. Versuche ein anderes Wort.')
                : GridView.extent(
                    maxCrossAxisExtent: 96,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 0.9,
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
                    children: [
                      if (query.isEmpty)
                        _choice(
                          '',
                          'Anfangsbuchstabe',
                          ArticleIcon(icon: '', name: widget.name, size: 36, color: iconColor),
                        ),
                      for (final (key, label) in matches)
                        _choice(key, label, ArticleIcon(icon: key, name: '', size: 36, color: iconColor)),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// A JPEG of at most 1280 pixels on the long side; photos from a phone stay small that way.
Uint8List _shrinkPhoto(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return bytes;
  const max = 1280;
  final image = decoded.width >= decoded.height
      ? (decoded.width > max ? img.copyResize(decoded, width: max) : decoded)
      : (decoded.height > max ? img.copyResize(decoded, height: max) : decoded);
  return img.encodeJpg(image, quality: 82);
}

/// Photos once loaded, by path, so that lists and pages do not fetch them again.
final _photoCache = <String, Uint8List>{};

Future<Uint8List> _loadPhoto(AppSession session, String path) async =>
    _photoCache[path] ??= await session.api.getBytes(path);

class _PhotoThumb extends StatelessWidget {
  const _PhotoThumb({required this.path, required this.onTap});

  final String path;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    return SizedBox(
      width: 88,
      height: 88,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          child: FutureBuilder<Uint8List>(
            future: _loadPhoto(session, path),
            builder: (context, snapshot) => snapshot.hasData
                ? Image.memory(snapshot.data!, fit: BoxFit.cover)
                : Container(color: Theme.of(context).colorScheme.surfaceContainerHighest),
          ),
        ),
      ),
    );
  }
}

/// One photo, large. Pops with true when it is to be deleted.
class _PhotoScreen extends StatelessWidget {
  const _PhotoScreen({required this.path, required this.title});

  final String path;
  final String title;

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            tooltip: 'Foto löschen',
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              if (await confirm(context, 'Foto löschen?') && context.mounted) Navigator.pop(context, true);
            },
          ),
        ],
      ),
      body: FutureBuilder<Uint8List>(
        future: _loadPhoto(session, path),
        builder: (context, snapshot) => snapshot.hasData
            ? InteractiveViewer(child: Center(child: Image.memory(snapshot.data!)))
            : const Center(child: CircularProgressIndicator()),
      ),
    );
  }
}

/// The comments on a shopping list, the oldest first, with a field to add one at the
/// bottom. Whoever sees the list may comment, also on a list only to look at.
class ShoppingCommentsScreen extends StatefulWidget {
  const ShoppingCommentsScreen({super.key, required this.list});

  final Map<String, dynamic> list;

  @override
  State<ShoppingCommentsScreen> createState() => _ShoppingCommentsScreenState();
}

class _ShoppingCommentsScreenState extends State<ShoppingCommentsScreen> with LiveReload {
  final _comment = TextEditingController();
  final _scroll = ScrollController();
  List<Map<String, dynamic>>? _comments;
  String? _error;
  bool _sending = false;
  bool _started = false;

  String get _path => '${SessionScope.of(context).familyPath}/shopping/lists/${widget.list['id']}/comments';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _load();
    listenLive(const {'shopping'}, _load);
  }

  @override
  void dispose() {
    _comment.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final session = SessionScope.of(context);
    try {
      final rows = (await session.api.get(_path) as List).cast<Map<String, dynamic>>();
      if (!mounted) return;
      final grew = rows.length > (_comments?.length ?? 0);
      setState(() {
        _comments = rows;
        _error = null;
      });
      // The newest are at the bottom, next to the field.
      if (grew) WidgetsBinding.instance.addPostFrameCallback((_) => _toEnd());
    } on ApiException catch (e) {
      if (mounted && _comments == null) setState(() => _error = e.message);
    }
  }

  void _toEnd() {
    if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
  }

  Future<void> _send() async {
    final body = _comment.text.trim();
    if (body.isEmpty || _sending) return;
    final session = SessionScope.of(context);
    setState(() => _sending = true);
    final ok = await guarded(context, () => session.api.post(_path, {'body': body}));
    if (!mounted) return;
    setState(() => _sending = false);
    if (!ok) return;
    _comment.clear();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final comments = _comments;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: Text('Kommentare: ${widget.list['name']}'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(4),
          child: Container(height: 4, color: _listColor(context, widget.list)),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: comments == null
                ? Center(child: _error == null ? const CircularProgressIndicator() : Text(_error!))
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      children: [
                        if (comments.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 24),
                            child: Text(
                              'Noch keine Kommentare. Schreib etwas für alle, die diese Liste sehen.',
                              textAlign: TextAlign.center,
                              style: text.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                            ),
                          ),
                        for (final comment in comments) CommentTile(comment: comment, path: _path, onChanged: _load),
                      ],
                    ),
                  ),
          ),
          SafeArea(
            top: false,
            minimum: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: CallbackShortcuts(
              // On a keyboard, Enter starts a new line and Shift + Enter sends.
              bindings: {
                const SingleActivator(LogicalKeyboardKey.enter, shift: true): _send,
                const SingleActivator(LogicalKeyboardKey.numpadEnter, shift: true): _send,
              },
              child: TextField(
                key: const Key('shopping-comment'),
                controller: _comment,
                minLines: 1,
                maxLines: 5,
                maxLength: 2000,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: 'Kommentar',
                  border: const OutlineInputBorder(),
                  counterText: '',
                  suffixIcon: IconButton(
                    key: const Key('shopping-comment-send'),
                    tooltip: 'Kommentar senden',
                    icon: const Icon(Icons.send),
                    onPressed: _sending ? null : _send,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
