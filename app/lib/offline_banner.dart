import 'dart:async';

import 'package:flutter/material.dart';

import 'api.dart';

/// Shows a bar above the app while the server cannot be reached, see [ApiClient.offline].
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
  bool _retrying = false;
  Timer? _timer;

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
    super.dispose();
  }

  /// While offline, asks again now and then, so that the bar goes once the server is back.
  void _follow() {
    if (!widget.api.offline.value) {
      _timer?.cancel();
      _timer = null;
    } else {
      _timer ??= Timer.periodic(const Duration(seconds: 30), (_) {
        if (!_retrying) _retry();
      });
    }
  }

  Future<void> _retry() async {
    setState(() => _retrying = true);
    try {
      await widget.onRetry();
    } on ApiException {
      // Still offline, the bar stays.
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder(
      valueListenable: widget.api.offline,
      builder: (context, offline, _) => Column(
        children: [
          if (offline)
            Material(
              key: const Key('offline-banner'),
              color: scheme.tertiaryContainer,
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
                  child: Row(
                    children: [
                      Icon(Icons.cloud_off, color: scheme.onTertiaryContainer),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Offline: Du siehst den zuletzt geladenen Stand. Ändern geht erst wieder mit Verbindung.',
                          style: TextStyle(color: scheme.onTertiaryContainer),
                        ),
                      ),
                      TextButton(
                        onPressed: _retrying ? null : _retry,
                        child: const Text('Erneut versuchen'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          Expanded(
            child: offline
                // The bar already keeps the top inset clear.
                ? MediaQuery.removePadding(context: context, removeTop: true, child: widget.child)
                : widget.child,
          ),
        ],
      ),
    );
  }
}
