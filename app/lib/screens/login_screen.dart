import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../common.dart';
import '../session.dart';
import 'about_screen.dart';

enum _Step { email, code, register }

/// Takes the code an admin made for someone without an address, and pops the token of
/// the new session. Signing in is left to the page behind: it replaces that page, and
/// a dialog still open would stay on top of what comes next.
class _AlternativeLoginDialog extends StatefulWidget {
  const _AlternativeLoginDialog();

  @override
  State<_AlternativeLoginDialog> createState() => _AlternativeLoginDialogState();
}

class _AlternativeLoginDialogState extends State<_AlternativeLoginDialog> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (_busy) return;
    if (_code.text.trim().isEmpty) {
      setState(() => _error = 'Bitte den Code eingeben');
      return;
    }
    final session = SessionScope.of(context);
    final navigator = Navigator.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await session.api.post('/api/auth/code', {'code': _code.text.trim()});
      navigator.pop(result['token'] as String);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Alternative Anmeldung'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Ohne E-Mail-Adresse meldest du dich mit dem Anmeldecode an, den du von einem Admin bekommen hast.'),
              const SizedBox(height: 16),
              TextField(
                key: const Key('login-code'),
                controller: _code,
                autofocus: true,
                autocorrect: false,
                enableSuggestions: false,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(labelText: 'Anmeldecode', errorText: _error, errorMaxLines: 3),
                onSubmitted: (_) => _login(),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          onPressed: _busy ? null : _login,
          child: const Text('Anmelden'),
        ),
      ],
    );
  }
}

/// Email first, then code or link, then registration if the address is new.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  /// How often the app checks whether the mail link was confirmed.
  static Duration pollInterval = const Duration(seconds: 3);

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _code = TextEditingController();
  final _name = TextEditingController();
  final _family = TextEditingController();

  _Step _step = _Step.email;
  String? _requestId;
  String _verifiedEmail = '';
  List<String> _invitedFamilies = [];
  FamilyType _familyType = FamilyType.family;
  bool _busy = false;
  String? _error;
  Timer? _pollTimer;

  @override
  void dispose() {
    _pollTimer?.cancel();
    _email.dispose();
    _code.dispose();
    _name.dispose();
    _family.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy || !_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _requestLogin() => _run(() async {
    final result = await SessionScope.of(context).api.post(
      '/api/auth/request',
      {'email': _email.text.trim()},
    );
    _requestId = result['request_id'] as String;
    _code.clear();
    setState(() => _step = _Step.code);
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(LoginScreen.pollInterval, (_) => _poll());
  });

  Future<void> _verifyCode() => _run(() async {
    final result = await SessionScope.of(context).api.post('/api/auth/verify', {
      'request_id': _requestId,
      'code': _code.text.trim(),
    });
    await _handleVerified(result as Map<String, dynamic>);
  });

  Future<void> _poll() async {
    if (_busy) return;
    try {
      final result = await SessionScope.of(context).api.post(
        '/api/auth/poll',
        {'request_id': _requestId},
      );
      if (mounted && result['status'] != 'pending') {
        await _handleVerified(result as Map<String, dynamic>);
      }
    } on ApiException catch (e) {
      if (e.status == 410) {
        _backToEmail(e.message);
      }
      // Short network problems are ignored; the next poll tries again.
    }
  }

  Future<void> _handleVerified(Map<String, dynamic> result) async {
    _pollTimer?.cancel();
    if (result['status'] == 'authenticated') {
      await SessionScope.of(context).signIn(result['token'] as String);
      return;
    }
    setState(() {
      _verifiedEmail = result['email'] as String;
      _invitedFamilies = (result['invited_families'] as List).cast<String>();
      _step = _Step.register;
    });
  }

  Future<void> _register() => _run(() async {
    final session = SessionScope.of(context);
    final result = await session.api.post('/api/auth/register', {
      'request_id': _requestId,
      'name': _name.text.trim(),
      'family_name': _family.text.trim(),
      'family_type': _familyType.name,
    });
    await session.signIn(result['token'] as String);
  });

  /// The form and its email field have no part in this, so it does not go through _run.
  Future<void> _alternativeLogin() async {
    final session = SessionScope.of(context);
    final token = await showDialog<String>(
      context: context,
      builder: (_) => const _AlternativeLoginDialog(),
    );
    if (token == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await session.signIn(token);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _backToEmail([String? message]) {
    _pollTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _step = _Step.email;
      _error = message;
    });
  }

  void _open(Widget page) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  String? _notEmpty(String? value) =>
      (value == null || value.trim().isEmpty) ? 'Bitte ausfüllen' : null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(
                      Icons.family_restroom,
                      size: 64,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Kintura',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 32),
                    ...switch (_step) {
                      _Step.email => _emailStep(),
                      _Step.code => _codeStep(theme),
                      _Step.register => _registerStep(theme),
                    },
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ],
                    const SizedBox(height: 24),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 8,
                      children: [
                        TextButton(
                          key: const Key('login-imprint'),
                          onPressed: () => _open(const ImprintScreen()),
                          child: const Text('Impressum'),
                        ),
                        TextButton(
                          key: const Key('login-privacy'),
                          onPressed: () => _open(const PrivacyScreen()),
                          child: const Text('Datenschutzerklärung'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _emailStep() => [
    TextFormField(
      key: const Key('email'),
      controller: _email,
      autofocus: true,
      keyboardType: TextInputType.emailAddress,
      autofillHints: const [AutofillHints.email],
      decoration: const InputDecoration(labelText: 'E-Mail-Adresse'),
      validator: (value) => (value == null || !value.contains('@'))
          ? 'Bitte eine E-Mail-Adresse eingeben'
          : null,
      onFieldSubmitted: (_) => _requestLogin(),
    ),
    const SizedBox(height: 16),
    FilledButton(
      onPressed: _busy ? null : _requestLogin,
      child: const Text('Weiter'),
    ),
    const SizedBox(height: 8),
    TextButton(
      key: const Key('alternative-login'),
      onPressed: _busy ? null : _alternativeLogin,
      child: const Text('Alternative Anmeldung'),
    ),
  ];

  List<Widget> _codeStep(ThemeData theme) => [
    Text(
      'Wir haben eine E-Mail an ${_email.text.trim()} geschickt. '
      'Gib den Code ein oder bestätige den Link aus der Mail, '
      'auch auf einem anderen Gerät.',
      textAlign: TextAlign.center,
      style: theme.textTheme.bodyLarge,
    ),
    const SizedBox(height: 24),
    TextFormField(
      key: const Key('code'),
      controller: _code,
      autofocus: true,
      keyboardType: TextInputType.number,
      autofillHints: const [AutofillHints.oneTimeCode],
      maxLength: 6,
      textAlign: TextAlign.center,
      style: theme.textTheme.headlineSmall?.copyWith(letterSpacing: 8),
      decoration: const InputDecoration(labelText: 'Code', counterText: ''),
      validator: _notEmpty,
      onFieldSubmitted: (_) => _verifyCode(),
    ),
    const SizedBox(height: 16),
    FilledButton(
      onPressed: _busy ? null : _verifyCode,
      child: const Text('Anmelden'),
    ),
    const SizedBox(height: 8),
    TextButton(
      onPressed: _busy ? null : () => _backToEmail(),
      child: const Text('Andere E-Mail-Adresse oder neuer Code'),
    ),
  ];

  List<Widget> _registerStep(ThemeData theme) {
    // Invited users may skip creating a family of their own.
    final invited = _invitedFamilies.isNotEmpty;
    return [
      Text('Registrieren', style: theme.textTheme.titleLarge),
      const SizedBox(height: 16),
      if (invited) ...[
        Text(
          'Du wurdest eingeladen in: ${_invitedFamilies.join(', ')}. '
          'Einen eigenen Kreis kannst du optional zusätzlich anlegen.',
        ),
        const SizedBox(height: 16),
      ],
      TextFormField(
        key: const Key('verified-email'),
        initialValue: _verifiedEmail,
        readOnly: true,
        enabled: false,
        decoration: const InputDecoration(labelText: 'E-Mail-Adresse'),
      ),
      const SizedBox(height: 16),
      TextFormField(
        key: const Key('name'),
        controller: _name,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        decoration: const InputDecoration(labelText: 'Dein Name'),
        validator: _notEmpty,
      ),
      const SizedBox(height: 16),
      FamilyTypeField(
        key: const Key('family-type'),
        value: _familyType,
        onChanged: (type) => setState(() => _familyType = type),
      ),
      const SizedBox(height: 16),
      TextFormField(
        key: const Key('family'),
        controller: _family,
        textCapitalization: TextCapitalization.words,
        decoration: InputDecoration(
          labelText: invited ? '${_familyType.nameLabel} (optional)' : _familyType.nameLabel,
        ),
        validator: invited ? null : _notEmpty,
      ),
      const SizedBox(height: 24),
      FilledButton(
        onPressed: _busy ? null : _register,
        child: const Text('Registrieren'),
      ),
    ];
  }
}
