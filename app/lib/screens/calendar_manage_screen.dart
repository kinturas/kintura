import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../common.dart';
import '../session.dart';
import 'event_edit_screen.dart';

const _panelWidth = 420.0;
const _panelShare = 0.88; // of a narrow screen, so that the calendar stays in view

/// Calendars with a choice of regions, the only ones restricted members can open.
const _regional = {'school', 'holidays'};

/// The cleanup choices in months.
const _cleanupChoices = {
  1: '1 Monat',
  3: '3 Monate',
  6: '6 Monate',
  9: '9 Monate',
  12: '1 Jahr',
  24: '2 Jahre',
  36: '3 Jahre',
};

String _keyPath(BuildContext context, Map<String, dynamic> calendar) {
  final session = SessionScope.of(context);
  return '${session.familyPath}/calendars/${Uri.encodeComponent(calendar['key'] as String)}';
}

/// Slides the calendar management in from the right, over the calendar.
Future<void> showCalendarManagePanel(BuildContext context) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Schließen',
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 250),
    pageBuilder: (context, _, _) => LayoutBuilder(
      builder: (context, constraints) => Align(
        alignment: Alignment.centerRight,
        child: Material(
          elevation: 16,
          child: SizedBox(
            key: const Key('calendar-panel'),
            width: math.min(_panelWidth, constraints.maxWidth * _panelShare),
            // Messages belong on the panel, not also on the calendar behind it.
            child: const ScaffoldMessenger(child: CalendarManageScreen()),
          ),
        ),
      ),
    ),
    transitionBuilder: (context, animation, _, child) => ClipRect(
      child: SlideTransition(
        position: Tween(begin: const Offset(1, 0), end: Offset.zero)
            .animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
        child: child,
      ),
    ),
  );
}

/// Turns calendars on and off, connects new ones and holds the calendar settings.
class CalendarManageScreen extends StatefulWidget {
  const CalendarManageScreen({super.key});

  @override
  State<CalendarManageScreen> createState() => _CalendarManageScreenState();
}

class _CalendarManageScreenState extends State<CalendarManageScreen> {
  final _view = GlobalKey<AsyncViewState<Map<String, dynamic>>>();

  /// Reports failures on [from], the page the change was made on.
  Future<bool> _change(BuildContext from, Future<void> Function() action) async {
    final ok = await guarded(from, action);
    if (ok) _view.currentState?.reload();
    return ok;
  }

  Future<bool> _toggle(Map<String, dynamic> calendar, bool enabled) {
    final session = SessionScope.of(context);
    final path = _keyPath(context, calendar);
    return _change(
      context,
      () => session.api.put(path, {
        'enabled': enabled,
        // A color everyone shares is not part of showing or hiding the calendar.
        if (calendar['color_shared'] != true) 'color': calendar['color'],
        'regions': calendar['regions'] ?? <String>[],
      }),
    );
  }

  Future<bool> _savePrefs(BuildContext from, Map<String, dynamic> prefs, Map<String, Object?> changes) {
    final session = SessionScope.of(context);
    return _change(from, () => session.api.put('${session.familyPath}/calendar-prefs', {...prefs, ...changes}));
  }

  Future<bool> _addFeed(BuildContext from, Map<String, String> feed) {
    final session = SessionScope.of(context);
    return _change(from, () => session.api.post('${session.familyPath}/calendar-feeds', feed));
  }

  Future<bool> _setCleanup(BuildContext from, int months, int current) async {
    final session = SessionScope.of(context);
    if (months < current &&
        !await confirm(
          from,
          'Einzelne Termine, die länger als ${_cleanupChoices[months]} zurückliegen, werden für den ganzen Kreis endgültig gelöscht.',
          action: 'Übernehmen',
        )) {
      return false;
    }
    if (!from.mounted) return false;
    return _change(from, () => session.api.put('${session.familyPath}/calendar-cleanup', {'months': months}));
  }

  Future<void> _open(Widget page) => Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => page));

  Future<void> _openDetail(Map<String, dynamic> calendar, Map<String, dynamic> data) async {
    final prefs = data['prefs'] as Map<String, dynamic>;
    await _open(
      _CalendarDetailScreen(
        calendar: calendar,
        states: (data['states'] as List).cast<Map<String, dynamic>>(),
        countries: (data['countries'] as List).cast<Map<String, dynamic>>(),
        selectedCountries: (prefs['holiday_countries'] as List).cast<String>(),
        onCountriesChanged: (from, selected) => _savePrefs(from, prefs, {'holiday_countries': selected}),
      ),
    );
    _view.currentState?.reload();
  }

  Widget _heading(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
    child: Text(text, style: Theme.of(context).textTheme.titleMedium),
  );

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: const CloseButton(),
        title: const Text('Kalender verwalten'),
      ),
      body: AsyncView<Map<String, dynamic>>(
        key: _view,
        load: () async => await session.api.get('${session.familyPath}/calendars') as Map<String, dynamic>,
        builder: (context, data) {
          final calendars = (data['calendars'] as List).cast<Map<String, dynamic>>();
          final prefs = data['prefs'] as Map<String, dynamic>;
          final reminder = prefs['default_reminder'] as int;
          final reminders = {
            0: 'Keine Erinnerung',
            for (final minutes in [...{...reminderChoices, reminder}.where((m) => m > 0)]..sort())
              minutes: reminderLabel(minutes),
          };
          final cleanup = data['cleanup_months'] as int;
          final isAdmin = session.current?.isAdmin ?? false;
          final restricted = session.current?.isRestricted ?? false;
          final scheme = Theme.of(context).colorScheme;
          final narrow = MediaQuery.sizeOf(context).width * _panelShare < _panelWidth;
          return ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              _heading(context, 'Meine Kalender'),
              for (final calendar in calendars) ...[
                ListTile(
                  key: Key('calendar-${calendar['key']}'),
                  leading: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Checkbox(
                        value: calendar['enabled'] as bool,
                        onChanged: (value) => _toggle(calendar, value!),
                      ),
                      ColorDot(calendar['color'] as String),
                    ],
                  ),
                  title: Text(calendar['name'] as String),
                  subtitle: Text(
                    calendar['last_error'] as String? ?? calendar['subtitle'] as String,
                    style: calendar['last_error'] == null ? null : TextStyle(color: scheme.error),
                  ),
                  // Restricted members only switch calendars on and off, and choose
                  // the states of the school holidays and the countries of the holidays.
                  trailing: !restricted || _regional.contains(calendar['kind']) ? const Icon(Icons.chevron_right) : null,
                  onTap: !restricted || _regional.contains(calendar['kind']) ? () => _openDetail(calendar, data) : null,
                ),
              ],
              _heading(context, 'Kalender verbinden'),
              const ListTile(
                enabled: false,
                leading: Icon(Icons.event_available_outlined),
                title: Text('Google'),
                subtitle: Text('Kommt später. Bis dahin geht die private iCal-Adresse über „Kalender-URL“.'),
              ),
              const ListTile(
                enabled: false,
                leading: Icon(Icons.mail_outline),
                title: Text('Outlook'),
                subtitle: Text('Kommt später'),
              ),
              // They could not take it out again, since that is on the page of the calendar.
              if (!restricted)
                ListTile(
                  leading: const Icon(Icons.link),
                  title: const Text('Kalender-URL'),
                  subtitle: const Text('Einen Kalender über seine Adresse einbinden'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _open(_FeedScreen(onAdd: _addFeed)),
                ),
              const ListTile(
                enabled: false,
                leading: Icon(Icons.upload_file),
                title: Text('Ereignisse aus ICS importieren'),
                subtitle: Text('Kommt später'),
              ),
              _heading(context, 'Einstellungen'),
              SwitchListTile(
                key: const Key('week-numbers'),
                secondary: const Icon(Icons.tag),
                title: const Text('Wochennummer anzeigen'),
                value: prefs['week_numbers'] as bool,
                onChanged: (value) => _savePrefs(context, prefs, {'week_numbers': value}),
              ),
              ListTile(
                leading: const Icon(Icons.first_page),
                title: const Text('Wochenbeginn'),
                trailing: SegmentedButton<String>(
                  key: const Key('week-start'),
                  showSelectedIcon: false,
                  // On a phone the full names would push the title onto a second line.
                  segments: [
                    ButtonSegment(value: 'monday', label: Text(narrow ? 'Mo' : 'Montag'), tooltip: 'Montag'),
                    ButtonSegment(value: 'sunday', label: Text(narrow ? 'So' : 'Sonntag'), tooltip: 'Sonntag'),
                  ],
                  selected: {prefs['week_start'] as String},
                  onSelectionChanged: (value) => _savePrefs(context, prefs, {'week_start': value.first}),
                ),
              ),
              ListTile(
                key: const Key('default-reminder'),
                leading: const Icon(Icons.notifications_outlined),
                title: const Text('Standard-Erinnerung'),
                subtitle: Text(reminders[reminder]!),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _open(
                  _ChoiceScreen(
                    title: 'Standard-Erinnerung',
                    intro: 'Gilt für neue Termine und lässt sich dort ändern.',
                    choices: reminders,
                    selected: reminder,
                    onSelected: (from, value) => _savePrefs(from, prefs, {'default_reminder': value}),
                  ),
                ),
              ),
              ListTile(
                key: const Key('cleanup'),
                leading: const Icon(Icons.auto_delete_outlined),
                title: const Text('Kalenderbereinigung'),
                subtitle: Text(_cleanupChoices[cleanup] ?? ''),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _open(
                  _ChoiceScreen(
                    title: 'Kalenderbereinigung',
                    intro: isAdmin
                        ? 'Löscht einzelne Termine, die länger als dieser Zeitraum zurückliegen, endgültig für den ganzen Kreis. Serien bleiben.'
                        : 'Löscht einzelne Termine, die länger als dieser Zeitraum zurückliegen. Das stellen die Admins des Kreises ein.',
                    choices: _cleanupChoices,
                    selected: cleanup,
                    onSelected: isAdmin ? (from, value) => _setCleanup(from, value, cleanup) : null,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// One value out of several, on a page of its own. Choosing one goes back.
class _ChoiceScreen extends StatelessWidget {
  const _ChoiceScreen({
    required this.title,
    required this.intro,
    required this.choices,
    required this.selected,
    required this.onSelected,
  });

  final String title;
  final String intro;
  final Map<int, String> choices;
  final int selected;

  /// Reports whether the value was saved; null makes the page read-only.
  final Future<bool> Function(BuildContext from, int value)? onSelected;

  @override
  Widget build(BuildContext context) {
    final save = onSelected;
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(
        children: [
          Padding(padding: const EdgeInsets.all(16), child: Text(intro)),
          for (final choice in choices.entries)
            ListTile(
              title: Text(choice.value),
              enabled: save != null,
              trailing: choice.key == selected ? const Icon(Icons.check) : null,
              onTap: save == null
                  ? null
                  : () async {
                      final navigator = Navigator.of(context);
                      if (choice.key == selected || await save(context, choice.key)) navigator.pop();
                    },
            ),
        ],
      ),
    );
  }
}

/// Several countries or states can be chosen. Each change counts at once.
class _ChecklistScreen extends StatefulWidget {
  const _ChecklistScreen({required this.title, required this.options, required this.selected, required this.onChanged});

  final String title;

  /// The names by code, in the order to show them.
  final Map<String, String> options;
  final List<String> selected;
  final Future<bool> Function(BuildContext from, List<String> selected) onChanged;

  @override
  State<_ChecklistScreen> createState() => _ChecklistScreenState();
}

class _ChecklistScreenState extends State<_ChecklistScreen> {
  late Set<String> _selected = {...widget.selected};

  Future<void> _set(String code, bool on) async {
    final before = _selected;
    final after = {...before};
    if (on) {
      after.add(code);
    } else {
      after.remove(code);
    }
    setState(() => _selected = after);
    final ok = await widget.onChanged(context, after.toList()..sort());
    if (!ok && mounted) setState(() => _selected = before);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: ListView(
        children: [
          for (final option in widget.options.entries)
            CheckboxListTile(
              title: Text(option.value),
              value: _selected.contains(option.key),
              onChanged: (value) => _set(option.key, value!),
            ),
        ],
      ),
    );
  }
}

/// Stays open if the address is rejected, so that it can be corrected.
class _FeedScreen extends StatefulWidget {
  const _FeedScreen({required this.onAdd});

  final Future<bool> Function(BuildContext from, Map<String, String> feed) onAdd;

  @override
  State<_FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<_FeedScreen> {
  final _name = TextEditingController();
  final _url = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    super.dispose();
  }

  bool get _valid => _name.text.trim().isNotEmpty && _url.text.trim().isNotEmpty;

  Future<void> _add() async {
    final navigator = Navigator.of(context);
    setState(() => _saving = true);
    final ok = await widget.onAdd(context, {'name': _name.text.trim(), 'url': _url.text.trim()});
    if (ok) {
      navigator.pop();
    } else if (mounted) {
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Kalender-URL')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            key: const Key('feed-name'),
            controller: _name,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Name'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('feed-url'),
            controller: _url,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(labelText: 'Adresse', hintText: 'https://… oder webcal://…'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: _valid && !_saving ? _add : null,
              child: const Text('Hinzufügen'),
            ),
          ),
        ],
      ),
    );
  }
}

/// The options of one calendar: its color and whatever else it offers.
class _CalendarDetailScreen extends StatefulWidget {
  const _CalendarDetailScreen({
    required this.calendar,
    required this.states,
    required this.countries,
    required this.selectedCountries,
    required this.onCountriesChanged,
  });

  final Map<String, dynamic> calendar;
  final List<Map<String, dynamic>> states;
  final List<Map<String, dynamic>> countries;
  final List<String> selectedCountries;
  final Future<bool> Function(BuildContext from, List<String> selected) onCountriesChanged;

  @override
  State<_CalendarDetailScreen> createState() => _CalendarDetailScreenState();
}

class _CalendarDetailScreenState extends State<_CalendarDetailScreen> {
  late String _color = widget.calendar['color'] as String;
  late final Set<String> _regions = {...(widget.calendar['regions'] as List?)?.cast<String>() ?? const <String>[]};
  late String? _shareUrl = widget.calendar['share_url'] as String?;
  late List<String> _selectedCountries = widget.selectedCountries;
  bool _refreshing = false;

  Map<String, dynamic> get _calendar => widget.calendar;

  Future<void> _chooseCountries() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _ChecklistScreen(
          title: 'Gesetzliche Feiertage',
          options: {for (final country in widget.countries) country['code'] as String: country['name'] as String},
          selected: _selectedCountries,
          onChanged: (from, selected) async {
            final ok = await widget.onCountriesChanged(from, selected);
            if (ok) _selectedCountries = selected;
            return ok;
          },
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  /// Reports failures on [from], the page the change was made on, and whether it worked.
  Future<bool> _save({BuildContext? from, String? color, Set<String>? regions}) async {
    final session = SessionScope.of(context);
    final path = _keyPath(context, _calendar);
    final ok = await guarded(
      from ?? context,
      () => session.api.put(path, {
        'enabled': _calendar['enabled'],
        if (color != null || _calendar['color_shared'] != true) 'color': color ?? _color,
        'regions': (regions ?? _regions).toList(),
      }),
    );
    if (ok && mounted) {
      setState(() {
        _color = color ?? _color;
        if (regions != null) {
          _regions
            ..clear()
            ..addAll(regions);
        }
      });
    }
    return ok;
  }

  void _chooseStates() {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _ChecklistScreen(
          title: 'Bundesländer',
          options: {for (final state in widget.states) state['Code'] as String: state['Name'] as String},
          selected: _regions.toList(),
          onChanged: (from, selected) => _save(from: from, regions: selected.toSet()),
        ),
      ),
    );
  }

  Future<void> _createShare() async {
    final session = SessionScope.of(context);
    final path = _keyPath(context, _calendar);
    await guarded(context, () async {
      final result = await session.api.post('$path/share');
      if (mounted) setState(() => _shareUrl = result['url'] as String);
    });
  }

  Future<void> _deleteShare() async {
    final session = SessionScope.of(context);
    final path = _keyPath(context, _calendar);
    if (!await confirm(context, 'Freigabe löschen? Der Link funktioniert dann nicht mehr.') || !mounted) return;
    final ok = await guarded(context, () => session.api.delete('$path/share'));
    if (ok && mounted) setState(() => _shareUrl = null);
  }

  Future<void> _copyShare() async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: _shareUrl!));
    messenger.showSnackBar(const SnackBar(content: Text('Link kopiert')));
  }

  Future<void> _sendShare() async {
    final query = 'subject=${Uri.encodeComponent('Kalender „${_calendar['name']}“')}'
        '&body=${Uri.encodeComponent(_shareUrl!)}';
    await launchUrl(Uri(scheme: 'mailto', query: query));
  }

  Future<void> _refreshFeed() async {
    final session = SessionScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final id = (_calendar['key'] as String).substring('feed:'.length);
    setState(() => _refreshing = true);
    await guarded(context, () async {
      final result = await session.api.post('${session.familyPath}/calendar-feeds/$id/refresh');
      final events = result['events'] as int;
      messenger.showSnackBar(
        SnackBar(
          content: Text(switch (events) {
            0 => 'Aktualisiert, der Kalender enthält keine Termine.',
            1 => 'Aktualisiert, der Kalender enthält 1 Termin.',
            _ => 'Aktualisiert, der Kalender enthält $events Termine.',
          }),
        ),
      );
    });
    if (mounted) setState(() => _refreshing = false);
  }

  Future<void> _deleteFeed() async {
    final session = SessionScope.of(context);
    final navigator = Navigator.of(context);
    if (!await confirm(context, '„${_calendar['name']}“ entfernen?') || !mounted) return;
    final id = (_calendar['key'] as String).substring('feed:'.length);
    final ok = await guarded(context, () => session.api.delete('${session.familyPath}/calendar-feeds/$id'));
    if (ok) navigator.pop();
  }

  Widget _section(BuildContext context, String title, Widget child) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 12),
        child,
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    final kind = _calendar['kind'] as String;
    final family = session.current;
    final colorShared = _calendar['color_shared'] == true;
    final mayChangeColor = !colorShared || (family?.isManager ?? false);
    return Scaffold(
      appBar: AppBar(title: Text(_calendar['name'] as String)),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          if (kind == 'holidays')
            _section(
              context,
              'Länder',
              ListTile(
                key: const Key('holiday-countries'),
                contentPadding: EdgeInsets.zero,
                title: Text(
                  _selectedCountries.isEmpty
                      ? 'Kein Land ausgewählt'
                      : [
                          for (final country in widget.countries)
                            if (_selectedCountries.contains(country['code'])) country['name'] as String,
                        ].join(', '),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: _chooseCountries,
              ),
            ),
          if (kind == 'school')
            _section(
              context,
              'Bundesländer',
              ListTile(
                key: const Key('school-states'),
                contentPadding: EdgeInsets.zero,
                title: Text(
                  _regions.isEmpty
                      ? 'Kein Bundesland ausgewählt'
                      : [
                          for (final state in widget.states)
                            if (_regions.contains(state['Code'])) state['Name'] as String,
                        ].join(', '),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: _chooseStates,
              ),
            ),
          // Restricted members only get here for the states and the countries.
          if (!(family?.isRestricted ?? false))
            _section(
              context,
              'Farbe',
              mayChangeColor
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (colorShared) ...[
                          const Text('Die Farbe gilt für alle im Kreis.'),
                          const SizedBox(height: 12),
                        ],
                        AsyncView<Map<String, dynamic>>(
                          load: () async => await session.api.get('${session.familyPath}/colors') as Map<String, dynamic>,
                          builder: (context, colors) => ColorChooser(
                            colors: colors,
                            selected: _color,
                            allowNone: false,
                            singleList: true,
                            onSelected: (color) => _save(color: color),
                          ),
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        ColorDot(_color),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Die Farbe gilt für alle im Kreis. Ändern können sie nur ${family?.type.roleLabel('manager') ?? 'Manager'}.',
                          ),
                        ),
                      ],
                    ),
            ),
          if (_calendar['shareable'] == true)
            _section(
              context,
              'Kalenderfreigabe',
              _shareUrl == null
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Über einen Link lässt sich dieser Kalender in anderen Apps abonnieren. '
                          'Wer den Link hat, sieht alles, was du hier sehen kannst.',
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: _createShare,
                          icon: const Icon(Icons.link),
                          label: const Text('Link erstellen'),
                        ),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SelectableText(_shareUrl!),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            IconButton(tooltip: 'Link kopieren', icon: const Icon(Icons.copy), onPressed: _copyShare),
                            IconButton(tooltip: 'Link senden', icon: const Icon(Icons.send_outlined), onPressed: _sendShare),
                            IconButton(tooltip: 'Link löschen', icon: const Icon(Icons.delete_outline), onPressed: _deleteShare),
                          ],
                        ),
                      ],
                    ),
            ),
          if (kind == 'feed')
            _section(
              context,
              'Adresse',
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(_calendar['url'] as String),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _refreshing ? null : _refreshFeed,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Jetzt aktualisieren'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _deleteFeed,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Kalender entfernen'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
