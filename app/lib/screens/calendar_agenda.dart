import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../common.dart';
import 'calendar_views.dart';

/// Months loaded at once. A series without an end has endless dates, so the list
/// can only ever hold a window of them, which grows while scrolling.
const _chunkMonths = 6;

/// A calendar can be empty for a long time, so loading stops after this many empty
/// chunks and leaves it to a button to look further.
const _maxEmptyChunks = 2;

/// How many days with entries stay loaded ahead of the one in view. Counted in days,
/// because the list only estimates its length in pixels from what it has built.
const _daysAhead = 10;

const _gridRowHeight = 40.0;
const _gridWeeks = 6;

/// Below this height the month grid would leave no room for the list.
const _minHeightForGrid = 560.0;

DateTime _dayOf(DateTime date) => DateTime(date.year, date.month, date.day);

/// The month grid above a continuous list of all days with entries. The list starts
/// at the selected day and can be scrolled both ways, and the grid follows it.
class AgendaView extends StatefulWidget {
  const AgendaView({
    super.key,
    required this.selected,
    required this.firstWeekday,
    required this.members,
    required this.load,
    required this.onSelected,
    required this.onOpen,
  });

  final DateTime selected;
  final int firstWeekday;

  /// The member filter; null means none.
  final Set<String>? members;

  /// Returns null if loading failed.
  final Future<List<CalendarEntry>?> Function(DateTime from, DateTime to) load;
  final ValueChanged<DateTime> onSelected;
  final ValueChanged<CalendarEntry> onOpen;

  @override
  State<AgendaView> createState() => AgendaViewState();
}

class AgendaViewState extends State<AgendaView> {
  final _scroll = ScrollController();
  final _center = UniqueKey();
  final _list = GlobalKey();
  final _dayKeys = <DateTime, GlobalKey>{};

  late DateTime _anchor = _dayOf(widget.selected);
  late DateTime _shown = _anchor;
  late DateTime _from;
  late DateTime _to;

  var _entries = <String, CalendarEntry>{};
  var _byStartDay = <DateTime, List<CalendarEntry>>{};
  var _firstOnDay = <DateTime, CalendarEntry>{};

  bool _loadingBefore = false;
  bool _loadingAfter = false;
  int _emptyBefore = 0;
  int _emptyAfter = 0;
  bool _followScheduled = false;

  /// Answers from before a reset of the window no longer count.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _setWindow(_anchor);
    reload();
  }

  @override
  void didUpdateWidget(AgendaView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final selected = _dayOf(widget.selected);
    if (selected != _shown) _jumpTo(selected);
    if (!setEquals(oldWidget.members, widget.members)) {
      _index();
      _emptyBefore = 0;
      _emptyAfter = 0;
      _loadMoreIfNeeded();
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _setWindow(DateTime around) {
    _from = DateTime(around.year, around.month - _chunkMonths);
    _to = DateTime(around.year, around.month + _chunkMonths);
  }

  /// A changed occurrence of a series has the same id as the others, and a long entry
  /// comes back with every chunk it reaches into.
  String _keyOf(CalendarEntry entry) => '${entry.raw['source']}|${entry.id}|${entry.raw['start_at']}';

  Iterable<CalendarEntry> get _shownEntries => _entries.values.where((entry) => entry.shownFor(widget.members));

  void _index() {
    final sorted = _shownEntries.toList()..sort((a, b) => a.start.compareTo(b.start));
    final byStartDay = <DateTime, List<CalendarEntry>>{};
    final firstOnDay = <DateTime, CalendarEntry>{};
    for (final entry in sorted) {
      final first = _dayOf(entry.start);
      byStartDay.putIfAbsent(first, () => []).add(entry);
      for (var day = first; !day.isAfter(entry.end); day = DateTime(day.year, day.month, day.day + 1)) {
        firstOnDay.putIfAbsent(day, () => entry);
      }
    }
    _byStartDay = byStartDay;
    _firstOnDay = firstOnDay;
  }

  /// Loads everything in the window again, for example after an edit.
  Future<void> reload() async {
    final generation = ++_generation;
    final entries = await widget.load(_from, _to);
    if (!mounted || generation != _generation || entries == null) return;
    setState(() {
      _entries = {for (final entry in entries) _keyOf(entry): entry};
      _index();
    });
    _loadMoreIfNeeded();
  }

  Future<void> _extend({required bool after}) async {
    final emptyChunks = after ? _emptyAfter : _emptyBefore;
    if ((after ? _loadingAfter : _loadingBefore) || emptyChunks >= _maxEmptyChunks) return;
    final generation = _generation;
    final from = after ? _to : DateTime(_from.year, _from.month - _chunkMonths);
    final to = after ? DateTime(_to.year, _to.month + _chunkMonths) : _from;
    setState(() {
      if (after) {
        _loadingAfter = true;
      } else {
        _loadingBefore = true;
      }
    });
    final entries = await widget.load(from, to);
    if (!mounted) return;
    setState(() {
      if (after) {
        _loadingAfter = false;
      } else {
        _loadingBefore = false;
      }
      if (generation != _generation) return;
      // After a failure the button offers another try, instead of one with every pixel scrolled.
      var empty = _maxEmptyChunks;
      if (entries != null) {
        // Only what is shown counts, or a filter that hides an endless series would never stop.
        final count = _shownEntries.length;
        _entries.addAll({for (final entry in entries) _keyOf(entry): entry});
        empty = _shownEntries.length == count ? emptyChunks + 1 : 0;
        _index();
        if (after) {
          _to = to;
        } else {
          _from = from;
        }
      }
      if (after) {
        _emptyAfter = empty;
      } else {
        _emptyBefore = empty;
      }
    });
    _loadMoreIfNeeded();
  }

  /// Runs after every load as well, since a short list cannot be scrolled to load the rest.
  void _loadMoreIfNeeded() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final days = _byStartDay.keys;
      if (days.where((day) => day.isAfter(_shown)).length < _daysAhead) _extend(after: true);
      if (days.where((day) => day.isBefore(_shown)).length < _daysAhead) _extend(after: false);
    });
  }

  void _jumpTo(DateTime day) {
    _anchor = day;
    _shown = day;
    if (day.isBefore(_from) || !day.isBefore(_to)) {
      _setWindow(day);
      _entries = {};
      _index();
      _emptyBefore = 0;
      _emptyAfter = 0;
      reload();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
      _loadMoreIfNeeded();
    });
  }

  /// The day at the top of the list is the selected one.
  void _followScroll() {
    final list = _list.currentContext?.findRenderObject() as RenderBox?;
    if (list == null) return;
    final top = list.localToGlobal(Offset.zero).dy;
    DateTime? day;
    var dayTop = double.negativeInfinity;
    // At the very beginning of the list no day reaches the top yet, so the first one counts.
    DateTime? firstDay;
    var firstTop = double.infinity;
    for (final entry in _dayKeys.entries) {
      final box = entry.value.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.attached) continue;
      final y = box.localToGlobal(Offset.zero).dy;
      if (y <= top + 1 && y > dayTop) {
        day = entry.key;
        dayTop = y;
      }
      if (y < firstTop) {
        firstDay = entry.key;
        firstTop = y;
      }
    }
    day ??= firstDay;
    if (day != null && day != _shown) {
      _shown = day;
      widget.onSelected(day);
      _loadMoreIfNeeded();
    }
  }

  bool _onScroll(ScrollUpdateNotification notification) {
    if (notification.depth != 0) return false;
    // The days only reach their new places in the coming layout.
    if (!_followScheduled) {
      _followScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _followScheduled = false;
        if (mounted) _followScroll();
      });
    }
    return false;
  }

  Widget _tile(CalendarEntry entry) {
    final lastDay = _dayOf(entry.end);
    final details = [
      if (entry.spansDays && lastDay != _dayOf(entry.start)) 'bis ${dateFormat.format(entry.end)}',
      if (entry.location.isNotEmpty) entry.location,
      if (entry.description.isNotEmpty) entry.description,
    ];
    final background = parseHexColor(entry.color);
    final foreground = readableOn(background);
    // The time beside the tile can be tapped as well; the tile itself wins on its own area.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => widget.onOpen(entry),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 2, 12, 2),
        child: Row(
          children: [
            SizedBox(
              width: 58,
              child: Text(
                entry.allDay ? 'Ganztags' : timeFormat.format(entry.start),
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
            Expanded(
              // Its own surface: the color of a ListTile lands on the nearest one, and from
              // there tiles scrolled out of the list would show over the month.
              child: Material(
                color: background,
                borderRadius: BorderRadius.circular(8),
                clipBehavior: Clip.antiAlias,
                child: ListTile(
                  textColor: foreground,
                  iconColor: foreground,
                  title: Text(entry.title),
                  subtitle: details.isEmpty ? null : Text(details.join('\n')),
                  trailing: entry.repeats ? const Icon(Icons.repeat, size: 18) : null,
                  onTap: () => widget.onOpen(entry),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// An entry belongs to the day it starts on, or a long one would fill the list with
  /// copies. Only the day the list starts at also names what is already running.
  Widget _dayBlock(BuildContext context, DateTime day) {
    final isToday = day == _dayOf(DateTime.now());
    final colors = Theme.of(context).colorScheme;
    final entries = [
      if (day == _anchor) ..._shownEntries.where((e) => e.start.isBefore(day) && e.occursOn(day)),
      ...?_byStartDay[day],
    ];
    // In a list without an end, the year is not obvious any more.
    final year = day.year == DateTime.now().year ? '' : ' ${day.year}';
    return Column(
      key: _dayKeys.putIfAbsent(day, GlobalKey.new),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(
            '${isToday ? 'Heute, ' : ''}${weekdayDateFormat.format(day)}$year',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(color: isToday ? colors.primary : null),
          ),
        ),
        if (entries.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Keine Termine an diesem Tag.'),
          ),
        for (final entry in entries) _tile(entry),
      ],
    );
  }

  Widget _edge(BuildContext context, {required bool after}) {
    final limit = after ? _to : _from;
    if (after ? _loadingAfter : _loadingBefore) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2))),
      );
    }
    if ((after ? _emptyAfter : _emptyBefore) < _maxEmptyChunks) return const SizedBox(height: 16);
    final month = DateFormat('MMMM yyyy', 'de').format(limit);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Text(after ? 'Keine weiteren Termine bis $month.' : 'Keine früheren Termine ab $month.', textAlign: TextAlign.center),
          TextButton(
            onPressed: () {
              if (after) {
                _emptyAfter = 0;
              } else {
                _emptyBefore = 0;
              }
              _extend(after: after);
            },
            child: const Text('Weiter suchen'),
          ),
        ],
      ),
    );
  }

  Widget _week(BuildContext context, DateTime weekStart, DateTime month) {
    final colors = Theme.of(context).colorScheme;
    final selected = _dayOf(widget.selected);
    final today = _dayOf(DateTime.now());
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          for (var i = 0; i < 7; i++)
            Expanded(
              child: Builder(
                builder: (context) {
                  final date = DateTime(weekStart.year, weekStart.month, weekStart.day + i);
                  final isSelected = date == selected;
                  final firstEntry = _firstOnDay[date];
                  return InkWell(
                    key: ValueKey(date),
                    customBorder: const CircleBorder(),
                    onTap: () => widget.onSelected(date),
                    child: Container(
                      margin: const EdgeInsets.all(1),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isSelected ? colors.primary : null,
                        border: date == today && !isSelected ? Border.all(color: colors.primary) : null,
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            '${date.day}',
                            style: TextStyle(
                              height: 1.2,
                              color: isSelected
                                  ? colors.onPrimary
                                  : date.month == month.month
                                  ? colors.onSurface
                                  : colors.outline,
                            ),
                          ),
                          firstEntry == null
                              ? const SizedBox.square(dimension: 7)
                              : EventDot(color: firstEntry.color, size: 7),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final today = _dayOf(DateTime.now());
    final days = {..._byStartDay.keys, _anchor, if (!today.isBefore(_from) && today.isBefore(_to)) today};
    final past = days.where((day) => day.isBefore(_anchor)).toList()..sort((a, b) => b.compareTo(a));
    final future = days.where((day) => !day.isBefore(_anchor)).toList()..sort();
    return LayoutBuilder(
      builder: (context, constraints) => Column(
        children: [
          if (constraints.maxHeight >= _minHeightForGrid) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: WeekdayRow(firstWeekday: widget.firstWeekday, height: _gridRowHeight),
            ),
            SizedBox(
              height: _gridWeeks * _gridRowHeight,
              child: WeekScroller(
                key: ValueKey(widget.firstWeekday),
                selected: widget.selected,
                firstWeekday: widget.firstWeekday,
                onDay: widget.onSelected,
                builder: _week,
              ),
            ),
          ],
          const Divider(height: 1),
          Expanded(
            child: NotificationListener<ScrollUpdateNotification>(
              onNotification: _onScroll,
              // The center lets earlier days grow upwards without moving what is in view.
              child: CustomScrollView(
                key: _list,
                controller: _scroll,
                center: _center,
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverToBoxAdapter(child: _edge(context, after: false)),
                  SliverList.builder(
                    itemCount: past.length,
                    itemBuilder: (context, index) => _dayBlock(context, past[index]),
                  ),
                  SliverList.builder(
                    key: _center,
                    itemCount: future.length,
                    itemBuilder: (context, index) => _dayBlock(context, future[index]),
                  ),
                  SliverToBoxAdapter(child: _edge(context, after: true)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
