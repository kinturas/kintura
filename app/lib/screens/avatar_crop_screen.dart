import 'package:crop_your_image/crop_your_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

/// Longer sides than this go to the server smaller; it makes its own sizes anyway.
const _maxUploadSide = 1024;

/// Lets the user pick a photo and cut the square out of it that shows in the circle.
/// Returns the cut picture, or null if nothing was chosen; see [shrinkForUpload].
Future<Uint8List?> pickAndCropAvatar(BuildContext context) async {
  final picked = await AvatarCropScreen.pickImage();
  if (picked == null || !context.mounted) return null;
  return Navigator.of(context).push<Uint8List>(
    MaterialPageRoute(builder: (_) => AvatarCropScreen(image: picked)),
  );
}

/// A JPEG of at most [_maxUploadSide] on each side, so that photos from a phone stay small.
Uint8List shrinkForUpload(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return bytes;
  final resized = decoded.width > _maxUploadSide || decoded.height > _maxUploadSide
      ? img.copyResize(decoded, width: _maxUploadSide, height: _maxUploadSide, interpolation: img.Interpolation.average)
      : decoded;
  return img.encodeJpg(resized, quality: 90);
}

class AvatarCropScreen extends StatefulWidget {
  const AvatarCropScreen({super.key, required this.image});

  final Uint8List image;

  /// Asks the device for one picture. Tests put another function here.
  static Future<Uint8List?> Function() pickImage = _pickImage;

  static Future<Uint8List?> _pickImage() async {
    final files = await FilePicker.pickFiles(type: FileType.image);
    if (files.isEmpty) return null;
    return files.first.readAsBytes();
  }

  @override
  State<AvatarCropScreen> createState() => _AvatarCropScreenState();
}

class _AvatarCropScreenState extends State<AvatarCropScreen> {
  final _controller = CropController();
  bool _cropping = false;
  String? _error;

  void _onCropped(CropResult result) {
    if (!mounted) return;
    switch (result) {
      case CropSuccess(:final croppedImage):
        Navigator.of(context).pop(croppedImage);
      case CropFailure():
        setState(() {
          _cropping = false;
          _error = 'Das Bild ließ sich nicht zuschneiden. Bitte ein anderes wählen.';
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Foto zuschneiden'),
        actions: [
          TextButton(
            key: const Key('avatar-crop-done'),
            onPressed: _cropping
                ? null
                : () {
                    setState(() => _cropping = true);
                    _controller.crop();
                  },
            child: const Text('Übernehmen'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Verschiebe und zoome das Bild, bis der Kreis passt.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Text(_error!, style: TextStyle(color: scheme.error)),
            ),
          Expanded(
            child: Crop(
              image: widget.image,
              controller: _controller,
              onCropped: _onCropped,
              withCircleUi: true,
              // Moving and zooming the picture, not dragging the circle.
              interactive: true,
              fixCropRect: true,
              baseColor: scheme.surface,
              maskColor: scheme.scrim.withValues(alpha: 0.55),
            ),
          ),
          if (_cropping) const LinearProgressIndicator(),
        ],
      ),
    );
  }
}
