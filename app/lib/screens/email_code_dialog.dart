import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../session.dart';

/// Shows a new login code once: only its hash stays on the server.
class LoginCodeDialog extends StatefulWidget {
  const LoginCodeDialog({super.key, required this.name, required this.code});

  final String name;
  final String code;

  @override
  State<LoginCodeDialog> createState() => _LoginCodeDialogState();
}

class _LoginCodeDialogState extends State<LoginCodeDialog> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    if (mounted) setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Anmeldecode'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Mit diesem Code meldet sich ${widget.name} unter „Alternative Anmeldung“ an.'),
              const SizedBox(height: 16),
              Center(
                child: SelectableText(
                  key: const Key('login-code-value'),
                  widget.code,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(fontFamily: 'monospace'),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Er gilt einmal und höchstens 7 Tage. Du siehst ihn nur jetzt. Ein früherer Code gilt nicht mehr, '
                'wer schon angemeldet ist, bleibt es aber.',
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: _copy,
          icon: Icon(_copied ? Icons.check : Icons.copy),
          label: Text(_copied ? 'Kopiert' : 'Kopieren'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Fertig'),
        ),
      ],
    );
  }
}

/// Takes the code from an invitation mail, on behalf of the invited person. Only if
/// the address has no account yet does the backend ask for the name it needs for one.
/// Pops true once the person is in.
class InvitationCodeDialog extends StatefulWidget {
  const InvitationCodeDialog({super.key, required this.email, required this.confirmPath});

  final String email;
  final String confirmPath;

  @override
  State<InvitationCodeDialog> createState() => _InvitationCodeDialogState();
}

class _InvitationCodeDialogState extends State<InvitationCodeDialog> {
  final _code = TextEditingController();
  final _name = TextEditingController();
  bool _askName = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    final session = SessionScope.of(context);
    final navigator = Navigator.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    String? error;
    var askName = _askName;
    try {
      final result = await session.api.post(widget.confirmPath, {
        'code': _code.text.trim(),
        'name': _name.text.trim(),
      });
      if (result['status'] == 'joined') {
        navigator.pop(true);
        return;
      }
      if (askName) error = 'Bitte gib einen Namen an.';
      askName = true;
    } on ApiException catch (e) {
      error = e.message;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _askName = askName;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Code eingeben'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!_askName) ...[
                Text('Die Einladungsmail an ${widget.email} enthält einen Code. Mit ihm nimmst du die Person direkt auf.'),
                const SizedBox(height: 16),
                TextField(
                  key: const Key('invitation-code'),
                  controller: _code,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: 'Code', errorText: _error, errorMaxLines: 3),
                  onSubmitted: (_) => _confirm(),
                ),
              ] else ...[
                Text('Für ${widget.email} gibt es noch kein Konto. Wie heißt die Person?'),
                const SizedBox(height: 16),
                TextField(
                  key: const Key('invitation-name'),
                  controller: _name,
                  autofocus: true,
                  textCapitalization: TextCapitalization.words,
                  decoration: InputDecoration(labelText: 'Name', errorText: _error, errorMaxLines: 3),
                  onSubmitted: (_) => _confirm(),
                ),
              ],
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
          onPressed: _busy ? null : _confirm,
          child: const Text('Bestätigen'),
        ),
      ],
    );
  }
}

/// Asks for an address, then for the code that was sent there. Pops true once the
/// code was right. [requestPath] and `$requestPath/confirm` do the rest.
class EmailCodeDialog extends StatefulWidget {
  const EmailCodeDialog({
    super.key,
    required this.title,
    required this.label,
    required this.requestPath,
    this.hint,
  });

  final String title;
  final String label;
  final String requestPath;

  /// Shown above the address, for what is special about it here.
  final String? hint;

  @override
  State<EmailCodeDialog> createState() => _EmailCodeDialogState();
}

class _EmailCodeDialogState extends State<EmailCodeDialog> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  bool _codeSent = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  /// What goes wrong belongs to the field in this dialog, not behind it.
  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    String? error;
    try {
      await action();
    } on ApiException catch (e) {
      error = e.message;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
    });
  }

  Future<void> _sendCode() async {
    final session = SessionScope.of(context);
    await _run(() async {
      await session.api.post(widget.requestPath, {'email': _email.text.trim()});
      _code.clear();
      _codeSent = true;
    });
  }

  Future<void> _confirm() async {
    final session = SessionScope.of(context);
    final navigator = Navigator.of(context);
    await _run(() async {
      await session.api.post('${widget.requestPath}/confirm', {'code': _code.text.trim()});
      await session.refresh();
      navigator.pop(true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final hint = widget.hint;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!_codeSent) ...[
                if (hint != null) ...[Text(hint), const SizedBox(height: 16)],
                TextField(
                  key: const Key('new-email'),
                  controller: _email,
                  autofocus: true,
                  keyboardType: TextInputType.emailAddress,
                  decoration: InputDecoration(labelText: widget.label, errorText: _error, errorMaxLines: 3),
                  onSubmitted: (_) => _sendCode(),
                ),
              ] else ...[
                Text('Wir haben einen Code an ${_email.text.trim()} geschickt. Mit ihm wird die Adresse übernommen.'),
                const SizedBox(height: 16),
                TextField(
                  key: const Key('email-code'),
                  controller: _code,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: 'Code', errorText: _error, errorMaxLines: 3),
                  onSubmitted: (_) => _confirm(),
                ),
              ],
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
          onPressed: _busy ? null : (_codeSent ? _confirm : _sendCode),
          child: Text(_codeSent ? 'Bestätigen' : 'Code senden'),
        ),
      ],
    );
  }
}
