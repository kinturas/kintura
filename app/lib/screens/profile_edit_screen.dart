import 'dart:convert';

import 'package:flutter/material.dart';

import '../common.dart';
import '../session.dart';
import 'avatar_crop_screen.dart';

/// The extra fields of a profile in the order they are offered. The keys are what the
/// backend stores.
const profileFieldLabels = {
  'phone': 'Telefon',
  'email': 'E-Mail',
  'mobile': 'Handy',
  'work_phone': 'Telefon Arbeit',
  'other': 'Sonstige',
  'address': 'Adresse',
};

class _ExtraField {
  _ExtraField(this.kind, String value, {this.isNew = false}) : controller = TextEditingController(text: value);

  final String kind;
  final TextEditingController controller;

  /// Added just now, so the cursor goes there.
  final bool isNew;

  TextInputType get keyboard => switch (kind) {
    'phone' || 'mobile' || 'work_phone' => TextInputType.phone,
    'email' => TextInputType.emailAddress,
    'address' => TextInputType.multiline,
    _ => TextInputType.text,
  };
}

/// Pops whether to delete the data as well, or nothing to stay.
class _LeaveDialog extends StatelessWidget {
  const _LeaveDialog({required this.family, required this.alone});

  final Family family;

  /// Nobody else is left, so nobody could let the user back in.
  final bool alone;

  @override
  Widget build(BuildContext context) {
    final error = Theme.of(context).colorScheme.error;
    return AlertDialog(
      title: Text('${family.name} verlassen?'),
      content: Text(
        alone
            ? 'Du bist das letzte Mitglied. Danach hat niemand mehr Zugang zu diesem Kreis, eventuell nur noch über den Support.\n\n'
                  '„Verlassen und alle Daten löschen“ löscht den ganzen Kreis endgültig.'
            : 'Wirst du wieder eingeladen, hast du wieder Zugriff auf deine Daten.\n\n'
                  '„Verlassen und alle Daten löschen“ löscht endgültig dein Profil, deine Nachrichten, Kommentare und Dateien '
                  'und Termine, die nur du siehst. Gemeinsame Termine und Listen bleiben für die anderen, ohne deinen Namen.',
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(foregroundColor: error),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Verlassen und alle Daten löschen'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Nur verlassen'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Abbrechen'),
        ),
      ],
    );
  }
}

class _ProfileData {
  _ProfileData(this.profile, this.colors);

  final Map<String, dynamic> profile;
  final Map<String, dynamic> colors;
}

/// Everything a member says about themselves in the current circle. An admin gets the
/// same page for a [member] who has no account to do it themselves. Pops true if saved.
class ProfileEditScreen extends StatefulWidget {
  const ProfileEditScreen({super.key, this.member});

  final Map<String, dynamic>? member;

  @override
  State<ProfileEditScreen> createState() => _ProfileEditScreenState();
}

class _ProfileEditScreenState extends State<ProfileEditScreen> {
  final _name = TextEditingController();
  final _familyRole = TextEditingController();
  final _contactEmail = TextEditingController();
  final _fields = <_ExtraField>[];
  DateTime? _birthday;
  late String _color = widget.member?['color'] as String? ?? SessionScope.of(context).current?.color ?? '';

  /// Where this profile lives, which is the own one unless a member was given.
  String _memberPath(AppSession session) {
    final member = widget.member;
    return member == null ? session.familyPath : '${session.familyPath}/members/${member['id']}';
  }

  /// The small photo as shown; null until it changes here, then what the server made.
  String? _avatar;
  bool _avatarBusy = false;

  String _currentAvatar(AppSession session) =>
      _avatar ?? (widget.member?['avatar'] as String? ?? session.current?.avatar ?? '');

  /// The own photo sits at the profile, a managed member's at the member.
  String _avatarPath(AppSession session) =>
      widget.member == null ? '${session.familyPath}/profile/avatar' : '${_memberPath(session)}/avatar';

  /// Takes effect at once, apart from saving the form: the photo is cut and sent right away.
  Future<void> _changeAvatar() async {
    final session = SessionScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final cropped = await pickAndCropAvatar(context);
    if (cropped == null || !mounted) return;
    setState(() => _avatarBusy = true);
    // Shrinking a large photo takes a moment too; the progress shows first.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (!mounted) return;
    final ok = await guarded(context, () async {
      final upload = shrinkForUpload(cropped);
      final result = await session.api.upload(_avatarPath(session), 'foto.jpg', upload, method: 'PUT');
      _avatar = (result as Map<String, dynamic>)['avatar'] as String;
      if (widget.member == null) await session.refresh();
    });
    if (mounted) setState(() => _avatarBusy = false);
    if (ok) messenger.showSnackBar(const SnackBar(content: Text('Foto gespeichert')));
  }

  /// The own photos of the other families, to take one over; none for a managed member.
  List<Family> _photosElsewhere(AppSession session) => widget.member != null
      ? const []
      : [
          for (final family in session.families)
            if (family.id != session.current?.id && family.avatar.isNotEmpty) family,
        ];

  Future<void> _copyAvatar() async {
    final session = SessionScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final source = await showDialog<Family>(
      context: context,
      builder: (context) => SimpleDialog(
        key: const Key('avatar-copy-dialog'),
        title: const Text('Foto aus anderem Kreis'),
        children: [
          for (final family in _photosElsewhere(session))
            ListTile(
              key: Key('avatar-copy-${family.id}'),
              contentPadding: const EdgeInsets.symmetric(horizontal: 24),
              leading: UserAvatar(family.memberName, color: family.color, photo: family.avatar, radius: 24),
              title: Text(family.name),
              subtitle: Text(family.type.label),
              onTap: () => Navigator.of(context).pop(family),
            ),
        ],
      ),
    );
    if (source == null || !mounted) return;
    setState(() => _avatarBusy = true);
    final ok = await guarded(context, () async {
      final result = await session.api.post('${session.familyPath}/profile/avatar/copy', {'family_id': source.id});
      _avatar = (result as Map<String, dynamic>)['avatar'] as String;
      await session.refresh();
    });
    if (mounted) setState(() => _avatarBusy = false);
    if (ok) messenger.showSnackBar(SnackBar(content: Text('Foto aus ${source.name} übernommen')));
  }

  Future<void> _removeAvatar() async {
    final session = SessionScope.of(context);
    if (!await confirm(
      context,
      widget.member == null
          ? 'Dein Profilfoto in diesem Kreis entfernen? Dann siehst du wieder deine Initialen.'
          : 'Das Profilfoto entfernen? Dann sind wieder die Initialen zu sehen.',
      action: 'Entfernen',
    )) {
      return;
    }
    if (!mounted) return;
    setState(() => _avatarBusy = true);
    final ok = await guarded(context, () async {
      await session.api.delete(_avatarPath(session));
      _avatar = '';
      if (widget.member == null) await session.refresh();
    });
    if (mounted) setState(() => _avatarBusy = false);
    if (ok && mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Foto entfernt')));
  }

  Widget _avatarRow(BuildContext context, AppSession session) {
    final avatar = _currentAvatar(session);
    return Row(
      children: [
        Stack(
          alignment: Alignment.center,
          children: [
            UserAvatar(_name.text, color: _color, photo: avatar, radius: 40),
            if (_avatarBusy)
              const SizedBox.square(
                key: Key('avatar-busy'),
                dimension: 80,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
          ],
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                key: const Key('avatar-change'),
                onPressed: _avatarBusy ? null : _changeAvatar,
                icon: const Icon(Icons.photo_camera_outlined),
                label: Text(avatar.isEmpty ? 'Foto hinzufügen' : 'Foto ändern'),
              ),
              if (_photosElsewhere(session).isNotEmpty)
                OutlinedButton.icon(
                  key: const Key('avatar-copy'),
                  onPressed: _avatarBusy ? null : _copyAvatar,
                  icon: const Icon(Icons.collections_outlined),
                  label: const Text('Foto aus anderem Kreis'),
                ),
              if (avatar.isNotEmpty)
                TextButton(
                  key: const Key('avatar-remove'),
                  onPressed: _avatarBusy ? null : _removeAvatar,
                  child: const Text('Foto entfernen'),
                ),
              if (_avatarBusy)
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: LinearProgressIndicator(key: Key('avatar-progress')),
                ),
            ],
          ),
        ),
      ],
    );
  }

  String _savedColor = '';
  bool _nameMissing = false;
  bool _saving = false;

  /// Set once the profile has loaded; until then there is nothing to lose or save.
  String? _initial;

  @override
  void dispose() {
    _name.dispose();
    _familyRole.dispose();
    _contactEmail.dispose();
    for (final field in _fields) {
      field.controller.dispose();
    }
    super.dispose();
  }

  void _fill(Map<String, dynamic> profile) {
    if (_initial != null) return;
    _name.text = profile['name'] as String;
    _familyRole.text = profile['family_role'] as String;
    _contactEmail.text = profile['contact_email'] as String;
    _birthday = DateTime.tryParse(profile['birthday'] as String);
    for (final field in (profile['fields'] as List).cast<Map<String, dynamic>>()) {
      _fields.add(_ExtraField(field['kind'] as String, field['value'] as String));
    }
    _savedColor = _color;
    _initial = _snapshot();
  }

  Map<String, Object> _body() {
    final birthday = _birthday;
    return {
      'name': _name.text.trim(),
      'family_role': _familyRole.text.trim(),
      'contact_email': _contactEmail.text.trim(),
      'birthday': birthday == null ? '' : dateKey(birthday),
      'fields': [
        for (final field in _fields) {'kind': field.kind, 'value': field.controller.text.trim()},
      ],
    };
  }

  /// A field that stayed empty is not saved, so it is no change either.
  String _snapshot() {
    final body = _body();
    return jsonEncode({
      ...body,
      'fields': [
        for (final field in body['fields'] as List<Map<String, String>>)
          if (field['value']!.isNotEmpty) field,
      ],
      'color': _color,
    });
  }

  Future<void> _save() async {
    if (_saving || _initial == null) return;
    if (_name.text.trim().isEmpty) {
      setState(() => _nameMissing = true);
      return;
    }
    final session = SessionScope.of(context);
    final navigator = Navigator.of(context);
    setState(() => _saving = true);
    final ok = await guarded(context, () async {
      await session.api.put('${_memberPath(session)}/profile', _body());
      if (_color != _savedColor) {
        await session.api.put('${_memberPath(session)}/color', {'color': _color});
      }
      await session.refresh();
    });
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) navigator.pop(true);
  }

  Future<void> _leaveFamily(Family family) async {
    final session = SessionScope.of(context);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    List<Map<String, dynamic>>? others;
    var formerCount = 0;
    await guarded(context, () async {
      final data = await session.api.get('${session.familyPath}/members');
      formerCount = ((data['former'] as List?) ?? const []).length;
      others = [
        for (final member in (data['members'] as List).cast<Map<String, dynamic>>())
          if (member['id'] != session.userId) member,
      ];
    });
    final people = others;
    if (people == null || !mounted) return;

    // The last admin cannot leave others without anyone in charge.
    if (family.isAdmin && people.isNotEmpty && !people.any((member) => member['is_admin'] == true)) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Du bist der letzte Admin'),
          content: Text(
            'Solange es in ${family.name} weitere Mitglieder gibt, kannst du den Kreis nicht verlassen. '
            // Nobody without an address can become an admin, so the usual advice would lead nowhere.
            '${people.every((member) => member['managed'] == true) ? 'Die anderen haben keine E-Mail-Adresse und können deshalb kein Admin werden. '
                      'Gib einem von ihnen unter Verwaltung → Mitglieder eine E-Mail-Adresse und mache es zum Admin, oder lösche sie dort.' : 'Mache zuerst ein anderes Mitglied zum Admin.'}',
          ),
          actions: [
            FilledButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
          ],
        ),
      );
      return;
    }

    // Nobody could look after those who left, or ever let them back in.
    if (family.isAdmin && formerCount > 0 && !people.any((member) => member['is_admin'] == true)) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Du bist der letzte Admin'),
          content: Text(
            'In ${family.name} gibt es noch Mitglieder, die den Kreis verlassen haben. '
            'Lösche sie zuerst unter Verwaltung → Mitglieder endgültig. Erst dann kannst du den Kreis verlassen.',
          ),
          actions: [
            FilledButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
          ],
        ),
      );
      return;
    }

    final deleteData = await showDialog<bool>(
      context: context,
      builder: (_) => _LeaveDialog(family: family, alone: people.isEmpty),
    );
    if (deleteData == null || !mounted) return;
    final ok = await guarded(context, () async {
      await session.api.post('${session.familyPath}/leave', {'delete_data': deleteData});
      await session.refresh();
    });
    if (!ok) return;
    navigator.popUntil((route) => route.isFirst);
    messenger.showSnackBar(SnackBar(content: Text('Du hast ${family.name} verlassen.')));
  }

  /// Going back only asks if there is something to lose.
  Future<void> _leave() async {
    final navigator = Navigator.of(context);
    final changed = _initial != null && _snapshot() != _initial;
    if (changed && !await confirm(context, 'Änderungen verwerfen?', action: 'Verwerfen', cancel: 'Weiter bearbeiten')) return;
    if (mounted) navigator.pop();
  }

  Widget _heading(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 12),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
  );

  Widget _fieldRow(_ExtraField field) => Padding(
    key: ObjectKey(field),
    padding: const EdgeInsets.only(top: 16),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: TextField(
            controller: field.controller,
            autofocus: field.isNew,
            keyboardType: field.keyboard,
            minLines: 1,
            maxLines: field.kind == 'address' ? 4 : 1,
            maxLength: 500,
            decoration: InputDecoration(labelText: profileFieldLabels[field.kind], counterText: ''),
          ),
        ),
        IconButton(
          tooltip: 'Feld entfernen',
          icon: const Icon(Icons.close),
          onPressed: () => setState(() {
            _fields.remove(field);
            // The field may still be on its way out of the tree this frame.
            WidgetsBinding.instance.addPostFrameCallback((_) => field.controller.dispose());
          }),
        ),
      ],
    ),
  );

  Widget _addField() => Padding(
    padding: const EdgeInsets.only(top: 16),
    child: Align(
      alignment: Alignment.centerLeft,
      child: MenuAnchor(
        menuChildren: [
          for (final entry in profileFieldLabels.entries)
            MenuItemButton(
              onPressed: () => setState(() => _fields.add(_ExtraField(entry.key, '', isNew: true))),
              child: Text(entry.value),
            ),
        ],
        builder: (context, controller, _) => OutlinedButton.icon(
          key: const Key('add-profile-field'),
          onPressed: () => controller.isOpen ? controller.close() : controller.open(),
          icon: const Icon(Icons.add),
          label: const Text('Weitere Felder hinzufügen'),
        ),
      ),
    ),
  );

  Widget _form(BuildContext context, AppSession session, Family family, _ProfileData data) {
    _fill(data.profile);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        Text('Diese Angaben gelten im Kreis ${family.name}.', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 16),
        _avatarRow(context, session),
        const SizedBox(height: 24),
        TextField(
          key: const Key('profile-name'),
          controller: _name,
          maxLength: 100,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(
            labelText: 'Name *',
            counterText: '',
            errorText: _nameMissing ? 'Bitte einen Namen eingeben' : null,
          ),
          onChanged: (_) {
            if (_nameMissing) setState(() => _nameMissing = false);
          },
        ),
        const SizedBox(height: 16),
        TextField(
          key: const Key('profile-family-role'),
          controller: _familyRole,
          maxLength: 200,
          decoration: InputDecoration(
            labelText: family.type.isFamily ? 'Familienrolle' : 'Rolle im Kreis',
            counterText: '',
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          key: const Key('profile-contact-email'),
          controller: _contactEmail,
          maxLength: 200,
          keyboardType: TextInputType.emailAddress,
          decoration: InputDecoration(
            labelText: 'E-Mail-Adresse',
            counterText: '',
            // Someone else has no registration to take it from, and neither has
            // someone logged in without an address.
            suffixIcon: widget.member != null || session.isManaged
                ? null
                : IconButton(
                    tooltip: 'Adresse aus der Registrierung einfügen',
                    icon: const Icon(Icons.content_paste),
                    onPressed: () => _contactEmail.text = session.userEmail,
                  ),
          ),
        ),
        const SizedBox(height: 16),
        DateField(
          label: 'Geburtstag',
          value: _birthday,
          clearable: true,
          onChanged: (date) => setState(() => _birthday = date),
        ),
        for (final field in _fields) _fieldRow(field),
        _addField(),
        _heading(context, 'Profilfarbe'),
        if (widget.member != null || family.mayChangeOwnColor)
          ColorChooser(
            colors: data.colors,
            singleList: true,
            selected: _color,
            onSelected: (color) => setState(() => _color = color),
          )
        else
          Row(
            children: [
              ColorDot(_color),
              const SizedBox(width: 12),
              const Expanded(child: Text('Deine Profilfarbe kann nur ein Admin ändern.')),
            ],
          ),
      ],
    );
  }

  /// Down at the foot of the page, as signing out is in the profile.
  Widget _leaveFooter(BuildContext context, Family family) {
    final error = Theme.of(context).colorScheme.error;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Divider(height: 1),
        ListTile(
          key: const Key('leave-family'),
          textColor: error,
          iconColor: error,
          leading: const Icon(Icons.exit_to_app),
          title: Text('Den Kreis ${family.name} verlassen'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _leaveFamily(family),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    final family = session.current;
    // Signing out or leaving ends the circle just before this page closes.
    if (family == null) return const SizedBox.shrink();
    final color = _color.isEmpty ? null : parseHexColor(_color);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: color,
          foregroundColor: color == null ? null : readableOn(color),
          // Stays the chosen color while the form scrolls below it.
          scrolledUnderElevation: color == null ? null : 0,
          title: const Text('Profil bearbeiten'),
          actions: [
            IconButton(
              tooltip: 'Speichern',
              icon: const Icon(Icons.check),
              onPressed: _saving ? null : _save,
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: AsyncView<_ProfileData>(
                  load: () async {
                    final results = await Future.wait([
                      session.api.get('${_memberPath(session)}/profile'),
                      session.api.get('${session.familyPath}/colors'),
                    ]);
                    return _ProfileData(results[0] as Map<String, dynamic>, results[1] as Map<String, dynamic>);
                  },
                  builder: (context, data) => _form(context, session, family, data),
                ),
              ),
              // Without an address only an admin can take someone out, for good.
              if (widget.member == null && !session.isManaged) _leaveFooter(context, family),
            ],
          ),
        ),
      ),
    );
  }
}
