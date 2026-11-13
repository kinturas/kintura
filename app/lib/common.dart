import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'api.dart';
import 'session.dart';

/// Roles that can be assigned; guest follows with the kiosk mode.
const assignableRoles = ['manager', 'user', 'restrict_user'];

/// First letters of the first and last word, e.g. AM for Anna Maria Müller.
String initials(String name) {
  final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return '?';
  String first(String word) => String.fromCharCode(word.runes.first).toUpperCase();
  return words.length == 1 ? first(words.first) : first(words.first) + first(words.last);
}

Color parseHexColor(String hex) => Color(int.parse('FF${hex.substring(1)}', radix: 16));

String toHexColor(Color color) =>
    '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

/// Black or white, whichever stays readable on [background].
Color readableOn(Color background) =>
    ThemeData.estimateBrightnessForColor(background) == Brightness.dark ? Colors.white : Colors.black;

/// The colors of a header tinted in the color of [family]; both null without one.
({Color? background, Color? foreground}) familyHeaderColors(Family? family) {
  final color = family?.familyColor ?? '';
  if (color.isEmpty) return (background: null, foreground: null);
  final background = parseHexColor(color);
  return (background: background, foreground: readableOn(background));
}

class UserAvatar extends StatelessWidget {
  const UserAvatar(this.name, {super.key, this.color = '', this.photo = '', this.radius = 18});

  final String name;

  /// Hex value; empty keeps the default colors of the theme.
  final String color;

  /// The small profile photo as GET members sends it, Base64 JPEG; empty shows the initials.
  final String photo;
  final double radius;

  // The same photo shows in many places; decoding it once is enough.
  static final _decoded = <String, MemoryImage>{};

  static MemoryImage? _image(String photo) {
    if (photo.isEmpty) return null;
    final cached = _decoded.remove(photo);
    if (cached != null) return _decoded[photo] = cached;
    try {
      final image = MemoryImage(base64Decode(photo));
      if (_decoded.length >= 200) _decoded.remove(_decoded.keys.first);
      return _decoded[photo] = image;
    } on FormatException {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final background = color.isEmpty ? null : parseHexColor(color);
    final image = _image(photo);
    return CircleAvatar(
      key: image == null ? null : const ValueKey('avatar-photo'),
      radius: radius,
      backgroundColor: background,
      foregroundColor: background == null ? null : readableOn(background),
      foregroundImage: image,
      child: Text(initials(name), style: radius > 24 ? TextStyle(fontSize: radius * 0.7) : null),
    );
  }
}

/// A round sample of a color; empty stands for no color.
class ColorDot extends StatelessWidget {
  const ColorDot(this.color, {super.key});

  final String color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.isEmpty ? null : parseHexColor(color),
        // Keeps very light colors visible on a light page.
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: color.isEmpty
          ? Icon(Icons.format_color_reset_outlined, size: 16, color: scheme.onSurfaceVariant)
          : null,
    );
  }
}

/// The name of [color] in the color table from GET colors, empty if it is not listed.
String colorLabel(Map<String, dynamic> colors, String color) {
  for (final entry in [...colors['custom'] as List, ...colors['base'] as List]) {
    if (entry['color'] == color) return entry['label'] as String;
  }
  return '';
}

/// Lets the user pick from the color table of a family, as served by GET colors.
class ColorChooser extends StatelessWidget {
  const ColorChooser({
    super.key,
    required this.colors,
    required this.selected,
    required this.onSelected,
    this.allowNone = true,
    this.singleList = false,
  });

  final Map<String, dynamic> colors;
  final String selected;
  final ValueChanged<String> onSelected;

  /// Offers "Keine Farbe", which is reported as an empty value.
  final bool allowNone;

  /// One list without headings, with the colors of the family at the end.
  final bool singleList;

  /// The colors something in the family already shows, in capitals; null from a
  /// server that does not say, and then every color looks taken as before.
  Set<String>? get _inUse {
    final list = colors['in_use'] as List?;
    return list == null ? null : {for (final color in list) (color as String).toUpperCase()};
  }

  Widget _swatch(BuildContext context, String color, String label, Set<String>? inUse) {
    final scheme = Theme.of(context).colorScheme;
    final isSelected = color == selected;
    final background = color.isEmpty ? null : parseHexColor(color);
    // A free color is only a thick ring; what is taken, or chosen here, is filled.
    final free = background != null && !isSelected && inUse != null && !inUse.contains(color.toUpperCase());
    return Tooltip(
      message: label,
      child: InkWell(
        key: color.isEmpty ? null : ValueKey('swatch-$color-${free ? 'free' : 'used'}'),
        customBorder: const CircleBorder(),
        onTap: () => onSelected(color),
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: free ? null : background,
            border: isSelected
                ? Border.all(color: scheme.onSurface, width: 3)
                : free
                ? Border.all(color: background, width: 5)
                : Border.all(color: scheme.outlineVariant),
          ),
          child: isSelected
              ? Icon(Icons.check, color: background == null ? scheme.onSurface : readableOn(background))
              : background == null
              ? Icon(Icons.format_color_reset_outlined, color: scheme.onSurfaceVariant)
              : null,
        ),
      ),
    );
  }

  Widget _group(BuildContext context, String title, List<dynamic> group, Set<String>? inUse) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          Wrap(
            spacing: 14,
            runSpacing: 14,
            children: [
              for (final entry in group)
                _swatch(context, entry['color'] as String, entry['label'] as String, inUse),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final custom = colors['custom'] as List;
    final inUse = _inUse;
    // Says what the filled swatches mean, once the server tells which colors are taken.
    final legend = inUse == null
        ? null
        : Padding(
            key: const Key('colors-in-use-hint'),
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              'Farben, die ausgefüllt sind, werden bereits verwendet.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          );
    if (singleList) {
      final swatches = Wrap(
        spacing: 14,
        runSpacing: 14,
        children: [
          if (allowNone) _swatch(context, '', 'Keine Farbe', inUse),
          for (final entry in [...colors['base'] as List, ...custom])
            _swatch(context, entry['color'] as String, entry['label'] as String, inUse),
        ],
      );
      if (legend == null) return swatches;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [legend, swatches],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ?legend,
        if (allowNone)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: _swatch(context, '', 'Keine Farbe', inUse),
          ),
        if (custom.isNotEmpty) _group(context, 'Eigene Farben', custom, inUse),
        _group(context, 'Stammfarben', colors['base'] as List, inUse),
      ],
    );
  }
}

/// What an admin decides about the color of a member: the color itself, in the
/// same list as in the profile, and whether the member may change it.
class ProfileColorFields extends StatelessWidget {
  const ProfileColorFields({
    super.key,
    required this.colors,
    required this.color,
    required this.canChange,
    required this.onColor,
    required this.onCanChange,
  });

  final Map<String, dynamic> colors;
  final String color;
  final bool canChange;
  final ValueChanged<String> onColor;
  final ValueChanged<bool> onCanChange;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Profilfarbe', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 12),
        ColorChooser(colors: colors, singleList: true, selected: color, onSelected: onColor),
        const SizedBox(height: 8),
        SwitchListTile(
          key: const Key('can-change-color'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Darf Profilfarbe selbst ändern'),
          value: canChange,
          onChanged: onCanChange,
        ),
      ],
    );
  }
}

class FamilyTypeField extends StatelessWidget {
  const FamilyTypeField({super.key, required this.value, required this.onChanged});

  final FamilyType value;
  final ValueChanged<FamilyType> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<FamilyType>(
      initialValue: value,
      decoration: const InputDecoration(labelText: 'Typ'),
      items: [
        for (final type in FamilyType.values)
          DropdownMenuItem(value: type, child: Text(type.label)),
      ],
      onChanged: (type) => onChanged(type!),
    );
  }
}

final dateFormat = DateFormat('dd.MM.yyyy', 'de');
final weekdayDateFormat = DateFormat('EEEE, d. MMMM', 'de');
final timeFormat = DateFormat('HH:mm', 'de');
final _dateKeyFormat = DateFormat('yyyy-MM-dd');

String dateKey(DateTime date) => _dateKeyFormat.format(date);

const maxUploadBytes = 25 * 1024 * 1024;

String formatFileSize(num bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}

/// Runs [action] and shows failures as a snackbar. Returns whether it succeeded.
Future<bool> guarded(
  BuildContext context,
  Future<void> Function() action,
) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await action();
    return true;
  } on ApiException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
    return false;
  }
}

Future<bool> confirm(
  BuildContext context,
  String title, {
  String action = 'Löschen',
  String cancel = 'Abbrechen',
  String? message,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: message == null ? null : Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(action),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// Loads data, shows progress and errors, and keeps the old data while reloading.
class AsyncView<T> extends StatefulWidget {
  const AsyncView({super.key, required this.load, required this.builder});

  final Future<T> Function() load;
  final Widget Function(BuildContext context, T data) builder;

  @override
  State<AsyncView<T>> createState() => AsyncViewState<T>();
}

class AsyncViewState<T> extends State<AsyncView<T>> {
  T? _data;
  String? _error;

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    try {
      final data = await widget.load();
      if (mounted) {
        setState(() {
          _data = data;
          _error = null;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    if (data != null) return widget.builder(context, data);
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: reload,
              child: const Text('Erneut versuchen'),
            ),
          ],
        ),
      );
    }
    return const Center(child: CircularProgressIndicator());
  }
}

class EmptyHint extends StatelessWidget {
  const EmptyHint({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: color),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center, style: TextStyle(color: color)),
          ],
        ),
      ),
    );
  }
}

/// Asks for a single line of text. Returns null if cancelled.
Future<String?> promptText(
  BuildContext context, {
  required String title,
  required String label,
  String initial = '',
  String action = 'Speichern',
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _PromptDialog(
      title: title,
      label: label,
      initial: initial,
      action: action,
    ),
  );
}

class _PromptDialog extends StatefulWidget {
  const _PromptDialog({
    required this.title,
    required this.label,
    required this.initial,
    required this.action,
  });

  final String title, label, initial, action;

  @override
  State<_PromptDialog> createState() => _PromptDialogState();
}

class _PromptDialogState extends State<_PromptDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _controller.text.trim());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(labelText: widget.label),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Abbrechen'),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.action)),
      ],
    );
  }
}

/// A form field that opens the date picker.
class DateField extends StatelessWidget {
  const DateField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.clearable = false,
  });

  final String label;
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;
  final bool clearable;

  @override
  Widget build(BuildContext context) {
    final date = value;
    return InkWell(
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: date ?? DateTime.now(),
          firstDate: DateTime(1900),
          lastDate: DateTime(2100),
        );
        if (picked != null) onChanged(picked);
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          suffixIcon: clearable && date != null
              ? IconButton(
                  tooltip: 'Datum entfernen',
                  icon: const Icon(Icons.clear),
                  onPressed: () => onChanged(null),
                )
              : const Icon(Icons.calendar_today_outlined),
        ),
        child: Text(date == null ? 'Kein Datum' : dateFormat.format(date)),
      ),
    );
  }
}
