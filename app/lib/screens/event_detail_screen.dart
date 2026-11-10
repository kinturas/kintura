import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../common.dart';
import '../session.dart';
import 'calendar_views.dart';
import 'event_edit_screen.dart';

const _maxCopyDays = 10;
const _calendarGridWeeks = 6;

String _whenText(CalendarEntry entry) {
  final firstDay = dateFormat.format(entry.start);
  final lastDay = dateFormat.format(entry.end);
  if (entry.allDay) return firstDay == lastDay ? '$firstDay, ganztägig' : '$firstDay – $lastDay, ganztägig';
  final from = timeFormat.format(entry.start);
  final to = timeFormat.format(entry.end);
  return firstDay == lastDay ? '$firstDay, $from – $to' : '$firstDay, $from – $lastDay, $to';
}

/// What only the standard calendar of this family has.
class _Details {
  _Details(this.event, this.members);

  final Map<String, dynamic> event;
  final List<Map<String, dynamic>> members;
}

/// Shows any entry of a calendar on a page of its own. Entries of the standard calendar
/// also offer comments and copies, and changes to those who may make them; the others
/// show what their calendar knows.
class EventDetailScreen extends StatefulWidget {
  const EventDetailScreen({
    super.key,
    required this.entry,
    required this.firstWeekday,
    required this.fetch,
    required this.onChanged,
  });

  /// Replaced in tests, where no share sheet can open.
  static Future<void> Function(String name, String content) shareFile = _shareFile;

  final CalendarEntry entry;
  final int firstWeekday;

  /// Returns null if loading failed, like the calendar itself.
  final Future<List<CalendarEntry>?> Function(DateTime from, DateTime to) fetch;

  /// Tells the calendar below that it is out of date.
  final VoidCallback onChanged;

  static Future<void> _shareFile(String name, String content) async {
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile.fromData(utf8.encode(content), mimeType: 'text/calendar', name: name)],
        fileNameOverrides: [name],
      ),
    );
  }

  @override
  State<EventDetailScreen> createState() => _EventDetailScreenState();
}

class _EventDetailScreenState extends State<EventDetailScreen> {
  final _details = GlobalKey<AsyncViewState<_Details>>();
  final _comment = TextEditingController();
  late CalendarEntry _entry = widget.entry;
  bool _sending = false;

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  String get _path => '${SessionScope.of(context).familyPath}/events/${_entry.id}';

  void _say(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  /// Back in the calendar if the entry is no longer on its day, moved or deleted.
  Future<void> _edit() async {
    final navigator = Navigator.of(context);
    final changed = await navigator.push<bool>(
      MaterialPageRoute(builder: (_) => EventEditScreen(eventId: _entry.id, day: _entry.start, color: _entry.color)),
    );
    if (changed != true || !mounted) return;
    widget.onChanged();
    final day = DateTime(_entry.start.year, _entry.start.month, _entry.start.day);
    final entries = await widget.fetch(day, DateTime(day.year, day.month, day.day + 1));
    if (!mounted) return;
    final onDay = entries?.where((entry) => entry.id == _entry.id).toList() ?? const <CalendarEntry>[];
    if (onDay.isEmpty) {
      navigator.pop();
      return;
    }
    setState(() => _entry = onDay.firstWhere((entry) => entry.start == _entry.start, orElse: () => onDay.first));
    await _details.currentState?.reload();
  }

  /// What a copy into the standard calendar starts with, for an entry of another
  /// calendar. Nobody there is known here, so it is for everyone, or stays private
  /// with the user if the original was hidden from others.
  Map<String, dynamic> _copyTemplate() {
    final raw = _entry.raw;
    final private = raw['visibility'] == 'participants';
    return {
      'title': _entry.title,
      'description': _entry.description,
      'location': _entry.location,
      'location_lat': raw['location_lat'],
      'location_lon': raw['location_lon'],
      'all_day': _entry.allDay,
      'start_local': raw['start_local'],
      'end_local': raw['end_local'],
      'timezone': raw['timezone'],
      'visibility': private ? 'participants' : 'all',
      'participants_all': !private,
      'participant_ids': [if (private) SessionScope.of(context).userId],
      'reminders': <int>[],
    };
  }

  /// Creates nothing until the form is saved.
  Future<void> _duplicate() async {
    final template = _entry.inStandardCalendar ? null : _copyTemplate();
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => EventEditScreen(
          eventId: _entry.inStandardCalendar ? _entry.id : null,
          template: template,
          day: _entry.start,
          duplicate: true,
          color: _entry.color,
        ),
      ),
    );
    if (changed != true || !mounted) return;
    widget.onChanged();
    _say('Termin dupliziert');
  }

  Future<void> _copy(Map<String, Object> body, String done) async {
    final session = SessionScope.of(context);
    final ok = await guarded(context, () => session.api.post('$_path/copy', body));
    if (!ok || !mounted) return;
    widget.onChanged();
    _say(done);
  }

  Future<void> _copyToDays() async {
    final days = await showDialog<List<DateTime>>(
      context: context,
      builder: (_) => _CopyDaysDialog(
        firstWeekday: widget.firstWeekday,
        start: _entry.start,
        isSeries: _entry.repeats,
      ),
    );
    if (days == null || days.isEmpty || !mounted) return;
    await _copy(
      {'days': days.map(dateKey).toList()},
      days.length == 1 ? 'Termin kopiert' : '${days.length} Termine kopiert',
    );
  }

  Future<void> _copyToFamily() async {
    final session = SessionScope.of(context);
    final family = await showDialog<Family>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('In welchen Kreis kopieren?'),
        children: [
          for (final family in session.families)
            if (family.id != session.current?.id)
              SimpleDialogOption(
                key: Key('copy-family-${family.id}'),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                onPressed: () => Navigator.pop(context, family),
                child: Text(family.name),
              ),
        ],
      ),
    );
    if (family == null || !mounted) return;
    await _copy({'family_id': family.id}, 'In „${family.name}“ kopiert');
  }

  Future<void> _share() async {
    final session = SessionScope.of(context);
    await guarded(context, () async {
      final raw = _entry.raw;
      final file = _entry.inStandardCalendar
          ? await session.api.get('$_path/ics')
          : await session.api.post('${session.familyPath}/calendar-entries/ics', {
              'title': _entry.title,
              'description': _entry.description,
              'location': _entry.location,
              'all_day': _entry.allDay,
              'start_at': raw['start_at'],
              'end_at': raw['end_at'],
              'start_local': raw['start_local'],
              'end_local': raw['end_local'],
            });
      await EventDetailScreen.shareFile(file['filename'] as String, file['content'] as String);
    });
  }

  Future<void> _delete() async {
    final session = SessionScope.of(context);
    final navigator = Navigator.of(context);
    final question = _entry.repeats ? 'Alle Termine dieser Serie löschen?' : 'Termin löschen?';
    if (!await confirm(context, question) || !mounted) return;
    final ok = await guarded(context, () => session.api.delete(_path));
    if (!ok) return;
    widget.onChanged();
    navigator.pop();
  }

  Future<void> _sendComment() async {
    final body = _comment.text.trim();
    if (body.isEmpty || _sending) return;
    final session = SessionScope.of(context);
    setState(() => _sending = true);
    final ok = await guarded(context, () => session.api.post('$_path/comments', {'body': body}));
    if (!mounted) return;
    setState(() => _sending = false);
    if (!ok) return;
    _comment.clear();
    await _details.currentState?.reload();
  }

  Future<void> _download(Map<String, dynamic> attachment) => guarded(context, () async {
    final session = SessionScope.of(context);
    final result = await session.api.post('$_path/attachments/${attachment['id']}/link');
    await launchUrl(Uri.parse(result['url'] as String), mode: LaunchMode.externalApplication);
  });

  List<Widget> _actions(BuildContext context) {
    final session = SessionScope.of(context);
    // Copies belong to whoever makes them, so they do not depend on changing the original.
    final standard = _entry.inStandardCalendar;
    final editable = _entry.editable;
    return [
      if (editable) IconButton(tooltip: 'Bearbeiten', icon: const Icon(Icons.edit_outlined), onPressed: _edit),
      PopupMenuButton<VoidCallback>(
        tooltip: 'Mehr',
        onSelected: (action) => action(),
        itemBuilder: (context) => [
          PopupMenuItem(value: _duplicate, child: const Text('Duplikat')),
          if (standard) PopupMenuItem(value: _copyToDays, child: const Text('In mehrere Termine kopieren')),
          if (standard && session.families.length > 1)
            PopupMenuItem(value: _copyToFamily, child: const Text('In anderen Kreis kopieren')),
          PopupMenuItem(value: _share, child: const Text('Teilen')),
          if (editable) PopupMenuItem(value: _delete, child: const Text('Löschen')),
        ],
      ),
    ];
  }

  Widget _title(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Text(
        _entry.title,
        style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _row(BuildContext context, IconData icon, List<String> lines) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (index, line) in lines.indexed)
                  Text(
                    line,
                    style: index == 0
                        ? null
                        : Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(BuildContext context, List<Widget> rows) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _title(context),
          for (final (index, row) in rows.indexed) ...[
            if (index > 0) const Divider(height: 1),
            row,
          ],
        ],
      ),
    );
  }

  List<String> get _calendarLines => [
    _entry.sourceName,
    if ((_entry.raw['source'] as String? ?? '').startsWith('family')) 'Standardkalender',
  ];

  /// Everything an entry says about itself, in every calendar.
  List<Widget> _placeAndNote(BuildContext context) => [
    if (_entry.location.isNotEmpty) _row(context, Icons.place_outlined, [_entry.location]),
    if (_entry.description.isNotEmpty) _row(context, Icons.notes, [_entry.description]),
  ];

  Widget _reduced(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _card(context, [
          _row(context, Icons.schedule, [_whenText(_entry)]),
          _row(context, Icons.calendar_today_outlined, _calendarLines),
          ..._placeAndNote(context),
        ]),
      ],
    );
  }

  List<String> _participantLines(_Details data) {
    if (data.event['participants_all'] == true) return const ['Alle'];
    final ids = (data.event['participant_ids'] as List?) ?? const [];
    return [
      [
        for (final member in data.members)
          if (ids.contains(member['id'])) member['name'] as String,
      ].join(', '),
    ];
  }

  String? _lastChange(Map<String, dynamic> event) {
    final at = event['updated_at'] as String?;
    if (at == null) return null;
    final time = DateTime.parse(at).toLocal();
    final name = event['updated_by_name'] as String? ?? '';
    final by = name.isEmpty ? '' : ' von $name';
    return 'Zuletzt geändert am ${dateFormat.format(time)} um ${timeFormat.format(time)}$by';
  }

  Widget _comments(BuildContext context, Map<String, dynamic> event) {
    final comments = ((event['comments'] as List?) ?? const []).cast<Map<String, dynamic>>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final comment in comments)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  [
                    if ((comment['author_name'] as String).isNotEmpty) comment['author_name'] as String,
                    DateFormat('dd.MM.yyyy, HH:mm', 'de').format(DateTime.parse(comment['created_at'] as String).toLocal()),
                  ].join(' · '),
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                const SizedBox(height: 2),
                Text(comment['body'] as String),
              ],
            ),
          ),
      ],
    );
  }

  /// Stays at the bottom of the page. On a keyboard, Enter starts a new line and
  /// Shift + Enter sends.
  Widget _commentField() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.enter, shift: true): _sendComment,
            const SingleActivator(LogicalKeyboardKey.numpadEnter, shift: true): _sendComment,
          },
          child: TextField(
            key: const Key('event-comment'),
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
                tooltip: 'Kommentar senden',
                icon: const Icon(Icons.send),
                onPressed: _sending ? null : _sendComment,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _full(BuildContext context, _Details data) {
    final event = data.event;
    final reminders = ((event['reminders'] as List?) ?? const []).cast<int>();
    final attachments = ((event['attachments'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final lastChange = _lastChange(event);
    final creator = event['creator_name'] as String? ?? '';
    final rule = event['recurrence'] as Map<String, dynamic>?;
    final list = ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _card(context, [
          _row(context, Icons.schedule, [_whenText(_entry), if (rule != null) recurrenceLabel(rule)]),
          _row(context, Icons.people_outline, _participantLines(data)),
          _row(context, Icons.calendar_today_outlined, _calendarLines),
          _row(context, Icons.notifications_none, [
            if (reminders.isEmpty) 'Keine Erinnerung',
            for (final minutes in reminders) reminderLabel(minutes),
          ]),
          // Whoever made it may have been deleted since.
          if (creator.isNotEmpty) _row(context, Icons.person_outline, ['Ersteller: $creator']),
          ..._placeAndNote(context),
          for (final attachment in attachments)
            ListTile(
              leading: const Icon(Icons.attach_file),
              title: Text(attachment['name'] as String),
              subtitle: Text(formatFileSize(attachment['size'] as num)),
              onTap: () => _download(attachment),
            ),
          if (lastChange != null) _row(context, Icons.history, [lastChange]),
        ]),
        const SizedBox(height: 16),
        _comments(context, event),
      ],
    );
    return Column(
      children: [
        Expanded(child: list),
        const Divider(height: 1),
        _commentField(),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    final color = parseHexColor(_entry.color);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: color,
        foregroundColor: readableOn(color),
        // Stays the color of the entry while the page scrolls below it.
        scrolledUnderElevation: 0,
        title: const Text('Termin'),
        actions: _actions(context),
      ),
      body: !_entry.inStandardCalendar
          ? _reduced(context)
          : AsyncView<_Details>(
              key: _details,
              load: () async {
                final results = await Future.wait([
                  session.api.get(_path),
                  session.api.get('${session.familyPath}/members'),
                ]);
                return _Details(
                  results[0] as Map<String, dynamic>,
                  (results[1]['members'] as List).cast<Map<String, dynamic>>(),
                );
              },
              builder: _full,
            ),
    );
  }
}

/// Chooses up to [_maxCopyDays] days to copy an event to.
class _CopyDaysDialog extends StatefulWidget {
  const _CopyDaysDialog({required this.firstWeekday, required this.start, required this.isSeries});

  final int firstWeekday;
  final DateTime start;
  final bool isSeries;

  @override
  State<_CopyDaysDialog> createState() => _CopyDaysDialogState();
}

class _CopyDaysDialogState extends State<_CopyDaysDialog> {
  late DateTime _month = DateTime(widget.start.year, widget.start.month);
  final _days = <DateTime>{};

  void _toggle(DateTime day) {
    setState(() {
      if (!_days.remove(day)) _days.add(day);
    });
  }

  Widget _day(BuildContext context, DateTime day) {
    final colors = Theme.of(context).colorScheme;
    final selected = _days.contains(day);
    final full = _days.length >= _maxCopyDays;
    return Expanded(
      child: InkWell(
        key: Key('copy-day-${dateKey(day)}'),
        customBorder: const CircleBorder(),
        onTap: selected || !full ? () => _toggle(day) : null,
        child: Container(
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(shape: BoxShape.circle, color: selected ? colors.primary : null),
          child: Text(
            '${day.day}',
            style: TextStyle(
              color: selected
                  ? colors.onPrimary
                  : day.month == _month.month && !full
                  ? colors.onSurface
                  : colors.outline,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final first = startOfWeek(_month, widget.firstWeekday);
    return AlertDialog(
      title: const Text('In mehrere Termine kopieren'),
      contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      content: SizedBox(
        width: 320,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: 'Voriger Monat',
                    icon: const Icon(Icons.chevron_left),
                    onPressed: () => setState(() => _month = DateTime(_month.year, _month.month - 1)),
                  ),
                  Expanded(
                    child: Text(
                      DateFormat('MMMM yyyy', 'de').format(_month),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Nächster Monat',
                    icon: const Icon(Icons.chevron_right),
                    onPressed: () => setState(() => _month = DateTime(_month.year, _month.month + 1)),
                  ),
                ],
              ),
              WeekdayRow(firstWeekday: widget.firstWeekday, height: 28),
              for (var week = 0; week < _calendarGridWeeks; week++)
                Row(
                  children: [
                    for (var i = 0; i < 7; i++)
                      _day(context, DateTime(first.year, first.month, first.day + week * 7 + i)),
                  ],
                ),
              const SizedBox(height: 8),
              Text('${_days.length} von $_maxCopyDays Tagen gewählt', style: Theme.of(context).textTheme.bodySmall),
              if (widget.isSeries)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Eine Serie wird als einzelne Termine kopiert.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Abbrechen')),
        FilledButton(
          onPressed: _days.isEmpty ? null : () => Navigator.pop(context, _days.toList()..sort()),
          child: const Text('Kopieren'),
        ),
      ],
    );
  }
}
