import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../common.dart';
import '../session.dart';

class MessagesScreen extends StatefulWidget {
  const MessagesScreen({super.key});

  @override
  State<MessagesScreen> createState() => _MessagesScreenState();
}

class _MessagesScreenState extends State<MessagesScreen> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  List<dynamic>? _messages;
  Timer? _timer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_timer == null) {
      _load();
      _timer = Timer.periodic(const Duration(seconds: 5), (_) => _load());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final session = SessionScope.of(context);
    try {
      final rows = await session.api.get('${session.familyPath}/messages') as List;
      if (mounted) setState(() => _messages = rows);
    } on ApiException {
      // The next poll tries again; loaded messages stay visible until then.
      if (mounted && _messages == null) setState(() => _messages = []);
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    final session = SessionScope.of(context);
    final ok = await guarded(
      context,
      () => session.api.post('${session.familyPath}/messages', {'body': text}),
    );
    if (ok) {
      _input.clear();
      _focus.requestFocus();
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    final messages = _messages;
    return Scaffold(
      appBar: AppBar(title: const Text('Nachrichten')),
      body: Column(
        children: [
          Expanded(
            child: messages == null
                ? const Center(child: CircularProgressIndicator())
                : messages.isEmpty
                ? const EmptyHint(
                    icon: Icons.chat_bubble_outline,
                    text: 'Noch keine Nachrichten.',
                  )
                : ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.all(12),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final message = messages[messages.length - 1 - index];
                      return _Bubble(
                        message: message as Map<String, dynamic>,
                        own: message['sender_id'] == session.userId,
                      );
                    },
                  ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      focusNode: _focus,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      decoration: const InputDecoration(labelText: 'Nachricht'),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    tooltip: 'Senden',
                    icon: const Icon(Icons.send),
                    onPressed: _send,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.own});

  final Map<String, dynamic> message;
  final bool own;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final sent = DateTime.parse(message['created_at'] as String).toLocal();
    final foreground = own ? colors.onPrimaryContainer : colors.onSurface;
    return Align(
      alignment: own ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Card(
          elevation: 0,
          color: own ? colors.primaryContainer : colors.surfaceContainerHigh,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!own)
                  Text(
                    message['sender_name'] as String,
                    style: theme.textTheme.labelMedium?.copyWith(color: colors.primary),
                  ),
                SelectableText(
                  message['body'] as String,
                  style: TextStyle(color: foreground),
                ),
                const SizedBox(height: 4),
                Text(
                  '${dateFormat.format(sent)} ${timeFormat.format(sent)}',
                  style: theme.textTheme.labelSmall?.copyWith(color: foreground),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
