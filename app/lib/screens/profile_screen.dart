import 'package:flutter/material.dart';

import '../common.dart';
import '../session.dart';
import 'about_screen.dart';
import 'email_code_dialog.dart';
import 'feedback_screen.dart';
import 'profile_edit_screen.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  Future<void> _changeEmail(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => const EmailCodeDialog(
        title: 'E-Mail-Adresse ändern',
        label: 'Neue E-Mail-Adresse',
        requestPath: '/api/me/email',
      ),
    );
    if (changed == true) {
      messenger.showSnackBar(const SnackBar(content: Text('Deine E-Mail-Adresse wurde geändert.')));
    }
  }

  Future<void> _setNotifications(BuildContext context, bool enabled) async {
    final session = SessionScope.of(context);
    await guarded(context, () async {
      await session.api.put('/api/me/notifications', {'enabled': enabled});
      await session.refresh();
    });
  }

  void _open(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  /// What applies to the user everywhere, not to one circle.
  List<Widget> _settings(BuildContext context, AppSession session) {
    final brightness = Theme.of(context).brightness;
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text('Einstellungen für alle Kreise', style: Theme.of(context).textTheme.titleSmall),
      ),
      // Both need a mailbox. An admin can add an address to someone without one.
      if (!session.isManaged) ...[
        ListTile(
          key: const Key('account-email'),
          leading: const Icon(Icons.mail_outline),
          title: const Text('E-Mail-Adresse'),
          subtitle: Text(session.userEmail),
          trailing: const Icon(Icons.edit_outlined),
          onTap: () => _changeEmail(context),
        ),
        SwitchListTile(
          key: const Key('notifications'),
          secondary: const Icon(Icons.notifications_none),
          title: const Text('Mitteilungen erhalten'),
          value: session.notifications,
          onChanged: (on) => _setNotifications(context, on),
        ),
      ],
      const _LaterTile(icon: Icons.tune, title: 'Benachrichtigungen verwalten'),
      ValueListenableBuilder(
        valueListenable: session.themeMode,
        builder: (context, themeMode, _) => Column(
          children: [
            SwitchListTile(
              key: const Key('dark-automatic'),
              secondary: const Icon(Icons.brightness_auto_outlined),
              title: const Text('Dunkelmodus automatisch'),
              subtitle: const Text('Folgt der Einstellung des Geräts'),
              value: themeMode == ThemeMode.system,
              // Taking over by hand starts with what is on the screen right now.
              onChanged: (on) => session.setThemeMode(
                on
                    ? ThemeMode.system
                    : brightness == Brightness.dark
                    ? ThemeMode.dark
                    : ThemeMode.light,
              ),
            ),
            if (themeMode != ThemeMode.system)
              SwitchListTile(
                key: const Key('dark-mode'),
                secondary: const Icon(Icons.dark_mode_outlined),
                title: const Text('Dunkelmodus'),
                value: themeMode == ThemeMode.dark,
                onChanged: (on) => session.setThemeMode(on ? ThemeMode.dark : ThemeMode.light),
              ),
          ],
        ),
      ),
      const _LaterTile(icon: Icons.help_outline, title: 'Hilfe'),
      ListTile(
        leading: const Icon(Icons.feedback_outlined),
        title: const Text('Feedback'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _open(context, const FeedbackScreen()),
      ),
      const _LaterTile(icon: Icons.language, title: 'Sprache'),
      ListTile(
        leading: const Icon(Icons.info_outline),
        title: const Text('Über'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _open(context, const AboutScreen()),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    final family = session.current;
    final color = family == null || family.color.isEmpty ? null : parseHexColor(family.color);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: color,
        foregroundColor: color == null ? null : readableOn(color),
        // Stays the color of the profile while the page scrolls below it.
        scrolledUnderElevation: color == null ? null : 0,
        title: const Text('Profil'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                children: [
                  if (family != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                      child: Text(
                        'Dein Profil im Kreis ${family.name}',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                  ListTile(
                    key: const Key('profile-tile'),
                    leading: UserAvatar(session.displayName, color: family?.color ?? ''),
                    title: Text(session.displayName),
                    subtitle: Text(session.isManaged ? 'Ohne E-Mail-Adresse' : session.userEmail),
                    trailing: family == null ? null : const Icon(Icons.edit_outlined),
                    onTap: family == null ? null : () => _open(context, const ProfileEditScreen()),
                  ),
                  const Divider(height: 1),
                  ..._settings(context, session),
                ],
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('Abmelden'),
              onTap: session.signOut,
            ),
          ],
        ),
      ),
    );
  }
}

/// A place for what is announced but not built yet.
class _LaterTile extends StatelessWidget {
  const _LaterTile({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      enabled: false,
      leading: Icon(icon),
      title: Text(title),
      subtitle: const Text('Kommt später'),
    );
  }
}
