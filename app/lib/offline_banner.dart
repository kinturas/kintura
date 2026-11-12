import 'dart:async';

import 'package:flutter/material.dart';

import 'api.dart';

/// Shows a bar right below the app bar of every page while the server cannot be
/// reached, see [ApiClient.offline]. It is a [MaterialBanner] of the app's
/// [ScaffoldMessenger], so it stays in place while pages change.
class OfflineBanner extends StatefulWidget {
  const OfflineBanner({super.key, required this.api, required this.onRetry, required this.child});

  final ApiClient api;

  /// Asks the server again; whatever gets through ends the offline state.
  final Future<void> Function() onRetry;
  final Widget child;

  @override
  State<OfflineBanner> createState() => _OfflineBannerState();
}

class _OfflineBannerState extends State<OfflineBanner> {
  final _retrying = ValueNotifier(false);
  Timer? _timer;
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    widget.api.offline.addListener(_follow);
    _follow();
  }

  @override
  void dispose() {
    widget.api.offline.removeListener(_follow);
    _timer?.cancel();
    _retrying.dispose();
    super.dispose();
  }

  void _follow() {
    final offline = widget.api.offline.value;
    if (!offline) {
      _timer?.cancel();
      _timer = null;
    } else {
      // While offline, asks again now and then, so that the bar goes once the server is back.
      _timer ??= Timer.periodic(const Duration(seconds: 30), (_) {
        if (!_retrying.value) _retry();
      });
    }
    // The change can come in while a frame is built, and the messenger cannot change then.
    WidgetsBinding.instance.addPostFrameCallback((_) => _update());
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _update() {
    if (!mounted) return;
    final offline = widget.api.offline.value;
    if (offline == _shown) return;
    _shown = offline;
    final messenger = ScaffoldMessenger.of(context);
    if (offline) {
      messenger.showMaterialBanner(_banner());
    } else {
      messenger.hideCurrentMaterialBanner();
    }
  }

  MaterialBanner _banner() {
    final scheme = Theme.of(context).colorScheme;
    return MaterialBanner(
      key: const Key('offline-banner'),
      backgroundColor: scheme.tertiaryContainer,
      leading: Icon(Icons.cloud_off, color: scheme.onTertiaryContainer),
      content: Text(
        'Änderungen nicht möglich',
        style: TextStyle(color: scheme.onTertiaryContainer),
      ),
      actions: [
        ValueListenableBuilder(
          valueListenable: _retrying,
          // This context lies inside the page, below the navigator that the dialog needs.
          builder: (context, retrying, _) => TextButton(
            onPressed: retrying ? null : () => _retryByHand(context),
            child: const Text('Erneut versuchen'),
          ),
        ),
      ],
    );
  }

  /// Unlike the checks in the background, says so when it did not work.
  Future<void> _retryByHand(BuildContext context) async {
    await _retry();
    if (!context.mounted || !widget.api.offline.value) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('offline-dialog'),
        icon: const Icon(Icons.cloud_off),
        title: const Text('Keine Verbindung'),
        content: const Text(
          'Der Server ist gerade nicht erreichbar. Prüfe, ob mobile Daten oder WLAN eingeschaltet sind, '
          'und versuche es dann noch einmal.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK')),
        ],
      ),
    );
  }

  /// Leaves [ApiClient.offline] set if the server still cannot be reached. Offline
  /// that is no error: the requests then answer from the device.
  Future<void> _retry() async {
    _retrying.value = true;
    try {
      await widget.onRetry();
    } on ApiException {
      // Nothing kept to fall back on; offline stays set either way.
    } finally {
      if (mounted) _retrying.value = false;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
