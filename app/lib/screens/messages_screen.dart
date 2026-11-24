import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../common.dart';
import '../live_updates.dart';
import '../session.dart';
import 'activity_screen.dart' show CircleLabel;
import 'chat_form_screen.dart';
import 'chat_screen.dart';

/// Whether Nachrichten shows all circles of the user; unless chosen, only the one in
/// view. Kept on the device, see [setMessagesOfAllCircles].
final messagesOfAllCircles = ValueNotifier(false);

/// Counts up whenever a chat was read here, for the numbers of unread messages.
final chatsRead = ValueNotifier(0);

const _allCirclesKey = 'messages_all_circles';
bool _allCirclesRead = false;

Future<void> _readAllCircles() async {
  if (_allCirclesRead) return;
  _allCirclesRead = true;
  try {
    final prefs = await SharedPreferences.getInstance();
    messagesOfAllCircles.value = prefs.getBool(_allCirclesKey) ?? false;
  } catch (_) {
    // Without storage, as in tests, it stays at the circle in view.
  }
}

Future<void> setMessagesOfAllCircles(bool all) async {
  _allCirclesRead = true;
  messagesOfAllCircles.value = all;
  try {
    await (await SharedPreferences.getInstance()).setBool(_allCirclesKey, all);
  } catch (_) {
    // Holds for now.
  }
}

/// The query for the circles in view, with [extra] parameters.
String _chatsPath(AppSession session, String path, [Map<String, String> extra = const {}]) => Uri(
  path: path,
  queryParameters: {
    ...extra,
    if (!messagesOfAllCircles.value && session.current != null) 'family': session.current!.id,
  },
).toString().replaceFirst(RegExp(r'\?$'), '');

/// What a message says in a list or a notification: its words, or what it carries.
String messagePreview(Map<String, dynamic> message) {
  if (message['deleted'] == true) return 'Nachricht gelöscht';
  if (((message['photos'] as num?) ?? 0) > 0) return '📷 Bild';
  if (((message['documents'] as num?) ?? 0) > 0) return '📎 Dokument';
  final body = (message['body'] as String? ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
  return body;
}

/// When a message came: the time today, the day before that.
String messageTime(String iso) {
  final at = DateTime.tryParse(iso)?.toLocal();
  if (at == null) return '';
  final now = DateTime.now();
  if (at.year == now.year && at.month == now.month && at.day == now.day) return timeFormat.format(at);
  final yesterday = now.subtract(const Duration(days: 1));
  if (at.year == yesterday.year && at.month == yesterday.month && at.day == yesterday.day) return 'Gestern';
  return '${at.day.toString().padLeft(2, '0')}.${at.month.toString().padLeft(2, '0')}.';
}

/// The color of a chat: of the group, or of the person.
Color? chatColor(Map<String, dynamic> chat) {
  final hex = chat['color'] as String? ?? '';
  return hex.isEmpty ? null : parseHexColor(hex);
}

/// The picture of a chat: the other person, or the group in its color.
class ChatAvatar extends StatelessWidget {
  const ChatAvatar(this.chat, {super.key, this.radius = 22});

  final Map<String, dynamic> chat;
  final double radius;

  @override
  Widget build(BuildContext context) {
    if (chat['kind'] == 'direct') {
      return UserAvatar(
        chat['name'] as String? ?? '',
        color: chat['color'] as String? ?? '',
        photo: chat['avatar'] as String? ?? '',
        radius: radius,
      );
    }
    final scheme = Theme.of(context).colorScheme;
    final color = chatColor(chat) ?? scheme.secondaryContainer;
    final foreground = ThemeData.estimateBrightnessForColor(color) == Brightness.dark ? Colors.white : Colors.black87;
    return CircleAvatar(
      radius: radius,
      backgroundColor: color,
      child: Icon(Icons.groups, color: foreground, size: radius),
    );
  }
}

enum _Filter { all, unread, groups }

/// Nachrichten: the direct messages and groups of the circle in view, or of all, the
/// one with the newest message first. With a search over all messages, filters, and
/// the archived chats on a page of their own.
class MessagesScreen extends StatefulWidget {
  const MessagesScreen({super.key, this.archived = false});

  /// Shows the chats the user archived, instead of the others.
  final bool archived;

  @override
  State<MessagesScreen> createState() => _MessagesScreenState();
}

class _MessagesScreenState extends State<MessagesScreen> with LiveReload {
  final _search = TextEditingController();
  List<Map<String, dynamic>>? _chats;
  List<Map<String, dynamic>> _found = [];
  String? _error;
  _Filter _filter = _Filter.all;
  Timer? _searchSoon;
  bool _started = false;
  String? _familyInView;

  @override
  void initState() {
    super.initState();
    messagesOfAllCircles.addListener(_scopeChanged);
    chatsRead.addListener(_load);
    _search.addListener(_searchChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final family = SessionScope.of(context).current?.id;
    if (!_started) {
      _started = true;
      _familyInView = family;
      _start();
      return;
    }
    if (family != _familyInView) {
      _familyInView = family;
      if (!messagesOfAllCircles.value) _scopeChanged();
    }
  }

  @override
  void dispose() {
    messagesOfAllCircles.removeListener(_scopeChanged);
    chatsRead.removeListener(_load);
    _searchSoon?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    await _readAllCircles();
    if (!mounted) return;
    _listen();
    await _load();
  }

  void _listen() => listenLive(const {'messages', 'family'}, _reload, everyFamily: messagesOfAllCircles.value);

  void _scopeChanged() {
    if (!mounted) return;
    _listen();
    setState(() => _chats = null);
    _reload();
  }

  Future<void> _reload() async {
    await _load();
    if (_search.text.trim().isNotEmpty) await _runSearch();
  }

  Future<void> _load() async {
    if (!mounted) return;
    final session = SessionScope.of(context);
    try {
      final rows = (await session.api.get(_chatsPath(session, '/api/chats')) as List).cast<Map<String, dynamic>>();
      if (!mounted) return;
      setState(() {
        _chats = rows;
        _error = null;
      });
    } on ApiException catch (e) {
      if (mounted && _chats == null) setState(() => _error = e.message);
    }
  }

  void _searchChanged() {
    _searchSoon?.cancel();
    setState(() {});
    if (_search.text.trim().length < 2) {
      setState(() => _found = []);
      return;
    }
    _searchSoon = Timer(const Duration(milliseconds: 300), _runSearch);
  }

  Future<void> _runSearch() async {
    final query = _search.text.trim();
    if (query.length < 2 || !mounted) return;
    final session = SessionScope.of(context);
    try {
      final rows = (await session.api.get(_chatsPath(session, '/api/chats/search', {'q': query})) as List)
          .cast<Map<String, dynamic>>();
      if (mounted && _search.text.trim() == query) setState(() => _found = rows);
    } on ApiException {
      // The chats found by name still show.
    }
  }

  Future<void> _open(Map<String, dynamic> chat) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatScreen(familyId: chat['family_id'] as String, chatId: chat['id'] as String, chat: chat),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _archive(Map<String, dynamic> chat, bool archived) async {
    final session = SessionScope.of(context);
    final ok = await guarded(
      context,
      () => session.api.put('/api/families/${chat['family_id']}/chats/${chat['id']}/archive', {'archived': archived}),
    );
    if (!ok || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(archived ? '„${chat['name']}“ archiviert.' : '„${chat['name']}“ ist wieder da.')),
    );
    await _load();
    chatsRead.value++;
  }

  Future<void> _new() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const Key('chat-new-direct'),
              leading: const Icon(Icons.person_outline),
              title: const Text('Direktnachricht'),
              subtitle: const Text('Nur ihr zwei'),
              onTap: () => Navigator.pop(context, 'direct'),
            ),
            ListTile(
              key: const Key('chat-new-group'),
              leading: const Icon(Icons.groups_outlined),
              title: const Text('Neue Gruppe'),
              subtitle: const Text('Mit Name, Farbe und den Personen, die sie betrifft'),
              onTap: () => Navigator.pop(context, 'group'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    final session = SessionScope.of(context);
    final family = session.current;
    if (family == null) return;
    final String? id = choice == 'direct'
        ? await pickDirectChat(context, family.id)
        : await Navigator.of(
            context,
          ).push<String>(MaterialPageRoute(builder: (_) => ChatFormScreen(familyId: family.id)));
    if (id == null || !mounted) return;
    await _load();
    if (!mounted) return;
    final chat = _chats?.where((c) => c['id'] == id).firstOrNull;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatScreen(familyId: family.id, chatId: id, chat: chat),
      ),
    );
    if (mounted) await _load();
  }

  List<Map<String, dynamic>> _shown(List<Map<String, dynamic>> chats) => [
    for (final chat in chats)
      if (chat['archived'] == widget.archived)
        if (switch (_filter) {
          _Filter.all => true,
          _Filter.unread => ((chat['unread'] as num?) ?? 0) > 0,
          _Filter.groups => chat['kind'] == 'group',
        })
          chat,
  ];

  @override
  Widget build(BuildContext context) {
    final chats = _chats;
    final searching = _search.text.trim().isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.archived ? 'Archiviert' : 'Nachrichten'),
        actions: [
          if (SessionScope.of(context).families.length > 1) const _CircleFilter(),
          const SizedBox(width: 8),
        ],
      ),
      floatingActionButton: widget.archived
          ? null
          : FloatingActionButton.extended(
              key: const Key('chat-new'),
              onPressed: _new,
              icon: const Icon(Icons.edit_outlined),
              label: const Text('Neu'),
            ),
      body: chats == null
          ? Center(child: _error == null ? const CircularProgressIndicator() : Text(_error!))
          : RefreshIndicator(
              onRefresh: _reload,
              child: ListView(
                padding: const EdgeInsets.only(bottom: 96),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: TextField(
                      key: const Key('chat-search'),
                      controller: _search,
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        hintText: 'In allen Nachrichten suchen',
                        prefixIcon: const Icon(Icons.search),
                        isDense: true,
                        suffixIcon: searching
                            ? IconButton(
                                tooltip: 'Suche leeren',
                                icon: const Icon(Icons.close),
                                onPressed: _search.clear,
                              )
                            : null,
                      ),
                    ),
                  ),
                  if (searching) ..._results(chats) else ..._list(chats),
                ],
              ),
            ),
    );
  }

  List<Widget> _list(List<Map<String, dynamic>> chats) {
    final shown = _shown(chats);
    final archived = chats.where((c) => c['archived'] == true).length;
    final all = messagesOfAllCircles.value;
    return [
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: Row(
          children: [
            for (final (filter, label) in const [
              (_Filter.all, 'Alle'),
              (_Filter.unread, 'Ungelesen'),
              (_Filter.groups, 'Gruppen'),
            ])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  key: Key('chat-filter-${filter.name}'),
                  label: Text(label),
                  selected: _filter == filter,
                  onSelected: (_) => setState(() => _filter = filter),
                ),
              ),
          ],
        ),
      ),
      if (!widget.archived)
        ListTile(
          key: const Key('chat-archived'),
          leading: const Icon(Icons.archive_outlined),
          title: const Text('Archiviert'),
          trailing: archived == 0 ? null : Text('$archived'),
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => const MessagesScreen(archived: true))).then((_) => _load()),
        ),
      if (shown.isEmpty)
        EmptyHint(
          icon: Icons.chat_bubble_outline,
          text: widget.archived
              ? 'Nichts archiviert.'
              : _filter == _Filter.all
              ? 'Noch keine Nachrichten. Schreib jemandem direkt oder leg eine Gruppe an.'
              : 'Hier ist gerade nichts.',
        )
      else
        for (final chat in shown)
          _ChatTile(
            chat: chat,
            showCircle: all,
            onTap: () => _open(chat),
            onArchive: () => _archive(chat, chat['archived'] != true),
          ),
    ];
  }

  List<Widget> _results(List<Map<String, dynamic>> chats) {
    final key = _search.text.trim().toLowerCase();
    final byName = chats.where((c) => (c['name'] as String? ?? '').toLowerCase().contains(key)).toList();
    final chatOf = {for (final chat in chats) chat['id'] as String: chat};
    final scheme = Theme.of(context).colorScheme;
    return [
      if (byName.isNotEmpty) ...[
        const _Heading('Chats'),
        for (final chat in byName)
          _ChatTile(
            chat: chat,
            showCircle: messagesOfAllCircles.value,
            onTap: () => _open(chat),
            onArchive: () => _archive(chat, chat['archived'] != true),
          ),
      ],
      if (_found.isNotEmpty) ...[
        const _Heading('Nachrichten'),
        for (final message in _found)
          if (chatOf[message['chat_id']] case final chat?)
            ListTile(
              key: ValueKey('chat-found-${message['id']}'),
              leading: ChatAvatar(chat, radius: 18),
              title: Text(chat['name'] as String? ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                '${message['own'] == true ? 'Du' : message['sender_name']}: '
                '${(message['body'] as String? ?? '').isEmpty ? '📎 ${message['file_name']}' : message['body']}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Text(
                messageTime(message['created_at'] as String? ?? ''),
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              onTap: () => _open(chat),
            ),
      ],
      if (byName.isEmpty && _found.isEmpty) const EmptyHint(icon: Icons.search_off, text: 'Nichts gefunden.'),
    ];
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
  );
}

/// One chat in the list: who or what, the last message, when, and how many are unread.
class _ChatTile extends StatelessWidget {
  const _ChatTile({required this.chat, required this.showCircle, required this.onTap, required this.onArchive});

  final Map<String, dynamic> chat;
  final bool showCircle;
  final VoidCallback onTap;
  final VoidCallback onArchive;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final last = chat['last_message'] as Map<String, dynamic>?;
    final unread = ((chat['unread'] as num?) ?? 0).toInt();
    final group = chat['kind'] == 'group';
    final category = chat['category_name'] as String? ?? '';
    final categoryColor = chat['category_color'] as String? ?? '';
    var preview = last == null ? (group ? 'Neue Gruppe' : 'Noch keine Nachrichten') : messagePreview(last);
    if (last != null && last['deleted'] != true) {
      if (last['own'] == true) {
        preview = 'Du: $preview';
      } else if (group && (last['sender_name'] as String? ?? '').isNotEmpty) {
        preview = '${last['sender_name']}: $preview';
      }
    }
    return ListTile(
      key: ValueKey('chat-${chat['id']}'),
      leading: ChatAvatar(chat),
      title: Row(
        children: [
          Flexible(
            child: Text(
              chat['name'] as String? ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: unread > 0 ? const TextStyle(fontWeight: FontWeight.bold) : null,
            ),
          ),
          if (chat['can_write'] == false) ...[
            const SizedBox(width: 4),
            Icon(Icons.visibility_outlined, size: 16, color: scheme.onSurfaceVariant),
          ],
          if (showCircle) ...[const SizedBox(width: 8), CircleLabel(chat['family_id'] as String)],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(preview, maxLines: 1, overflow: TextOverflow.ellipsis),
          if (category.isNotEmpty)
            Row(
              children: [
                Icon(
                  Icons.circle,
                  size: 10,
                  color: categoryColor.isEmpty ? scheme.primary : parseHexColor(categoryColor),
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(category, style: text.labelSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
        ],
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            last == null ? '' : messageTime(last['created_at'] as String? ?? ''),
            style: text.labelSmall?.copyWith(color: unread > 0 ? scheme.primary : scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          if (unread > 0)
            Badge(
              key: ValueKey('chat-unread-${chat['id']}'),
              label: Text(unread > 99 ? '99+' : '$unread'),
              backgroundColor: scheme.primary,
              textColor: scheme.onPrimary,
            ),
        ],
      ),
      onTap: onTap,
      onLongPress: () => _menu(context),
    );
  }

  Future<void> _menu(BuildContext context) async {
    final archived = chat['archived'] == true;
    final picked = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListTile(
          leading: Icon(archived ? Icons.unarchive_outlined : Icons.archive_outlined),
          title: Text(archived ? 'Wieder in die Liste' : 'Archivieren'),
          subtitle: const Text('Nur für dich'),
          onTap: () => Navigator.pop(context, true),
        ),
      ),
    );
    if (picked == true) onArchive();
  }
}

/// The circle in view or all, top right in Nachrichten.
class _CircleFilter extends StatelessWidget {
  const _CircleFilter();

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: messagesOfAllCircles,
    builder: (context, all, _) {
      final session = SessionScope.of(context);
      return PopupMenuButton<bool>(
        key: const Key('messages-filter'),
        tooltip: 'Kreise filtern',
        icon: Icon(all ? Icons.filter_list : Icons.filter_alt),
        position: PopupMenuPosition.under,
        onSelected: setMessagesOfAllCircles,
        itemBuilder: (context) => [
          CheckedPopupMenuItem(
            value: false,
            checked: !all,
            child: Text('Nur ${session.current?.name ?? 'aktueller Kreis'}'),
          ),
          CheckedPopupMenuItem(value: true, checked: all, child: const Text('Alle Kreise')),
        ],
      );
    },
  );
}

/// The number of unread messages on the tile, of the circle in view or of all, as
/// Nachrichten shows them.
class UnreadMessages extends StatefulWidget {
  const UnreadMessages({super.key, required this.background, required this.foreground});

  final Color background;
  final Color foreground;

  @override
  State<UnreadMessages> createState() => _UnreadMessagesState();
}

class _UnreadMessagesState extends State<UnreadMessages> with LiveReload {
  int _count = 0;
  String? _family;

  @override
  void initState() {
    super.initState();
    chatsRead.addListener(_load);
    messagesOfAllCircles.addListener(_load);
    _readAllCircles().then((_) => _load());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final family = SessionScope.of(context).current?.id;
    if (family == _family) return;
    _family = family;
    _count = 0;
    listenLive(const {'messages', 'family'}, _load, everyFamily: true);
    _load();
  }

  @override
  void dispose() {
    chatsRead.removeListener(_load);
    messagesOfAllCircles.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    final session = SessionScope.of(context);
    final current = session.current?.id;
    if (current == null) return;
    try {
      final result = await session.api.get('/api/chats/unread') as Map<String, dynamic>;
      final byCircle = (result['families'] as Map<String, dynamic>? ?? const {});
      final total = (result['count'] as num?)?.toInt() ?? 0;
      final count = messagesOfAllCircles.value ? total : (byCircle[current] as num?)?.toInt() ?? 0;
      if (mounted) setState(() => _count = count);
    } on ApiException {
      // Without the number the tile still works.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_count == 0) return const SizedBox.shrink();
    return Badge(
      key: const Key('messages-unread'),
      label: Text(_count > 99 ? '99+' : '$_count'),
      backgroundColor: widget.background,
      textColor: widget.foreground,
      largeSize: 22,
      padding: const EdgeInsets.symmetric(horizontal: 7),
    );
  }
}
