import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../common.dart';
import '../session.dart';

const _weekdayNames = ['Montag', 'Dienstag', 'Mittwoch', 'Donnerstag', 'Freitag', 'Samstag', 'Sonntag'];
const _weekdayShort = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];
const _monthWeeks = {1: 'ersten', 2: 'zweiten', 3: 'dritten', 4: 'vierten', -1: 'letzten'};
const reminderChoices = [5, 15, 30, 60, 120, 1440, 2880];
const _minutesPerHour = 60;
const _minutesPerDay = 1440;

final _localFormat = DateFormat("yyyy-MM-dd'T'HH:mm");

/// "30 Minuten vorher", in the largest unit that fits without a remainder.
String reminderLabel(int minutes) {
  String count(int n, String one, String many) => '$n ${n == 1 ? one : many} vorher';
  if (minutes % _minutesPerDay == 0) return count(minutes ~/ _minutesPerDay, 'Tag', 'Tage');
  if (minutes % _minutesPerHour == 0) return count(minutes ~/ _minutesPerHour, 'Stunde', 'Stunden');
  return count(minutes, 'Minute', 'Minuten');
}

/// Describes a repeat rule as served by the backend; null means none.
String recurrenceLabel(Map<String, dynamic>? rule) {
  if (rule == null) return 'Niemals';
  final interval = rule['interval'] as int;
  final weekdays = (rule['weekdays'] as List?)?.cast<int>() ?? const <int>[];
  String every(String one, String many) => interval == 1 ? one : 'Alle $interval $many';
  switch (rule['freq']) {
    case 'day':
      return every('Täglich', 'Tage');
    case 'week':
      if (interval == 1 && weekdays.length == 5 && weekdays.last == 5) return 'Jeden Wochentag';
      final base = every('Jede Woche', 'Wochen');
      return weekdays.isEmpty ? base : '$base am ${[for (final day in weekdays) _weekdayShort[day - 1]].join(', ')}';
    case 'month':
      final base = every('Jeden Monat', 'Monate');
      final week = rule['month_week'] as int?;
      if (week != null) return '$base am ${_monthWeeks[week]} ${_weekdayNames[(rule['month_weekday'] as int) - 1]}';
      final day = rule['month_day'] as int?;
      return day == null ? base : '$base am $day.';
    case 'year':
      return every('Jedes Jahr', 'Jahre');
  }
  return 'Individuell';
}

/// „Ersteller: Name“. Whoever may change it can tap it, which only managers can.
class _CreatorTile extends StatelessWidget {
  const _CreatorTile({super.key, required this.name, this.onTap});

  /// Empty if the creator is no longer a member.
  final String name;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text.rich(
        TextSpan(
          children: [
            const TextSpan(text: 'Ersteller: '),
            TextSpan(
              text: name.isEmpty ? 'Unbekannt' : name,
              style: onTap == null ? null : TextStyle(color: colors.primary, decoration: TextDecoration.underline),
            ),
          ],
        ),
      ),
      trailing: onTap == null ? null : const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

/// Chooses a new creator. Pops the member, or nothing if none was chosen.
class _CreatorScreen extends StatelessWidget {
  const _CreatorScreen({required this.current});

  final String? current;

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Ersteller ändern')),
      body: AsyncView<List<Map<String, dynamic>>>(
        load: () async {
          final data = await session.api.get('${session.familyPath}/members');
          return (data['members'] as List).cast<Map<String, dynamic>>();
        },
        builder: (context, members) => ListView(
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Bei Terminen nur für Teilnehmer und Ersteller gilt: Wer bisher Ersteller war und nicht Teilnehmer ist, sieht den Termin danach nicht mehr.'),
            ),
            for (final member in members)
              ListTile(
                key: Key('creator-${member['id']}'),
                leading: UserAvatar(member['name'] as String, color: member['color'] as String, photo: member['avatar'] as String? ?? ''),
                title: Text(member['name'] as String),
                trailing: member['id'] == current ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, member),
              ),
          ],
        ),
      ),
    );
  }
}

class PickedFile {
  PickedFile(this.name, this.bytes);

  final String name;
  final Uint8List bytes;
}

/// Everything the form needs before it can show anything.
class _FormData {
  _FormData(
    this.event,
    this.members,
    this.categories,
    this.defaultZone,
    this.zones,
    this.defaultReminder,
    this.calendarColor,
  );

  final Map<String, dynamic>? event;
  final List<Map<String, dynamic>> members;
  final List<Map<String, dynamic>> categories;
  final String defaultZone;
  final List<Map<String, dynamic>> zones;

  /// In minutes; 0 means none.
  final int defaultReminder;

  /// What an event looks like that nothing else gives a color.
  final String? calendarColor;
}

/// Creates or edits an event on a page of its own. Pops true if something changed.
class EventEditScreen extends StatefulWidget {
  const EventEditScreen({
    super.key,
    this.eventId,
    required this.day,
    this.duplicate = false,
    this.template,
    this.color,
  });

  /// Replaced in tests, where no file dialog can open.
  static Future<List<PickedFile>> Function() pickFiles = _pickFiles;

  final String? eventId;
  final DateTime day;

  /// Fills the form with the event [eventId] or [template], but only saving creates a
  /// new one. Starts by asking for the day, which [day] suggests.
  final bool duplicate;

  /// What to fill the form with if the original is no event of this family.
  final Map<String, dynamic>? template;

  /// The color of the entry this form was opened from, for the header while it loads.
  final String? color;

  static Future<List<PickedFile>> _pickFiles() async {
    final files = await FilePicker.pickFiles();
    return [for (final file in files) PickedFile(file.name, await file.readAsBytes())];
  }

  @override
  State<EventEditScreen> createState() => _EventEditScreenState();
}

class _EventEditScreenState extends State<EventEditScreen> {
  final _form = GlobalKey<_EventFormState>();

  /// Follows the form as soon as it has loaded.
  late String? _color = widget.color;

  /// Going back only asks if there is something to lose.
  Future<void> _leave() async {
    final navigator = Navigator.of(context);
    final changed = _form.currentState?.hasChanges ?? false;
    if (changed && !await confirm(context, 'Änderungen verwerfen?', action: 'Verwerfen', cancel: 'Weiter bearbeiten')) return;
    if (mounted) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: _page(context),
    );
  }

  Widget _page(BuildContext context) {
    final session = SessionScope.of(context);
    final isNew = widget.eventId == null || widget.duplicate;
    final color = _color == null ? null : parseHexColor(_color!);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: color,
        foregroundColor: color == null ? null : readableOn(color),
        // Stays the color of the entry while the form scrolls below it.
        scrolledUnderElevation: color == null ? null : 0,
        title: Text(isNew ? 'Neuer Termin' : 'Termin'),
        actions: [
          IconButton(
            tooltip: 'Speichern',
            icon: const Icon(Icons.check),
            onPressed: () => _form.currentState?.save(),
          ),
        ],
      ),
      body: AsyncView<_FormData>(
        load: () async {
          final path = session.familyPath;
          final results = await Future.wait([
            session.api.get('$path/members'),
            session.api.get('$path/categories'),
            session.api.get('/api/timezones'),
            session.api.get('$path/calendar-prefs'),
            if (widget.eventId != null) session.api.get('$path/events/${widget.eventId}'),
          ]);
          return _FormData(
            widget.eventId == null ? widget.template : results[4] as Map<String, dynamic>,
            (results[0]['members'] as List).cast<Map<String, dynamic>>(),
            (results[1]['categories'] as List).cast<Map<String, dynamic>>(),
            results[2]['default'] as String,
            (results[2]['zones'] as List).cast<Map<String, dynamic>>(),
            results[3]['default_reminder'] as int,
            results[3]['calendar_color'] as String?,
          );
        },
        builder: (context, data) => _EventForm(
          key: _form,
          data: data,
          day: widget.day,
          duplicate: widget.duplicate,
          onColor: (color) {
            if (color != _color) setState(() => _color = color);
          },
        ),
      ),
    );
  }
}

class _EventForm extends StatefulWidget {
  const _EventForm({
    super.key,
    required this.data,
    required this.day,
    required this.duplicate,
    required this.onColor,
  });

  final _FormData data;
  final DateTime day;
  final bool duplicate;

  /// Tells the page the color the event would get as it stands.
  final ValueChanged<String?> onColor;

  @override
  State<_EventForm> createState() => _EventFormState();
}

class _EventFormState extends State<_EventForm> {
  Map<String, dynamic>? get _event => widget.data.event;

  late final _title = TextEditingController(text: _event?['title'] as String?);
  late final _description = TextEditingController(text: _event?['description'] as String?);
  late bool _allDay = _event?['all_day'] as bool? ?? false;

  // Both follow the wall clock of the chosen time zone, not that of the device.
  late DateTime _start = _firstStart();
  late DateTime _end = _event == null
      ? _start.add(const Duration(hours: 1))
      : _start.add(DateTime.parse(_event!['end_local'] as String).difference(DateTime.parse(_event!['start_local'] as String)));

  DateTime _firstStart() {
    final day = widget.day;
    if (_event == null) return DateTime(day.year, day.month, day.day, 12);
    final saved = DateTime.parse(_event!['start_local'] as String);
    // [day] is the occurrence that was opened, which for a series is not the saved one.
    return widget.duplicate ? DateTime(day.year, day.month, day.day, saved.hour, saved.minute) : saved;
  }

  late String _timezone = _event?['timezone'] as String? ?? widget.data.defaultZone;
  late bool _everyone = _event?['participants_all'] as bool? ?? true;
  late final Set<String> _participants = {
    ...(_event?['participant_ids'] as List?)?.cast<String>() ?? const <String>[],
  };
  late String _visibility = _event?['visibility'] as String? ?? 'all';
  // A new event belongs to whoever saves it, unless they hand it on right away.
  late String? _creatorId = _isNew ? SessionScope.of(context).userId : _event!['created_by'] as String?;
  late String _creatorName = _isNew ? _nameOf(_creatorId) : _event!['creator_name'] as String? ?? '';
  bool _creatorChanged = false;

  String _nameOf(String? id) {
    for (final member in widget.data.members) {
      if (member['id'] == id) return member['name'] as String;
    }
    return '';
  }
  late String? _categoryId = _event?['category_id'] as String?;
  late Map<String, dynamic>? _recurrence = _event?['recurrence'] as Map<String, dynamic>?;
  late final List<int> _reminders = _event == null
      ? [if (widget.data.defaultReminder > 0) widget.data.defaultReminder]
      : (_event!['reminders'] as List).cast<int>().toList();
  late String _location = _event?['location'] as String? ?? '';
  late double? _locationLat = (_event?['location_lat'] as num?)?.toDouble();
  late double? _locationLon = (_event?['location_lon'] as num?)?.toDouble();

  // Attachments stay with the event they were added to.
  late final List<Map<String, dynamic>> _attachments = [
    if (!_isNew) ...(_event?['attachments'] as List?)?.cast<Map<String, dynamic>>() ?? const <Map<String, dynamic>>[],
  ];
  final _removedAttachments = <String>[];
  final _pendingFiles = <PickedFile>[];

  /// Set once saved, so that a failed upload can be retried without a second event.
  late String? _savedId = _isNew ? null : _event!['id'] as String?;
  bool _saving = false;

  /// Nothing of this event is saved yet, even if the form starts from another one.
  bool get _isNew => _event == null || widget.duplicate;

  @override
  void initState() {
    super.initState();
    _initial = _snapshot();
    if (widget.duplicate) WidgetsBinding.instance.addPostFrameCallback((_) => _pickDuplicateDay());
  }

  Future<void> _pickDuplicateDay() async {
    if (!mounted) return;
    final day = await showDatePicker(
      context: context,
      initialDate: _start,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      helpText: 'Tag auswählen',
    );
    if (day != null && mounted) _setStart(DateTime(day.year, day.month, day.day, _start.hour, _start.minute));
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    super.dispose();
  }

  void _setStart(DateTime value) {
    setState(() {
      final length = _end.difference(_start);
      _start = value;
      _end = value.add(length);
    });
  }

  Map<String, Object?> _body() {
    // All-day events span the whole day in their time zone.
    final start = _allDay ? DateTime(_start.year, _start.month, _start.day) : _start;
    final end = _allDay ? DateTime(_end.year, _end.month, _end.day, 23, 59) : _end;
    return {
      'title': _title.text.trim(),
      'description': _description.text.trim(),
      'start_local': _localFormat.format(start),
      'end_local': _localFormat.format(end),
      'all_day': _allDay,
      'timezone': _timezone,
      'participants_all': _everyone,
      'participant_ids': _everyone ? <String>[] : _participants.toList(),
      'visibility': _visibility,
      'category_id': _categoryId ?? '',
      'recurrence': _recurrence,
      'reminders': _reminders,
      'location': _location,
      'location_lat': _locationLat,
      'location_lon': _locationLon,
    };
  }

  /// What the form holds, to compare it with how it started. Choosing something and
  /// taking it back again changes nothing, whatever the order of the lists.
  String _snapshot() => jsonEncode({
    ..._body(),
    'participant_ids': _participants.toList()..sort(),
    'reminders': [..._reminders]..sort(),
  });

  late final String _initial;

  bool get hasChanges =>
      _snapshot() != _initial || _creatorChanged || _removedAttachments.isNotEmpty || _pendingFiles.isNotEmpty;

  Future<void> save() async {
    if (_saving) return;
    final session = SessionScope.of(context);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final path = '${session.familyPath}/events';
    final body = _body();
    setState(() => _saving = true);
    final ok = await guarded(context, () async {
      final id = _savedId;
      if (id == null) {
        final created = await session.api.post(path, body);
        _savedId = created['id'] as String;
      } else {
        await session.api.put('$path/$id', body);
      }
      while (_removedAttachments.isNotEmpty) {
        await session.api.delete('$path/$_savedId/attachments/${_removedAttachments.first}');
        _removedAttachments.removeAt(0);
      }
      while (_pendingFiles.isNotEmpty) {
        final file = _pendingFiles.first;
        await session.api.upload('$path/$_savedId/attachments', file.name, file.bytes);
        _pendingFiles.removeAt(0);
        if (mounted) setState(() {});
      }
      // Last, because handing it over can end the access for everything above.
      if (_creatorChanged) {
        await session.api.put('$path/$_savedId/creator', {'user_id': _creatorId});
        _creatorChanged = false;
      }
    });
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) {
      navigator.pop(true);
    } else if (_savedId != null && _isNew) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            _pendingFiles.isNotEmpty
                ? 'Der Termin ist gespeichert, aber nicht alle Anhänge. Bitte erneut speichern.'
                : 'Der Termin ist gespeichert, aber der Ersteller nicht geändert. Bitte erneut speichern.',
          ),
        ),
      );
    }
  }

  /// Counts with „Speichern“, like everything else on this page.
  Future<void> _pickCreator() async {
    final member = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(builder: (_) => _CreatorScreen(current: _creatorId)),
    );
    if (member == null || member['id'] == _creatorId) return;
    setState(() {
      _creatorId = member['id'] as String;
      _creatorName = member['name'] as String;
      _creatorChanged = true;
    });
  }

  Future<void> _pickZone() async {
    final zone = await showDialog<String>(
      context: context,
      builder: (_) => _ZoneDialog(zones: widget.data.zones, selected: _timezone),
    );
    if (zone != null) setState(() => _timezone = zone);
  }

  Future<void> _pickRecurrence() async {
    final result = await showDialog<_RecurrenceChoice>(
      context: context,
      builder: (_) => const _RecurrenceDialog(),
    );
    if (result == null || !mounted) return;
    if (!result.custom) {
      setState(() => _recurrence = result.rule);
      return;
    }
    final rule = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _CustomRecurrenceDialog(start: _start, initial: _recurrence),
    );
    if (rule != null) setState(() => _recurrence = rule);
  }

  Future<void> _addReminder() async {
    final choice = await showDialog<int>(
      context: context,
      builder: (_) => const _ReminderDialog(),
    );
    if (choice == null || !mounted) return;
    if (choice == _ReminderDialog.none) {
      setState(_reminders.clear);
      return;
    }
    final minutes = choice == _ReminderDialog.custom
        ? await showDialog<int>(context: context, builder: (_) => const _CustomReminderDialog())
        : choice;
    if (minutes == null || _reminders.contains(minutes)) return;
    setState(() {
      _reminders
        ..add(minutes)
        ..sort();
    });
  }

  Future<void> _pickLocation() async {
    final place = await showDialog<_Place>(
      context: context,
      builder: (_) => _PlaceDialog(initial: _location),
    );
    // Taking over the unchanged text keeps a place from the search as it is.
    if (place == null || (place.label == _location && place.lat == null)) return;
    setState(() {
      _location = place.label;
      _locationLat = place.lat;
      _locationLon = place.lon;
    });
  }

  Future<void> _openMaps() async {
    await launchUrl(
      Uri.https('www.google.com', '/maps/search/', {'api': '1', 'query': _location}),
      mode: LaunchMode.externalApplication,
    );
  }

  Future<void> _addFiles() async {
    final messenger = ScaffoldMessenger.of(context);
    final files = await EventEditScreen.pickFiles();
    if (!mounted) return;
    setState(() {
      for (final file in files) {
        if (file.bytes.length > maxUploadBytes) {
          messenger.showSnackBar(SnackBar(content: Text('${file.name} ist größer als 25 MB.')));
        } else {
          _pendingFiles.add(file);
        }
      }
    });
  }

  Future<void> _download(Map<String, dynamic> attachment) => guarded(context, () async {
    final session = SessionScope.of(context);
    final result = await session.api.post(
      '${session.familyPath}/events/$_savedId/attachments/${attachment['id']}/link',
    );
    await launchUrl(Uri.parse(result['url'] as String), mode: LaunchMode.externalApplication);
  });

  Widget _dateTimeRow(String label, DateTime value, ValueChanged<DateTime> onChanged) {
    return Row(
      children: [
        Expanded(
          child: DateField(
            label: label,
            value: value,
            onChanged: (date) {
              if (date != null) {
                onChanged(DateTime(date.year, date.month, date.day, value.hour, value.minute));
              }
            },
          ),
        ),
        if (!_allDay) ...[
          const SizedBox(width: 8),
          TextButton(
            onPressed: () async {
              final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(value));
              if (time != null) {
                onChanged(DateTime(value.year, value.month, value.day, time.hour, time.minute));
              }
            },
            child: Text(timeFormat.format(value)),
          ),
        ],
      ],
    );
  }

  Widget _section(String title, Widget child) {
    return Padding(
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
  }

  Widget _participantTile({
    required Key key,
    required String label,
    required Widget icon,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
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
                  child: Opacity(opacity: selected ? 1 : 0.45, child: icon),
                ),
                const SizedBox(height: 4),
                Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.labelSmall),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _toggleParticipant(String id) {
    setState(() {
      if (_everyone) {
        _everyone = false;
        _participants
          ..clear()
          ..add(id);
      } else if (!_participants.remove(id)) {
        _participants.add(id);
      }
      // Nobody at all makes no sense, so this falls back to the default.
      if (_participants.isEmpty) _everyone = true;
    });
  }

  /// The same order as in the calendar: a category with a color goes first, then the
  /// one person the event is for, then the calendar.
  String? get _eventColor {
    for (final category in widget.data.categories) {
      final color = category['color'] as String? ?? '';
      if (category['id'] == _categoryId && color.isNotEmpty) return color;
    }
    if (!_everyone && _participants.length == 1) {
      for (final member in widget.data.members) {
        final color = member['color'] as String? ?? '';
        if (member['id'] == _participants.first && color.isNotEmpty) return color;
      }
    }
    return widget.data.calendarColor;
  }

  Map<String, dynamic> get _zone => widget.data.zones.firstWhere(
    (zone) => zone['id'] == _timezone,
    orElse: () => {'id': _timezone, 'label': _timezone, 'offset': ''},
  );

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final zone = _zone;
    // The page around it can only change after this build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onColor(_eventColor);
    });
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
                  key: const Key('event-title'),
                  controller: _title,
                  autofocus: _event == null,
                  decoration: const InputDecoration(labelText: 'Titel'),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Ganztägig'),
                  value: _allDay,
                  onChanged: (value) => setState(() => _allDay = value),
                ),
                _dateTimeRow('Beginn', _start, _setStart),
                const SizedBox(height: 16),
                _dateTimeRow('Ende', _end, (value) => setState(() => _end = value)),
                ListTile(
                  key: const Key('event-timezone'),
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.public),
                  title: const Text('Zeitzone'),
                  subtitle: Text('${zone['label']} ${zone['offset']}'.trim()),
                  trailing: const Icon(Icons.arrow_drop_down),
                  onTap: _pickZone,
                ),
                _section(
                  'Teilnehmer',
                  Wrap(
                    children: [
                      _participantTile(
                        key: const Key('participant-all'),
                        label: 'Alle',
                        icon: const CircleAvatar(radius: 18, child: Icon(Icons.groups)),
                        selected: _everyone,
                        onTap: () => setState(() {
                          _everyone = true;
                          _participants.clear();
                        }),
                      ),
                      for (final member in data.members)
                        _participantTile(
                          key: Key('participant-${member['id']}'),
                          label: member['name'] as String,
                          icon: UserAvatar(member['name'] as String, color: member['color'] as String, photo: member['avatar'] as String? ?? ''),
                          selected: !_everyone && _participants.contains(member['id']),
                          onTap: () => _toggleParticipant(member['id'] as String),
                        ),
                    ],
                  ),
                ),
                _section(
                  'Sichtbar für',
                  SegmentedButton<String>(
                    segments: [
                      const ButtonSegment(value: 'all', label: Text('Jeden')),
                      // Only a new event is sure to be one's own.
                      ButtonSegment(
                        value: 'participants',
                        label: Text(_isNew ? 'Dich und Teilnehmer' : 'Teilnehmer und Ersteller'),
                      ),
                    ],
                    selected: {_visibility},
                    onSelectionChanged: (value) => setState(() => _visibility = value.first),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: _CreatorTile(
                    key: const Key('event-creator'),
                    name: _creatorName,
                    onTap: SessionScope.of(context).current?.isManager ?? false ? _pickCreator : null,
                  ),
                ),
                if (data.categories.isNotEmpty)
                  _section(
                    'Kategorie',
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final category in data.categories)
                          ChoiceChip(
                            key: Key('category-${category['id']}'),
                            // A check mark would cover the color.
                            showCheckmark: false,
                            avatar: ColorDot(category['color'] as String),
                            label: Text(category['name'] as String),
                            selected: _categoryId == category['id'],
                            // Tapping the chosen one again leaves the event without a category.
                            onSelected: (selected) =>
                                setState(() => _categoryId = selected ? category['id'] as String : null),
                          ),
                      ],
                    ),
                  ),
                const SizedBox(height: 16),
                ListTile(
                  key: const Key('event-recurrence'),
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.repeat),
                  title: const Text('Wiederholen'),
                  subtitle: Text(recurrenceLabel(_recurrence)),
                  trailing: const Icon(Icons.arrow_drop_down),
                  onTap: _pickRecurrence,
                ),
                _section(
                  'Erinnerung per E-Mail',
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final minutes in _reminders)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          leading: const Icon(Icons.notifications_outlined),
                          title: Text(reminderLabel(minutes)),
                          trailing: IconButton(
                            tooltip: 'Erinnerung entfernen',
                            icon: const Icon(Icons.close),
                            onPressed: () => setState(() => _reminders.remove(minutes)),
                          ),
                        ),
                      if (_reminders.isEmpty) const Text('Keine Erinnerung'),
                      TextButton.icon(
                        onPressed: _addReminder,
                        icon: const Icon(Icons.add),
                        label: const Text('Erinnerung hinzufügen'),
                      ),
                    ],
                  ),
                ),
                _section(
                  'Ort',
                  _location.isEmpty
                      ? TextButton.icon(
                          onPressed: _pickLocation,
                          icon: const Icon(Icons.place_outlined),
                          label: const Text('Ort hinzufügen'),
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.place_outlined),
                              title: Text(_location),
                              onTap: _pickLocation,
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: 'In Google Maps öffnen',
                                    icon: const Icon(Icons.map_outlined),
                                    onPressed: _openMaps,
                                  ),
                                  IconButton(
                                    tooltip: 'Ort entfernen',
                                    icon: const Icon(Icons.close),
                                    onPressed: () => setState(() {
                                      _location = '';
                                      _locationLat = null;
                                      _locationLon = null;
                                    }),
                                  ),
                                ],
                              ),
                            ),
                            if (_locationLat != null && _locationLon != null)
                              _PlaceMap(lat: _locationLat!, lon: _locationLon!, onTap: _openMaps),
                          ],
                        ),
                ),
                _section(
                  'Anhänge',
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final attachment in _attachments)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          leading: const Icon(Icons.attach_file),
                          title: Text(attachment['name'] as String),
                          subtitle: Text(formatFileSize(attachment['size'] as num)),
                          onTap: () => _download(attachment),
                          trailing: IconButton(
                            tooltip: 'Anhang entfernen',
                            icon: const Icon(Icons.close),
                            onPressed: () => setState(() {
                              _attachments.remove(attachment);
                              _removedAttachments.add(attachment['id'] as String);
                            }),
                          ),
                        ),
                      for (final file in _pendingFiles)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          leading: const Icon(Icons.attach_file),
                          title: Text(file.name),
                          subtitle: Text(formatFileSize(file.bytes.length)),
                          trailing: IconButton(
                            tooltip: 'Anhang entfernen',
                            icon: const Icon(Icons.close),
                            onPressed: () => setState(() => _pendingFiles.remove(file)),
                          ),
                        ),
                      TextButton.icon(
                        onPressed: _addFiles,
                        icon: const Icon(Icons.add),
                        label: const Text('Anhang hinzufügen'),
                      ),
                    ],
                  ),
                ),
                _section(
                  'Notiz',
                  TextField(
                    key: const Key('event-description'),
                    controller: _description,
                    minLines: 3,
                    maxLines: 8,
                    decoration: const InputDecoration(
                      hintText: 'Beschreibung',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ZoneDialog extends StatefulWidget {
  const _ZoneDialog({required this.zones, required this.selected});

  final List<Map<String, dynamic>> zones;
  final String selected;

  @override
  State<_ZoneDialog> createState() => _ZoneDialogState();
}

class _ZoneDialogState extends State<_ZoneDialog> {
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final filter = _filter.toLowerCase();
    final zones = widget.zones.where((zone) {
      final text = '${zone['label']} ${zone['id']} ${zone['offset']}'.toLowerCase();
      return text.contains(filter);
    }).toList();
    return AlertDialog(
      title: const Text('Zeitzone'),
      contentPadding: const EdgeInsets.fromLTRB(0, 16, 0, 0),
      content: SizedBox(
        width: 480,
        height: 460,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: TextField(
                decoration: const InputDecoration(labelText: 'Suchen', prefixIcon: Icon(Icons.search)),
                onChanged: (value) => setState(() => _filter = value),
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  for (final zone in zones)
                    ListTile(
                      selected: zone['id'] == widget.selected,
                      title: Text(zone['label'] as String),
                      subtitle: Text('${zone['offset']} · ${zone['id']}'),
                      onTap: () => Navigator.pop(context, zone['id'] as String),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Abbrechen')),
      ],
    );
  }
}

class _RecurrenceChoice {
  const _RecurrenceChoice(this.rule, {this.custom = false});

  final Map<String, dynamic>? rule;
  final bool custom;
}

class _RecurrenceDialog extends StatelessWidget {
  const _RecurrenceDialog();

  @override
  Widget build(BuildContext context) {
    // Weekday and day of the month are left out, so the backend takes them from the start.
    final options = <(String, _RecurrenceChoice)>[
      ('Niemals', const _RecurrenceChoice(null)),
      ('Täglich', const _RecurrenceChoice({'freq': 'day', 'interval': 1})),
      (
        'Jeden Wochentag',
        const _RecurrenceChoice({
          'freq': 'week',
          'interval': 1,
          'weekdays': [1, 2, 3, 4, 5],
        }),
      ),
      ('Jede Woche', const _RecurrenceChoice({'freq': 'week', 'interval': 1})),
      ('Alle 2 Wochen', const _RecurrenceChoice({'freq': 'week', 'interval': 2})),
      ('Jeden Monat', const _RecurrenceChoice({'freq': 'month', 'interval': 1})),
      ('Jedes Jahr', const _RecurrenceChoice({'freq': 'year', 'interval': 1})),
      ('Individuell', const _RecurrenceChoice(null, custom: true)),
    ];
    return SimpleDialog(
      title: const Text('Wiederholen'),
      children: [
        for (final (label, choice) in options)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, choice),
            child: Text(label),
          ),
      ],
    );
  }
}

class _CustomRecurrenceDialog extends StatefulWidget {
  const _CustomRecurrenceDialog({required this.start, this.initial});

  final DateTime start;
  final Map<String, dynamic>? initial;

  @override
  State<_CustomRecurrenceDialog> createState() => _CustomRecurrenceDialogState();
}

class _CustomRecurrenceDialogState extends State<_CustomRecurrenceDialog> {
  late final _interval = TextEditingController(text: '${widget.initial?['interval'] ?? 1}');
  late String _freq = widget.initial?['freq'] as String? ?? 'week';
  late final Set<int> _weekdays = {
    ...(widget.initial?['weekdays'] as List?)?.cast<int>() ?? [widget.start.weekday],
  };
  late bool _byWeekday = widget.initial?['month_week'] != null;
  late int _monthDay = widget.initial?['month_day'] as int? ?? widget.start.day;
  late int _monthWeek = widget.initial?['month_week'] as int? ?? 1;
  late int _monthWeekday = widget.initial?['month_weekday'] as int? ?? widget.start.weekday;

  @override
  void dispose() {
    _interval.dispose();
    super.dispose();
  }

  int? get _intervalValue {
    final value = int.tryParse(_interval.text);
    return value != null && value >= 1 && value <= 999 ? value : null;
  }

  bool get _valid => _intervalValue != null && (_freq != 'week' || _weekdays.isNotEmpty);

  void _submit() {
    Navigator.pop(context, <String, dynamic>{
      'freq': _freq,
      'interval': _intervalValue,
      if (_freq == 'week') 'weekdays': _weekdays.toList()..sort(),
      if (_freq == 'month' && !_byWeekday) 'month_day': _monthDay,
      if (_freq == 'month' && _byWeekday) ...{'month_week': _monthWeek, 'month_weekday': _monthWeekday},
    });
  }

  Widget _weekdayButton(int day) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _weekdays.contains(day);
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        key: Key('weekday-$day'),
        customBorder: const CircleBorder(),
        onTap: () => setState(() {
          if (!_weekdays.remove(day)) _weekdays.add(day);
        }),
        child: CircleAvatar(
          radius: 18,
          backgroundColor: selected ? scheme.primary : scheme.surfaceContainerHighest,
          foregroundColor: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
          child: Text(_weekdayShort[day - 1], style: const TextStyle(fontSize: 13)),
        ),
      ),
    );
  }

  Widget _monthOptions() {
    return RadioGroup<bool>(
      groupValue: _byWeekday,
      onChanged: (value) => setState(() => _byWeekday = value!),
      child: Column(
        children: [
          Row(
            children: [
              const Radio<bool>(key: Key('month-by-day'), value: false),
              const Text('Am Tag '),
              DropdownButton<int>(
                key: const Key('month-day'),
                value: _monthDay,
                menuMaxHeight: 320,
                items: [
                  for (var day = 1; day <= 31; day++) DropdownMenuItem(value: day, child: Text('$day')),
                ],
                onChanged: (value) => setState(() {
                  _monthDay = value!;
                  _byWeekday = false;
                }),
              ),
            ],
          ),
          Row(
            children: [
              const Radio<bool>(key: Key('month-by-weekday'), value: true),
              const Text('Am '),
              DropdownButton<int>(
                key: const Key('month-week'),
                value: _monthWeek,
                items: [
                  for (final entry in _monthWeeks.entries)
                    DropdownMenuItem(value: entry.key, child: Text(entry.value)),
                ],
                onChanged: (value) => setState(() {
                  _monthWeek = value!;
                  _byWeekday = true;
                }),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: DropdownButton<int>(
                  key: const Key('month-weekday'),
                  value: _monthWeekday,
                  isExpanded: true,
                  items: [
                    for (var day = 1; day <= 7; day++)
                      DropdownMenuItem(value: day, child: Text(_weekdayNames[day - 1])),
                  ],
                  onChanged: (value) => setState(() {
                    _monthWeekday = value!;
                    _byWeekday = true;
                  }),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Individuell wiederholen'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text('Alle'),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 64,
                    child: TextField(
                      key: const Key('recurrence-interval'),
                      controller: _interval,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButton<String>(
                      key: const Key('recurrence-unit'),
                      value: _freq,
                      isExpanded: true,
                      items: const [
                        DropdownMenuItem(value: 'day', child: Text('Tage')),
                        DropdownMenuItem(value: 'week', child: Text('Wochen')),
                        DropdownMenuItem(value: 'month', child: Text('Monate')),
                        DropdownMenuItem(value: 'year', child: Text('Jahre')),
                      ],
                      onChanged: (value) => setState(() => _freq = value!),
                    ),
                  ),
                ],
              ),
              if (_freq == 'week') ...[
                const SizedBox(height: 20),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [for (var day = 1; day <= 7; day++) _weekdayButton(day)],
                ),
              ],
              if (_freq == 'month') ...[
                const SizedBox(height: 12),
                _monthOptions(),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Abbrechen')),
        FilledButton(onPressed: _valid ? _submit : null, child: const Text('Übernehmen')),
      ],
    );
  }
}

class _ReminderDialog extends StatelessWidget {
  const _ReminderDialog();

  static const none = -1;
  static const custom = -2;

  @override
  Widget build(BuildContext context) {
    return SimpleDialog(
      title: const Text('Erinnerung hinzufügen'),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, none),
          child: const Text('Keine Erinnerung'),
        ),
        for (final minutes in reminderChoices)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, minutes),
            child: Text(reminderLabel(minutes)),
          ),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, custom),
          child: const Text('Individuell'),
        ),
      ],
    );
  }
}

class _CustomReminderDialog extends StatefulWidget {
  const _CustomReminderDialog();

  @override
  State<_CustomReminderDialog> createState() => _CustomReminderDialogState();
}

class _CustomReminderDialogState extends State<_CustomReminderDialog> {
  final _count = TextEditingController(text: '10');
  int _unit = 1;

  // The backend accepts up to a year.
  static const _maxMinutes = 366 * _minutesPerDay;

  @override
  void dispose() {
    _count.dispose();
    super.dispose();
  }

  int? get _minutes {
    final count = int.tryParse(_count.text);
    if (count == null || count < 1 || count * _unit > _maxMinutes) return null;
    return count * _unit;
  }

  @override
  Widget build(BuildContext context) {
    final minutes = _minutes;
    return AlertDialog(
      title: const Text('Individuelle Erinnerung'),
      content: Row(
        children: [
          SizedBox(
            width: 72,
            child: TextField(
              key: const Key('reminder-count'),
              controller: _count,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButton<int>(
              key: const Key('reminder-unit'),
              value: _unit,
              isExpanded: true,
              items: const [
                DropdownMenuItem(value: 1, child: Text('Minuten vorher')),
                DropdownMenuItem(value: _minutesPerHour, child: Text('Stunden vorher')),
                DropdownMenuItem(value: _minutesPerDay, child: Text('Tage vorher')),
              ],
              onChanged: (value) => setState(() => _unit = value!),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Abbrechen')),
        FilledButton(
          onPressed: minutes == null ? null : () => Navigator.pop(context, minutes),
          child: const Text('Hinzufügen'),
        ),
      ],
    );
  }
}

/// A place from the search has coordinates, free text has none.
typedef _Place = ({String label, double? lat, double? lon});

/// A fixed section of the OpenStreetMap around a place. Only the tiles in view are
/// loaded, directly from OpenStreetMap, whose rules ask for the credit in the corner.
class _PlaceMap extends StatelessWidget {
  const _PlaceMap({required this.lat, required this.lon, required this.onTap});

  static const _zoom = 15;
  static const _tileSize = 256.0;
  static const _height = 180.0;

  final double lat;
  final double lon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tiles = 1 << _zoom;
    final radians = lat * math.pi / 180;
    final centerX = (lon + 180) / 360 * tiles * _tileSize;
    final centerY = (1 - math.log(math.tan(radians) + 1 / math.cos(radians)) / math.pi) / 2 * tiles * _tileSize;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final left = centerX - width / 2;
        final top = centerY - _height / 2;
        return ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            key: const Key('place-map'),
            height: _height,
            child: Stack(
              children: [
                GestureDetector(
                  onTap: onTap,
                  child: Stack(
                    children: [
                      SizedBox(width: width, height: _height, child: ColoredBox(color: Theme.of(context).colorScheme.surfaceContainerHighest)),
                      for (var y = (top / _tileSize).floor(); y * _tileSize < top + _height; y++)
                        for (var x = (left / _tileSize).floor(); x * _tileSize < left + width; x++)
                          if (y >= 0 && y < tiles)
                            Positioned(
                              left: x * _tileSize - left,
                              top: y * _tileSize - top,
                              child: Image.network(
                                'https://tile.openstreetmap.org/$_zoom/${x % tiles}/$y.png',
                                width: _tileSize,
                                height: _tileSize,
                                // Browsers name the app themselves through the referrer.
                                headers: kIsWeb ? null : const {'User-Agent': 'Kintura/1.0'},
                                errorBuilder: (_, _, _) => const SizedBox.shrink(),
                              ),
                            ),
                      Positioned(
                        left: width / 2 - 18,
                        top: _height / 2 - 36,
                        child: Icon(Icons.place, size: 36, color: Theme.of(context).colorScheme.error),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: GestureDetector(
                    onTap: () => launchUrl(Uri.https('www.openstreetmap.org', '/copyright')),
                    child: ColoredBox(
                      color: Colors.white70,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                        child: Text(
                          '© OpenStreetMap',
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Colors.black87),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Searches addresses while typing. Free text also works, e.g. for "bei Oma".
class _PlaceDialog extends StatefulWidget {
  const _PlaceDialog({required this.initial});

  final String initial;

  @override
  State<_PlaceDialog> createState() => _PlaceDialogState();
}

class _PlaceDialogState extends State<_PlaceDialog> {
  static const _minLength = 3;
  static const _typingPause = Duration(milliseconds: 500);

  late final _query = TextEditingController(text: widget.initial);
  List<_Place>? _places;
  String? _error;
  bool _searching = false;
  Timer? _pause;
  int _latest = 0; // Answers can overtake each other, only the newest counts.

  @override
  void dispose() {
    _pause?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _typed() {
    _pause?.cancel();
    if (_query.text.trim().length >= _minLength) {
      _pause = Timer(_typingPause, _search);
      setState(() {});
    } else {
      _latest++;
      setState(() {
        _places = null;
        _error = null;
        _searching = false;
      });
    }
  }

  Future<void> _search() async {
    _pause?.cancel();
    final session = SessionScope.of(context);
    final text = _query.text.trim();
    if (text.isEmpty) return;
    final request = ++_latest;
    setState(() => _searching = true);
    try {
      final result = await session.api.get('/api/places?${Uri(queryParameters: {'q': text}).query}');
      if (!mounted || request != _latest) return;
      setState(() {
        _places = [
          for (final place in (result['places'] as List).cast<Map<String, dynamic>>())
            (
              label: place['label'] as String,
              lat: (place['lat'] as num).toDouble(),
              lon: (place['lon'] as num).toDouble(),
            ),
        ];
        _error = null;
        _searching = false;
      });
    } on ApiException catch (e) {
      if (!mounted || request != _latest) return;
      setState(() {
        _error = e.message;
        _searching = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final places = _places;
    final text = _query.text.trim();
    return AlertDialog(
      title: const Text('Ort hinzufügen'),
      contentPadding: const EdgeInsets.fromLTRB(0, 16, 0, 0),
      content: SizedBox(
        width: 480,
        height: 420,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: TextField(
                key: const Key('place-query'),
                controller: _query,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Ort oder Adresse',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _searching
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                        )
                      : null,
                ),
                onChanged: (_) => _typed(),
                onSubmitted: (_) => _search(),
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  if (text.isNotEmpty)
                    ListTile(
                      leading: const Icon(Icons.edit_location_alt_outlined),
                      title: Text('„$text“ übernehmen'),
                      onTap: () => Navigator.pop<_Place>(context, (label: text, lat: null, lon: null)),
                    ),
                  if (_error != null)
                    ListTile(title: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)))
                  else if (places != null && places.isEmpty)
                    const ListTile(title: Text('Nichts gefunden.')),
                  for (final place in places ?? const <_Place>[])
                    ListTile(
                      leading: const Icon(Icons.place_outlined),
                      title: Text(place.label),
                      onTap: () => Navigator.pop<_Place>(context, place),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
              child: Text(
                'Adresssuche: © OpenStreetMap-Mitwirkende',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Abbrechen')),
      ],
    );
  }
}
