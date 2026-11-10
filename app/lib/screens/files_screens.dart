import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../common.dart';
import '../session.dart';

Future<void> _pickAndUpload(
  BuildContext context,
  String kind,
  FileType type,
) async {
  final session = SessionScope.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final files = await FilePicker.pickFiles(type: type);
  for (final file in files) {
    final length = file.lengthSync() ?? await file.length();
    if (length != null && length > maxUploadBytes) {
      messenger.showSnackBar(
        SnackBar(content: Text('${file.name} ist größer als 25 MB.')),
      );
      continue;
    }
    try {
      await session.api.upload(
        '${session.familyPath}/files?kind=$kind',
        file.name,
        await file.readAsBytes(),
      );
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('${file.name}: ${e.message}')));
    }
  }
}

/// Downloads through a short-lived link in the system browser.
Future<void> _download(BuildContext context, String fileId) => guarded(context, () async {
  final session = SessionScope.of(context);
  final result = await session.api.post('${session.familyPath}/files/$fileId/link');
  await launchUrl(
    Uri.parse(result['url'] as String),
    mode: LaunchMode.externalApplication,
  );
});

class DocumentsScreen extends StatefulWidget {
  const DocumentsScreen({super.key});

  @override
  State<DocumentsScreen> createState() => _DocumentsScreenState();
}

class _DocumentsScreenState extends State<DocumentsScreen> {
  final _view = GlobalKey<AsyncViewState<List<dynamic>>>();

  Future<void> _delete(Map<String, dynamic> file) async {
    final session = SessionScope.of(context);
    if (!await confirm(context, '„${file['name']}“ löschen?') || !mounted) return;
    await guarded(
      context,
      () => session.api.delete('${session.familyPath}/files/${file['id']}'),
    );
    _view.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Dokumente')),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Dokument hochladen',
        onPressed: () async {
          await _pickAndUpload(context, 'document', FileType.any);
          _view.currentState?.reload();
        },
        child: const Icon(Icons.upload_file),
      ),
      body: AsyncView<List<dynamic>>(
        key: _view,
        load: () async =>
            await session.api.get('${session.familyPath}/files?kind=document') as List,
        builder: (context, files) {
          if (files.isEmpty) {
            return const EmptyHint(
              icon: Icons.folder_outlined,
              text: 'Noch keine Dokumente hochgeladen.',
            );
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: 88),
            children: [
              for (final file in files.cast<Map<String, dynamic>>())
                ListTile(
                  leading: const Icon(Icons.description_outlined),
                  title: Text(file['name'] as String),
                  subtitle: Text(
                    '${formatFileSize(file['size'] as num)} ·${file['uploaded_by_name']} · '
                    '${dateFormat.format(DateTime.parse(file['created_at'] as String).toLocal())}',
                  ),
                  onTap: () => _download(context, file['id'] as String),
                  trailing: IconButton(
                    tooltip: 'Löschen',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _delete(file),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class PhotosScreen extends StatefulWidget {
  const PhotosScreen({super.key});

  @override
  State<PhotosScreen> createState() => _PhotosScreenState();
}

class _PhotosScreenState extends State<PhotosScreen> {
  final _view = GlobalKey<AsyncViewState<List<dynamic>>>();

  @override
  Widget build(BuildContext context) {
    final session = SessionScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Fotos')),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Fotos hochladen',
        onPressed: () async {
          await _pickAndUpload(context, 'photo', FileType.image);
          _view.currentState?.reload();
        },
        child: const Icon(Icons.add_a_photo_outlined),
      ),
      body: AsyncView<List<dynamic>>(
        key: _view,
        load: () async =>
            await session.api.get('${session.familyPath}/files?kind=photo') as List,
        builder: (context, photos) {
          if (photos.isEmpty) {
            return const EmptyHint(
              icon: Icons.photo_library_outlined,
              text: 'Noch keine Fotos hochgeladen.',
            );
          }
          return GridView.builder(
            padding: const EdgeInsets.all(8),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 180,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
            ),
            itemCount: photos.length,
            itemBuilder: (context, index) {
              final photo = photos[index] as Map<String, dynamic>;
              return InkWell(
                key: ValueKey(photo['id']),
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => _PhotoViewer(photo: photo)),
                  );
                  _view.currentState?.reload();
                },
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: _AuthImage(fileId: photo['id'] as String, cacheWidth: 400),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// Images need the session header, so they are fetched through the API client.
class _AuthImage extends StatefulWidget {
  const _AuthImage({required this.fileId, this.cacheWidth, this.fit = BoxFit.cover});

  final String fileId;
  final int? cacheWidth;
  final BoxFit fit;

  @override
  State<_AuthImage> createState() => _AuthImageState();
}

class _AuthImageState extends State<_AuthImage> {
  Future<Uint8List>? _bytes;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final session = SessionScope.of(context);
    _bytes ??= session.api.getBytes(
      '${session.familyPath}/files/${widget.fileId}/content',
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: _bytes,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Center(child: Icon(Icons.broken_image_outlined));
        }
        final bytes = snapshot.data;
        if (bytes == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return Image.memory(
          bytes,
          fit: widget.fit,
          cacheWidth: widget.cacheWidth,
          errorBuilder: (_, _, _) =>
              const Center(child: Icon(Icons.broken_image_outlined)),
        );
      },
    );
  }
}

class _PhotoViewer extends StatelessWidget {
  const _PhotoViewer({required this.photo});

  final Map<String, dynamic> photo;

  Future<void> _delete(BuildContext context) async {
    final session = SessionScope.of(context);
    final navigator = Navigator.of(context);
    if (!await confirm(context, 'Foto löschen?') || !context.mounted) return;
    final ok = await guarded(
      context,
      () => session.api.delete('${session.familyPath}/files/${photo['id']}'),
    );
    if (ok) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(photo['name'] as String),
        actions: [
          IconButton(
            tooltip: 'Herunterladen',
            icon: const Icon(Icons.download),
            onPressed: () => _download(context, photo['id'] as String),
          ),
          IconButton(
            tooltip: 'Löschen',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _delete(context),
          ),
        ],
      ),
      body: InteractiveViewer(
        maxScale: 5,
        child: Center(
          child: _AuthImage(fileId: photo['id'] as String, fit: BoxFit.contain),
        ),
      ),
    );
  }
}
