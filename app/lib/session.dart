import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api.dart';

abstract class TokenStore {
  Future<String?> read();
  Future<void> write(String token);
  Future<void> clear();
}

class SecureTokenStore implements TokenStore {
  static const _key = 'session_token';
  final _storage = const FlutterSecureStorage();

  @override
  Future<String?> read() => _storage.read(key: _key);
  @override
  Future<void> write(String token) => _storage.write(key: _key, value: token);
  @override
  Future<void> clear() => _storage.delete(key: _key);
}

/// Keeps the chosen design on this device, whoever is signed in.
abstract class ThemeStore {
  Future<String?> read();
  Future<void> write(String mode);
}

class SecureThemeStore implements ThemeStore {
  static const _key = 'theme_mode';
  final _storage = const FlutterSecureStorage();

  @override
  Future<String?> read() => _storage.read(key: _key);
  @override
  Future<void> write(String mode) => _storage.write(key: _key, value: mode);
}

/// The enum names are the values the backend stores. The wording is spelled out
/// per type because the grammatical gender differs.
enum FamilyType {
  family(
    'Familie',
    'Familien-Chat',
    'Name der Familie',
    'aus der Familie',
    Icons.family_restroom,
  ),
  friends(
    'Freundeskreis',
    'Freundeskreis-Chat',
    'Name des Freundeskreises',
    'aus dem Freundeskreis',
    Icons.diversity_3,
  ),
  relatives(
    'Verwandtschaft',
    'Verwandtschafts-Chat',
    'Name der Verwandtschaft',
    'aus der Verwandtschaft',
    Icons.groups_outlined,
  ),
  workgroup(
    'Arbeitsgruppe',
    'Arbeitsgruppen-Chat',
    'Name der Arbeitsgruppe',
    'aus der Arbeitsgruppe',
    Icons.work_outline,
  );

  const FamilyType(
    this.label,
    this.chat,
    this.nameLabel,
    this.fromThe,
    this.icon,
  );

  final String label;
  final String chat;
  final String nameLabel;
  final String fromThe;
  final IconData icon;

  bool get isFamily => this == FamilyType.family;

  String roleLabel(String role) => switch (role) {
    'manager' => isFamily ? 'Eltern' : 'Manager',
    'user' => isFamily ? 'Erwachsenes Kind' : 'User',
    'restrict_user' => isFamily ? 'Kind' : 'Restricted',
    _ => 'Gast',
  };
}

class Family {
  Family(this.id, this.name, this.type, this.role, this.isAdmin, this.color, {this.canChangeColor = true, this.memberName = '', this.familyColor = ''});

  factory Family.fromJson(Map<String, dynamic> json) => Family(
    json['id'] as String,
    json['name'] as String,
    FamilyType.values.asNameMap()[json['type']] ?? FamilyType.family,
    json['role'] as String,
    json['is_admin'] as bool,
    json['color'] as String,
    canChangeColor: json['can_change_color'] as bool? ?? true,
    memberName: json['member_name'] as String? ?? '',
    familyColor: json['family_color'] as String? ?? '',
  );

  final String id;
  final String name;
  final FamilyType type;
  final String role;
  final bool isAdmin;

  bool get isManager => role == 'manager';

  /// In families the children.
  bool get isRestricted => role == 'restrict_user';

  /// The user's color in this family: a hex value like #1565C0, empty for none.
  final String color;

  /// An admin can take this away. It never holds for admins, who can set any color.
  final bool canChangeColor;

  bool get mayChangeOwnColor => canChangeColor || isAdmin;

  /// What the user is called in this family.
  final String memberName;

  /// The color of the family itself, which tints the dashboard header; empty for none.
  final String familyColor;
}

/// A family that asked the user to join. Nobody joins without saying so.
class Invitation {
  Invitation(this.id, this.familyId, this.familyName, this.familyType);

  factory Invitation.fromJson(Map<String, dynamic> json) => Invitation(
    json['id'] as String,
    json['family_id'] as String,
    json['family_name'] as String,
    FamilyType.values.asNameMap()[json['family_type']] ?? FamilyType.family,
  );

  final String id;
  final String familyId;
  final String familyName;
  final FamilyType familyType;
}

enum SessionStatus { loading, signedOut, signedIn, unreachable }

class AppSession extends ChangeNotifier {
  AppSession({required this.api, required this.tokens, this.themes}) {
    api.onUnauthorized = _dropSession;
  }

  final ApiClient api;
  final TokenStore tokens;
  final ThemeStore? themes;

  /// Follows the device until something else is chosen.
  final themeMode = ValueNotifier(ThemeMode.system);

  /// A design that cannot be read or kept is no reason to stop the app.
  Future<void> loadThemeMode() async {
    try {
      final stored = await themes?.read();
      themeMode.value = ThemeMode.values.asNameMap()[stored] ?? ThemeMode.system;
    } catch (_) {
      themeMode.value = ThemeMode.system;
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode.value = mode;
    try {
      await themes?.write(mode.name);
    } catch (_) {
      // It still holds until the app closes.
    }
  }

  SessionStatus status = SessionStatus.loading;
  String userId = '';
  String userName = '';
  String userEmail = '';

  /// Logged in with a code from an admin, without an address of their own.
  bool isManaged = false;

  /// Whether reminders reach the user.
  bool notifications = true;
  List<Family> families = [];

  /// Waiting for an answer, see [answerInvitation].
  List<Invitation> invitations = [];
  Family? current;

  /// The name in the selected family, as everyone there sees it.
  String get displayName {
    final name = current?.memberName ?? '';
    return name.isEmpty ? userName : name;
  }

  /// Path prefix for everything that belongs to the selected family.
  String get familyPath => '/api/families/${current!.id}';

  Future<void> start() async {
    status = SessionStatus.loading;
    notifyListeners();
    api.token = await tokens.read();
    if (api.token == null) {
      status = SessionStatus.signedOut;
      notifyListeners();
      return;
    }
    try {
      await refresh();
    } on ApiException catch (e) {
      // A network problem must not log the user out; a 401 already did.
      if (e.status != 401) {
        status = SessionStatus.unreachable;
        notifyListeners();
      }
    }
  }

  Future<void> signIn(String token) async {
    // Whatever is kept from before may belong to someone else.
    await api.cache?.clear();
    await tokens.write(token);
    api.token = token;
    await refresh();
  }

  /// Reloads user and families and selects the last used family.
  Future<void> refresh() async {
    final me = await api.get('/api/me') as Map<String, dynamic>;
    userId = me['id'] as String;
    userName = me['name'] as String;
    userEmail = me['email'] as String;
    isManaged = me['managed'] as bool? ?? false;
    notifications = me['notifications'] as bool? ?? true;
    families = (me['families'] as List)
        .map((f) => Family.fromJson(f as Map<String, dynamic>))
        .toList();
    // Older servers took invitations in by themselves and send none.
    invitations = [
      for (final row in me['invitations'] as List? ?? const []) Invitation.fromJson(row as Map<String, dynamic>),
    ];
    final lastId = me['last_family_id'] as String?;
    current = families.where((f) => f.id == lastId).firstOrNull;
    status = SessionStatus.signedIn;
    notifyListeners();
  }

  Future<void> select(Family family) async {
    try {
      await api.post('/api/families/${family.id}/select');
    } on ApiException catch (e) {
      // Offline the other family can still be read, only the server does not remember the choice.
      if (e.status != 0) rethrow;
    }
    current = family;
    notifyListeners();
  }

  /// Joins the family of [invitation], which then opens, or declines it.
  Future<void> answerInvitation(Invitation invitation, {required bool accept}) async {
    await api.post('/api/invitations/${invitation.id}/${accept ? 'accept' : 'decline'}');
    await refresh();
  }

  Future<void> createFamily(String name, FamilyType type) async {
    await api.post('/api/families', {'name': name, 'type': type.name});
    await refresh();
  }

  Future<void> signOut() async {
    try {
      await api.post('/api/auth/logout');
    } on ApiException {
      // The local session ends either way.
    }
    _dropSession();
  }

  // Keeps the family fields: open pages still build once before they are closed,
  // and the next sign-in replaces the values.
  void _dropSession() {
    tokens.clear();
    // Nothing of the account stays readable on the device.
    api.cache?.clear();
    api.token = null;
    status = SessionStatus.signedOut;
    notifyListeners();
  }
}

class SessionScope extends InheritedNotifier<AppSession> {
  const SessionScope({
    super.key,
    required AppSession session,
    required super.child,
  }) : super(notifier: session);

  static AppSession of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<SessionScope>()!
      .notifier!;
}
