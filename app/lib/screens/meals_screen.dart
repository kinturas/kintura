import 'package:flutter/material.dart';

import '../common.dart';
import '../session.dart';

const _slots = {
  'breakfast': 'Frühstück',
  'lunch': 'Mittagessen',
  'dinner': 'Abendessen',
};

class MealsScreen extends StatefulWidget {
  const MealsScreen({super.key});

  @override
  State<MealsScreen> createState() => _MealsScreenState();
}

class _MealsScreenState extends State<MealsScreen> {
  late DateTime _monday = _mondayOf(DateTime.now());
  Map<String, String> _meals = {};

  static DateTime _mondayOf(DateTime date) =>
      DateTime(date.year, date.month, date.day - (date.weekday - 1));

  DateTime _day(int offset) =>
      DateTime(_monday.year, _monday.month, _monday.day + offset);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_meals.isEmpty) _load();
  }

  Future<void> _load() async {
    final session = SessionScope.of(context);
    await guarded(context, () async {
      final rows = await session.api.get(
        '${session.familyPath}/meals?from=${dateKey(_day(0))}&to=${dateKey(_day(6))}',
      ) as List;
      if (!mounted) return;
      setState(() {
        _meals = {
          for (final row in rows)
            '${row['date']}/${row['slot']}': row['title'] as String,
        };
      });
    });
  }

  void _changeWeek(int delta) {
    setState(() {
      _monday = _day(7 * delta);
      _meals = {};
    });
    _load();
  }

  Future<void> _edit(DateTime day, String slot) async {
    final session = SessionScope.of(context);
    final key = '${dateKey(day)}/$slot';
    final title = await promptText(
      context,
      title: '${_slots[slot]} am ${dateFormat.format(day)}',
      label: 'Gericht (leer = entfernen)',
      initial: _meals[key] ?? '',
    );
    if (title == null || !mounted) return;
    final ok = await guarded(
      context,
      () => session.api.put('${session.familyPath}/meals/$key', {'title': title}),
    );
    if (ok) _load();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Mahlzeiten')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Row(
            children: [
              IconButton(
                tooltip: 'Vorige Woche',
                icon: const Icon(Icons.chevron_left),
                onPressed: () => _changeWeek(-1),
              ),
              Expanded(
                child: Text(
                  '${dateFormat.format(_day(0))} – ${dateFormat.format(_day(6))}',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              IconButton(
                tooltip: 'Nächste Woche',
                icon: const Icon(Icons.chevron_right),
                onPressed: () => _changeWeek(1),
              ),
            ],
          ),
          for (var i = 0; i < 7; i++)
            Card(
              elevation: 0,
              color: colors.surfaceContainerLow,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        weekdayDateFormat.format(_day(i)),
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    for (final slot in _slots.entries)
                      ListTile(
                        dense: true,
                        title: Text(slot.value),
                        subtitle: Text(
                          _meals['${dateKey(_day(i))}/${slot.key}'] ?? '–',
                        ),
                        onTap: () => _edit(_day(i), slot.key),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
