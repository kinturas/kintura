import 'package:flutter/material.dart';

import '../common.dart';
import '../session.dart';

Future<Map<String, dynamic>> _loadColors(AppSession session) async =>
    await session.api.get('${session.familyPath}/colors') as Map<String, dynamic>;

class ColorsTab extends StatefulWidget {
  const ColorsTab({super.key});

  @override
  State<ColorsTab> createState() => ColorsTabState();
}

class ColorsTabState extends State<ColorsTab> {
  final _view = GlobalKey<AsyncViewState<Map<String, dynamic>>>();

  /// Creates a color, or changes [color] if given.
  Future<void> _edit([Map<String, dynamic>? color]) async {
    final session = SessionScope.of(context);
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => _ColorDialog(color),
    );
    if (result == null || !mounted) return;
    final path = '${session.familyPath}/colors';
    final ok = await guarded(context, () async {
      if (color == null) {
        await session.api.post(path, result);
      } else {
        await session.api.put('$path/${color['id']}', result);
        // The color may be the user's own.
        await session.refresh();
      }
    });
    if (ok) _view.currentState?.reload();
  }

  Future<void> _delete(Map<String, dynamic> color) async {
    final session = SessionScope.of(context);
    if (!await confirm(context, '„${color['label']}“ löschen?') || !mounted) return;
    final ok = await guarded(
      context,
      () => session.api.delete('${session.familyPath}/colors/${color['id']}'),
    );
    if (ok) _view.currentState?.reload();
  }

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
  );

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    final isAdmin = session.current!.isAdmin;
    return AsyncView<Map<String, dynamic>>(
      key: _view,
      load: () => _loadColors(session),
      builder: (context, data) {
        final custom = (data['custom'] as List).cast<Map<String, dynamic>>();
        return ListView(
          children: [
            _heading('Eigene Farben'),
            if (custom.isEmpty && !isAdmin)
              const ListTile(title: Text('Noch keine eigenen Farben')),
            for (final color in custom)
              ListTile(
                key: ValueKey(color['id'] as String),
                leading: ColorDot(color['color'] as String),
                title: Text(color['label'] as String),
                subtitle: Text(color['color'] as String),
                onTap: isAdmin ? () => _edit(color) : null,
                trailing: isAdmin
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.edit_outlined),
                          const SizedBox(width: 8),
                          // Colors in use cannot be deleted.
                          if (color['used'] == true)
                            const Tooltip(
                              message: 'Wird verwendet',
                              child: Padding(
                                padding: EdgeInsets.all(8),
                                child: Icon(Icons.lock_outline),
                              ),
                            )
                          else
                            IconButton(
                              tooltip: 'Löschen',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => _delete(color),
                            ),
                        ],
                      )
                    : null,
              ),
            if (isAdmin)
              Padding(
                padding: const EdgeInsets.all(16),
                child: OutlinedButton.icon(
                  onPressed: _edit,
                  icon: const Icon(Icons.add),
                  label: const Text('Farbe hinzufügen'),
                ),
              ),
            const Divider(height: 1),
            _heading('Stammfarben'),
            for (final color in (data['base'] as List).cast<Map<String, dynamic>>())
              ListTile(
                key: ValueKey(color['color'] as String),
                leading: ColorDot(color['color'] as String),
                title: Text(color['label'] as String),
                subtitle: Text(color['color'] as String),
              ),
          ],
        );
      },
    );
  }
}

/// Asks for text and value of a custom color and returns them as JSON fields.
class _ColorDialog extends StatefulWidget {
  const _ColorDialog(this.color);

  final Map<String, dynamic>? color;

  @override
  State<_ColorDialog> createState() => _ColorDialogState();
}

class _ColorDialogState extends State<_ColorDialog> {
  static final _hexPattern = RegExp(r'^#[0-9A-Fa-f]{6}$');

  late final _label = TextEditingController(text: widget.color?['label'] as String? ?? '');
  // The start value is no base color, so that saving it right away works.
  late final _hex = TextEditingController(text: widget.color?['color'] as String? ?? '#5C7CFA');
  late HSVColor _hsv = HSVColor.fromColor(parseHexColor(_hex.text));

  bool get _valid => _label.text.trim().isNotEmpty && _hexPattern.hasMatch(_hex.text);

  @override
  void dispose() {
    _label.dispose();
    _hex.dispose();
    super.dispose();
  }

  void _setHsv(HSVColor hsv) => setState(() {
    _hsv = hsv;
    _hex.text = toHexColor(hsv.toColor());
  });

  void _hexChanged(String value) => setState(() {
    if (_hexPattern.hasMatch(value)) _hsv = HSVColor.fromColor(parseHexColor(value));
  });

  Widget _slider(String label, double value, double max, ValueChanged<double> onChanged) {
    return Row(
      children: [
        SizedBox(width: 88, child: Text(label)),
        Expanded(
          child: Slider(value: value, max: max, onChanged: onChanged),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.color == null ? 'Farbe hinzufügen' : 'Farbe ändern'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const Key('color-label'),
                controller: _label,
                autofocus: widget.color == null,
                maxLength: 30,
                decoration: const InputDecoration(labelText: 'Text'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 8),
              Container(
                key: const Key('color-preview'),
                height: 56,
                decoration: BoxDecoration(
                  color: _hsv.toColor(),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                ),
              ),
              const SizedBox(height: 8),
              _slider('Farbton', _hsv.hue, 360, (v) => _setHsv(_hsv.withHue(v))),
              _slider('Sättigung', _hsv.saturation, 1, (v) => _setHsv(_hsv.withSaturation(v))),
              _slider('Helligkeit', _hsv.value, 1, (v) => _setHsv(_hsv.withValue(v))),
              TextField(
                key: const Key('color-hex'),
                controller: _hex,
                decoration: const InputDecoration(labelText: 'Farbwert'),
                onChanged: _hexChanged,
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
          onPressed: _valid
              ? () => Navigator.pop(context, {
                  'color': _hex.text,
                  'label': _label.text.trim(),
                })
              : null,
          child: const Text('Speichern'),
        ),
      ],
    );
  }
}

class CategoriesTab extends StatefulWidget {
  const CategoriesTab({super.key});

  @override
  State<CategoriesTab> createState() => CategoriesTabState();
}

class CategoriesTabState extends State<CategoriesTab> {
  final _view = GlobalKey<AsyncViewState<Map<String, dynamic>>>();

  /// Creates a category, or changes [category] if given.
  Future<void> _edit(Map<String, dynamic> colors, [Map<String, dynamic>? category]) async {
    final session = SessionScope.of(context);
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => _CategoryDialog(colors, category),
    );
    if (result == null || !mounted) return;
    final path = '${session.familyPath}/categories';
    final ok = await guarded(context, () async {
      if (category == null) {
        await session.api.post(path, result);
      } else {
        await session.api.put('$path/${category['id']}', result);
      }
    });
    if (ok) _view.currentState?.reload();
  }

  Future<void> _delete(Map<String, dynamic> category) async {
    final session = SessionScope.of(context);
    if (!await confirm(context, '„${category['name']}“ löschen?') || !mounted) return;
    final ok = await guarded(
      context,
      () => session.api.delete('${session.familyPath}/categories/${category['id']}'),
    );
    if (ok) _view.currentState?.reload();
  }

  /// Shows the change at once and goes back to the saved order if it fails.
  Future<void> _move(List<dynamic> categories, int oldIndex, int newIndex) async {
    if (newIndex == oldIndex) return;
    final session = SessionScope.of(context);
    setState(() => categories.insert(newIndex, categories.removeAt(oldIndex)));
    final ok = await guarded(
      context,
      () => session.api.put('${session.familyPath}/categories/order', {
        'ids': [for (final category in categories) category['id']],
      }),
    );
    if (!ok) _view.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    final isAdmin = session.current!.isAdmin;
    return AsyncView<Map<String, dynamic>>(
      key: _view,
      load: () async {
        final colors = await _loadColors(session);
        final data = await session.api.get('${session.familyPath}/categories') as Map<String, dynamic>;
        return {...data, 'colors': colors};
      },
      builder: (context, data) {
        final colors = data['colors'] as Map<String, dynamic>;
        final categories = data['categories'] as List<dynamic>;
        return ReorderableListView.builder(
          buildDefaultDragHandles: false,
          footer: isAdmin
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: OutlinedButton.icon(
                    onPressed: () => _edit(colors),
                    icon: const Icon(Icons.add),
                    label: const Text('Kategorie hinzufügen'),
                  ),
                )
              : null,
          itemCount: categories.length,
          onReorderItem: (oldIndex, newIndex) => _move(categories, oldIndex, newIndex),
          itemBuilder: (context, index) {
            final category = categories[index] as Map<String, dynamic>;
            final color = category['color'] as String;
            return ListTile(
              key: ValueKey(category['id'] as String),
              leading: ColorDot(color),
              title: Text(category['name'] as String),
              subtitle: Text(color.isEmpty ? 'Keine Farbe' : colorLabel(colors, color)),
              onTap: isAdmin ? () => _edit(colors, category) : null,
              trailing: isAdmin
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.edit_outlined),
                        const SizedBox(width: 8),
                        category['used'] == true
                            ? const Tooltip(
                                message: 'Wird von Terminen verwendet',
                                child: Padding(
                                  padding: EdgeInsets.all(8),
                                  child: Icon(Icons.lock_outline),
                                ),
                              )
                            : IconButton(
                                tooltip: 'Löschen',
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () => _delete(category),
                              ),
                        const SizedBox(width: 8),
                        ReorderableDragStartListener(
                          index: index,
                          child: const Icon(Icons.drag_handle),
                        ),
                      ],
                    )
                  : null,
            );
          },
        );
      },
    );
  }
}

/// Asks for name and color of a category and returns them as JSON fields.
class _CategoryDialog extends StatefulWidget {
  const _CategoryDialog(this.colors, this.category);

  final Map<String, dynamic> colors;
  final Map<String, dynamic>? category;

  @override
  State<_CategoryDialog> createState() => _CategoryDialogState();
}

class _CategoryDialogState extends State<_CategoryDialog> {
  late final _name = TextEditingController(text: widget.category?['name'] as String? ?? '');
  late String _color = widget.category?['color'] as String? ?? '';

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.category == null ? 'Kategorie hinzufügen' : 'Kategorie ändern'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _name,
                autofocus: widget.category == null,
                maxLength: 50,
                decoration: const InputDecoration(labelText: 'Name'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 16),
              ColorChooser(
                colors: widget.colors,
                selected: _color,
                onSelected: (color) => setState(() => _color = color),
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
          onPressed: _name.text.trim().isEmpty
              ? null
              : () => Navigator.pop(context, {
                  'name': _name.text.trim(),
                  'color': _color,
                }),
          child: const Text('Speichern'),
        ),
      ],
    );
  }
}
