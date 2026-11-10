import 'package:flutter/material.dart';

import '../common.dart';
import '../session.dart';
import 'calendar_screen.dart';
import 'files_screens.dart';
import 'lists_screen.dart';
import 'meals_screen.dart';
import 'messages_screen.dart';
import 'profile_screen.dart';
import 'settings_screen.dart';
import 'special_days_screen.dart';

class _Area {
  const _Area(this.title, this.subtitle, this.icon, this.color, this.page, {this.comingSoon = false});

  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final Widget page;

  /// Not released yet: the tile shows that and cannot be opened. To release an area,
  /// remove the flag from it in [_areasFor].
  final bool comingSoon;
}

List<_Area> _areasFor(FamilyType type) => [
  const _Area('Listen', 'Einkauf & Aufgaben', Icons.checklist, Color(0xFF2E7D5B), ListsScreen()),
  const _Area('Kalender', 'Termine', Icons.calendar_month, Color(0xFF3567B5), CalendarScreen()),
  const _Area('Dokumente', 'Wichtige Unterlagen', Icons.folder_outlined, Color(0xFF8A6D1F), DocumentsScreen(), comingSoon: true),
  const _Area('Mahlzeiten', 'Essensplaner', Icons.restaurant_menu, Color(0xFFC2571A), MealsScreen(), comingSoon: true),
  _Area('Nachrichten', type.chat, Icons.chat_bubble_outline, const Color(0xFF7B4FB0), const MessagesScreen(), comingSoon: true),
  const _Area('Fotos', 'Gemeinsame Bilder', Icons.photo_library_outlined, Color(0xFFB83E6F), PhotosScreen(), comingSoon: true),
  _Area('Einstellungen', type.label, Icons.settings_outlined, const Color(0xFF55636B), const SettingsScreen()),
  const _Area('Besondere Tage', 'Festtage & Gedenktage', Icons.celebration_outlined, Color(0xFF1E8A99), SpecialDaysScreen(), comingSoon: true),
];

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    final family = session.current;
    if (family == null) return const _NoFamilyScreen();
    final areas = _areasFor(family.type);
    return Scaffold(
      appBar: AppBar(
        title: const _FamilySwitcher(),
        actions: [
          IconButton(
            tooltip: 'Profil',
            icon: UserAvatar(session.displayName, color: family.color),
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const ProfileScreen())),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              sliver: SliverToBoxAdapter(
                child: Text(
                  'Hallo ${session.displayName}',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverGrid.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 240,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 1.1,
                ),
                itemCount: areas.length,
                itemBuilder: (context, index) => _AreaTile(areas[index]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AreaTile extends StatelessWidget {
  const _AreaTile(this.area);

  final _Area area;

  @override
  Widget build(BuildContext context) {
    // Deriving the colors from a scheme keeps tiles readable in dark mode.
    final colors = ColorScheme.fromSeed(
      seedColor: area.color,
      brightness: Theme.of(context).brightness,
    );
    final text = Theme.of(context).textTheme;
    return Card(
      elevation: 0,
      color: colors.primaryContainer,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: area.comingSoon
            ? null
            : () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => area.page)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(area.icon, size: 36, color: colors.onPrimaryContainer),
                  if (area.comingSoon) ...[
                    const Spacer(),
                    Flexible(
                      flex: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: colors.onPrimaryContainer,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          'Kommt bald',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.labelSmall?.copyWith(color: colors.primaryContainer),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const Spacer(),
              Text(
                area.title,
                style: text.titleMedium?.copyWith(
                  color: colors.onPrimaryContainer,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                area.subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.bodySmall?.copyWith(color: colors.onPrimaryContainer),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FamilySwitcher extends StatelessWidget {
  const _FamilySwitcher();

  static const _newFamily = '';

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    return PopupMenuButton<String>(
      tooltip: 'Kreis wechseln',
      position: PopupMenuPosition.under,
      onSelected: (id) {
        if (id == _newFamily) {
          showCreateFamilyDialog(context);
        } else {
          guarded(
            context,
            () => session.select(session.families.firstWhere((f) => f.id == id)),
          );
        }
      },
      itemBuilder: (context) => [
        for (final family in session.families)
          CheckedPopupMenuItem(
            value: family.id,
            checked: family.id == session.current?.id,
            child: Text(family.name),
          ),
        // Whoever makes a circle is its admin, and that takes an address.
        if (!session.isManaged) ...[
          const PopupMenuDivider(),
          const PopupMenuItem(
            value: _newFamily,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.add),
              title: Text('Neuer Kreis'),
            ),
          ),
        ],
      ],
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(session.current!.name, overflow: TextOverflow.ellipsis),
          ),
          const Icon(Icons.arrow_drop_down),
        ],
      ),
    );
  }
}

/// Shown when a user no longer belongs to any family.
class _NoFamilyScreen extends StatelessWidget {
  const _NoFamilyScreen();

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Kintura'),
        actions: [
          TextButton(onPressed: session.signOut, child: const Text('Abmelden')),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Du gehörst noch zu keinem Kreis.'),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => showCreateFamilyDialog(context),
              child: const Text('Kreis anlegen'),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> showCreateFamilyDialog(BuildContext context) => showDialog(
  context: context,
  builder: (_) => const _CreateFamilyDialog(),
);

class _CreateFamilyDialog extends StatefulWidget {
  const _CreateFamilyDialog();

  @override
  State<_CreateFamilyDialog> createState() => _CreateFamilyDialogState();
}

class _CreateFamilyDialogState extends State<_CreateFamilyDialog> {
  final _name = TextEditingController();
  FamilyType _type = FamilyType.family;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final session = SessionScope.of(context);
    final navigator = Navigator.of(context);
    final ok = await guarded(
      context,
      () => session.createFamily(_name.text.trim(), _type),
    );
    if (ok) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Neuer Kreis'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FamilyTypeField(
            value: _type,
            onChanged: (type) => setState(() => _type = type),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            autofocus: true,
            decoration: InputDecoration(labelText: _type.nameLabel),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Abbrechen'),
        ),
        FilledButton(onPressed: _save, child: const Text('Anlegen')),
      ],
    );
  }
}
