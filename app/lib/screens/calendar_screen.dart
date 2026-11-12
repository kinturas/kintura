import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../common.dart';
import '../session.dart';
import 'calendar_agenda.dart';
import 'calendar_manage_screen.dart';
import 'calendar_views.dart';
import 'event_detail_screen.dart';
import 'event_edit_screen.dart';

/// The layouts; the names are what the backend stores.
const _viewLabels = {'agenda': 'Tagebuch', 'day': 'Tag', 'three': '3 Tage', 'week': 'Woche', 'month': 'Monat'};

class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  final _today = DateTime.now();
  late DateTime _selected = DateTime(_today.year, _today.month, _today.day);
  var _entries = <CalendarEntry>[];
  Map<String, dynamic>? _prefs;
  bool _started = false;
  bool _prefsLoaded = false;
  final _agenda = GlobalKey<AgendaViewState>();

  /// Only lasts while the calendar is open, so that it cannot hide events unnoticed
  /// the next time. Null means no filter.
  Set<String>? _members;

  /// For managers, with the same lifetime: also what is hidden from them, and no member filter.
  bool _showAll = false;
  int _latestLoad = 0;

  String get _view => _prefs?['view'] as String? ?? 'agenda';
  bool get _showsWeekNumbers => _prefs?['week_numbers'] == true && _view != 'agenda';
  int get _firstWeekday => _prefs?['week_start'] == 'sunday' ? DateTime.sunday : DateTime.monday;

  DateTime get _month => DateTime(_selected.year, _selected.month);

  List<CalendarEntry> get _shownEntries => [
    for (final entry in _entries)
      if (entry.shownFor(_members)) entry,
  ];

  /// The days a time grid shows.
  List<DateTime> get _gridDaysShown {
    final first = _view == 'week' ? startOfWeek(_selected, _firstWeekday) : _selected;
    final count = switch (_view) {
      'three' => 3,
      'week' => 7,
      _ => 1,
    };
    return [for (var i = 0; i < count; i++) DateTime(first.year, first.month, first.day + i)];
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      _start();
    }
  }

  Future<void> _start() async {
    final session = SessionScope.of(context);
    await guarded(context, () async {
      final prefs = await session.api.get('${session.familyPath}/calendar-prefs') as Map<String, dynamic>;
      if (mounted) setState(() => _prefs = prefs);
    });
    if (!mounted) return;
    setState(() => _prefsLoaded = true);
    await _load();
  }

  Future<void> _load() async {
    // The agenda holds its own growing range of entries.
    if (_view == 'agenda') {
      await _agenda.currentState?.reload();
      return;
    }
    final DateTime start, end;
    if (_view == 'month') {
      // The weeks around it come into view while scrolling, so they load along.
      start = startOfWeek(DateTime(_month.year, _month.month - 1), _firstWeekday);
      final next = startOfWeek(DateTime(_month.year, _month.month + 1), _firstWeekday);
      end = DateTime(next.year, next.month, next.day + 6 * 7);
    } else {
      // The spans on both sides come into view while swiping, so they load along.
      final days = _gridDaysShown;
      start = DateTime(days.first.year, days.first.month, days.first.day - days.length);
      end = DateTime(days.last.year, days.last.month, days.last.day + 1 + days.length);
    }
    final request = ++_latestLoad;
    final entries = await _fetch(start, end);
    // Paging fast, an older answer can arrive after a newer one.
    if (entries != null && mounted && request == _latestLoad) setState(() => _entries = entries);
  }

  /// Returns null if loading failed, after reporting it.
  Future<List<CalendarEntry>?> _fetch(DateTime start, DateTime end) async {
    final session = SessionScope.of(context);
    final query = Uri(
      queryParameters: {
        'from': start.toUtc().toIso8601String(),
        'to': end.toUtc().toIso8601String(),
        if (_showAll) 'all': '1',
      },
    ).query;
    List<CalendarEntry>? entries;
    await guarded(context, () async {
      final rows = await session.api.get('${session.familyPath}/calendar-entries?$query') as List;
      entries = [for (final row in rows) CalendarEntry(row as Map<String, dynamic>)];
    });
    return entries;
  }

  void _move(int delta) {
    setState(() {
      final days = switch (_view) {
        'three' => 3,
        'week' => 7,
        _ => 1,
      };
      _selected = DateTime(_selected.year, _selected.month, _selected.day + days * delta);
    });
    _load();
  }

  static bool _hasMouse(BuildContext context) => switch (Theme.of(context).platform) {
    TargetPlatform.windows || TargetPlatform.macOS || TargetPlatform.linux => true,
    _ => false,
  };

  /// To the first of a month, as when swiping there.
  void _moveMonth(int delta) => _goTo(DateTime(_month.year, _month.month + delta));

  void _goTo(DateTime day) {
    setState(() => _selected = DateTime(day.year, day.month, day.day));
    if (_view != 'agenda') _load();
  }

  void _goToday() => _goTo(_today);

  Future<void> _pickDay() async {
    final day = await showDatePicker(
      context: context,
      initialDate: _selected,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      helpText: 'Tag auswählen',
    );
    if (day != null && mounted) _goTo(day);
  }

  Future<void> _setView(String view) async {
    final prefs = _prefs;
    if (prefs == null) return;
    final session = SessionScope.of(context);
    setState(() => _prefs = {...prefs, 'view': view});
    _load();
    await guarded(context, () => session.api.put('${session.familyPath}/calendar-prefs', _prefs));
  }

  void _openDay(DateTime day) {
    _selected = day;
    _setView('day');
  }

  Future<void> _add() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => EventEditScreen(day: _selected)),
    );
    if (changed == true) _load();
  }

  void _open(CalendarEntry entry) {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => EventDetailScreen(
          entry: entry,
          firstWeekday: _firstWeekday,
          fetch: _fetch,
          onChanged: _load,
        ),
      ),
    );
  }

  Future<void> _pickMembers() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _MemberFilterScreen(
          selected: _members,
          onChanged: (members) => setState(() => _members = members),
          showAll: _showAll,
          onShowAll: (on) {
            setState(() {
              _showAll = on;
              _members = null;
            });
            _load();
          },
        ),
      ),
    );
  }

  Widget _footerButton(Key key, Widget icon, String label, VoidCallback onPressed) => Expanded(
    child: InkWell(
      key: key,
      onTap: onPressed,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          icon,
          const SizedBox(height: 4),
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.labelSmall),
        ],
      ),
    ),
  );

  Future<void> _manage() async {
    await showCalendarManagePanel(context);
    if (mounted) _start();
  }

  String get _rangeLabel {
    final days = _gridDaysShown;
    if (days.length == 1) return DateFormat('EE, d. MMMM yyyy', 'de').format(days.first);
    return '${DateFormat('d. MMM', 'de').format(days.first)} – ${DateFormat('d. MMM yyyy', 'de').format(days.last)}';
  }

  String? get _weekLabel {
    if (!_showsWeekNumbers) return null;
    final numbers = {for (final day in _gridDaysShown) isoWeekNumber(day)};
    return 'KW ${numbers.join('/')}';
  }

  Widget _header(BuildContext context) {
    final week = _weekLabel;
    return Row(
      children: [
        IconButton(tooltip: 'Zurück', icon: const Icon(Icons.chevron_left), onPressed: () => _move(-1)),
        Expanded(
          child: Column(
            children: [
              Text(_rangeLabel, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
              if (week != null) Text(week, style: Theme.of(context).textTheme.labelSmall),
            ],
          ),
        ),
        IconButton(tooltip: 'Weiter', icon: const Icon(Icons.chevron_right), onPressed: () => _move(1)),
      ],
    );
  }

  Widget _body(BuildContext context) {
    if (!_prefsLoaded) return const Center(child: CircularProgressIndicator());
    return switch (_view) {
      'month' => Padding(
        padding: const EdgeInsets.all(4),
        child: MonthView(
          selected: _selected,
          firstWeekday: _firstWeekday,
          entries: _shownEntries,
          showWeekNumbers: _showsWeekNumbers,
          onDay: _goTo,
          onOpenDay: _openDay,
          onOpenEntry: _open,
        ),
      ),
      'day' || 'three' || 'week' => Column(
        children: [
          _header(context),
          Expanded(
            child: TimeGridView(days: _gridDaysShown, entries: _shownEntries, onOpenEntry: _open, onPage: _goTo),
          ),
        ],
      ),
      _ => AgendaView(
        key: _agenda,
        selected: _selected,
        firstWeekday: _firstWeekday,
        members: _members,
        load: _fetch,
        onSelected: (day) => setState(() => _selected = day),
        onOpen: _open,
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Tooltip(
          message: 'Tag auswählen',
          child: InkWell(
            key: const Key('calendar-title'),
            borderRadius: BorderRadius.circular(8),
            onTap: _pickDay,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(child: Text(DateFormat('MMMM yyyy', 'de').format(_month), overflow: TextOverflow.ellipsis)),
                const Icon(Icons.arrow_drop_down),
              ],
            ),
          ),
        ),
        actions: [
          // Swiping is for fingers; with a mouse, arrows are at hand. In the web app
          // the platform is that of the browser's device.
          if (_view == 'month' && _hasMouse(context)) ...[
            IconButton(tooltip: 'Voriger Monat', icon: const Icon(Icons.chevron_left), onPressed: () => _moveMonth(-1)),
            IconButton(tooltip: 'Nächster Monat', icon: const Icon(Icons.chevron_right), onPressed: () => _moveMonth(1)),
          ],
          PopupMenuButton<String>(
            tooltip: 'Ansicht',
            icon: const Icon(Icons.view_module_outlined),
            initialValue: _view,
            onSelected: _setView,
            itemBuilder: (context) => [
              for (final entry in _viewLabels.entries)
                PopupMenuItem(value: entry.key, child: Text(entry.value)),
            ],
          ),
          IconButton(
            tooltip: 'Kalender verwalten',
            icon: const Icon(Icons.edit_calendar_outlined),
            onPressed: _manage,
          ),
        ],
      ),
      bottomNavigationBar: BottomAppBar(
        height: 64,
        padding: EdgeInsets.zero,
        child: Row(
          children: [
            _footerButton(const Key('calendar-today'), const Icon(Icons.today), 'Heute', _goToday),
            _footerButton(const Key('calendar-add'), const Icon(Icons.add), 'Hinzufügen', _add),
            _footerButton(
              const Key('calendar-members'),
              Badge(
                isLabelVisible: _showAll || _members != null,
                label: Text(_showAll ? 'Alle' : '${_members?.length ?? 0}'),
                child: const Icon(Icons.people_outline),
              ),
              'Mitgliederfilter',
              _pickMembers,
            ),
          ],
        ),
      ),
      body: _body(context),
    );
  }
}

/// Chooses whose events of the standard calendar are shown. Each change counts at once.
class _MemberFilterScreen extends StatefulWidget {
  const _MemberFilterScreen({
    required this.selected,
    required this.onChanged,
    required this.showAll,
    required this.onShowAll,
  });

  final Set<String>? selected;
  final ValueChanged<Set<String>?> onChanged;
  final bool showAll;
  final ValueChanged<bool> onShowAll;

  @override
  State<_MemberFilterScreen> createState() => _MemberFilterScreenState();
}

class _MemberFilterScreenState extends State<_MemberFilterScreen> {
  late Set<String>? _selected = widget.selected;
  late bool _showAll = widget.showAll;

  void _set(Set<String> selected, Set<String> everyone) {
    final next = selected.containsAll(everyone) ? null : selected;
    setState(() => _selected = next);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    final family = session.current;
    return Scaffold(
      appBar: AppBar(title: const Text('Mitgliederfilter')),
      body: AsyncView<List<Map<String, dynamic>>>(
        load: () async {
          final data = await session.api.get('${session.familyPath}/members');
          return (data['members'] as List).cast<Map<String, dynamic>>();
        },
        builder: (context, members) {
          final everyone = {for (final member in members) member['id'] as String};
          final selected = _selected ?? everyone;
          return ListView(
            children: [
              if (family?.isManager ?? false) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text(
                    'Nur für ${family!.type.roleLabel('manager')}',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                SwitchListTile(
                  key: const Key('show-all-entries'),
                  title: const Text('Alle Einträge anzeigen'),
                  subtitle: const Text(
                    'Nur bei Bedarf aktivieren. Zeigt auch Termine, die nur für Teilnehmer und Ersteller sichtbar sind.',
                  ),
                  value: _showAll,
                  onChanged: (on) {
                    setState(() {
                      _showAll = on;
                      _selected = null;
                    });
                    widget.onShowAll(on);
                  },
                ),
                const Divider(height: 1),
              ],
              if (!_showAll) ...[
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Zeigt nur die Termine aus dem Standardkalender, bei denen die gewählten Mitglieder Teilnehmer sind. Andere Kalender werden ausgeblendet.'),
                ),
                CheckboxListTile(
                  key: const Key('members-all'),
                  title: const Text('Alle Mitglieder'),
                  tristate: true,
                  value: selected.containsAll(everyone) ? true : (selected.isEmpty ? false : null),
                  onChanged: (_) => _set(selected.containsAll(everyone) ? {} : everyone, everyone),
                ),
                const Divider(height: 1),
                for (final member in members)
                  CheckboxListTile(
                    secondary: UserAvatar(member['name'] as String, color: member['color'] as String),
                    title: Text(member['name'] as String),
                    value: selected.contains(member['id']),
                    onChanged: (on) {
                      final next = {...selected};
                      if (on!) {
                        next.add(member['id'] as String);
                      } else {
                        next.remove(member['id']);
                      }
                      _set(next, everyone);
                    },
                  ),
              ],
            ],
          );
        },
      ),
    );
  }
}
