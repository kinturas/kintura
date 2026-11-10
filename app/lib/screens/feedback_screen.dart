import 'package:flutter/material.dart';

import '../common.dart';
import '../session.dart';

/// Sends a text to the operators of the app.
class FeedbackScreen extends StatefulWidget {
  const FeedbackScreen({super.key});

  @override
  State<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends State<FeedbackScreen> {
  final _text = TextEditingController();
  bool _missing = false;
  bool _sending = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _text.text.trim();
    if (text.isEmpty) {
      setState(() => _missing = true);
      return;
    }
    final session = SessionScope.of(context);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _sending = true);
    final ok = await guarded(context, () => session.api.post('/api/feedback', {'text': text}));
    if (!mounted) return;
    setState(() => _sending = false);
    if (!ok) return;
    messenger.showSnackBar(const SnackBar(content: Text('Danke für dein Feedback!')));
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Feedback')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Was gefällt dir, was fehlt, was funktioniert nicht? Dein Name und deine E-Mail-Adresse werden mitgeschickt.'),
          const SizedBox(height: 16),
          TextField(
            key: const Key('feedback-text'),
            controller: _text,
            autofocus: true,
            minLines: 6,
            maxLines: 12,
            maxLength: 5000,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: 'Dein Feedback',
              alignLabelWithHint: true,
              errorText: _missing ? 'Bitte einen Text eingeben' : null,
            ),
            onChanged: (_) {
              if (_missing) setState(() => _missing = false);
            },
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _sending ? null : _send,
            icon: const Icon(Icons.send),
            label: const Text('Senden'),
          ),
        ],
      ),
    );
  }
}
