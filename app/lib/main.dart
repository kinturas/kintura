import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'api.dart';
import 'offline_banner.dart';
import 'offline_cache.dart';
import 'screens/dashboard_screen.dart';
import 'screens/login_screen.dart';
import 'session.dart';
import 'session_sync.dart';
import 'shopping/shopping_outbox.dart';
import 'live_updates.dart';
import 'notifications/activity_notifier.dart';
import 'screens/activity_screen.dart';
import 'update_check.dart';

const seedColor = Color(0xFF2E6B57);

/// For what opens from outside a page, as a tapped notification.
final appNavigator = GlobalKey<NavigatorState>();

/// Every page, including its app bar and footer, stays this wide on large screens.
const maxPageWidth = 960.0;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('de');
  final api = ApiClient(cache: await _openCache());
  // Before the first request, so that the server knows the version from the start.
  final version = await identifyApp(api);
  final session = AppSession(
    api: api,
    tokens: SecureTokenStore(),
    themes: SecureThemeStore(),
    shopping: ShoppingOutbox(await _openOutbox()),
  );
  // Before the first frame, or the app would start in the wrong design.
  await session.loadThemeMode();
  session.start();
  SessionSync(session: session).start();
  LiveConnection(session: session).start();
  activityNotifier = ActivityNotifier(session: session, onOpen: _openActivities);
  unawaited(activityNotifier!.start());
  final updates = UpdateCheck(api: api, version: version)..start();
  runApp(KinturaApp(session: session, updates: updates));
}

/// Without storage the app still works, only not offline.
Future<ResponseCache?> _openCache() async {
  try {
    return await PrefsResponseCache.open();
  } catch (_) {
    return null;
  }
}

/// Without storage, shopping offline lasts only until the app closes.
Future<OutboxStore?> _openOutbox() async {
  try {
    return await PrefsOutboxStore.open();
  } catch (_) {
    return null;
  }
}

class KinturaApp extends StatelessWidget {
  const KinturaApp({super.key, required this.session, this.updates});

  final AppSession session;

  /// Shows a bar once a newer version is there, and a page once this one is too old, see [UpdateCheck].
  final UpdateCheck? updates;

  ThemeData _theme(Brightness brightness) => ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: brightness,
    ),
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return SessionScope(
      session: session,
      child: ValueListenableBuilder(
        valueListenable: session.themeMode,
        builder: (context, themeMode, _) => MaterialApp(
          navigatorKey: appNavigator,
          title: 'Kintura',
          debugShowCheckedModeBanner: false,
          themeMode: themeMode,
          theme: _theme(Brightness.light),
          darkTheme: _theme(Brightness.dark),
          locale: const Locale('de'),
          supportedLocales: const [Locale('de')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          builder: (context, child) {
            final page = ColoredBox(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: maxPageWidth),
                  child: child,
                ),
              ),
            );
            final online = OfflineBanner(
              api: session.api,
              // Without anything kept, the app waits on its own page for the server.
              onRetry: () => session.status == SessionStatus.signedIn ? session.refresh() : session.start(),
              child: page,
            );
            final check = updates;
            return check == null ? online : UpdateBanner(check: check, child: online);
          },
          home: const _Root(),
        ),
      ),
    );
  }
}

class _Root extends StatelessWidget {
  const _Root();

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    if (session.status == SessionStatus.signedOut) {
      // The session can end on any page, for example when the server rejects it.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          Navigator.of(context).popUntil((route) => route.isFirst);
        }
      });
    }
    return switch (session.status) {
      SessionStatus.loading => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      SessionStatus.signedOut => const LoginScreen(),
      SessionStatus.signedIn => const DashboardScreen(),
      SessionStatus.unreachable => Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Der Server ist nicht erreichbar.'),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: session.start,
                child: const Text('Erneut versuchen'),
              ),
            ],
          ),
        ),
      ),
    };
  }
}

/// Aktuelles, from a tapped notification; over what is open, once signed in.
void _openActivities() {
  final navigator = appNavigator.currentState;
  if (navigator == null || activityNotifier?.session.status != SessionStatus.signedIn) return;
  navigator.push(MaterialPageRoute<void>(builder: (_) => const ActivityScreen()));
}
