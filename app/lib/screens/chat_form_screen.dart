import 'package:flutter/material.dart';

import '../common.dart';
import '../session.dart';

/// Picks another member of the circle and opens the direct messages with them, which
/// exist only once for two. Returns the id of the chat, or null.
Future<String?> pickDirectChat(BuildContext context, String familyId) async {
  final session = SessionScope.of(context);
  final members = await showModalBottomSheet<List<Map<String, dynamic>>>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => _MemberPicker(familyId: familyId),
  );
  final member = members?.firstOrNull;
  if (member == null || !context.mounted) return null;
  String? id;
  await guarded(context, () async {
    final result = await session.api.post('/api/families/$familyId/chats', {'kind': 'direct', 'user_id': member['id']});
    id = (result as Map<String, dynamic>)['id'] as String;
  });
  return id;
}

class _MemberPicker extends StatelessWidget {
  const _MemberPicker({required this.familyId});

  final String familyId;

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
        child: AsyncView<List<dynamic>>(
          load: () async =>
              ((await session.api.get('/api/families/$familyId/members')) as Map<String, dynamic>)['members'] as List,
          builder: (context, members) {
            final others = members.cast<Map<String, dynamic>>().where((m) => m['id'] != session.userId).toList();
            if (others.isEmpty) {
              return const Padding(
                padding: EdgeInsets.all(24),
                child: Text('Im Kreis ist sonst noch niemand.', textAlign: TextAlign.center),
              );
            }
            return ListView(
              shrinkWrap: true,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text('Direktnachricht an', style: Theme.of(context).textTheme.titleMedium),
                ),
                for (final m in others)
                  ListTile(
                    key: ValueKey('chat-member-${m['id']}'),
                    leading: UserAvatar(
                      m['name'] as String,
                      color: m['color'] as String? ?? '',
                      photo: m['avatar'] as String? ?? '',
                    ),
                    title: Text(m['name'] as String),
                    onTap: () => Navigator.pop(context, [m]),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// A new group, or the settings of one: name, color, the people it concerns, a
/// category and who may see it, as for shopping lists. Pops with the id of the group,
/// or an empty one once it was deleted.
class ChatFormScreen extends StatefulWidget {
  const ChatFormScreen({super.key, required this.familyId, this.chat});

  final String familyId;
  final Map<String, dynamic>? chat;

  @override
  State<ChatFormScreen> createState() => _ChatFormScreenState();
}

class _ChatFormScreenState extends State<ChatFormScreen> {
  late final _name = TextEditingController(text: widget.chat?['name'] as String? ?? '');
  late String _color = widget.chat?['color'] as String? ?? '';
  late bool _everyone = widget.chat?['assignees_all'] as bool? ?? false;
  late final Set<String> _assignees = {...(widget.chat?['assignee_ids'] as List? ?? const []).cast<String>()};
  late String _visibility = widget.chat?['visibility'] as String? ?? 'participants';
  late String _category = widget.chat?['category_id'] as String? ?? '';
  bool _saving = false;

  bool get _isNew => widget.chat == null;

  String get _base => '/api/families/${widget.familyId}/chats';

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
    });
  }

  Future<void> _save() async {
    final session = SessionScope.of(context);
    final navigator = Navigator.of(context);
    final body = {
      'kind': 'group',
      'name': _name.text.trim(),
      'color': _color,
      'assignees_all': _everyone,
      'assignee_ids': _everyone ? <String>[] : _assignees.toList(),
      'visibility': _visibility,
      'category_id': _category,
    };
    setState(() => _saving = true);
    String? id;
    final ok = await guarded(context, () async {
      if (_isNew) {
        id = ((await session.api.post(_base, body)) as Map<String, dynamic>)['id'] as String;
      } else {
        await session.api.put('$_base/${widget.chat!['id']}', body);
        id = widget.chat!['id'] as String;
      }
    });
    if (mounted) setState(() => _saving = false);
    if (ok) navigator.pop(id);
  }

  Future<void> _delete() async {
    final session = SessionScope.of(context);
    final navigator = Navigator.of(context);
    if (!await confirm(
      context,
      '„${widget.chat!['name']}“ löschen?',
      message: 'Alle Nachrichten, Bilder und Dokumente der Gruppe gehen mit, für alle.',
    )) {
      return;
    }
    if (!mounted) return;
    final ok = await guarded(context, () => session.api.delete('$_base/${widget.chat!['id']}'));
    if (ok) navigator.pop('');
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

  Widget _personTile(String label, Widget avatar, bool selected, VoidCallback onTap, {Key? key}) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      key: key,
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
    final hint = Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'Neue Gruppe' : 'Gruppe bearbeiten'),
        actions: [
          if (!_isNew)
            IconButton(tooltip: 'Gruppe löschen', icon: const Icon(Icons.delete_outline), onPressed: _delete),
          TextButton(
            key: const Key('chat-form-save'),
            onPressed: _saving ? null : _save,
            child: const Text('Speichern'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: AsyncView<(Map<String, dynamic>, List<dynamic>, List<dynamic>)>(
        load: () async {
          final path = '/api/families/${widget.familyId}';
          final results = await Future.wait([
            session.api.get('$path/colors'),
            session.api.get('$path/members'),
            session.api.get('$path/categories'),
          ]);
          return (
            results[0] as Map<String, dynamic>,
            (results[1] as Map<String, dynamic>)['members'] as List,
            (results[2] as Map<String, dynamic>)['categories'] as List,
          );
        },
        builder: (context, data) {
          final (colors, members, categories) = data;
          final others = members.cast<Map<String, dynamic>>().where((m) => m['id'] != session.userId);
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
                        key: const Key('chat-form-name'),
                        controller: _name,
                        autofocus: _isNew,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: const InputDecoration(labelText: 'Titel', hintText: 'z. B. Urlaubsplanung'),
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
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
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
                                  key: const Key('chat-form-everyone'),
                                ),
                                for (final m in others)
                                  _personTile(
                                    m['name'] as String,
                                    UserAvatar(
                                      m['name'] as String,
                                      color: m['color'] as String? ?? '',
                                      photo: m['avatar'] as String? ?? '',
                                    ),
                                    !_everyone && _assignees.contains(m['id']),
                                    () => _toggle(m['id'] as String),
                                    key: ValueKey('chat-form-member-${m['id']}'),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text('Wer die Gruppe anlegt, gehört immer dazu.', style: hint),
                          ],
                        ),
                      ),
                      _section(
                        'Kategorie',
                        DropdownButtonFormField<String>(
                          key: const Key('chat-form-category'),
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
                                  ? 'Alle im Kreis können mitlesen. Schreiben können nur die Personen, die sie betrifft.'
                                  : 'Nur die Personen, die sie betrifft, und wer sie angelegt hat, sehen die Gruppe.',
                              style: hint,
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
