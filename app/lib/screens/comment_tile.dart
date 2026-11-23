import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../common.dart';
import '../session.dart';

/// One comment, on an event or a shopping list: who wrote it and when, its words, and
/// on the right a menu to change one's own or delete it; an admin may delete anyone's.
/// A deleted comment stays in its place as a note of who deleted it.
class CommentTile extends StatelessWidget {
  const CommentTile({super.key, required this.comment, required this.path, required this.onChanged});

  final Map<String, dynamic> comment;

  /// Where the comments are, without the comment's id.
  final String path;

  /// After it was changed or deleted.
  final Future<void> Function() onChanged;

  String get _id => comment['id'] as String;

  Future<void> _edit(BuildContext context) async {
    final session = SessionScope.of(context);
    final body = await showDialog<String>(
      context: context,
      builder: (_) => _EditCommentDialog(body: comment['body'] as String),
    );
    if (body == null || body == comment['body'] || !context.mounted) return;
    if (await guarded(context, () => session.api.put('$path/$_id', {'body': body}))) await onChanged();
  }

  Future<void> _delete(BuildContext context) async {
    final session = SessionScope.of(context);
    if (!await confirm(context, 'Kommentar löschen?', message: 'An seiner Stelle steht dann, wer ihn gelöscht hat.') ||
        !context.mounted) {
      return;
    }
    if (await guarded(context, () => session.api.delete('$path/$_id'))) await onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final author = comment['author_name'] as String? ?? '';
    final deleted = comment['deleted'] == true;
    final canEdit = comment['can_edit'] == true;
    final canDelete = comment['can_delete'] == true;
    final DateFormat format = DateFormat('dd.MM.yyyy, HH:mm', 'de');
    final by = comment['deleted_by_name'] as String? ?? '';
    return Padding(
      key: ValueKey('comment-$_id'),
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  [
                    if (author.isNotEmpty) author,
                    format.format(DateTime.parse(comment['created_at'] as String).toLocal()),
                    if (comment['edited_at'] != null && !deleted) 'bearbeitet',
                  ].join(' · '),
                  style: theme.textTheme.labelSmall,
                ),
                const SizedBox(height: 2),
                if (deleted)
                  Text(
                    by.isEmpty ? 'Kommentar wurde gelöscht.' : 'Kommentar wurde von $by gelöscht.',
                    style: TextStyle(fontStyle: FontStyle.italic, color: theme.colorScheme.onSurfaceVariant),
                  )
                else
                  Text(comment['body'] as String),
              ],
            ),
          ),
          if (canEdit || canDelete)
            PopupMenuButton<String>(
              key: ValueKey('comment-menu-$_id'),
              tooltip: 'Kommentar bearbeiten oder löschen',
              icon: const Icon(Icons.more_vert, size: 20),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              onSelected: (choice) => choice == 'edit' ? _edit(context) : _delete(context),
              itemBuilder: (_) => [
                if (canEdit)
                  const PopupMenuItem(
                    value: 'edit',
                    child: ListTile(leading: Icon(Icons.edit_outlined), title: Text('Bearbeiten')),
                  ),
                if (canDelete)
                  const PopupMenuItem(
                    value: 'delete',
                    child: ListTile(leading: Icon(Icons.delete_outline), title: Text('Löschen')),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _EditCommentDialog extends StatefulWidget {
  const _EditCommentDialog({required this.body});

  final String body;

  @override
  State<_EditCommentDialog> createState() => _EditCommentDialogState();
}

class _EditCommentDialogState extends State<_EditCommentDialog> {
  late final _body = TextEditingController(text: widget.body);

  @override
  void initState() {
    super.initState();
    _body.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final body = _body.text.trim();
    return AlertDialog(
      title: const Text('Kommentar bearbeiten'),
      content: SizedBox(
        width: 480,
        child: TextField(
          key: const Key('comment-edit'),
          controller: _body,
          autofocus: true,
          minLines: 1,
          maxLines: 8,
          maxLength: 2000,
          textCapitalization: TextCapitalization.sentences,
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Abbrechen')),
        FilledButton(
          key: const Key('comment-edit-save'),
          onPressed: body.isEmpty ? null : () => Navigator.pop(context, _body.text.trim()),
          child: const Text('Speichern'),
        ),
      ],
    );
  }
}
