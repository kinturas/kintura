import 'package:flutter/material.dart';

import '../common.dart';
import '../session.dart';

class ListsScreen extends StatefulWidget {
  const ListsScreen({super.key});

  @override
  State<ListsScreen> createState() => _ListsScreenState();
}

class _ListsScreenState extends State<ListsScreen> {
  final _view = GlobalKey<AsyncViewState<List<dynamic>>>();

  Future<void> _add() async {
    final session = SessionScope.of(context);
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (_) => const _NewListDialog(),
    );
    if (result == null || !mounted) return;
    final ok = await guarded(
      context,
      () => session.api.post('${session.familyPath}/lists', {
        'name': result.$1,
        'kind': result.$2,
      }),
    );
    if (ok) _view.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Listen')),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Neue Liste',
        onPressed: _add,
        child: const Icon(Icons.add),
      ),
      body: AsyncView<List<dynamic>>(
        key: _view,
        load: () async =>
            await session.api.get('${session.familyPath}/lists') as List,
        builder: (context, lists) {
          if (lists.isEmpty) {
            return const EmptyHint(
              icon: Icons.checklist,
              text: 'Noch keine Listen. Lege zum Beispiel eine Einkaufsliste an.',
            );
          }
          return ListView(
            children: [
              for (final list in lists)
                ListTile(
                  leading: Icon(
                    list['kind'] == 'shopping'
                        ? Icons.shopping_cart_outlined
                        : Icons.task_alt,
                  ),
                  title: Text(list['name'] as String),
                  subtitle: Text('${list['open_items']} offen'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => _ListDetailScreen(list)),
                    );
                    _view.currentState?.reload();
                  },
                ),
            ],
          );
        },
      ),
    );
  }
}

class _NewListDialog extends StatefulWidget {
  const _NewListDialog();

  @override
  State<_NewListDialog> createState() => _NewListDialogState();
}

class _NewListDialogState extends State<_NewListDialog> {
  final _name = TextEditingController();
  String _kind = 'shopping';

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Neue Liste'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          const SizedBox(height: 16),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'shopping', label: Text('Einkauf')),
              ButtonSegment(value: 'tasks', label: Text('Aufgaben')),
            ],
            selected: {_kind},
            onSelectionChanged: (s) => setState(() => _kind = s.first),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, (_name.text.trim(), _kind)),
          child: const Text('Anlegen'),
        ),
      ],
    );
  }
}

class _ListDetailScreen extends StatefulWidget {
  const _ListDetailScreen(this.list);

  final Map<String, dynamic> list;

  @override
  State<_ListDetailScreen> createState() => _ListDetailScreenState();
}

class _ListDetailScreenState extends State<_ListDetailScreen> {
  final _view = GlobalKey<AsyncViewState<List<dynamic>>>();
  final _newItem = TextEditingController();
  final _newItemFocus = FocusNode();

  bool get _isTasks => widget.list['kind'] == 'tasks';

  @override
  void dispose() {
    _newItem.dispose();
    _newItemFocus.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final title = _newItem.text.trim();
    if (title.isEmpty) return;
    final session = SessionScope.of(context);
    final ok = await guarded(
      context,
      () => session.api.post(
        '${session.familyPath}/lists/${widget.list['id']}/items',
        {'title': title},
      ),
    );
    if (ok) {
      _newItem.clear();
      _newItemFocus.requestFocus();
      _view.currentState?.reload();
    }
  }

  Future<void> _save(Map<String, dynamic> item) async {
    final session = SessionScope.of(context);
    await guarded(
      context,
      () => session.api.put('${session.familyPath}/items/${item['id']}', item),
    );
    _view.currentState?.reload();
  }

  Future<void> _delete(Map<String, dynamic> item) async {
    final session = SessionScope.of(context);
    await guarded(
      context,
      () => session.api.delete('${session.familyPath}/items/${item['id']}'),
    );
    _view.currentState?.reload();
  }

  Future<void> _deleteList() async {
    final session = SessionScope.of(context);
    final navigator = Navigator.of(context);
    if (!await confirm(context, '„${widget.list['name']}“ löschen?')) return;
    if (!mounted) return;
    final ok = await guarded(
      context,
      () => session.api.delete(
        '${session.familyPath}/lists/${widget.list['id']}',
      ),
    );
    if (ok) navigator.pop();
  }

  Future<void> _edit(Map<String, dynamic> item) async {
    final session = SessionScope.of(context);
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _ItemDialog(item: item, isTask: _isTasks, session: session),
    );
    if (result != null && mounted) await _save(result);
  }

  String? _subtitle(Map<String, dynamic> item) {
    final due = item['due_date'] as String?;
    final parts = [
      if ((item['note'] as String).isNotEmpty) item['note'] as String,
      if (due != null) 'bis ${dateFormat.format(DateTime.parse(due))}',
      if (item['assignee_name'] != null) item['assignee_name'] as String,
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.list['name'] as String),
        actions: [
          IconButton(
            tooltip: 'Liste löschen',
            icon: const Icon(Icons.delete_outline),
            onPressed: _deleteList,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: AsyncView<List<dynamic>>(
              key: _view,
              load: () async => await session.api.get(
                '${session.familyPath}/lists/${widget.list['id']}/items',
              ) as List,
              builder: (context, items) {
                if (items.isEmpty) {
                  return const EmptyHint(
                    icon: Icons.playlist_add,
                    text: 'Diese Liste ist noch leer.',
                  );
                }
                return ListView(
                  children: [
                    for (final item in items.cast<Map<String, dynamic>>())
                      _itemTile(item),
                  ],
                );
              },
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _newItem,
                      focusNode: _newItemFocus,
                      decoration: InputDecoration(
                        labelText: _isTasks ? 'Neue Aufgabe' : 'Neuer Artikel',
                      ),
                      onSubmitted: (_) => _add(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    tooltip: 'Hinzufügen',
                    icon: const Icon(Icons.add),
                    onPressed: _add,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _itemTile(Map<String, dynamic> item) {
    final done = item['done'] as bool;
    final subtitle = _subtitle(item);
    return ListTile(
      leading: Checkbox(
        value: done,
        onChanged: (value) => _save({...item, 'done': value ?? false}),
      ),
      title: Text(
        item['title'] as String,
        style: done ? const TextStyle(decoration: TextDecoration.lineThrough) : null,
      ),
      subtitle: subtitle == null ? null : Text(subtitle),
      onTap: () => _edit(item),
      trailing: IconButton(
        tooltip: 'Löschen',
        icon: const Icon(Icons.close),
        onPressed: () => _delete(item),
      ),
    );
  }
}

class _ItemDialog extends StatefulWidget {
  const _ItemDialog({
    required this.item,
    required this.isTask,
    required this.session,
  });

  final Map<String, dynamic> item;
  final bool isTask;
  final AppSession session;

  @override
  State<_ItemDialog> createState() => _ItemDialogState();
}

class _ItemDialogState extends State<_ItemDialog> {
  late final _title = TextEditingController(text: widget.item['title'] as String);
  late final _note = TextEditingController(text: widget.item['note'] as String);
  late String? _assignee = widget.item['assignee_id'] as String?;
  late DateTime? _due = DateTime.tryParse(widget.item['due_date'] as String? ?? '');
  List<dynamic> _members = [];

  @override
  void initState() {
    super.initState();
    if (widget.isTask) _loadMembers();
  }

  Future<void> _loadMembers() async {
    final session = widget.session;
    final ok = await guarded(context, () async {
      final result = await session.api.get('${session.familyPath}/members');
      _members = result['members'] as List;
    });
    if (ok && mounted) setState(() {});
  }

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.isTask ? 'Aufgabe' : 'Artikel'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _title,
              decoration: const InputDecoration(labelText: 'Titel'),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _note,
              decoration: InputDecoration(
                labelText: widget.isTask ? 'Notiz' : 'Menge / Notiz',
              ),
            ),
            if (widget.isTask) ...[
              const SizedBox(height: 16),
              DateField(
                label: 'Fällig am',
                value: _due,
                clearable: true,
                onChanged: (date) => setState(() => _due = date),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String?>(
                key: ValueKey(_members.length),
                initialValue: _members.any((m) => m['id'] == _assignee) ? _assignee : null,
                decoration: const InputDecoration(labelText: 'Zuständig'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('Niemand')),
                  for (final m in _members)
                    DropdownMenuItem(
                      value: m['id'] as String,
                      child: Text(m['name'] as String),
                    ),
                ],
                onChanged: (value) => setState(() => _assignee = value),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, {
            ...widget.item,
            'title': _title.text.trim(),
            'note': _note.text.trim(),
            'due_date': _due == null ? '' : dateKey(_due!),
            'assignee_id': _assignee ?? '',
          }),
          child: const Text('Speichern'),
        ),
      ],
    );
  }
}
