import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Says that Kintura is still a test version: until 1.0.0 functions are missing
/// and things may change. The version itself is shown apart, see AppVersionText.
class BetaNotice extends StatelessWidget {
  const BetaNotice({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Container(
      key: const Key('beta-notice'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.science_outlined, color: scheme.onTertiaryContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Beta · Testversion',
                  style: text.titleSmall?.copyWith(color: scheme.onTertiaryContainer, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  'Kintura ist noch in Entwicklung. Noch nicht alle Funktionen sind fertig, '
                  'und bis zur Version 1.0.0 kann sich noch einiges ändern.',
                  style: text.bodyMedium?.copyWith(color: scheme.onTertiaryContainer),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "Version 0.0.7 (12)" of this build, as the release set it; nothing while it is unknown.
class AppVersionText extends StatefulWidget {
  const AppVersionText({super.key});

  @override
  State<AppVersionText> createState() => _AppVersionTextState();
}

class _AppVersionTextState extends State<AppVersionText> {
  // Asked once, or every rebuild would start over and flicker.
  final _info = PackageInfo.fromPlatform();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<PackageInfo>(
      future: _info,
      builder: (context, info) {
        final data = info.data;
        if (data == null || data.version.isEmpty) return const SizedBox.shrink();
        final build = data.buildNumber.isEmpty ? '' : ' (${data.buildNumber})';
        return Text(
          'Version ${data.version}$build',
          key: const Key('app-version'),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
        );
      },
    );
  }
}
