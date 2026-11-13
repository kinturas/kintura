import 'package:flutter/material.dart';

import '../common.dart';
import '../session.dart';
import 'color_management_tab.dart';
import 'email_code_dialog.dart';
import 'profile_edit_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _view = GlobalKey<AsyncViewState<Map<String, dynamic>>>();

  Future<void> _deleteFormer(Map<String, dynamic> person) async {
    final session = SessionScope.of(context);
    final really = await confirm(
      context,
      '${person['name']} endgültig löschen?',
      message: 'Das Profil und alle Daten in diesem Kreis werden gelöscht und lassen sich nicht wiederherstellen. '
          'Gemeinsame Termine und Listen bleiben für die anderen.',
    );
    if (!really || !mounted) return;
    final ok = await guarded(context, () => session.api.delete('${session.familyPath}/former/${person['id']}'));
    if (ok) _view.currentState?.reload();
  }

  /// With a [former] member, it starts from what is known about them.
  Future<void> _invite({Map<String, dynamic>? former}) async {
    final session = SessionScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => _InviteScreen(
          session.current!.type,
          former: former,
          onSave: (invitation) async {
            final ok = await guarded(context, () async {
              final result = await session.api.post(
                '${session.familyPath}/invitations',
                invitation,
              );
              if (result['mail_sent'] != true) {
                messenger.showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Die Einladungsmail konnte nicht versendet werden. '
                      'Die Person kann sich trotzdem mit dieser Adresse anmelden.',
                    ),
                  ),
                );
              }
            });
            if (ok) _view.currentState?.reload();
            return ok;
          },
        ),
      ),
    );
  }

  Future<void> _deleteInvitation(Map<String, dynamic> invitation) async {
    final session = SessionScope.of(context);
    await guarded(
      context,
      () => session.api.delete(
        '${session.familyPath}/invitations/${invitation['id']}',
      ),
    );
    _view.currentState?.reload();
  }

  Future<void> _resendInvitation(Map<String, dynamic> invitation) async {
    final session = SessionScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final ok = await guarded(
      context,
      () => session.api.post('${session.familyPath}/invitations/${invitation['id']}/resend', {}),
    );
    if (ok) {
      messenger.showSnackBar(SnackBar(content: Text('Einladung an ${invitation['email']} gesendet.')));
    }
  }

  Future<void> _enterInvitationCode(Map<String, dynamic> invitation) async {
    final session = SessionScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final joined = await showDialog<bool>(
      context: context,
      builder: (_) => InvitationCodeDialog(
        email: invitation['email'] as String,
        confirmPath: '${session.familyPath}/invitations/${invitation['id']}/confirm',
      ),
    );
    if (joined != true) return;
    messenger.showSnackBar(SnackBar(content: Text('${invitation['email']} wurde aufgenommen.')));
    _view.currentState?.reload();
  }

  Future<void> _editMember(Map<String, dynamic> member) async {
    final session = SessionScope.of(context);
    final path = '${session.familyPath}/members/${member['id']}';
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => _MemberScreen(
          session.current!.type,
          member,
          isSelf: member['id'] == session.userId,
          onLeftPage: () => _view.currentState?.reload(),
          onSave: (changes) async {
            final ok = await guarded(context, () async {
              await session.api.put(path, {'role': changes['role'], 'is_admin': changes['is_admin']});
              if (changes['color'] != member['color'] ||
                  changes['can_change_color'] != (member['can_change_color'] ?? true)) {
                await session.api.put('$path/color', {
                  'color': changes['color'],
                  'can_change_color': changes['can_change_color'],
                });
              }
              await session.refresh();
            });
            if (ok) _view.currentState?.reload();
            return ok;
          },
        ),
      ),
    );
  }

  Future<void> _removeMember(Map<String, dynamic> member) async {
    final session = SessionScope.of(context);
    final navigator = Navigator.of(context);
    final isSelf = member['id'] == session.userId;
    // Without an address nobody could invite them back, so there is no keeping them.
    final managed = member['managed'] == true;
    final question = managed
        ? '${member['name']} endgültig löschen?'
        : isSelf
        ? '„${session.current!.name}“ verlassen?'
        : '${member['name']} ${session.current!.type.fromThe} entfernen?';
    final action = managed
        ? 'Löschen'
        : isSelf
        ? 'Verlassen'
        : 'Entfernen';
    final message = managed
        ? 'Das Profil und alle Daten dieses Benutzers werden gelöscht und lassen sich nicht wiederherstellen. '
              'Gemeinsame Termine und Listen bleiben für die anderen.'
        : null;
    if (!await confirm(context, question, action: action, message: message) || !mounted) return;
    final ok = await guarded(context, () async {
      await session.api.delete('${session.familyPath}/members/${member['id']}');
      if (isSelf) await session.refresh();
    });
    if (!ok) return;
    if (isSelf) {
      navigator.popUntil((route) => route.isFirst);
    } else {
      _view.currentState?.reload();
    }
  }

  Future<void> _addManaged() async {
    final session = SessionScope.of(context);
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => _ManagedScreen(
          session.current!.type,
          onSave: (member) async {
            final ok = await guarded(
              context,
              () => session.api.post('${session.familyPath}/members', member),
            );
            if (ok) _view.currentState?.reload();
            return ok;
          },
        ),
      ),
    );
  }

  String _describe(FamilyType type, Map<String, dynamic> person) {
    final role = type.roleLabel(person['role'] as String);
    if (person['managed'] == true) return '$role · ohne E-Mail';
    return person['is_admin'] == true ? '$role (Admin)' : role;
  }

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    final family = session.current;
    // Leaving the last family clears it just before this page closes.
    if (family == null) return const SizedBox.shrink();
    final header = familyHeaderColors(family);
    final onHeader = header.foreground;
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: header.background,
          foregroundColor: onHeader,
          scrolledUnderElevation: header.background == null ? null : 0,
          title: const Text('Einstellungen'),
          bottom: TabBar(
            // Four names do not fit next to each other on a phone.
            isScrollable: true,
            // On the family's color the theme's tab colors may not be readable.
            labelColor: onHeader,
            unselectedLabelColor: onHeader?.withValues(alpha: 0.72),
            indicatorColor: onHeader,
            dividerColor: onHeader?.withValues(alpha: 0.2),
            tabs: [
              const Tab(text: 'Mitglieder'),
              Tab(text: family.type.label),
              const Tab(text: 'Kategorien'),
              const Tab(text: 'Farben'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            AsyncView<Map<String, dynamic>>(
              key: _view,
              load: () async =>
                  await session.api.get('${session.familyPath}/members') as Map<String, dynamic>,
              builder: (context, data) {
                final members = (data['members'] as List).cast<Map<String, dynamic>>();
                final invitations = (data['invitations'] as List).cast<Map<String, dynamic>>();
                final former = ((data['former'] as List?) ?? const []).cast<Map<String, dynamic>>();
                return ListView(
                  children: [
                    for (final member in members)
                      ListTile(
                        leading: UserAvatar(
                          member['name'] as String,
                          color: member['color'] as String,
                        ),
                        title: Text(member['name'] as String),
                        subtitle: Text(_describe(family.type, member)),
                        onTap: family.isAdmin ? () => _editMember(member) : null,
                        // Admins remove others, everyone else can only leave. Without an
                        // address leaving would be the end of it, so that is up to an admin.
                        trailing: family.isAdmin != (member['id'] == session.userId) && !session.isManaged
                            ? IconButton(
                                tooltip: member['id'] == session.userId
                                    ? '${family.type.label} verlassen'
                                    : 'Entfernen',
                                icon: Icon(
                                  member['id'] == session.userId
                                      ? Icons.logout
                                      : Icons.person_remove_outlined,
                                ),
                                onPressed: () => _removeMember(member),
                              )
                            : null,
                      ),
                    for (final invitation in invitations) ...[
                      ListTile(
                        leading: (invitation['color'] as String? ?? '').isEmpty
                            ? const Icon(Icons.mail_outline)
                            : ColorDot(invitation['color'] as String),
                        title: Text(invitation['email'] as String),
                        subtitle: Text('Eingeladen · ${_describe(family.type, invitation)}'),
                        trailing: IconButton(
                          tooltip: 'Einladung zurückziehen',
                          icon: const Icon(Icons.close),
                          onPressed: () => _deleteInvitation(invitation),
                        ),
                      ),
                      // Words rather than two more icons: next to the address they would
                      // leave it little room on a phone, and what they do is not obvious.
                      Padding(
                        padding: const EdgeInsets.only(left: 56, right: 16, bottom: 8),
                        child: Wrap(
                          spacing: 8,
                          children: [
                            TextButton.icon(
                              key: Key('invitation-resend-${invitation['id']}'),
                              onPressed: () => _resendInvitation(invitation),
                              icon: const Icon(Icons.send_outlined),
                              label: const Text('Erneut senden'),
                            ),
                            TextButton.icon(
                              key: Key('invitation-enter-code-${invitation['id']}'),
                              onPressed: () => _enterInvitationCode(invitation),
                              icon: const Icon(Icons.pin_outlined),
                              label: const Text('Code eingeben'),
                            ),
                          ],
                        ),
                      ),
                    ],
                    for (final person in former)
                      ListTile(
                        key: Key('former-${person['id']}'),
                        enabled: false,
                        leading: const Icon(Icons.person_off_outlined),
                        title: Text(person['name'] as String),
                        subtitle: Text('Gelöscht · ${person['email']}'),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Wieder einladen',
                              icon: const Icon(Icons.person_add_outlined),
                              onPressed: () => _invite(former: person),
                            ),
                            IconButton(
                              tooltip: 'Endgültig löschen',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => _deleteFormer(person),
                            ),
                          ],
                        ),
                      ),
                    if (family.isAdmin)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          children: [
                            OutlinedButton.icon(
                              onPressed: _invite,
                              icon: const Icon(Icons.person_add_outlined),
                              label: const Text('Mitglied einladen'),
                            ),
                            OutlinedButton.icon(
                              onPressed: _addManaged,
                              icon: const Icon(Icons.person_outline),
                              label: const Text('Benutzer ohne E-Mail hinzufügen'),
                            ),
                          ],
                        ),
                      ),
                  ],
                );
              },
            ),
            _FamilyTab(family),
            const CategoriesTab(),
            const ColorsTab(),
          ],
        ),
      ),
    );
  }
}

class _FamilyTab extends StatefulWidget {
  const _FamilyTab(this.family);

  final Family family;

  @override
  State<_FamilyTab> createState() => _FamilyTabState();
}

class _FamilyTabState extends State<_FamilyTab> {
  late final _name = TextEditingController(text: widget.family.name);
  late FamilyType _type = widget.family.type;
  late String _color = widget.family.familyColor;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final session = SessionScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final ok = await guarded(context, () async {
      await session.api.put(session.familyPath, {
        'name': _name.text.trim(),
        'type': _type.name,
        'color': _color,
      });
      await session.refresh();
    });
    if (ok) messenger.showSnackBar(const SnackBar(content: Text('Gespeichert')));
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.family.isAdmin) {
      return ListView(
        children: [
          ListTile(
            leading: Icon(widget.family.type.icon),
            title: Text(widget.family.name),
            subtitle: Text(widget.family.type.label),
            trailing: widget.family.familyColor.isEmpty ? null : ColorDot(widget.family.familyColor),
          ),
        ],
      );
    }
    final session = SessionScope.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        FamilyTypeField(
          value: _type,
          onChanged: (type) => setState(() => _type = type),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _name,
          decoration: InputDecoration(labelText: _type.nameLabel),
        ),
        const SizedBox(height: 24),
        Text('Farbe', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          'Der Kopf des Dashboards färbt sich darin ein, für alle im Kreis.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        AsyncView<Map<String, dynamic>>(
          load: () async => await session.api.get('${session.familyPath}/colors') as Map<String, dynamic>,
          builder: (context, colors) => ColorChooser(
            key: const Key('family-color'),
            colors: colors,
            singleList: true,
            selected: _color,
            onSelected: (color) => setState(() => _color = color),
          ),
        ),
        const SizedBox(height: 24),
        FilledButton(onPressed: _save, child: const Text('Speichern')),
      ],
    );
  }
}

class _RoleFields extends StatelessWidget {
  const _RoleFields({
    required this.type,
    required this.role,
    required this.isAdmin,
    required this.onRole,
    required this.onAdmin,
    this.roleRequired = false,
    this.roleError,
    this.showAdmin = true,
  });

  /// Someone without an address can never log in, so they cannot be an admin either.
  final bool showAdmin;

  final FamilyType type;

  /// Null until one is chosen, which only happens for someone new.
  final String? role;
  final bool isAdmin;
  final ValueChanged<String> onRole;
  final bool roleRequired;
  final String? roleError;

  /// Null locks the switch: nobody can revoke their own admin flag.
  final ValueChanged<bool>? onAdmin;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        DropdownButtonFormField<String>(
          initialValue: role,
          // A long role name has to fit a narrow dialog on a phone.
          isExpanded: true,
          decoration: InputDecoration(
            labelText: roleRequired ? 'Rolle *' : 'Rolle',
            errorText: roleError,
          ),
          items: [
            for (final role in assignableRoles)
              DropdownMenuItem(
                value: role,
                child: Text(type.roleLabel(role), overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (role) => onRole(role!),
        ),
        if (showAdmin) ...[
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Admin'),
            subtitle: onAdmin == null
                ? const Text('Du kannst dir die Admin-Rechte nicht selbst entziehen.')
                : null,
            value: isAdmin,
            onChanged: onAdmin,
          ),
        ],
      ],
    );
  }
}

/// The page of a member or an invitation. It stays open if saving fails, so that
/// nothing that was entered is lost.
class _PersonPage extends StatefulWidget {
  const _PersonPage({
    required this.title,
    required this.saveLabel,
    required this.onSave,
    required this.children,
  });

  final String title;
  final String saveLabel;

  /// Returns whether saving worked.
  final Future<bool> Function() onSave;
  final List<Widget> children;

  @override
  State<_PersonPage> createState() => _PersonPageState();
}

class _PersonPageState extends State<_PersonPage> {
  bool _saving = false;

  Future<void> _save() async {
    if (_saving) return;
    final navigator = Navigator.of(context);
    setState(() => _saving = true);
    final ok = await widget.onSave();
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: widget.saveLabel,
            icon: const Icon(Icons.check),
            onPressed: _saving ? null : _save,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: widget.children,
      ),
    );
  }
}

class _MemberScreen extends StatefulWidget {
  const _MemberScreen(
    this.type,
    this.member, {
    required this.isSelf,
    required this.onSave,
    required this.onLeftPage,
  });

  final FamilyType type;
  final Map<String, dynamic> member;
  final bool isSelf;
  final Future<bool> Function(Map<String, Object> changes) onSave;

  /// The member changed in a way this page cannot show, so it closes.
  final VoidCallback onLeftPage;

  @override
  State<_MemberScreen> createState() => _MemberScreenState();
}

class _MemberScreenState extends State<_MemberScreen> {
  late String _role = widget.member['role'] as String;
  late bool _isAdmin = widget.member['is_admin'] as bool;
  late String _color = widget.member['color'] as String;
  late bool _canChangeColor = widget.member['can_change_color'] as bool? ?? true;

  bool get _managed => widget.member['managed'] == true;

  void _close() {
    widget.onLeftPage();
    Navigator.of(context).pop();
  }

  Future<void> _addEmail() async {
    final session = SessionScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final name = widget.member['name'] as String;
    final added = await showDialog<bool>(
      context: context,
      builder: (_) => EmailCodeDialog(
        title: 'E-Mail hinzufügen',
        label: 'E-Mail-Adresse',
        requestPath: '${session.familyPath}/members/${widget.member['id']}/email',
        hint: 'An diese Adresse geht ein Code. Mit ihm wird sie $name zugeordnet. Hat sie schon ein Konto in einem anderen Kreis, '
            'übernimmt dieses Konto das Mitglied mit allem, was bisher dazu gehört.',
        warning: 'Bitte sei dir sicher, dass die Adresse stimmt: Wer dieses Postfach liest, meldet sich künftig als $name an '
            'und sieht alles, was $name hier sieht.',
      ),
    );
    if (added != true || !mounted) return;
    messenger.showSnackBar(SnackBar(content: Text('$name kann sich jetzt anmelden.')));
    _close();
  }

  Future<void> _editProfile() async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => ProfileEditScreen(member: widget.member)),
    );
    if (saved == true && mounted) _close();
  }

  Future<void> _createLoginCode() async {
    final session = SessionScope.of(context);
    String? code;
    await guarded(context, () async {
      final result = await session.api.post('${session.familyPath}/members/${widget.member['id']}/login-code');
      code = result['code'] as String;
    });
    final created = code;
    if (created == null || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => LoginCodeDialog(name: widget.member['name'] as String, code: created),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    return _PersonPage(
      title: widget.member['name'] as String,
      saveLabel: 'Speichern',
      onSave: () => widget.onSave({
        'role': _role,
        'is_admin': _isAdmin,
        'color': _color,
        'can_change_color': _canChangeColor,
      }),
      children: [
        _RoleFields(
          type: widget.type,
          role: _role,
          isAdmin: _isAdmin,
          onRole: (role) => setState(() => _role = role),
          onAdmin: widget.isSelf ? null : (isAdmin) => setState(() => _isAdmin = isAdmin),
          showAdmin: !_managed,
        ),
        const SizedBox(height: 16),
        AsyncView<Map<String, dynamic>>(
          load: () async => await session.api.get('${session.familyPath}/colors') as Map<String, dynamic>,
          builder: (context, colors) => ProfileColorFields(
            colors: colors,
            color: _color,
            canChange: _canChangeColor,
            onColor: (color) => setState(() => _color = color),
            onCanChange: (on) => setState(() => _canChangeColor = on),
          ),
        ),
        if (_managed) ...[
          const SizedBox(height: 16),
          Text('Verwaltung', style: Theme.of(context).textTheme.titleSmall),
          ListTile(
            key: const Key('member-add-email'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.mail_outline),
            title: const Text('E-Mail hinzufügen'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _addEmail,
          ),
          ListTile(
            key: const Key('member-edit-profile'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.badge_outlined),
            title: const Text('Profil bearbeiten'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _editProfile,
          ),
          ListTile(
            key: const Key('member-login-code'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.key_outlined),
            title: const Text('Anmeldecode erstellen'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _createLoginCode,
          ),
        ],
      ],
    );
  }
}

/// Adds someone who has no address and cannot log in, like a small child.
class _ManagedScreen extends StatefulWidget {
  const _ManagedScreen(this.type, {required this.onSave});

  final FamilyType type;
  final Future<bool> Function(Map<String, Object> member) onSave;

  @override
  State<_ManagedScreen> createState() => _ManagedScreenState();
}

class _ManagedScreenState extends State<_ManagedScreen> {
  final _name = TextEditingController();
  String? _role;
  bool _nameMissing = false;
  bool _roleMissing = false;
  String _color = '';
  bool _canChangeColor = true;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    return _PersonPage(
      title: 'Benutzer ohne E-Mail hinzufügen',
      saveLabel: 'Hinzufügen',
      onSave: () async {
        final name = _name.text.trim();
        final role = _role;
        if (name.isEmpty || role == null) {
          setState(() {
            _nameMissing = name.isEmpty;
            _roleMissing = role == null;
          });
          return false;
        }
        return widget.onSave({
          'name': name,
          'role': role,
          'color': _color,
          'can_change_color': _canChangeColor,
        });
      },
      children: [
        const Text('Für jemanden ohne E-Mail-Adresse, zum Beispiel ein kleines Kind. Anmelden kann sich dieser Benutzer nur mit einem Code, den du für ihn erstellst. Eine Adresse lässt sich später ergänzen.'),
        const SizedBox(height: 16),
        TextField(
          key: const Key('managed-name'),
          controller: _name,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(
            labelText: 'Name *',
            errorText: _nameMissing ? 'Bitte einen Namen eingeben' : null,
          ),
          onChanged: (_) {
            if (_nameMissing) setState(() => _nameMissing = false);
          },
        ),
        const SizedBox(height: 16),
        _RoleFields(
          type: widget.type,
          role: _role,
          isAdmin: false,
          roleRequired: true,
          roleError: _roleMissing ? 'Bitte eine Rolle auswählen' : null,
          showAdmin: false,
          onRole: (role) => setState(() {
            _role = role;
            _roleMissing = false;
          }),
          onAdmin: null,
        ),
        const SizedBox(height: 16),
        AsyncView<Map<String, dynamic>>(
          load: () async => await session.api.get('${session.familyPath}/colors') as Map<String, dynamic>,
          builder: (context, colors) => ProfileColorFields(
            colors: colors,
            color: _color,
            canChange: _canChangeColor,
            onColor: (color) => setState(() => _color = color),
            onCanChange: (on) => setState(() => _canChangeColor = on),
          ),
        ),
      ],
    );
  }
}

class _InviteScreen extends StatefulWidget {
  const _InviteScreen(this.type, {required this.onSave, this.former});

  final FamilyType type;
  final Future<bool> Function(Map<String, Object> invitation) onSave;

  /// Someone who left and is asked back. Their address and color are known already.
  final Map<String, dynamic>? former;

  @override
  State<_InviteScreen> createState() => _InviteScreenState();
}

class _InviteScreenState extends State<_InviteScreen> {
  late final _email = TextEditingController(text: widget.former?['email'] as String?);
  /// Nothing is chosen in advance, so that nobody gets a role by accident.
  String? _role;
  bool _roleMissing = false;
  bool _emailMissing = false;
  bool _isAdmin = false;
  late String _color = widget.former?['color'] as String? ?? '';
  bool _canChangeColor = true;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    return _PersonPage(
      title: 'Mitglied einladen',
      saveLabel: 'Einladen',
      onSave: () async {
        final email = _email.text.trim();
        final role = _role;
        if (email.isEmpty || role == null) {
          setState(() {
            _emailMissing = email.isEmpty;
            _roleMissing = role == null;
          });
          return false;
        }
        return widget.onSave({
          'email': email,
          'role': role,
          'is_admin': _isAdmin,
          'color': _color,
          'can_change_color': _canChangeColor,
        });
      },
      children: [
        TextField(
          controller: _email,
          autofocus: true,
          keyboardType: TextInputType.emailAddress,
          decoration: InputDecoration(
            labelText: 'E-Mail-Adresse *',
            errorText: _emailMissing ? 'Bitte eine E-Mail-Adresse eingeben' : null,
          ),
          onChanged: (_) {
            if (_emailMissing) setState(() => _emailMissing = false);
          },
        ),
        const SizedBox(height: 16),
        _RoleFields(
          type: widget.type,
          role: _role,
          isAdmin: _isAdmin,
          roleRequired: true,
          roleError: _roleMissing ? 'Bitte eine Rolle auswählen' : null,
          onRole: (role) => setState(() {
            _role = role;
            _roleMissing = false;
          }),
          onAdmin: (isAdmin) => setState(() => _isAdmin = isAdmin),
        ),
        const SizedBox(height: 16),
        AsyncView<Map<String, dynamic>>(
          load: () async => await session.api.get('${session.familyPath}/colors') as Map<String, dynamic>,
          builder: (context, colors) => ProfileColorFields(
            colors: colors,
            color: _color,
            canChange: _canChangeColor,
            onColor: (color) => setState(() => _color = color),
            onCanChange: (on) => setState(() => _canChangeColor = on),
          ),
        ),
      ],
    );
  }
}
