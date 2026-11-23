import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../common.dart';
import '../live_updates.dart';
import '../session.dart';
import 'calendar_views.dart';
import 'event_detail_screen.dart';
import 'shopping_screen.dart';

/// Counts up whenever Aktuelles was read, for the number on the tile to follow.
final activitiesSeen = ValueNotifier(0);

/// Whether Aktuelles shows all circles of the user, as it does unless they chose only
/// the one in view. Kept on the device, see [setActivitiesOfAllCircles].
final activitiesOfAllCircles = ValueNotifier(true);

const _allCirclesKey = 'activities_all_circles';
bool _allCirclesRead = false;

Future<void> _readAllCircles() async {
  if (_allCirclesRead) return;
  _allCirclesRead = true;
  try {
    final prefs = await SharedPreferences.getInstance();
    activitiesOfAllCircles.value = prefs.getBool(_allCirclesKey) ?? true;
  } catch (_) {
    // Without storage, as in tests, it stays at all circles.
  }
}

Future<void> setActivitiesOfAllCircles(bool all) async {
  _allCirclesRead = true;
  activitiesOfAllCircles.value = all;
  try {
    await (await SharedPreferences.getInstance()).setBool(_allCirclesKey, all);
  } catch (_) {
    // Holds for now; next time it starts at all circles again.
  }
}

/// The query of Aktuelles for the circles in view, with [extra] parameters.
String _activitiesPath(AppSession session, String path, [Map<String, String> extra = const {}]) => Uri(
  path: path,
  queryParameters: {
    ...extra,
    if (!activitiesOfAllCircles.value && session.current != null) 'family': session.current!.id,
  },
).toString().replaceFirst(RegExp(r'\?$'), '');

/// What every live change may have brought into Aktuelles.
const _activityTopics = {'shopping', 'calendar', 'family'};

/// The sentence for an entry of Aktuelles, as the server sends it; for what the user
/// did themselves, told to them.
String activityText(Map<String, dynamic> activity) {
  final title = '„${activity['title']}“';
  final names = (activity['names'] as List? ?? const []).cast<String>();
  final count = (activity['count'] as num?)?.toInt() ?? names.length;
  if (activity['own'] == true) {
    final people = _people(names, count);
    return switch (activity['kind']) {
      'event_added' => 'Du hast $people zum Termin $title hinzugefügt.',
      'event_all' => 'Du hast den Termin $title für alle angelegt.',
      'event_changed' => 'Du hast den Termin $title geändert.',
      'event_removed' => 'Du hast $people aus dem Termin $title herausgenommen.',
      'event_deleted' => 'Du hast den Termin $title gelöscht.',
      'list_added' => 'Du hast $people zur Einkaufsliste $title hinzugefügt.',
      'list_all' => 'Du hast die Einkaufsliste $title für alle angelegt.',
      'list_deleted' => 'Du hast die Einkaufsliste $title gelöscht.',
      'list_readable' => 'Du hast $people die Einkaufsliste $title zum Ansehen freigegeben.',
      'items_added' when count <= 1 && names.isNotEmpty => 'Du hast ${names.first} auf $title gesetzt.',
      'items_added' => 'Du hast $count Artikel auf $title gesetzt: ${_shortList(names, count)}.',
      'items_done' when count <= 1 && names.isNotEmpty => 'Du hast ${names.first} auf $title abgehakt.',
      'items_done' => 'Du hast $count Artikel auf $title abgehakt: ${_shortList(names, count)}.',
      _ => 'Du hast etwas geändert.',
    };
  }
  final actor = activity['actor_name'] as String? ?? '';
  final who = actor.isEmpty ? 'Jemand' : actor;
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
    'items_done' when count <= 1 && names.isNotEmpty => '$who hat ${names.first} auf $title abgehakt.',
    'items_done' => '$who hat $count Artikel auf $title abgehakt: ${_shortList(names, count)}.',
    _ => '$who hat etwas geändert.',
  };
}

String _shortList(List<String> names, int count) {
  const shown = 4;
  final list = names.take(shown).join(', ');
  return count > shown ? '$list und ${count - shown} weitere' : list;
}

/// Whom something was done for: Ben, Ben und Cara, Ben, Cara und 2 weitere.
String _people(List<String> names, int count) {
  if (names.isEmpty) return count == 1 ? 'eine Person' : '$count Personen';
  final rest = count - names.length;
  if (rest > 0) return '${names.join(', ')} und $rest weitere';
  if (names.length == 1) return names.first;
  return '${names.take(names.length - 1).join(', ')} und ${names.last}';
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
  'items_done' => Icons.task_alt,
  'list_readable' => Icons.visibility_outlined,
  'list_added' || 'list_all' || 'list_deleted' => Icons.shopping_cart_outlined,
  'event_deleted' || 'event_removed' => Icons.event_busy,
  _ => Icons.event,
};

bool _opensList(String kind) => const {'items_added', 'items_done', 'list_added', 'list_all', 'list_readable'}.contains(kind);

/// Kinds about an event that is still there to open.
bool _opensEvent(String kind) => const {'event_added', 'event_all', 'event_changed', 'event_removed'}.contains(kind);

/// Whether entries carry the circle they belong to: only if more than one is in view.
bool _showsCircles(AppSession session) => activitiesOfAllCircles.value && session.families.length > 1;

/// Puts [familyId] in view, for what opens from Aktuelles to work in its circle. False
/// if that circle is gone or could not be selected.
Future<bool> _selectCircle(BuildContext context, String? familyId) async {
  final session = SessionScope.of(context);
  if (familyId == null || familyId == session.current?.id) return true;
  final family = session.families.where((f) => f.id == familyId).firstOrNull;
  final messenger = ScaffoldMessenger.of(context);
  if (family == null) {
    messenger.showSnackBar(const SnackBar(content: Text('Diesen Kreis gibt es für dich nicht mehr.')));
    return false;
  }
  final ok = await guarded(context, () => session.select(family));
  if (ok) messenger.showSnackBar(SnackBar(content: Text('Gewechselt zu ${family.name}')));
  return ok;
}

/// Opens an event that is coming up as the calendar does, in its circle.
Future<void> openUpcomingEvent(BuildContext context, Map<String, dynamic> event) =>
    openCircleEvent(context, event['family_id'] as String?, event['id'] as String, startAt: event['start_at'] as String);

/// Opens the event [eventId] of the circle [familyId] as the calendar does: the
/// occurrence that starts at [startAt], or without it the next one of a series, or the
/// only one.
Future<void> openCircleEvent(BuildContext context, String? familyId, String eventId, {String? startAt}) async {
  final navigator = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);
  if (!await _selectCircle(context, familyId) || !context.mounted) return;
  final session = SessionScope.of(context);
  final base = session.familyPath;

  Future<List<CalendarEntry>> entries(DateTime from, DateTime to) async {
    final query = Uri(
      queryParameters: {'from': from.toUtc().toIso8601String(), 'to': to.toUtc().toIso8601String()},
    ).query;
    final rows = await session.api.get('$base/calendar-entries?$query') as List;
    return [for (final row in rows) CalendarEntry(row as Map<String, dynamic>)];
  }

  /// The earliest occurrence of the event between [from] and [to].
  Future<CalendarEntry?> occurrence(DateTime from, DateTime to) async {
    final found = (await entries(from, to)).where((e) => e.inStandardCalendar && e.id == eventId).toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    return found.where((e) => startAt == null || e.raw['start_at'] == startAt).firstOrNull ?? found.firstOrNull;
  }

  CalendarEntry? entry;
  var firstWeekday = DateTime.monday;
  final ok = await guarded(context, () async {
    if (startAt != null) {
      final start = DateTime.parse(startAt);
      entry = await occurrence(start, start.add(const Duration(minutes: 1)));
    } else {
      Map<String, dynamic> event;
      try {
        event = await session.api.get('$base/events/$eventId') as Map<String, dynamic>;
      } on ApiException catch (e) {
        // Deleted meanwhile, or no longer to be seen.
        if (e.status == 404) return;
        rethrow;
      }
      final first = DateTime.parse(event['start_at'] as String);
      if (event['recurrence'] != null) {
        final now = DateTime.now();
        entry = await occurrence(now, now.add(const Duration(days: 31))) ??
            await occurrence(now, now.add(const Duration(days: 366)));
      }
      // A single event, or a series that is over: its first time.
      entry ??= await occurrence(first, first.add(const Duration(minutes: 1)));
    }
    if (entry == null) return;
    final prefs = await session.api.get('$base/calendar-prefs') as Map<String, dynamic>?;
    if (prefs?['week_start'] == 'sunday') firstWeekday = DateTime.sunday;
  });
  if (!ok || !context.mounted) return;
  final found = entry;
  if (found == null) {
    messenger.showSnackBar(
      const SnackBar(content: Text('Diesen Termin gibt es nicht mehr, oder sein Kalender ist ausgeblendet.')),
    );
    return;
  }
  await navigator.push<void>(
    MaterialPageRoute(
      builder: (context) => EventDetailScreen(
        entry: found,
        firstWeekday: firstWeekday,
        fetch: (from, to) async {
          List<CalendarEntry>? out;
          await guarded(context, () async => out = await entries(from, to));
          return out;
        },
        onChanged: () {},
      ),
    ),
  );
}

/// The entries of Aktuelles as tiles, with their pictures, opening what they are about.
mixin _ActivityEntries<T extends StatefulWidget> on State<T> {
  /// The members of each circle, by circle and user.
  final Map<String, Map<String, Map<String, dynamic>>> _members = {};

  /// Loads again after coming back from what an entry opened.
  Future<void> _load();

  /// The members of the circles of [items], for their pictures.
  Future<void> _loadMembers(List<Map<String, dynamic>> items) async {
    final session = SessionScope.of(context);
    final families = {for (final item in items) item['family_id'] as String? ?? session.current!.id};
    await Future.wait([
      for (final family in families)
        session.api.get('/api/families/$family/members').then((result) {
          _members[family] = {
            for (final m in ((result as Map<String, dynamic>)['members'] as List).cast<Map<String, dynamic>>())
              m['id'] as String: m,
          };
        }).catchError((Object _) {
          // Without the pictures the entries still read.
        }),
    ]);
  }

  Future<void> _open(Map<String, dynamic> activity) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    if (!await _selectCircle(context, activity['family_id'] as String?) || !mounted) return;
    final session = SessionScope.of(context);
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
    await navigator.push(MaterialPageRoute(builder: (_) => ShoppingScreen(listId: list['id'] as String)));
    if (mounted) await _load();
  }

  Future<void> _openActivityEvent(Map<String, dynamic> activity) async {
    await openCircleEvent(context, activity['family_id'] as String?, activity['ref_id'] as String);
    if (mounted) await _load();
  }

  Widget _tile(Map<String, dynamic> activity, ColorScheme scheme, bool circles) {
    final session = SessionScope.of(context);
    final kind = activity['kind'] as String;
    final family = activity['family_id'] as String? ?? session.current!.id;
    final actor = _members[family]?[activity['actor_id']];
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
          if (circles)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: CircleLabel(family),
            ),
          Icon(_iconOf(kind), color: scheme.onSurfaceVariant),
        ],
      ),
      onTap: _opensList(kind)
          ? () => _open(activity)
          : _opensEvent(kind)
          ? () => _openActivityEvent(activity)
          : null,
    );
  }
}

/// Aktuelles: what is coming up for the user, then the latest of what happened in their
/// circles that concerns them or that they did, the newest first.
class ActivityScreen extends StatefulWidget {
  const ActivityScreen({super.key});

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> with LiveReload, _ActivityEntries {
  /// What Aktuelles shows itself; more opens a page of its own.
  static const _shown = 20;

  List<Map<String, dynamic>> _upcoming = [];
  bool _moreUpcoming = false;
  List<Map<String, dynamic>> _items = [];

  /// Whether more happened than is shown.
  bool _more = false;
  String? _error;
  bool _loaded = false;
  bool _started = false;
  String? _familyInView;

  @override
  void initState() {
    super.initState();
    activitiesOfAllCircles.addListener(_scopeChanged);
  }

  @override
  void dispose() {
    activitiesOfAllCircles.removeListener(_scopeChanged);
    super.dispose();
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
    // Only the circle in view: another one in view is other news.
    if (family != _familyInView) {
      _familyInView = family;
      if (!activitiesOfAllCircles.value) _scopeChanged();
    }
  }

  Future<void> _start() async {
    await _readAllCircles();
    if (!mounted) return;
    _listen();
    await _load();
  }

  void _listen() => listenLive(_activityTopics, _load, everyFamily: activitiesOfAllCircles.value);

  void _scopeChanged() {
    if (!mounted) return;
    _listen();
    setState(() {
      _items = [];
      _more = false;
    });
    _load();
  }

  @override
  Future<void> _load() async {
    final session = SessionScope.of(context);
    try {
      final results = await Future.wait([
        session.api.get(_activitiesPath(session, '/api/activities/upcoming')),
        session.api.get(_activitiesPath(session, '/api/activities', {'limit': '$_shown'})),
      ]);
      if (!mounted) return;
      final upcoming = results[0] as Map<String, dynamic>;
      final page = results[1] as Map<String, dynamic>;
      final items = (page['items'] as List).cast<Map<String, dynamic>>();
      await _loadMembers(items);
      if (!mounted) return;
      setState(() {
        _upcoming = (upcoming['items'] as List).cast<Map<String, dynamic>>();
        _moreUpcoming = upcoming['more'] == true;
        _items = items;
        _more = page['next'] != null;
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
      await session.api.post(_activitiesPath(session, '/api/activities/seen'));
      activitiesSeen.value++;
    } on ApiException {
      // Stays unread for now; the next visit tries again.
    }
  }

  Future<void> _openEvent(Map<String, dynamic> event) async {
    await openUpcomingEvent(context, event);
    if (mounted) await _load();
  }

  Future<void> _showAllUpcoming() async {
    await Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const UpcomingEventsScreen()));
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final circles = _showsCircles(session);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Aktuelles'),
        actions: [if (session.families.length > 1) const _CircleFilter(), const SizedBox(width: 8)],
      ),
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
                        'Es stehen keine Termine für dich an.',
                        style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  for (final event in _upcoming)
                    UpcomingEventTile(event, showCircle: circles, onTap: () => _openEvent(event)),
                  if (_moreUpcoming)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          key: const Key('upcoming-all'),
                          onPressed: _showAllUpcoming,
                          icon: const Icon(Icons.event_note_outlined),
                          label: const Text('Alle bevorstehenden Termine anzeigen'),
                        ),
                      ),
                    ),
                  _SectionTitle('Was ist passiert'),
                  if (_items.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Text(
                        'Noch nichts. Hier steht, was du an Terminen und Einkaufslisten änderst, und wenn dich '
                        'jemand dazu hinzufügt oder etwas daran ändert.',
                        style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  for (final activity in _items) _tile(activity, scheme, circles),
                  if (_more)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          key: const Key('activities-more'),
                          onPressed: _showRecent,
                          icon: const Icon(Icons.history),
                          label: const Text('Letzte 100 Ereignisse anzeigen'),
                        ),
                      ),
                    ),
                ],
              ),
            ),
    );
  }

  Future<void> _showRecent() async {
    await Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const RecentActivitiesScreen()));
    if (mounted) await _load();
  }
}

/// The last hundred entries of Aktuelles, in the circles in view.
class RecentActivitiesScreen extends StatefulWidget {
  const RecentActivitiesScreen({super.key});

  /// As many as the server gives in one page.
  static const limit = 100;

  @override
  State<RecentActivitiesScreen> createState() => _RecentActivitiesScreenState();
}

class _RecentActivitiesScreenState extends State<RecentActivitiesScreen> with LiveReload, _ActivityEntries {
  List<Map<String, dynamic>> _items = [];
  bool _loaded = false;
  String? _error;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _load();
    listenLive(_activityTopics, _load, everyFamily: activitiesOfAllCircles.value);
  }

  @override
  Future<void> _load() async {
    final session = SessionScope.of(context);
    try {
      final page = await session.api.get(
        _activitiesPath(session, '/api/activities', {'limit': '${RecentActivitiesScreen.limit}'}),
      ) as Map<String, dynamic>;
      final items = (page['items'] as List).cast<Map<String, dynamic>>();
      await _loadMembers(items);
      if (!mounted) return;
      setState(() {
        _items = items;
        _loaded = true;
        _error = null;
      });
    } on ApiException catch (e) {
      if (mounted && !_loaded) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final circles = _showsCircles(SessionScope.of(context));
    return Scaffold(
      appBar: AppBar(title: const Text('Letzte Ereignisse')),
      body: !_loaded
          ? Center(child: _error == null ? const CircularProgressIndicator() : Text(_error!))
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.only(bottom: 32),
                children: [for (final activity in _items) _tile(activity, scheme, circles)],
              ),
            ),
    );
  }
}

/// All circles or only the one in view, top right in Aktuelles.
class _CircleFilter extends StatelessWidget {
  const _CircleFilter();

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: activitiesOfAllCircles,
    builder: (context, all, _) => _menu(context, all),
  );

  Widget _menu(BuildContext context, bool all) {
    final session = SessionScope.of(context);
    return PopupMenuButton<bool>(
      key: const Key('activities-filter'),
      tooltip: 'Kreise filtern',
      icon: Icon(all ? Icons.filter_list : Icons.filter_alt),
      position: PopupMenuPosition.under,
      onSelected: setActivitiesOfAllCircles,
      itemBuilder: (context) => [
        CheckedPopupMenuItem(value: true, checked: all, child: const Text('Alle Kreise')),
        CheckedPopupMenuItem(
          value: false,
          checked: !all,
          child: Text('Nur ${session.current?.name ?? 'aktueller Kreis'}'),
        ),
      ],
    );
  }
}

/// The circle an entry belongs to, in its color.
class CircleLabel extends StatelessWidget {
  const CircleLabel(this.familyId, {super.key});

  final String familyId;

  @override
  Widget build(BuildContext context) {
    final family = SessionScope.of(context).families.where((f) => f.id == familyId).firstOrNull;
    if (family == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final header = familyHeaderColors(family);
    final background = header.background ?? scheme.secondaryContainer;
    final foreground = header.foreground ?? scheme.onSecondaryContainer;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 96),
      child: Container(
        key: ValueKey('circle-$familyId'),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(10)),
        child: Text(
          family.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: foreground),
        ),
      ),
    );
  }
}

/// An event that is coming up, to open.
class UpcomingEventTile extends StatelessWidget {
  const UpcomingEventTile(this.event, {super.key, required this.showCircle, required this.onTap});

  final Map<String, dynamic> event;
  final bool showCircle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = event['color'] as String? ?? '';
    final family = event['family_id'] as String?;
    return ListTile(
      key: ValueKey('upcoming-${event['id']}-${event['start_at']}'),
      leading: Icon(Icons.event, color: color.isEmpty ? scheme.primary : parseHexColor(color)),
      title: Text(event['title'] as String),
      subtitle: Text(
        [
          upcomingTime(event),
          if ((event['location'] as String? ?? '').isNotEmpty) event['location'] as String,
        ].join(' · '),
      ),
      trailing: showCircle && family != null ? CircleLabel(family) : null,
      onTap: onTap,
    );
  }
}

/// All events coming up for the user, in the circles in view.
class UpcomingEventsScreen extends StatefulWidget {
  const UpcomingEventsScreen({super.key});

  @override
  State<UpcomingEventsScreen> createState() => _UpcomingEventsScreenState();
}

class _UpcomingEventsScreenState extends State<UpcomingEventsScreen> with LiveReload {
  static const _limit = 200;

  List<Map<String, dynamic>> _events = [];
  bool _more = false;
  bool _loaded = false;
  String? _error;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _load();
    listenLive(const {'calendar', 'family'}, _load, everyFamily: activitiesOfAllCircles.value);
  }

  Future<void> _load() async {
    final session = SessionScope.of(context);
    try {
      final result = await session.api.get(
        _activitiesPath(session, '/api/activities/upcoming', {'limit': '$_limit'}),
      ) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _events = (result['items'] as List).cast<Map<String, dynamic>>();
        _more = result['more'] == true;
        _loaded = true;
        _error = null;
      });
    } on ApiException catch (e) {
      if (mounted && !_loaded) setState(() => _error = e.message);
    }
  }

  Future<void> _open(Map<String, dynamic> event) async {
    await openUpcomingEvent(context, event);
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final circles = _showsCircles(session);
    return Scaffold(
      appBar: AppBar(title: const Text('Bevorstehende Termine')),
      body: !_loaded
          ? Center(child: _error == null ? const CircularProgressIndicator() : Text(_error!))
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.only(bottom: 32),
                children: [
                  if (_events.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'Es stehen keine Termine für dich an.',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  for (final event in _events) UpcomingEventTile(event, showCircle: circles, onTap: () => _open(event)),
                  if (_more)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'Weitere Termine findest du im Kalender.',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ),
                ],
              ),
            ),
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
    activitiesOfAllCircles.addListener(_scopeChanged);
    _readAllCircles();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final family = SessionScope.of(context).current?.id;
    if (family == _family) return;
    _family = family;
    _count = 0;
    _scopeChanged();
  }

  @override
  void dispose() {
    activitiesSeen.removeListener(_load);
    activitiesOfAllCircles.removeListener(_scopeChanged);
    super.dispose();
  }

  void _scopeChanged() {
    if (!mounted) return;
    listenLive(_activityTopics, _load, everyFamily: activitiesOfAllCircles.value);
    _load();
  }

  Future<void> _load() async {
    final session = SessionScope.of(context);
    if (session.current == null) return;
    try {
      final result = await session.api.get(_activitiesPath(session, '/api/activities/unread')) as Map<String, dynamic>;
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
