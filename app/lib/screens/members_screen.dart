import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../common.dart';
import '../session.dart';
import 'profile_edit_screen.dart';

/// Everyone in the family with name and role; a tap shows their profile. Managing
/// them is the administration's, see SettingsScreen.
class MembersScreen extends StatelessWidget {
  const MembersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    final family = session.current;
    // Leaving the family ends it just before this page closes.
    if (family == null) return const SizedBox.shrink();
    return Scaffold(
      appBar: _familyAppBar(family, Text(family.type.label)),
      body: AsyncView<Map<String, dynamic>>(
        load: () async => await session.api.get('${session.familyPath}/members') as Map<String, dynamic>,
        builder: (context, data) {
          final members = (data['members'] as List).cast<Map<String, dynamic>>();
          return ListView(
            children: [
              for (final member in members)
                ListTile(
                  key: Key('member-${member['id']}'),
                  leading: UserAvatar(member['name'] as String, color: member['color'] as String? ?? '', photo: member['avatar'] as String? ?? ''),
                  title: Text(member['name'] as String),
                  subtitle: Text(memberRoleLabel(family.type, member)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => MemberProfileScreen(member: member)),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// The app bar in the color of the family, as on the dashboard.
AppBar _familyAppBar(Family family, Widget title, {List<Widget>? actions}) {
  final header = familyHeaderColors(family);
  return AppBar(
    backgroundColor: header.background,
    foregroundColor: header.foreground,
    // Keeps the color steady instead of tinting it once the page scrolls.
    scrolledUnderElevation: header.background == null ? null : 0,
    title: title,
    actions: actions,
  );
}

/// "Eltern, Admin" or "Kind": the role of a member as GET members lists it.
String memberRoleLabel(FamilyType type, Map<String, dynamic> member) =>
    type.roleLabel(member['role'] as String) + (member['is_admin'] == true ? ', Admin' : '');

/// What a member tells about themselves in this family. Their own page has the
/// button to change it, with the same form as in the profile.
class MemberProfileScreen extends StatefulWidget {
  const MemberProfileScreen({super.key, required this.member});

  /// The member as GET members lists them.
  final Map<String, dynamic> member;

  @override
  State<MemberProfileScreen> createState() => _MemberProfileScreenState();
}

class _MemberProfileScreenState extends State<MemberProfileScreen> {
  final _view = GlobalKey<AsyncViewState<Map<String, dynamic>>>();

  Future<void> _edit() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ProfileEditScreen()));
    _view.currentState?.reload();
  }

  Widget _entry(BuildContext context, IconData icon, String label, String value) => ListTile(
    leading: Icon(icon),
    title: Text(value),
    subtitle: Text(label),
  );

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    final family = session.current;
    if (family == null) return const SizedBox.shrink();
    final member = widget.member;
    final isOwn = member['id'] == session.userId;
    final path = '${session.familyPath}/members/${member['id']}/profile';
    return Scaffold(
      appBar: _familyAppBar(
        family,
        const Text('Profil'),
        actions: [
          if (isOwn)
            IconButton(
              key: const Key('member-profile-edit'),
              tooltip: 'Profil bearbeiten',
              icon: const Icon(Icons.edit_outlined),
              onPressed: _edit,
            ),
        ],
      ),
      body: AsyncView<Map<String, dynamic>>(
        key: _view,
        load: () async => await session.api.get(path) as Map<String, dynamic>,
        builder: (context, profile) {
          final name = profile['name'] as String? ?? member['name'] as String;
          // After editing the own profile, the own color is the one in the session.
          final color = isOwn ? family.color : member['color'] as String? ?? '';
          final familyRole = profile['family_role'] as String? ?? '';
          final contactEmail = profile['contact_email'] as String? ?? '';
          final birthday = profile['birthday'] as String? ?? '';
          final fields = [
            for (final field in profile['fields'] as List? ?? const [])
              if (((field as Map)['value'] as String? ?? '').trim().isNotEmpty) field,
          ];
          final details = [
            if (familyRole.isNotEmpty)
              _entry(context, Icons.badge_outlined, family.type.isFamily ? 'Familienrolle' : 'Rolle im Kreis', familyRole),
            if (contactEmail.isNotEmpty) _entry(context, Icons.mail_outline, 'E-Mail-Adresse', contactEmail),
            if (birthday.isNotEmpty)
              _entry(context, Icons.cake_outlined, 'Geburtstag', dateFormat.format(DateTime.parse(birthday))),
            for (final field in fields)
              _entry(
                context,
                switch (field['kind']) {
                  'phone' || 'work_phone' => Icons.phone_outlined,
                  'mobile' => Icons.smartphone_outlined,
                  'email' => Icons.alternate_email,
                  'address' => Icons.home_outlined,
                  _ => Icons.notes_outlined,
                },
                profileFieldLabels[field['kind']] ?? 'Sonstige',
                field['value'] as String,
              ),
          ];
          return ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              ListTile(
                key: const Key('member-profile-head'),
                contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                leading: _LargeAvatar(
                  name: name,
                  color: color,
                  // The own photo may have just changed; the session has the new one.
                  photo: isOwn ? family.avatar : member['avatar'] as String? ?? '',
                  path: '${session.familyPath}/members/${member['id']}/avatar',
                ),
                title: Text(name, style: Theme.of(context).textTheme.titleLarge),
                subtitle: Text(memberRoleLabel(family.type, member)),
              ),
              const Divider(),
              if (details.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Keine weiteren Angaben im Profil.'),
                )
              else
                ...details,
            ],
          );
        },
      ),
    );
  }
}

/// The member's photo in the size of the profile page: the small one at once, the
/// large one as soon as it has loaded.
class _LargeAvatar extends StatefulWidget {
  const _LargeAvatar({required this.name, required this.color, required this.photo, required this.path});

  final String name;
  final String color;
  final String photo;
  final String path;

  @override
  State<_LargeAvatar> createState() => _LargeAvatarState();
}

class _LargeAvatarState extends State<_LargeAvatar> {
  Uint8List? _large;
  String? _loadedFor;

  void _load() {
    final photo = widget.photo;
    if (photo.isEmpty || _loadedFor == photo) return;
    _loadedFor = photo;
    _large = null;
    SessionScope.of(context).api.getBytes(widget.path).then((bytes) {
      if (mounted && _loadedFor == photo) setState(() => _large = bytes);
    }, onError: (_) {
      // The small photo stays; it is there already.
    });
  }

  /// The photo over the whole screen; it waits for the large one if it is not there yet.
  Future<void> _openFull() async {
    final api = SessionScope.of(context).api;
    final large = _large;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => _FullPhotoScreen(name: widget.name, photo: large != null ? Future.value(large) : api.getBytes(widget.path)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    _load();
    final large = _large;
    final avatar = large == null || widget.photo.isEmpty
        ? UserAvatar(widget.name, color: widget.color, photo: widget.photo, radius: 32)
        : CircleAvatar(key: const ValueKey('avatar-large'), radius: 32, foregroundImage: MemoryImage(large));
    // Without a photo there is nothing bigger to show.
    if (widget.photo.isEmpty) return avatar;
    return Tooltip(
      message: 'Foto ansehen',
      child: InkWell(
        key: const Key('avatar-open'),
        customBorder: const CircleBorder(),
        onTap: _openFull,
        child: avatar,
      ),
    );
  }
}

/// A member's photo filling the screen, to zoom with fingers or the wheel.
class _FullPhotoScreen extends StatelessWidget {
  const _FullPhotoScreen({required this.name, required this.photo});

  final String name;
  final Future<Uint8List> photo;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('avatar-full'),
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(name),
      ),
      body: FutureBuilder<Uint8List>(
        future: photo,
        builder: (context, snapshot) {
          final bytes = snapshot.data;
          if (snapshot.hasError) {
            return const Center(
              child: Text('Das Foto ließ sich nicht laden.', style: TextStyle(color: Colors.white)),
            );
          }
          if (bytes == null) return const Center(child: CircularProgressIndicator());
          return InteractiveViewer(
            maxScale: 4,
            child: Center(child: Image.memory(bytes, fit: BoxFit.contain, width: double.infinity)),
          );
        },
      ),
    );
  }
}
