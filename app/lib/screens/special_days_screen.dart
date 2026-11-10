import 'package:flutter/material.dart';

import '../common.dart';
import '../session.dart';

const _kinds = {
  'feast': ('Festtag', Icons.celebration_outlined),
  'memorial': ('Gedenktag', Icons.local_florist_outlined),
  'birthday': ('Geburtstag', Icons.cake_outlined),
  'other': ('Sonstiges', Icons.star_outline),
};

/// Date of the next occurrence, or the date itself for a past one-time day.
DateTime nextOccurrence(DateTime date, bool yearly, DateTime today) {
  if (!yearly) return date;
  final thisYear = DateTime(today.year, date.month, date.day);
  return thisYear.isBefore(today)
      ? DateTime(today.year + 1, date.month, date.day)
      : thisYear;
}

String countdown(DateTime next, DateTime today) {
  final days = DateTime.utc(next.year, next.month, next.day)
      .difference(DateTime.utc(today.year, today.month, today.day))
      .inDays;
  return switch (days) {
    0 => 'Heute',
    1 => 'Morgen',
    > 1 => 'In $days Tagen',
    _ => 'Vorbei',
  };
}

class SpecialDaysScreen extends StatefulWidget {
  const SpecialDaysScreen({super.key});

  @override
  State<SpecialDaysScreen> createState() => _SpecialDaysScreenState();
}

class _SpecialDaysScreenState extends State<SpecialDaysScreen> {
  final _view = GlobalKey<AsyncViewState<List<dynamic>>>();

  Future<void> _edit([Map<String, dynamic>? day]) async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => _SpecialDayDialog(day: day),
    );
    if (changed == true) _view.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return Scaffold(
      appBar: AppBar(title: const Text('Besondere Tage')),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Neuer Tag',
        onPressed: _edit,
        child: const Icon(Icons.add),
      ),
      body: AsyncView<List<dynamic>>(
        key: _view,
        load: () async =>
            await session.api.get('${session.familyPath}/special-days') as List,
        builder: (context, rows) {
          if (rows.isEmpty) {
            return const EmptyHint(
              icon: Icons.celebration_outlined,
              text: 'Noch keine besonderen Tage eingetragen.',
            );
          }
          final days = [
            for (final row in rows.cast<Map<String, dynamic>>())
              (
                row: row,
                next: nextOccurrence(
                  DateTime.parse(row['date'] as String),
                  row['yearly'] as bool,
                  today,
                ),
              ),
          ];
          // Upcoming days first, past one-time days at the end.
          days.sort((a, b) {
            final aPast = a.next.isBefore(today);
            final bPast = b.next.isBefore(today);
            if (aPast != bPast) return aPast ? 1 : -1;
            return a.next.compareTo(b.next);
          });
          return ListView(
            padding: const EdgeInsets.only(bottom: 88),
            children: [
              for (final day in days)
                ListTile(
                  leading: Icon(_kinds[day.row['kind']]!.$2),
                  title: Text(day.row['title'] as String),
                  subtitle: Text(
                    '${_kinds[day.row['kind']]!.$1} · ${dateFormat.format(day.next)}'
                    '${day.row['yearly'] as bool ? ' · jährlich' : ''}',
                  ),
                  trailing: Text(countdown(day.next, today)),
                  onTap: () => _edit(day.row),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _SpecialDayDialog extends StatefulWidget {
  const _SpecialDayDialog({this.day});

  final Map<String, dynamic>? day;

  @override
  State<_SpecialDayDialog> createState() => _SpecialDayDialogState();
}

class _SpecialDayDialogState extends State<_SpecialDayDialog> {
  late final _title = TextEditingController(text: widget.day?['title'] as String?);
  late final _note = TextEditingController(text: widget.day?['note'] as String?);
  late String _kind = widget.day?['kind'] as String? ?? 'feast';
  late bool _yearly = widget.day?['yearly'] as bool? ?? true;
  late DateTime _date =
      DateTime.tryParse(widget.day?['date'] as String? ?? '') ?? DateTime.now();

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final session = SessionScope.of(context);
    final navigator = Navigator.of(context);
    final body = {
      'title': _title.text.trim(),
      'kind': _kind,
      'date': dateKey(_date),
      'yearly': _yearly,
      'note': _note.text.trim(),
    };
    final id = widget.day?['id'];
    final ok = await guarded(
      context,
      () => id == null
          ? session.api.post('${session.familyPath}/special-days', body)
          : session.api.put('${session.familyPath}/special-days/$id', body),
    );
    if (ok) navigator.pop(true);
  }

  Future<void> _delete() async {
    final session = SessionScope.of(context);
    final navigator = Navigator.of(context);
    if (!await confirm(context, 'Eintrag löschen?') || !mounted) return;
    final ok = await guarded(
      context,
      () => session.api.delete(
        '${session.familyPath}/special-days/${widget.day!['id']}',
      ),
    );
    if (ok) navigator.pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.day == null ? 'Neuer besonderer Tag' : 'Besonderer Tag'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _title,
              autofocus: widget.day == null,
              decoration: const InputDecoration(labelText: 'Titel'),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: _kind,
              decoration: const InputDecoration(labelText: 'Art'),
              items: [
                for (final kind in _kinds.entries)
                  DropdownMenuItem(value: kind.key, child: Text(kind.value.$1)),
              ],
              onChanged: (value) => setState(() => _kind = value!),
            ),
            const SizedBox(height: 16),
            DateField(
              label: 'Datum',
              value: _date,
              onChanged: (date) {
                if (date != null) setState(() => _date = date);
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Jedes Jahr'),
              value: _yearly,
              onChanged: (value) => setState(() => _yearly = value),
            ),
            TextField(
              controller: _note,
              decoration: const InputDecoration(labelText: 'Notiz'),
            ),
          ],
        ),
      ),
      actions: [
        if (widget.day != null)
          TextButton(onPressed: _delete, child: const Text('Löschen')),
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Abbrechen'),
        ),
        FilledButton(onPressed: _save, child: const Text('Speichern')),
      ],
    );
  }
}
