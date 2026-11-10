import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'api.dart';
import 'screens/dashboard_screen.dart';
import 'screens/login_screen.dart';
import 'session.dart';

const seedColor = Color(0xFF2E6B57);

/// Every page, including its app bar and footer, stays this wide on large screens.
const maxPageWidth = 960.0;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('de');
  final session = AppSession(api: ApiClient(), tokens: SecureTokenStore(), themes: SecureThemeStore());
  // Before the first frame, or the app would start in the wrong design.
  await session.loadThemeMode();
  session.start();
  runApp(KinturaApp(session: session));
}

class KinturaApp extends StatelessWidget {
  const KinturaApp({super.key, required this.session});

  final AppSession session;

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
          title: 'Kintura',
          debugShowCheckedModeBanner: false,
          themeMode: themeMode,
          theme: _theme(Brightness.light),
          darkTheme: _theme(Brightness.dark),
          locale: const Locale('de'),
          supportedLocales: const [Locale('de')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          builder: (context, child) => ColoredBox(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: maxPageWidth),
                child: child,
              ),
            ),
          ),
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
