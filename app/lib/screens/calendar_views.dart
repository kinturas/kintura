import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../common.dart';

const weekNumberWidth = 28.0;
const weekdayLabels = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];

/// One entry of any calendar, as served by GET calendar-entries.
class CalendarEntry {
  // An all-day entry keeps its days everywhere; anything else shows in device time.
  CalendarEntry(this.raw)
    : start = raw['all_day'] as bool
          ? DateTime.parse(raw['start_local'] as String)
          : DateTime.parse(raw['start_at'] as String).toLocal(),
      end = raw['all_day'] as bool
          ? DateTime.parse(raw['end_local'] as String)
          : DateTime.parse(raw['end_at'] as String).toLocal();

  final Map<String, dynamic> raw;
  final DateTime start;
  final DateTime end;

  String get id => raw['id'] as String;
  String get title => raw['title'] as String;
  String get description => raw['description'] as String;
  String get location => raw['location'] as String;
  String get color => raw['color'] as String;
  String get sourceName => raw['source_name'] as String;
  bool get allDay => raw['all_day'] as bool;
  bool get repeats => raw['recurrence'] != null;

  /// Whether the user may change it: the creator or a manager, in the standard calendar.
  bool get editable => raw['editable'] as bool;

  /// Whether it is an event of the selected circle, with comments and everything else.
  bool get inStandardCalendar => raw['source'] == 'family';

  /// Whole days and anything of a day or longer sit above the hours, where a
  /// column full of color would only hide the rest.
  bool get spansDays => allDay || end.difference(start) >= const Duration(hours: 24);

  /// The member filter leaves only the standard calendar of the family; null means no
  /// filter. An event for everyone concerns every member.
  bool shownFor(Set<String>? members) {
    if (members == null) return true;
    if (raw['source'] != 'family') return false;
    if (raw['participants_all'] == true) return true;
    final participants = raw['participant_ids'] as List? ?? const [];
    return participants.any(members.contains);
  }

  bool occursOn(DateTime day) {
    final next = DateTime(day.year, day.month, day.day + 1);
    final first = DateTime(day.year, day.month, day.day);
    return start.isBefore(next) && !end.isBefore(first);
  }
}

/// The first day of the week that contains [date]; [firstWeekday] follows DateTime.weekday.
DateTime startOfWeek(DateTime date, int firstWeekday) {
  final back = (date.weekday - firstWeekday + 7) % 7;
  return DateTime(date.year, date.month, date.day - back);
}

/// The calendar week by ISO 8601, which is the one in use in Germany.
int isoWeekNumber(DateTime date) {
  final thursday = DateTime.utc(date.year, date.month, date.day + 4 - date.weekday);
  return thursday.difference(DateTime.utc(thursday.year)).inDays ~/ 7 + 1;
}

/// The weekday labels in display order.
List<String> orderedWeekdays(int firstWeekday) => [
  for (var i = 0; i < 7; i++) weekdayLabels[(firstWeekday - 1 + i) % 7],
];

/// A small sample of an entry's color. The outline keeps very light colors visible.
class EventDot extends StatelessWidget {
  const EventDot({super.key, required this.color, required this.size});

  final String color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: parseHexColor(color),
        border: Border.all(color: Theme.of(context).colorScheme.outline, width: 0.5),
      ),
    );
  }
}

/// The title of an entry on its color.
class EntryChip extends StatelessWidget {
  const EntryChip({super.key, required this.entry, required this.onTap});

  final CalendarEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final background = parseHexColor(entry.color);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 18,
        margin: const EdgeInsets.only(bottom: 2),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(4)),
        child: Text(
          entry.title,
          maxLines: 1,
          overflow: TextOverflow.clip,
          softWrap: false,
          style: TextStyle(fontSize: 11, color: readableOn(background)),
        ),
      ),
    );
  }
}

/// A freely scrolling list of weeks, six of them in view, that stops wherever it is
/// let go. The month in the middle counts as the current one.
class WeekScroller extends StatefulWidget {
  const WeekScroller({
    super.key,
    required this.selected,
    required this.firstWeekday,
    required this.onDay,
    required this.builder,
  });

  final DateTime selected;
  final int firstWeekday;

  /// Reports a day of the month that scrolled into the middle. A change of [selected]
  /// from outside only moves the weeks along.
  final ValueChanged<DateTime> onDay;
  final Widget Function(BuildContext context, DateTime weekStart, DateTime month) builder;

  @override
  State<WeekScroller> createState() => _WeekScrollerState();
}

class _WeekScrollerState extends State<WeekScroller> {
  static const _weeksInView = 6;
  static const _slide = Duration(milliseconds: 250);

  /// Further than this the weeks jump, or they would rush past for no use.
  static const _maxSlideWeeks = 10;

  /// Made with the first layout, which tells where the current month lies.
  ScrollController? _scroll;
  ScrollController get _controller => _scroll!;
  late final DateTime _base = startOfWeek(DateTime(1970, 1, 5), widget.firstWeekday);
  late DateTime _month = _monthOf(widget.selected);

  /// What the weeks reported themselves, which needs no following.
  DateTime? _reported;
  double _rowHeight = 0;

  /// While moving by itself it passes months nobody went to.
  int _sliding = 0;

  DateTime _monthOf(DateTime day) => DateTime(day.year, day.month);

  // In UTC, because a day with a time change is not 24 hours long.
  int _weekOf(DateTime day) =>
      DateTime.utc(day.year, day.month, day.day).difference(DateTime.utc(_base.year, _base.month, _base.day)).inDays ~/ 7;

  DateTime _startOf(int week) => DateTime(_base.year, _base.month, _base.day + week * 7);

  double _offsetOfMonth(DateTime month) => _weekOf(month) * _rowHeight;

  @override
  void didUpdateWidget(WeekScroller oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selected == oldWidget.selected || widget.selected == _reported) return;
    _reported = null;
    WidgetsBinding.instance.addPostFrameCallback((_) => _follow(widget.selected));
  }

  @override
  void dispose() {
    _scroll?.dispose();
    super.dispose();
  }

  /// Shows a day chosen elsewhere, unless it is in view and its month is the current one.
  Future<void> _follow(DateTime day) async {
    if (!mounted || _scroll == null || !_controller.hasClients) return;
    final month = _monthOf(day);
    final top = _controller.offset;
    final y = _weekOf(day) * _rowHeight;
    final inView = y >= top && y + _rowHeight <= top + _rowHeight * _weeksInView;
    if (month == _month && inView) return;
    setState(() => _month = month);
    final target = _offsetOfMonth(month);
    _sliding++;
    if ((target - top).abs() > _maxSlideWeeks * _rowHeight) {
      _controller.jumpTo(target);
    } else {
      await _controller.animateTo(target, duration: _slide, curve: Curves.easeOut);
    }
    _sliding--;
  }

  void _onScroll() {
    if (_sliding > 0 || _rowHeight == 0) return;
    final top = _controller.offset;
    final middle = _startOf(((top + _rowHeight * _weeksInView / 2) / _rowHeight).floor());
    final month = _monthOf(DateTime(middle.year, middle.month, middle.day + 3));
    if (month == _month) return;
    setState(() => _month = month);
    // The first of the month, or when coming from below, the first of its days in view.
    final firstInView = _startOf((top / _rowHeight).ceil());
    final day = firstInView.isAfter(month) && _monthOf(firstInView) == month ? firstInView : month;
    _reported = day;
    widget.onDay(day);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight / _weeksInView;
        if (_scroll == null) {
          _rowHeight = height;
          _scroll = ScrollController(initialScrollOffset: _offsetOfMonth(_month))..addListener(_onScroll);
        } else if (height != _rowHeight) {
          // Stays on the same week when the room changes, as when a phone is turned.
          final week = (_controller.offset / _rowHeight).round();
          _rowHeight = height;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _controller.hasClients) {
              _sliding++;
              _controller.jumpTo(week * height);
              _sliding--;
            }
          });
        }
        return ListView.builder(
          controller: _controller,
          itemExtent: height,
          itemBuilder: (context, week) => widget.builder(context, _startOf(week), _month),
        );
      },
    );
  }
}

/// One page per month, six weeks each, that snaps into place: swiped sideways,
/// dragged with the mouse, or turned one month per step of the wheel.
class MonthPager extends StatefulWidget {
  const MonthPager({
    super.key,
    required this.selected,
    required this.firstWeekday,
    required this.onDay,
    required this.builder,
    this.weekLabel,
  });

  final DateTime selected;
  final int firstWeekday;

  /// Labels the weeks in a column that stays in place while the months move;
  /// only its labels change with the month in view. Null shows no column.
  final Widget Function(BuildContext context, DateTime weekStart)? weekLabel;

  /// Reports the first day of a month paged to. A change of [selected] from
  /// outside only moves the pages along.
  final ValueChanged<DateTime> onDay;
  final Widget Function(BuildContext context, DateTime weekStart, DateTime month) builder;

  @override
  State<MonthPager> createState() => _MonthPagerState();
}

class _MonthPagerState extends State<MonthPager> {
  static const _weeks = 6;
  static const _slide = Duration(milliseconds: 250);

  /// Further than this the pages jump, or months would rush past for no use.
  static const _maxSlideMonths = 3;

  /// A wheel or trackpad sends many steps for one turn; this many count as one.
  static const _wheelPause = Duration(milliseconds: 400);

  // Set in initState: a lazy `late` initializer would only run on first use, by
  // then possibly with the month the pages are still to move to.
  late final PageController _controller;
  late int _page;

  /// The month mostly in view, also halfway through a swipe; it names the weeks.
  late final ValueNotifier<int> _inView;

  @override
  void initState() {
    super.initState();
    _page = _pageOf(widget.selected);
    _controller = PageController(initialPage: _page)..addListener(_onMove);
    _inView = ValueNotifier(_page);
  }

  /// While moving by itself it passes months nobody went to.
  int _sliding = 0;
  DateTime _lastWheel = DateTime(0);

  // Months since January 1970.
  static int _pageOf(DateTime day) => (day.year - 1970) * 12 + day.month - 1;
  static DateTime _monthAt(int page) => DateTime(1970, page + 1);

  @override
  void didUpdateWidget(MonthPager oldWidget) {
    super.didUpdateWidget(oldWidget);
    final target = _pageOf(widget.selected);
    if (target == _page) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _goTo(target));
  }

  @override
  void dispose() {
    _controller.dispose();
    _inView.dispose();
    super.dispose();
  }

  void _onMove() {
    final page = _controller.page;
    if (page != null) _inView.value = page.round();
  }

  /// The first days of the weeks a month shows.
  List<DateTime> _weeksOf(int page) {
    final first = startOfWeek(_monthAt(page), widget.firstWeekday);
    return [for (var week = 0; week < _weeks; week++) DateTime(first.year, first.month, first.day + week * 7)];
  }

  /// Shows a month chosen elsewhere.
  Future<void> _goTo(int target) async {
    if (!mounted || !_controller.hasClients || target == _page) return;
    _page = target;
    _sliding++;
    if ((target - (_controller.page ?? target)).abs() > _maxSlideMonths) {
      _controller.jumpToPage(target);
    } else {
      await _controller.animateToPage(target, duration: _slide, curve: Curves.easeOut);
    }
    _sliding--;
  }

  void _onPageChanged(int page) {
    if (_sliding > 0) return;
    _page = page;
    widget.onDay(_monthAt(page));
  }

  void _onWheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    // Taken before the pages scroll freely by it, which would leave them between months.
    GestureBinding.instance.pointerSignalResolver.register(event, (event) {
      final delta = (event as PointerScrollEvent).scrollDelta;
      final step = delta.dy.abs() >= delta.dx.abs() ? delta.dy : delta.dx;
      final now = DateTime.now();
      if (step == 0 || now.difference(_lastWheel) < _wheelPause) return;
      _lastWheel = now;
      final page = (_controller.page ?? _page).round() + (step > 0 ? 1 : -1);
      _controller.animateToPage(page, duration: _slide, curve: Curves.easeOut);
    });
  }

  Widget _month(BuildContext context, int page) {
    final month = _monthAt(page);
    return Listener(
      onPointerSignal: _onWheel,
      child: Column(
        children: [
          for (final weekStart in _weeksOf(page)) Expanded(child: widget.builder(context, weekStart, month)),
        ],
      ),
    );
  }

  Widget _weekLabels(Widget Function(BuildContext context, DateTime weekStart) label) {
    return SizedBox(
      key: const Key('week-numbers'),
      width: weekNumberWidth,
      child: ValueListenableBuilder(
        valueListenable: _inView,
        builder: (context, page, _) => AnimatedSwitcher(
          duration: const Duration(milliseconds: 150),
          child: Column(
            key: ValueKey(page),
            children: [
              for (final weekStart in _weeksOf(page)) Expanded(child: Center(child: label(context, weekStart))),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.weekLabel;
    final pages = ScrollConfiguration(
      // On the web and the desktop only touch drags by default; the mouse should too.
      behavior: ScrollConfiguration.of(context).copyWith(dragDevices: PointerDeviceKind.values.toSet()),
      child: PageView.builder(
        key: const Key('month-pager'),
        controller: _controller,
        onPageChanged: _onPageChanged,
        itemBuilder: _month,
      ),
    );
    if (label == null) return pages;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [_weekLabels(label), Expanded(child: pages)],
    );
  }
}

/// The names of the days above the weeks, which stay in place while those move.
class WeekdayRow extends StatelessWidget {
  const WeekdayRow({super.key, required this.firstWeekday, this.leading = 0, this.height});

  final int firstWeekday;

  /// Room for the week numbers at the start of a row.
  final double leading;
  final double? height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: Row(
        children: [
          SizedBox(width: leading),
          for (final label in orderedWeekdays(firstWeekday))
            Expanded(
              child: Center(child: Text(label, style: Theme.of(context).textTheme.labelMedium)),
            ),
        ],
      ),
    );
  }
}

/// Six weeks with the titles of their entries.
class MonthView extends StatelessWidget {
  const MonthView({
    super.key,
    required this.selected,
    required this.firstWeekday,
    required this.entries,
    required this.showWeekNumbers,
    required this.onDay,
    required this.onOpenDay,
    required this.onOpenEntry,
  });

  final DateTime selected;
  final int firstWeekday;
  final List<CalendarEntry> entries;
  final bool showWeekNumbers;
  final ValueChanged<DateTime> onDay;
  final ValueChanged<DateTime> onOpenDay;
  final ValueChanged<CalendarEntry> onOpenEntry;

  Widget _cell(BuildContext context, DateTime day, DateTime month) {
    final scheme = Theme.of(context).colorScheme;
    final today = DateTime.now();
    final isToday = DateUtils.isSameDay(day, today);
    final dayEntries = entries.where((entry) => entry.occursOn(day)).toList();
    return InkWell(
      key: ValueKey(day),
      onTap: () => onOpenDay(day),
      child: Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(border: Border.all(color: scheme.outlineVariant, width: 0.5)),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // What fits below the number; one line stays for "+2" when needed.
            final fit = ((constraints.maxHeight - 22) / 20).floor().clamp(0, 20);
            final shown = dayEntries.length > fit ? (fit - 1).clamp(0, 20) : dayEntries.length;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 20,
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: Text(
                      '${day.day}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: isToday ? FontWeight.bold : null,
                        color: isToday
                            ? scheme.primary
                            : day.month == month.month
                            ? scheme.onSurface
                            : scheme.outline,
                      ),
                    ),
                  ),
                ),
                for (final entry in dayEntries.take(shown))
                  EntryChip(entry: entry, onTap: () => onOpenEntry(entry)),
                if (shown < dayEntries.length && fit > 0)
                  Text(
                    '+${dayEntries.length - shown}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 11),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        WeekdayRow(firstWeekday: firstWeekday, leading: showWeekNumbers ? weekNumberWidth : 0),
        const SizedBox(height: 4),
        Expanded(
          child: MonthPager(
            key: ValueKey(firstWeekday),
            selected: selected,
            firstWeekday: firstWeekday,
            onDay: onDay,
            weekLabel: showWeekNumbers
                ? (context, weekStart) =>
                      Text('${isoWeekNumber(weekStart)}', style: Theme.of(context).textTheme.labelSmall)
                : null,
            builder: (context, weekStart, month) => Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < 7; i++)
                  Expanded(child: _cell(context, DateTime(weekStart.year, weekStart.month, weekStart.day + i), month)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Where a timed entry sits within a day.
class PlacedEntry {
  PlacedEntry(this.entry, this.startMinute, this.endMinute);

  final CalendarEntry entry;
  final int startMinute;
  final int endMinute;
  int lane = 0;
  int lanes = 1;
}

/// Lays out the timed entries of a day: overlapping ones share the width in lanes.
List<PlacedEntry> layoutDay(List<CalendarEntry> entries, DateTime day) {
  final next = DateTime(day.year, day.month, day.day + 1);
  final placed = <PlacedEntry>[];
  for (final entry in entries) {
    if (entry.spansDays || !entry.occursOn(day)) continue;
    final startMinute = entry.start.isBefore(day) ? 0 : entry.start.hour * 60 + entry.start.minute;
    final endMinute = entry.end.isBefore(next) ? entry.end.hour * 60 + entry.end.minute : 24 * 60;
    placed.add(PlacedEntry(entry, startMinute, endMinute));
  }
  placed.sort((a, b) => a.startMinute.compareTo(b.startMinute));

  // Entries that overlap directly or through others form a group of the same width.
  var group = <PlacedEntry>[];
  var groupEnd = -1;
  void closeGroup() {
    final laneEnds = <int>[];
    for (final item in group) {
      final free = laneEnds.indexWhere((end) => end <= item.startMinute);
      if (free >= 0) {
        item.lane = free;
        laneEnds[free] = _visibleEnd(item);
      } else {
        item.lane = laneEnds.length;
        laneEnds.add(_visibleEnd(item));
      }
    }
    for (final item in group) {
      item.lanes = laneEnds.length;
    }
    group = [];
    groupEnd = -1;
  }

  for (final item in placed) {
    if (group.isNotEmpty && item.startMinute >= groupEnd) closeGroup();
    group.add(item);
    if (_visibleEnd(item) > groupEnd) groupEnd = _visibleEnd(item);
  }
  if (group.isNotEmpty) closeGroup();
  return placed;
}

const _minEntryMinutes = 25;

/// Short entries are drawn taller than they last, so they also take that space.
int _visibleEnd(PlacedEntry item) =>
    item.endMinute - item.startMinute < _minEntryMinutes ? item.startMinute + _minEntryMinutes : item.endMinute;

/// Hours on the left and one column per day: the day, three-day and week views.
///
/// Swiped sideways, it snaps to the next or previous span of as many days. The
/// hours stay in place, and so does how far down the day is scrolled.
class TimeGridView extends StatefulWidget {
  const TimeGridView({super.key, required this.days, required this.entries, required this.onOpenEntry, this.onPage});

  final List<DateTime> days;
  final List<CalendarEntry> entries;
  final ValueChanged<CalendarEntry> onOpenEntry;

  /// Reports the first day of a span swiped to. A change of [days] from outside
  /// only moves the pages along.
  final ValueChanged<DateTime>? onPage;

  @override
  State<TimeGridView> createState() => _TimeGridViewState();
}

class _TimeGridViewState extends State<TimeGridView> {
  static const _hourHeight = 48.0;
  static const _gutter = 44.0;
  static const _maxAllDayShown = 3;
  static const _dayHeaderHeight = 44.0;

  /// The height of an [EntryChip] with its margin.
  static const _chipHeight = 20.0;
  static const _slide = Duration(milliseconds: 250);

  /// Further than this many spans the pages change at once instead of sliding.
  static const _maxSlidePages = 3;

  /// Pages lie around this index, so that there is room both ways.
  static const _base = 100000;

  late final PageController _controller;

  /// The page in view, the first day of the page [_base], and the days per page.
  late int _page;
  late DateTime _anchor;
  late int _count;

  /// While moving by itself it passes spans nobody went to.
  int _sliding = 0;

  // Most days have nothing to show before the morning.
  double _hourOffset = 7 * _hourHeight;
  final _hours = ScrollController(initialScrollOffset: 7 * _hourHeight);

  @override
  void initState() {
    super.initState();
    _page = _base;
    _anchor = widget.days.first;
    _count = widget.days.length;
    _controller = PageController(initialPage: _page);
  }

  @override
  void dispose() {
    _controller.dispose();
    _hours.dispose();
    super.dispose();
  }

  static DateTime _shift(DateTime day, int days) => DateTime(day.year, day.month, day.day + days);

  // In UTC, because a day with a time change is not 24 hours long.
  static int _daysBetween(DateTime from, DateTime to) =>
      DateTime.utc(to.year, to.month, to.day).difference(DateTime.utc(from.year, from.month, from.day)).inDays;

  List<DateTime> _daysOf(int page) {
    final first = _shift(_anchor, (page - _base) * _count);
    return [for (var i = 0; i < _count; i++) _shift(first, i)];
  }

  int get _currentPage => _controller.hasClients ? (_controller.page ?? _page).round() : _page;

  @override
  void didUpdateWidget(TimeGridView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final first = widget.days.first;
    final count = widget.days.length;
    final diff = _daysBetween(_daysOf(_page).first, first);
    if (count == _count && diff == 0) return;
    final steps = diff ~/ _count;
    if (count == _count && diff % _count == 0 && steps.abs() <= _maxSlidePages) {
      final target = _page + steps;
      _page = target;
      WidgetsBinding.instance.addPostFrameCallback((_) => _slideTo(target));
      return;
    }
    // Another span, or a day off the steps: the page in view shows it at once.
    final page = _currentPage;
    _count = count;
    _anchor = _shift(first, -(page - _base) * count);
    _page = page;
  }

  Future<void> _slideTo(int target) async {
    if (!mounted || !_controller.hasClients) return;
    _sliding++;
    await _controller.animateToPage(target, duration: _slide, curve: Curves.easeOut);
    _sliding--;
  }

  void _onPageChanged(int page) {
    if (_sliding > 0) return;
    _page = page;
    widget.onPage?.call(_daysOf(page).first);
  }

  void _onHourScroll(double offset) {
    _hourOffset = offset;
    if (_hours.hasClients && _hours.offset != offset) _hours.jumpTo(offset);
  }

  List<CalendarEntry> _allDayOn(DateTime day) =>
      widget.entries.where((entry) => entry.spansDays && entry.occursOn(day)).toList();

  /// Lines of all-day entries, the same on the pages next to each other, so
  /// that the hours line up with each of them while swiping.
  int get _allDayLines {
    var lines = 0;
    for (var page = _page - 1; page <= _page + 1; page++) {
      for (final day in _daysOf(page)) {
        final count = _allDayOn(day).length;
        if (count > lines) lines = count;
      }
    }
    return lines > _maxAllDayShown ? _maxAllDayShown : lines;
  }

  Widget _dayHeader(BuildContext context, DateTime day) {
    final scheme = Theme.of(context).colorScheme;
    final isToday = DateUtils.isSameDay(day, DateTime.now());
    return Column(
      children: [
        Text(weekdayLabels[day.weekday - 1], style: Theme.of(context).textTheme.labelSmall),
        CircleAvatar(
          radius: 13,
          backgroundColor: isToday ? scheme.primary : Colors.transparent,
          foregroundColor: isToday ? scheme.onPrimary : scheme.onSurface,
          child: Text('${day.day}', style: const TextStyle(fontSize: 13)),
        ),
      ],
    );
  }

  Widget _allDayCell(DateTime day) {
    final entries = _allDayOn(day);
    final shown = entries.length > _maxAllDayShown ? _maxAllDayShown - 1 : entries.length;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final entry in entries.take(shown))
            EntryChip(entry: entry, onTap: () => widget.onOpenEntry(entry)),
          if (shown < entries.length)
            SizedBox(
              height: _chipHeight,
              child: Text('+${entries.length - shown}', textAlign: TextAlign.center, style: const TextStyle(fontSize: 11)),
            ),
        ],
      ),
    );
  }

  Widget _dayColumn(BuildContext context, DateTime day) {
    final scheme = Theme.of(context).colorScheme;
    final placed = layoutDay(widget.entries, day);
    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          children: [
            for (var hour = 0; hour < 24; hour++)
              Positioned(
                top: hour * _hourHeight,
                left: 0,
                right: 0,
                height: _hourHeight,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(color: scheme.outlineVariant, width: 0.5),
                      left: BorderSide(color: scheme.outlineVariant, width: 0.5),
                    ),
                  ),
                ),
              ),
            for (final item in placed)
              Positioned(
                top: item.startMinute / 60 * _hourHeight,
                height: (_visibleEnd(item) - item.startMinute) / 60 * _hourHeight - 1,
                left: constraints.maxWidth / item.lanes * item.lane + 1,
                width: constraints.maxWidth / item.lanes - 2,
                child: _timedEntry(item),
              ),
          ],
        );
      },
    );
  }

  Widget _timedEntry(PlacedEntry item) {
    final background = parseHexColor(item.entry.color);
    return GestureDetector(
      onTap: () => widget.onOpenEntry(item.entry),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        clipBehavior: Clip.hardEdge,
        decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(4)),
        child: Text(
          item.entry.title,
          overflow: TextOverflow.clip,
          style: TextStyle(fontSize: 11, color: readableOn(background)),
        ),
      ),
    );
  }

  /// The days of one page: their headers, all-day entries and hours.
  Widget _pageOf(BuildContext context, int page, int lines, ScrollBehavior scrolling) {
    final days = _daysOf(page);
    return Column(
      children: [
        SizedBox(
          height: _dayHeaderHeight,
          child: Row(children: [for (final day in days) Expanded(child: _dayHeader(context, day))]),
        ),
        if (lines > 0)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: SizedBox(
              height: lines * _chipHeight,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [for (final day in days) Expanded(child: _allDayCell(day))],
              ),
            ),
          ),
        const Divider(height: 8),
        Expanded(
          // Up and down it scrolls as before; only the pages also follow the mouse.
          child: ScrollConfiguration(
            behavior: scrolling,
            child: _HourScroll(
              initialOffset: _hourOffset,
              onScroll: _onHourScroll,
              child: SizedBox(
                height: 24 * _hourHeight,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [for (final day in days) Expanded(child: _dayColumn(context, day))],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final lines = _allDayLines;
    final scrolling = ScrollConfiguration.of(context);
    final headerHeight = _dayHeaderHeight + (lines > 0 ? 4 + lines * _chipHeight : 0) + 8;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The hours stay while the days move; they follow the scrolling of the page in view.
        SizedBox(
          width: _gutter,
          child: Column(
            children: [
              SizedBox(height: headerHeight),
              Expanded(
                child: SingleChildScrollView(
                  controller: _hours,
                  physics: const NeverScrollableScrollPhysics(),
                  child: SizedBox(
                    height: 24 * _hourHeight,
                    child: Stack(
                      children: [
                        for (var hour = 1; hour < 24; hour++)
                          Positioned(
                            top: hour * _hourHeight - 8,
                            right: 6,
                            child: Text(
                              '${hour.toString().padLeft(2, '0')}:00',
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ScrollConfiguration(
            // On the web and the desktop only touch drags by default; the mouse should too.
            behavior: scrolling.copyWith(dragDevices: PointerDeviceKind.values.toSet()),
            child: PageView.builder(
              key: const Key('day-pager'),
              controller: _controller,
              onPageChanged: _onPageChanged,
              itemBuilder: (context, page) => _pageOf(context, page, lines, scrolling),
            ),
          ),
        ),
      ],
    );
  }
}

/// The hours of one page, scrolled up and down. A page that comes into view
/// starts where the others were.
class _HourScroll extends StatefulWidget {
  const _HourScroll({required this.initialOffset, required this.onScroll, required this.child});

  final double initialOffset;
  final ValueChanged<double> onScroll;
  final Widget child;

  @override
  State<_HourScroll> createState() => _HourScrollState();
}

class _HourScrollState extends State<_HourScroll> {
  late final ScrollController _scroll;

  @override
  void initState() {
    super.initState();
    _scroll = ScrollController(initialScrollOffset: widget.initialOffset)
      ..addListener(() => widget.onScroll(_scroll.offset));
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(controller: _scroll, child: widget.child);
}
