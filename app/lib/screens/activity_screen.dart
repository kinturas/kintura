import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api.dart';
import '../common.dart';
import '../live_updates.dart';
import '../session.dart';
import 'shopping_screen.dart';

/// Counts up whenever Aktuelles was read, for the number on the tile to follow.
final activitiesSeen = ValueNotifier(0);

/// What every live change may have brought into Aktuelles.
const _activityTopics = {'shopping', 'calendar', 'family'};

/// The sentence for an entry of Aktuelles, as the server sends it.
String activityText(Map<String, dynamic> activity) {
  final actor = activity['actor_name'] as String? ?? '';
  final who = actor.isEmpty ? 'Jemand' : actor;
  final title = '„${activity['title']}“';
  final names = (activity['names'] as List? ?? const []).cast<String>();
  final count = (activity['count'] as num?)?.toInt() ?? names.length;
  return switch (activity['kind']) {
    'event_added' => '$who hat dich zum Termin $title hinzugefügt.',
    'event_all' => '$who hat den Termin $title für alle angelegt.',
    'event_changed' => '$who hat den Termin $title geändert.',
    'event_removed' => '$who hat dich aus dem Termin $title herausgenommen.',
    'event_deleted' => '$who hat den Termin $title gelöscht.',
    'list_added' => '$who hat dich zur Einkaufsliste $title hinzugefügt.',
    'list_all' => '$who hat die Einkaufsliste $title für alle angelegt.',
    'list_deleted' => '$who hat die Einkaufsliste $title gelöscht.',
    'list_readable' => '$who hat dir die Einkaufsliste $title zum Ansehen freigegeben (lesend).',
    'items_added' when count <= 1 && names.isNotEmpty => '$who hat ${names.first} auf $title gesetzt.',
    'items_added' => '$who hat $count Artikel auf $title gesetzt: ${_shortList(names, count)}.',
    _ => '$who hat etwas geändert.',
  };
}

String _shortList(List<String> names, int count) {
  const shown = 4;
  final list = names.take(shown).join(', ');
  return count > shown ? '$list und ${count - shown} weitere' : list;
}

final _dayAndTime = DateFormat('EE, d.M., HH:mm', 'de');
final _dayOnly = DateFormat('EE, d.M.', 'de');

/// When something happened, as one says it: just now, minutes or hours ago, then the day.
String activityTime(DateTime at, {DateTime? now}) {
  now ??= DateTime.now();
  final local = at.toLocal();
  final ago = now.difference(local);
  if (ago.inMinutes < 1) return 'gerade eben';
  if (ago.inMinutes < 60) return 'vor ${ago.inMinutes} Min.';
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  if (day == today) return 'vor ${ago.inHours} Std.';
  if (today.difference(day).inDays == 1) return 'gestern, ${timeFormat.format(local)}';
  return _dayAndTime.format(local);
}

/// When an event is coming up: today, tomorrow or the day, with the time.
String upcomingTime(Map<String, dynamic> event, {DateTime? now}) {
  now ??= DateTime.now();
  final start = DateTime.parse(event['start_local'] as String);
  final today = DateTime(now.year, now.month, now.day);
  final days = DateTime(start.year, start.month, start.day).difference(today).inDays;
  final day = switch (days) {
    <= 0 => 'Heute',
    1 => 'Morgen',
    _ => _dayOnly.format(start),
  };
  return event['all_day'] == true ? '$day, ganztägig' : '$day, ${timeFormat.format(start)}';
}

IconData _iconOf(String kind) => switch (kind) {
  'items_added' => Icons.add_shopping_cart,
  'list_readable' => Icons.visibility_outlined,
  'list_added' || 'list_all' || 'list_deleted' => Icons.shopping_cart_outlined,
  'event_deleted' || 'event_removed' => Icons.event_busy,
  _ => Icons.event,
};

bool _opensList(String kind) => const {'items_added', 'list_added', 'list_all', 'list_readable'}.contains(kind);

/// Aktuelles: what is coming up for the user, then what happened in the family that
/// concerns them, the newest first, a page at a time.
class ActivityScreen extends StatefulWidget {
  const ActivityScreen({super.key});

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> with LiveReload {
  static const _pageSize = 20;

  List<Map<String, dynamic>> _upcoming = [];
  List<Map<String, dynamic>> _items = [];
  Map<String, Map<String, dynamic>> _members = {};
  String? _next;
  String? _error;
  bool _loaded = false;
  bool _loadingMore = false;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _load();
    listenLive(_activityTopics, _load);
  }

  /// The first page again, as long as what is shown already, at most a few pages.
  Future<void> _load() async {
    final session = SessionScope.of(context);
    final base = '${session.familyPath}/activities';
    final limit = _items.length.clamp(_pageSize, 50);
    try {
      final results = await Future.wait([
        session.api.get('$base/upcoming'),
        session.api.get('$base?limit=$limit'),
        session.api.get('${session.familyPath}/members'),
      ]);
      if (!mounted) return;
      final page = results[1] as Map<String, dynamic>;
      setState(() {
        _upcoming = (results[0] as List).cast<Map<String, dynamic>>();
        _items = (page['items'] as List).cast<Map<String, dynamic>>();
        _next = page['next'] as String?;
        _members = {
          for (final m in ((results[2] as Map<String, dynamic>)['members'] as List).cast<Map<String, dynamic>>())
            m['id'] as String: m,
        };
        _loaded = true;
        _error = null;
      });
      await _markSeen();
    } on ApiException catch (e) {
      if (mounted && !_loaded) setState(() => _error = e.message);
    }
  }

  Future<void> _markSeen() async {
    final session = SessionScope.of(context);
    try {
      await session.api.post('${session.familyPath}/activities/seen');
      activitiesSeen.value++;
    } on ApiException {
      // Stays unread for now; the next visit tries again.
    }
  }

  Future<void> _more() async {
    final next = _next;
    if (next == null || _loadingMore) return;
    final session = SessionScope.of(context);
    setState(() => _loadingMore = true);
    await guarded(context, () async {
      final page = await session.api.get(
        '${session.familyPath}/activities?limit=$_pageSize&before=${Uri.encodeQueryComponent(next)}',
      ) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _items = [..._items, ...(page['items'] as List).cast<Map<String, dynamic>>()];
        _next = page['next'] as String?;
      });
    });
    if (mounted) setState(() => _loadingMore = false);
  }

  Future<void> _open(Map<String, dynamic> activity) async {
    final session = SessionScope.of(context);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    List<dynamic>? lists;
    final ok = await guarded(context, () async {
      lists = await session.api.get('${session.familyPath}/shopping/lists') as List;
    });
    if (!ok || !mounted) return;
    final list = lists!.cast<Map<String, dynamic>>().where((l) => l['id'] == activity['ref_id']).firstOrNull;
    if (list == null) {
      messenger.showSnackBar(const SnackBar(content: Text('Diese Einkaufsliste gibt es nicht mehr.')));
      return;
    }
    await navigator.push(MaterialPageRoute(builder: (_) => ShoppingListScreen(list: list, lists: lists!)));
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Aktuelles')),
      body: !_loaded
          ? Center(child: _error == null ? const CircularProgressIndicator() : Text(_error!))
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.only(bottom: 32),
                children: [
                  _SectionTitle('Was steht an'),
                  if (_upcoming.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Text(
                        'In den nächsten 7 Tagen hast du keine Termine.',
                        style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  for (final event in _upcoming)
                    ListTile(
                      leading: Icon(
                        Icons.event,
                        color: (event['color'] as String? ?? '').isEmpty
                            ? scheme.primary
                            : parseHexColor(event['color'] as String),
                      ),
                      title: Text(event['title'] as String),
                      subtitle: Text(
                        [
                          upcomingTime(event),
                          if ((event['location'] as String? ?? '').isNotEmpty) event['location'] as String,
                        ].join(' · '),
                      ),
                    ),
                  _SectionTitle('Was ist passiert'),
                  if (_items.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Text(
                        'Noch nichts. Hier steht, wenn dich jemand zu einem Termin oder einer Einkaufsliste '
                        'hinzufügt oder etwas daran ändert.',
                        style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  for (final activity in _items) _tile(activity, scheme),
                  if (_next != null)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Center(
                        child: OutlinedButton(
                          key: const Key('activities-more'),
                          onPressed: _loadingMore ? null : _more,
                          child: Text(_loadingMore ? 'Lädt …' : 'Ältere anzeigen'),
                        ),
                      ),
                    ),
                ],
              ),
            ),
    );
  }

  Widget _tile(Map<String, dynamic> activity, ColorScheme scheme) {
    final kind = activity['kind'] as String;
    final actor = _members[activity['actor_id']];
    final name = activity['actor_name'] as String? ?? '';
    final isNew = activity['new'] == true;
    return ListTile(
      key: ValueKey('activity-${activity['id']}'),
      leading: UserAvatar(
        name.isEmpty ? '?' : name,
        color: actor?['color'] as String? ?? '',
        photo: actor?['avatar'] as String? ?? '',
      ),
      title: Text(
        activityText(activity),
        style: isNew ? const TextStyle(fontWeight: FontWeight.w600) : null,
      ),
      subtitle: Text(activityTime(DateTime.parse(activity['updated_at'] as String))),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isNew)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Icon(Icons.circle, size: 10, color: scheme.primary, semanticLabel: 'neu'),
            ),
          Icon(_iconOf(kind), color: scheme.onSurfaceVariant),
        ],
      ),
      onTap: _opensList(kind) ? () => _open(activity) : null,
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
    child: Text(title, style: Theme.of(context).textTheme.titleSmall),
  );
}

/// The number of unread entries, on the tile of Aktuelles; nothing when there are none.
class UnreadActivities extends StatefulWidget {
  const UnreadActivities({super.key, required this.background, required this.foreground});

  final Color background;
  final Color foreground;

  @override
  State<UnreadActivities> createState() => _UnreadActivitiesState();
}

class _UnreadActivitiesState extends State<UnreadActivities> with LiveReload {
  int _count = 0;
  String? _family;

  @override
  void initState() {
    super.initState();
    activitiesSeen.addListener(_load);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final family = SessionScope.of(context).current?.id;
    if (family == _family) return;
    _family = family;
    _count = 0;
    _load();
    listenLive(_activityTopics, _load);
  }

  @override
  void dispose() {
    activitiesSeen.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final session = SessionScope.of(context);
    if (session.current == null) return;
    try {
      final result = await session.api.get('${session.familyPath}/activities/unread') as Map<String, dynamic>;
      if (mounted) setState(() => _count = (result['count'] as num?)?.toInt() ?? 0);
    } on ApiException {
      // Without the number the tile still works.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_count == 0) return const SizedBox.shrink();
    return Badge(
      key: const Key('activities-unread'),
      label: Text(_count > 99 ? '99+' : '$_count'),
      backgroundColor: widget.background,
      textColor: widget.foreground,
      largeSize: 22,
      padding: const EdgeInsets.symmetric(horizontal: 7),
    );
  }
}
