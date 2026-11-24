import 'dart:math';

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../common.dart';
import '../live_updates.dart';
import '../session.dart';
import 'activity_screen.dart' show CircleLabel;
import 'chat_form_screen.dart';
import 'event_edit_screen.dart' show PickedFile;
import 'messages_screen.dart';

/// The picture of who wrote a message, next to it, and the room between them.
const _avatarSize = 24.0;
const _avatarGap = 6.0;

/// The largest file the server takes, see maxUploadSize in files.go.
const _maxUpload = 25 << 20;

/// Pictures once loaded, by path, so that scrolling does not fetch them again.
final _pictures = <String, Future<Uint8List>>{};

Future<Uint8List> _picture(AppSession session, String path) =>
    _pictures[path] ??= session.api.getBytes(path).catchError((Object e) {
      _pictures.remove(path);
      throw e;
    });

/// A picture shrunk for sending: at most 1600 pixels, as JPEG. Others, as animated
/// GIFs, go as they are.
Uint8List? _shrinkPicture(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null || (decoded.numFrames > 1)) return null;
  const max = 1600;
  final image = decoded.width >= decoded.height
      ? (decoded.width > max ? img.copyResize(decoded, width: max) : decoded)
      : (decoded.height > max ? img.copyResize(decoded, height: max) : decoded);
  return img.encodeJpg(image, quality: 85);
}

String _fileSize(num bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1).replaceAll('.', ',')} MB';
}

/// One chat: the messages, the oldest at the top, and below the field to write with
/// emojis, pictures and documents. Who may only read along sees no field.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.familyId, required this.chatId, this.chat});

  final String familyId;
  final String chatId;

  /// As the list of chats has it; loaded when missing, as from a notification.
  final Map<String, dynamic>? chat;

  /// Asks for files; replaced in tests.
  static Future<List<PickedFile>> Function({required bool pictures}) pickFiles = _pickFiles;

  static Future<List<PickedFile>> _pickFiles({required bool pictures}) async {
    final files = await FilePicker.pickFiles(type: pictures ? FileType.image : FileType.any);
    return [for (final file in files) PickedFile(file.name, await file.readAsBytes())];
  }

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with LiveReload {
  final _input = TextEditingController();
  final _focus = FocusNode();
  Map<String, dynamic>? _chat;
  List<Map<String, dynamic>>? _messages;
  bool _more = false;
  bool _loadingOlder = false;
  String? _error;
  bool _sending = false;
  int _uploading = 0;
  bool _emoji = false;
  bool _started = false;

  /// The message the next one answers, shown above the field until sent or dropped.
  Map<String, dynamic>? _replyTo;

  /// The members of the circle by id, for the pictures next to their messages.
  Map<String, Map<String, dynamic>> _people = {};

  String get _base => '/api/families/${widget.familyId}/chats/${widget.chatId}';

  bool get _canWrite => _chat?['can_write'] == true;

  @override
  void initState() {
    super.initState();
    _chat = widget.chat;
    _input.addListener(() => setState(() {}));
    _focus.addListener(() {
      // The keyboard and the emojis take turns.
      if (_focus.hasFocus && _emoji) setState(() => _emoji = false);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    listenLive(const {'messages', 'family'}, _reload, everyFamily: true);
    _reload();
  }

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    await Future.wait([_loadChat(), _load(), _loadPeople()]);
  }

  /// Who is in the circle, with color and picture; former members show their initials.
  Future<void> _loadPeople() async {
    final session = SessionScope.of(context);
    try {
      final result = await session.api.get('/api/families/${widget.familyId}/members') as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _people = {for (final m in (result['members'] as List).cast<Map<String, dynamic>>()) m['id'] as String: m};
      });
    } on ApiException {
      // Then initials in the color of the message.
    }
  }

  Widget _avatarOf(Map<String, dynamic> message) {
    final person = _people[message['sender_id']];
    final name = person?['name'] as String? ?? message['sender_name'] as String? ?? '';
    return UserAvatar(
      name.isEmpty ? '?' : name,
      key: ValueKey('chat-avatar-${message['id']}'),
      color: person?['color'] as String? ?? message['sender_color'] as String? ?? '',
      photo: person?['avatar'] as String? ?? '',
      radius: _avatarSize / 2,
    );
  }

  /// The chat as the list has it: its name, and what the user may do.
  Future<void> _loadChat() async {
    final session = SessionScope.of(context);
    try {
      final rows = (await session.api.get('/api/chats?family=${widget.familyId}') as List).cast<Map<String, dynamic>>();
      if (!mounted) return;
      final chat = rows.where((c) => c['id'] == widget.chatId).firstOrNull;
      setState(() {
        if (chat != null) _chat = chat;
        if (chat == null) _error = 'Diesen Chat gibt es nicht mehr.';
      });
    } on ApiException {
      // What was passed in stays.
    }
  }

  Future<void> _load() async {
    final session = SessionScope.of(context);
    try {
      final page = await session.api.get('$_base/messages') as Map<String, dynamic>;
      if (!mounted) return;
      final fresh = (page['messages'] as List).cast<Map<String, dynamic>>();
      setState(() {
        // Older ones loaded before stay above.
        final older = [
          for (final m in _messages ?? const <Map<String, dynamic>>[])
            if (fresh.isNotEmpty && (m['created_at'] as String).compareTo(fresh.first['created_at'] as String) < 0) m,
        ];
        _messages = [...older, ...fresh];
        if (older.isEmpty) _more = page['more'] == true;
        _error = null;
      });
      await _markRead();
    } on ApiException catch (e) {
      if (mounted && _messages == null) setState(() => _error = e.message);
    }
  }

  Future<void> _loadOlder() async {
    final messages = _messages;
    if (messages == null || messages.isEmpty || _loadingOlder) return;
    setState(() => _loadingOlder = true);
    final session = SessionScope.of(context);
    try {
      final before = Uri.encodeQueryComponent(messages.first['created_at'] as String);
      final page = await session.api.get('$_base/messages?before=$before') as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _messages = [...(page['messages'] as List).cast<Map<String, dynamic>>(), ...messages];
        _more = page['more'] == true;
      });
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  Future<void> _markRead() async {
    final session = SessionScope.of(context);
    try {
      await session.api.post('$_base/read');
      chatsRead.value++;
    } on ApiException {
      // Unread for now; the next look tries again.
    }
  }

  Future<void> _send() async {
    final body = _input.text.trim();
    if (body.isEmpty || _sending) return;
    final session = SessionScope.of(context);
    setState(() => _sending = true);
    final replyTo = _replyTo?['id'] as String?;
    final ok = await guarded(context, () => session.api.post('$_base/messages', {'body': body, 'reply_to': ?replyTo}));
    if (!mounted) return;
    setState(() {
      _sending = false;
      if (ok) _replyTo = null;
    });
    if (!ok) return;
    _input.clear();
    await _load();
  }

  Future<void> _attach({required bool pictures}) async {
    final session = SessionScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final files = await ChatScreen.pickFiles(pictures: pictures);
    if (files.isEmpty || !mounted) return;
    setState(() => _uploading += files.length);
    try {
      for (final file in files) {
        var name = file.name;
        var bytes = file.bytes;
        if (pictures) {
          final smaller = await compute(_shrinkPicture, bytes);
          if (smaller != null) {
            bytes = smaller;
            name = '${name.replaceFirst(RegExp(r'\.[^.]*$'), '')}.jpg';
          }
        }
        if (bytes.length > _maxUpload) {
          messenger.showSnackBar(SnackBar(content: Text('„${file.name}“ ist größer als 25 MB.')));
          continue;
        }
        try {
          await session.api.upload('$_base/attachments', name, bytes);
        } on ApiException catch (e) {
          messenger.showSnackBar(SnackBar(content: Text(e.message)));
        }
        if (mounted) setState(() => _uploading--);
      }
    } finally {
      if (mounted) setState(() => _uploading = 0);
    }
    if (mounted) await _load();
  }

  PopupMenuItem<String> _action(String value, IconData icon, String label) => PopupMenuItem(
    key: Key('chat-action-$value'),
    value: value,
    child: ListTile(leading: Icon(icon), title: Text(label), contentPadding: EdgeInsets.zero),
  );

  /// What to do with a message, where it was tapped: react, answer, copy, forward, delete.
  Future<void> _messageMenu(Map<String, dynamic> message, Offset at) async {
    final deleted = message['deleted'] == true;
    final body = message['body'] as String? ?? '';
    final files = message['attachments'] as List? ?? const [];
    final items = [
      if (_canWrite && !deleted) _action('react', Icons.add_reaction_outlined, 'Reaktion'),
      if (_canWrite && !deleted) _action('reply', Icons.reply, 'Antworten'),
      // Pictures and documents cannot go into the clipboard.
      if (!deleted && body.isNotEmpty && files.isEmpty) _action('copy', Icons.copy, 'Kopieren'),
      if (!deleted) _action('forward', Icons.shortcut, 'Weiterleiten'),
      if (message['can_delete'] == true) _action('delete', Icons.delete_outline, 'Löschen'),
    ];
    if (items.isEmpty) return;
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
      items: items,
    );
    if (!mounted) return;
    switch (action) {
      case 'react':
        final mine = _myReaction(message);
        final emoji = await pickReaction(context, current: mine);
        if (emoji != null) await _react(message, emoji);
      case 'reply':
        setState(() {
          _replyTo = message;
          _emoji = false;
        });
        _focus.requestFocus();
      case 'copy':
        await Clipboard.setData(ClipboardData(text: body));
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Kopiert.')));
      case 'forward':
        final messenger = ScaffoldMessenger.of(context);
        final to = await Navigator.of(context).push<String>(
          MaterialPageRoute(
            builder: (_) => _ForwardScreen(familyId: widget.familyId, message: message),
          ),
        );
        if (to != null) messenger.showSnackBar(SnackBar(content: Text('An „$to“ weitergeleitet.')));
        if (mounted) await _load();
      case 'delete':
        if (!await confirm(
          context,
          'Nachricht löschen?',
          message: 'Für alle. An ihrer Stelle steht dann „Nachricht wurde gelöscht“.',
        )) {
          return;
        }
        if (!mounted) return;
        final session = SessionScope.of(context);
        if (await guarded(context, () => session.api.delete('$_base/messages/${message['id']}'))) await _load();
    }
  }

  String? _myReaction(Map<String, dynamic> message) =>
      (message['reactions'] as List? ?? const [])
              .cast<Map<String, dynamic>>()
              .where((r) => r['mine'] == true)
              .firstOrNull?['emoji']
          as String?;

  /// Reacts with [emoji]; the same one again takes it back.
  Future<void> _react(Map<String, dynamic> message, String emoji) async {
    final session = SessionScope.of(context);
    final next = _myReaction(message) == emoji ? '' : emoji;
    if (await guarded(context, () => session.api.put('$_base/messages/${message['id']}/reaction', {'emoji': next}))) {
      await _load();
    }
  }

  Future<void> _openFile(Map<String, dynamic> file) async {
    if (file['kind'] == 'photo') {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => _PictureScreen(
            path: '$_base/attachments/${file['id']}',
            name: file['name'] as String? ?? '',
            onDownload: () => _download(file),
          ),
        ),
      );
      return;
    }
    await _download(file);
  }

  /// Opens the file in the browser or the app the system has for it.
  Future<void> _download(Map<String, dynamic> file) async {
    final session = SessionScope.of(context);
    await guarded(context, () async {
      final result = await session.api.post('$_base/attachments/${file['id']}/link') as Map<String, dynamic>;
      await launchUrl(Uri.parse(result['url'] as String), mode: LaunchMode.externalApplication);
    });
  }

  Future<void> _edit() async {
    final chat = _chat;
    if (chat == null) return;
    final navigator = Navigator.of(context);
    final result = await navigator.push<String>(
      MaterialPageRoute(
        builder: (_) => ChatFormScreen(familyId: widget.familyId, chat: chat),
      ),
    );
    if (result == null || !mounted) return;
    if (result.isEmpty) {
      // Deleted.
      navigator.pop();
      return;
    }
    await _loadChat();
  }

  Future<void> _archive(bool archived) async {
    final session = SessionScope.of(context);
    final navigator = Navigator.of(context);
    final ok = await guarded(context, () => session.api.put('$_base/archive', {'archived': archived}));
    if (!ok || !mounted) return;
    chatsRead.value++;
    if (archived) {
      navigator.pop();
    } else {
      await _loadChat();
    }
  }

  void _toggleEmoji() {
    if (_emoji) {
      _focus.requestFocus();
    } else {
      _focus.unfocus();
    }
    setState(() => _emoji = !_emoji);
  }

  @override
  Widget build(BuildContext context) {
    final chat = _chat;
    final messages = _messages;
    final session = SessionScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final group = chat?['kind'] == 'group';
    final subtitle = <String>[
      if (session.families.length > 1 && widget.familyId != session.current?.id)
        session.families.where((f) => f.id == widget.familyId).firstOrNull?.name ?? '',
      if (group && chat?['assignees_all'] == true) 'Alle im Kreis',
      if (group && chat?['assignees_all'] != true) '${((chat?['assignee_ids'] as List?)?.length ?? 0) + 1} Personen',
      if (chat != null && !_canWrite) 'nur lesend',
    ].where((s) => s.isNotEmpty).join(' · ');
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: chat == null
            ? const Text('Nachrichten')
            : Row(
                children: [
                  ChatAvatar(chat, radius: 18),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(chat['name'] as String? ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
                        if (subtitle.isNotEmpty)
                          Text(
                            subtitle,
                            style: Theme.of(context).textTheme.labelSmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
        bottom: chat != null && chatColor(chat) != null && group
            ? PreferredSize(
                preferredSize: const Size.fromHeight(4),
                child: Container(height: 4, color: chatColor(chat)),
              )
            : null,
        actions: [
          if (chat != null)
            PopupMenuButton<String>(
              key: const Key('chat-menu'),
              onSelected: (value) => switch (value) {
                'edit' => _edit(),
                'archive' => _archive(true),
                'unarchive' => _archive(false),
                _ => null,
              },
              itemBuilder: (context) => [
                if (chat['can_edit'] == true) const PopupMenuItem(value: 'edit', child: Text('Gruppe bearbeiten')),
                if (chat['archived'] == true)
                  const PopupMenuItem(value: 'unarchive', child: Text('Wieder in die Liste'))
                else
                  const PopupMenuItem(value: 'archive', child: Text('Archivieren')),
              ],
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: messages == null
                ? Center(child: _error == null ? const CircularProgressIndicator() : Text(_error!))
                : messages.isEmpty
                ? EmptyHint(
                    icon: Icons.chat_bubble_outline,
                    text: _canWrite ? 'Noch keine Nachrichten. Schreib die erste!' : 'Noch keine Nachrichten.',
                  )
                : _list(messages, group),
          ),
          if (_uploading > 0) const LinearProgressIndicator(),
          if (chat != null && !_canWrite)
            SafeArea(
              top: false,
              child: Container(
                key: const Key('chat-read-only'),
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                color: scheme.surfaceContainerHigh,
                child: const Text(
                  'In dieser Gruppe kannst du nur mitlesen. Schreiben können die Personen, die sie betrifft.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          else if (chat != null)
            _composer(),
          if (_emoji && _canWrite)
            EmojiPicker(
              textEditingController: _input,
              config: Config(
                height: 280,
                locale: const Locale('de'),
                checkPlatformCompatibility: !kIsWeb,
                emojiViewConfig: EmojiViewConfig(
                  emojiSizeMax: 28 * (defaultTargetPlatform == TargetPlatform.iOS ? 1.2 : 1.0),
                  backgroundColor: scheme.surface,
                ),
                categoryViewConfig: CategoryViewConfig(
                  backgroundColor: scheme.surface,
                  indicatorColor: scheme.primary,
                  iconColorSelected: scheme.primary,
                ),
                bottomActionBarConfig: BottomActionBarConfig(
                  backgroundColor: scheme.surfaceContainerHigh,
                  buttonColor: scheme.surfaceContainerHigh,
                  buttonIconColor: scheme.onSurfaceVariant,
                ),
                searchViewConfig: SearchViewConfig(backgroundColor: scheme.surface, hintText: 'Emoji suchen'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _list(List<Map<String, dynamic>> messages, bool group) {
    // The newest at the bottom: built from there.
    final rows = <Widget>[];
    String? day;
    for (final message in messages) {
      final at = DateTime.tryParse(message['created_at'] as String? ?? '')?.toLocal();
      final key = at == null ? '' : dateFormat.format(at);
      if (key != day && at != null) {
        day = key;
        rows.add(_DayLabel(at));
      }
      rows.add(
        _Bubble(
          message: message,
          group: group,
          base: _base,
          onMenu: (at) => _messageMenu(message, at),
          onReaction: _canWrite ? (emoji) => _react(message, emoji) : null,
          onOpenFile: _openFile,
          avatar: _avatarOf(message),
        ),
      );
    }
    if (_more) {
      rows.insert(
        0,
        Center(
          child: TextButton(
            key: const Key('chat-older'),
            onPressed: _loadingOlder ? null : _loadOlder,
            child: const Text('Ältere Nachrichten laden'),
          ),
        ),
      );
    }
    final reversed = rows.reversed.toList();
    return ListView.builder(
      key: const Key('chat-messages'),
      reverse: true,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
      itemCount: reversed.length,
      itemBuilder: (context, index) => reversed[index],
    );
  }

  Widget _composer() {
    final replyTo = _replyTo;
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (replyTo != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: _Quote(
                replyTo,
                foreground: Theme.of(context).colorScheme.onSurface,
                onClose: () => setState(() => _replyTo = null),
              ),
            ),
          _inputRow(),
        ],
      ),
    );
  }

  Widget _inputRow() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        IconButton(
          key: const Key('chat-emoji'),
          tooltip: _emoji ? 'Tastatur' : 'Emojis',
          icon: Icon(_emoji ? Icons.keyboard_outlined : Icons.emoji_emotions_outlined),
          onPressed: _toggleEmoji,
        ),
        PopupMenuButton<bool>(
          key: const Key('chat-attach'),
          tooltip: 'Anhängen',
          icon: const Icon(Icons.attach_file),
          position: PopupMenuPosition.over,
          onSelected: (pictures) => _attach(pictures: pictures),
          itemBuilder: (context) => const [
            PopupMenuItem(
              value: true,
              child: ListTile(
                leading: Icon(Icons.image_outlined),
                title: Text('Bild'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
            PopupMenuItem(
              value: false,
              child: ListTile(
                leading: Icon(Icons.description_outlined),
                title: Text('Dokument'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ],
        ),
        Expanded(
          child: CallbackShortcuts(
            // On a keyboard Enter sends, Shift + Enter starts a new line.
            bindings: {
              const SingleActivator(LogicalKeyboardKey.enter): _send,
              const SingleActivator(LogicalKeyboardKey.numpadEnter): _send,
            },
            child: TextField(
              key: const Key('chat-input'),
              controller: _input,
              focusNode: _focus,
              minLines: 1,
              maxLines: 5,
              maxLength: 4000,
              textCapitalization: TextCapitalization.sentences,
              keyboardType: TextInputType.multiline,
              decoration: const InputDecoration(
                hintText: 'Nachricht',
                counterText: '',
                isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(24))),
              ),
            ),
          ),
        ),
        const SizedBox(width: 4),
        IconButton.filled(
          key: const Key('chat-send'),
          tooltip: 'Senden',
          icon: const Icon(Icons.send),
          onPressed: _sending || _input.text.trim().isEmpty ? null : _send,
        ),
      ],
    );
  }
}

class _DayLabel extends StatelessWidget {
  const _DayLabel(this.day);

  final DateTime day;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(day.year, day.month, day.day);
    final label = switch (today.difference(that).inDays) {
      0 => 'Heute',
      1 => 'Gestern',
      _ => dateFormat.format(day),
    };
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(10)),
        child: Text(label, style: Theme.of(context).textTheme.labelSmall),
      ),
    );
  }
}

/// One message: on the right one's own, on the left the others', in a group with the
/// name of who wrote it. Pictures show in it, documents as a row to open.
class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.message,
    required this.group,
    required this.base,
    required this.onMenu,
    required this.onOpenFile,
    this.onReaction,
    this.avatar,
  });

  final Map<String, dynamic> message;
  final bool group;
  final String base;

  /// Opens what to do with the message, where it was tapped.
  final void Function(Offset at) onMenu;
  final void Function(Map<String, dynamic> file) onOpenFile;

  /// Reacts with the emoji of a reaction that is there; null for who only reads.
  final void Function(String emoji)? onReaction;

  /// The picture of who wrote it, for the messages of others.
  final Widget? avatar;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final own = message['own'] == true;
    final deleted = message['deleted'] == true;
    final background = own ? scheme.primaryContainer : scheme.surfaceContainerHigh;
    final foreground = own ? scheme.onPrimaryContainer : scheme.onSurface;
    final files = (message['attachments'] as List? ?? const []).cast<Map<String, dynamic>>();
    final body = message['body'] as String? ?? '';
    final at = DateTime.tryParse(message['created_at'] as String? ?? '')?.toLocal();
    final senderColor = message['sender_color'] as String? ?? '';
    final session = SessionScope.of(context);
    final reactions = (message['reactions'] as List? ?? const []).cast<Map<String, dynamic>>();
    final reply = message['reply'] as Map<String, dynamic>?;
    final quiet = TextStyle(color: foreground.withValues(alpha: 0.7), fontStyle: FontStyle.italic);
    final bubble = Align(
      alignment: own ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        // Never the whole width, also on a small screen: the side it is on stays clear.
        constraints: BoxConstraints(
          maxWidth: min(
            420,
            MediaQuery.sizeOf(context).width * 0.8 - (own || this.avatar == null ? 0 : _avatarSize + _avatarGap),
          ),
        ),
        child: Column(
          crossAxisAlignment: own ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              key: ValueKey('chat-message-${message['id']}'),
              onTapUp: (details) => onMenu(details.globalPosition),
              onLongPressStart: (details) => onMenu(details.globalPosition),
              onSecondaryTapUp: (details) => onMenu(details.globalPosition),
              child: Container(
                margin: EdgeInsets.only(top: 2, bottom: reactions.isEmpty ? 8 : 2),
                padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
                decoration: BoxDecoration(
                  color: background,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(16),
                    topRight: const Radius.circular(16),
                    bottomLeft: Radius.circular(own ? 16 : 4),
                    bottomRight: Radius.circular(own ? 4 : 16),
                  ),
                ),
                // As wide as what it holds, so that a short message stays short; the time still sits on the right.
                child: IntrinsicWidth(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (group && !own)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: Text(
                            (message['sender_name'] as String? ?? '').isEmpty
                                ? 'Ehemaliges Mitglied'
                                : message['sender_name'] as String,
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: senderColor.isEmpty ? scheme.primary : parseHexColor(senderColor),
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      if (message['forwarded'] == true && !deleted)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.shortcut, size: 14, color: quiet.color),
                            const SizedBox(width: 4),
                            Text('Weitergeleitet', style: quiet.copyWith(fontSize: 12)),
                          ],
                        ),
                      if (reply != null && !deleted) _Quote(reply, foreground: foreground),
                      if (deleted) Text('Nachricht wurde gelöscht', style: quiet),
                      for (final file in files)
                        if (file['kind'] == 'photo')
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: InkWell(
                              key: ValueKey('chat-picture-${file['id']}'),
                              onTap: () => onOpenFile(file),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(10),
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 260,
                                    maxHeight: 320,
                                    minWidth: 120,
                                    minHeight: 80,
                                  ),
                                  child: FutureBuilder<Uint8List>(
                                    future: _picture(session, '$base/attachments/${file['id']}'),
                                    builder: (context, snapshot) => snapshot.hasData
                                        ? Image.memory(snapshot.data!, fit: BoxFit.cover)
                                        : Container(
                                            width: 200,
                                            height: 150,
                                            color: scheme.surfaceContainerHighest,
                                            child: snapshot.hasError ? const Icon(Icons.broken_image_outlined) : null,
                                          ),
                                  ),
                                ),
                              ),
                            ),
                          )
                        else
                          InkWell(
                            key: ValueKey('chat-file-${file['id']}'),
                            onTap: () => onOpenFile(file),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.description_outlined, color: foreground),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          file['name'] as String? ?? '',
                                          style: TextStyle(color: foreground, decoration: TextDecoration.underline),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        Text(
                                          _fileSize((file['size'] as num?) ?? 0),
                                          style: theme.textTheme.labelSmall?.copyWith(color: foreground),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      if (body.isNotEmpty) Text(body, style: TextStyle(color: foreground, fontSize: 15)),
                      Align(
                        alignment: Alignment.bottomRight,
                        child: Text(
                          at == null ? '' : timeFormat.format(at),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: foreground.withValues(alpha: 0.7),
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (reactions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    for (final reaction in reactions) _ReactionChip(message['id'] as String, reaction, onReaction),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
    final avatar = this.avatar;
    if (own || avatar == null) return bubble;
    // Who wrote it, small at the bottom left, as the line of the message ends there.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Padding(padding: const EdgeInsets.only(bottom: 8), child: avatar),
        const SizedBox(width: _avatarGap),
        Expanded(child: bubble),
      ],
    );
  }
}

/// A picture of a chat, large, to zoom and to save.
class _PictureScreen extends StatelessWidget {
  const _PictureScreen({required this.path, required this.name, required this.onDownload});

  final String path;
  final String name;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(name),
        actions: [IconButton(tooltip: 'Herunterladen', icon: const Icon(Icons.download), onPressed: onDownload)],
      ),
      body: FutureBuilder<Uint8List>(
        future: _picture(session, path),
        builder: (context, snapshot) => snapshot.hasData
            ? InteractiveViewer(maxScale: 5, child: Center(child: Image.memory(snapshot.data!)))
            : const Center(child: CircularProgressIndicator()),
      ),
    );
  }
}

/// The chat behind a notification: shows it once the circle is known.
class ChatFromNotification extends StatelessWidget {
  const ChatFromNotification({super.key, required this.familyId, required this.chatId});

  final String familyId;
  final String chatId;

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    if (!session.families.any((f) => f.id == familyId)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Nachrichten')),
        body: const EmptyHint(icon: Icons.chat_bubble_outline, text: 'Diesen Kreis gibt es für dich nicht mehr.'),
      );
    }
    return ChatScreen(familyId: familyId, chatId: chatId);
  }
}

/// The reactions offered first; „Mehr“ shows all emojis.
const quickReactions = ['❤️', '👍', '👎', '🔥', '🥰', '👏', '😁', '🙏'];

/// Asks for an emoji to react with: one of [quickReactions], or any other. Null when
/// left without choosing.
Future<String?> pickReaction(BuildContext context, {String? current}) {
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => _ReactionPicker(current: current),
  );
}

class _ReactionPicker extends StatefulWidget {
  const _ReactionPicker({this.current});

  final String? current;

  @override
  State<_ReactionPicker> createState() => _ReactionPickerState();
}

class _ReactionPickerState extends State<_ReactionPicker> {
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_all) {
      return SafeArea(
        child: EmojiPicker(
          onEmojiSelected: (_, emoji) => Navigator.pop(context, emoji.emoji),
          config: Config(
            height: 320,
            locale: const Locale('de'),
            checkPlatformCompatibility: !kIsWeb,
            emojiViewConfig: EmojiViewConfig(backgroundColor: scheme.surface),
            categoryViewConfig: CategoryViewConfig(
              backgroundColor: scheme.surface,
              indicatorColor: scheme.primary,
              iconColorSelected: scheme.primary,
            ),
            bottomActionBarConfig: BottomActionBarConfig(
              backgroundColor: scheme.surfaceContainerHigh,
              buttonColor: scheme.surfaceContainerHigh,
              buttonIconColor: scheme.onSurfaceVariant,
              showBackspaceButton: false,
            ),
            searchViewConfig: SearchViewConfig(backgroundColor: scheme.surface, hintText: 'Emoji suchen'),
          ),
        ),
      );
    }
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 4,
          runSpacing: 4,
          children: [
            for (final emoji in quickReactions)
              InkResponse(
                key: ValueKey('reaction-$emoji'),
                radius: 28,
                onTap: () => Navigator.pop(context, emoji),
                child: Container(
                  width: 48,
                  height: 48,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: emoji == widget.current ? scheme.primaryContainer : null,
                  ),
                  child: Text(emoji, style: const TextStyle(fontSize: 28)),
                ),
              ),
            IconButton.filledTonal(
              key: const Key('reaction-more'),
              tooltip: 'Mehr',
              iconSize: 28,
              icon: const Icon(Icons.add),
              onPressed: () => setState(() => _all = true),
            ),
          ],
        ),
      ),
    );
  }
}

/// One emoji under a message, with how many reacted so; tapping it reacts the same,
/// or takes one's own back.
class _ReactionChip extends StatelessWidget {
  const _ReactionChip(this.messageId, this.reaction, this.onReaction);

  final String messageId;
  final Map<String, dynamic> reaction;
  final void Function(String emoji)? onReaction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final emoji = reaction['emoji'] as String;
    final count = (reaction['count'] as num?)?.toInt() ?? 1;
    final mine = reaction['mine'] == true;
    final names = (reaction['names'] as List? ?? const []).cast<String>();
    final onReaction = this.onReaction;
    return Tooltip(
      message: names.join(', '),
      child: Material(
        key: ValueKey('chat-reaction-$messageId-$emoji'),
        color: mine ? scheme.primaryContainer : scheme.surfaceContainerHighest,
        shape: StadiumBorder(side: BorderSide(color: mine ? scheme.primary : scheme.outlineVariant)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onReaction == null ? null : () => onReaction(emoji),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            child: Text(count > 1 ? '$emoji $count' : emoji, style: const TextStyle(fontSize: 15)),
          ),
        ),
      ),
    );
  }
}

/// What a message shows of the one it answers: who wrote it and the start of it.
class _Quote extends StatelessWidget {
  const _Quote(this.reply, {required this.foreground, this.onClose});

  final Map<String, dynamic> reply;
  final Color foreground;

  /// Shows a button to drop the answer, above the field.
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = reply['sender_name'] as String? ?? '';
    final text = reply['deleted'] == true ? 'Nachricht wurde gelöscht' : messagePreview(reply);
    return Container(
      key: Key(onClose == null ? 'chat-quote' : 'chat-reply'),
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
      decoration: BoxDecoration(
        color: foreground.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(8),
        border: Border(left: BorderSide(color: scheme.primary, width: 3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            fit: onClose == null ? FlexFit.loose : FlexFit.tight,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  name.isEmpty ? 'Ehemaliges Mitglied' : name,
                  style: TextStyle(color: scheme.primary, fontWeight: FontWeight.bold, fontSize: 12),
                ),
                Text(
                  text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: foreground.withValues(alpha: 0.8), fontSize: 13),
                ),
              ],
            ),
          ),
          if (onClose != null)
            IconButton(
              key: const Key('chat-reply-cancel'),
              tooltip: 'Nicht antworten',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close, size: 18),
              onPressed: onClose,
            ),
        ],
      ),
    );
  }
}

/// Picks the chat a message goes on to: any the user writes in, in all circles.
/// Pops with its name once it is sent.
class _ForwardScreen extends StatefulWidget {
  const _ForwardScreen({required this.familyId, required this.message});

  /// The circle the message is in.
  final String familyId;
  final Map<String, dynamic> message;

  @override
  State<_ForwardScreen> createState() => _ForwardScreenState();
}

class _ForwardScreenState extends State<_ForwardScreen> {
  final _search = TextEditingController();
  List<Map<String, dynamic>>? _chats;
  String? _error;
  bool _sending = false;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final session = SessionScope.of(context);
    try {
      final rows = (await session.api.get('/api/chats') as List).cast<Map<String, dynamic>>();
      if (mounted) setState(() => _chats = rows.where((c) => c['can_write'] == true).toList());
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _send(Map<String, dynamic> chat) async {
    if (_sending) return;
    final name = chat['name'] as String? ?? '';
    if (!await confirm(context, 'An „$name“ weiterleiten?', action: 'Weiterleiten') || !mounted) return;
    final session = SessionScope.of(context);
    final navigator = Navigator.of(context);
    setState(() => _sending = true);
    final ok = await guarded(
      context,
      () => session.api.post('/api/families/${chat['family_id']}/chats/${chat['id']}/messages', {
        'forward_of': widget.message['id'],
        'forward_family_id': widget.familyId,
      }),
    );
    if (!mounted) return;
    setState(() => _sending = false);
    if (ok) navigator.pop(name);
  }

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    final key = _search.text.trim().toLowerCase();
    final chats = _chats?.where((c) => (c['name'] as String? ?? '').toLowerCase().contains(key)).toList();
    final several = session.families.length > 1;
    final message = widget.message;
    final files = (message['attachments'] as List? ?? const []).cast<Map<String, dynamic>>();
    final body = message['body'] as String? ?? '';
    final preview = body.isNotEmpty ? body : files.map((f) => '📎 ${f['name']}').join(', ');
    return Scaffold(
      appBar: AppBar(title: const Text('Weiterleiten an')),
      body: Column(
        children: [
          if (_sending) const LinearProgressIndicator(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                preview,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontStyle: FontStyle.italic),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              key: const Key('forward-search'),
              controller: _search,
              decoration: const InputDecoration(hintText: 'Chat suchen', prefixIcon: Icon(Icons.search), isDense: true),
            ),
          ),
          Expanded(
            child: chats == null
                ? Center(child: _error == null ? const CircularProgressIndicator() : Text(_error!))
                : chats.isEmpty
                ? const EmptyHint(icon: Icons.chat_bubble_outline, text: 'Kein Chat gefunden.')
                : ListView(
                    padding: scrollPadding(context, EdgeInsets.zero),
                    children: [
                      for (final chat in chats)
                        ListTile(
                          key: ValueKey('forward-${chat['id']}'),
                          leading: ChatAvatar(chat, radius: 20),
                          title: Text(chat['name'] as String? ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
                          trailing: several ? CircleLabel(chat['family_id'] as String) : null,
                          onTap: () => _send(chat),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
