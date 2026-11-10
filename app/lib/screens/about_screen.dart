import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../session.dart';

const _copyright = '© 2026 Kintura';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  void _open(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Über')),
      body: ListView(
        children: [
          FutureBuilder<PackageInfo>(
            future: PackageInfo.fromPlatform(),
            builder: (context, info) {
              final data = info.data;
              return ListTile(
                key: const Key('about-version'),
                title: const Text('Version'),
                subtitle: Text(data == null ? '…' : '${data.version} (${data.buildNumber})'),
              );
            },
          ),
          const ListTile(title: Text('Copyright'), subtitle: Text(_copyright)),
          ListTile(
            title: const Text('Impressum'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _open(context, const ImprintScreen()),
          ),
          ListTile(
            title: const Text('Datenschutzerklärung'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _open(context, const PrivacyScreen()),
          ),
        ],
      ),
    );
  }
}

/// A text of the operator, such as the imprint, which is edited in the admin dashboard
/// and loaded from the backend because it must be readable before signing in.
class _Page {
  _Page.fromJson(Map<String, dynamic> json) : content = json['content'] as String;

  final String content;
}

class _LegalPage extends StatefulWidget {
  const _LegalPage({required this.title, required this.slug});

  final String title;
  final String slug;

  @override
  State<_LegalPage> createState() => _LegalPageState();
}

class _LegalPageState extends State<_LegalPage> {
  Future<_Page>? _page;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _page ??= _load();
  }

  Future<_Page> _load() async {
    final data = await SessionScope.of(context).api.get('/api/pages/${widget.slug}');
    return _Page.fromJson(data as Map<String, dynamic>);
  }

  Future<void> _openLink(String text, String? href, String title) async {
    final uri = href == null ? null : Uri.tryParse(href);
    if (uri == null || !const {'http', 'https', 'mailto', 'tel'}.contains(uri.scheme)) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: FutureBuilder<_Page>(
        future: _page,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Die Angaben konnten nicht geladen werden.', textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () => setState(() => _page = _load()),
                      child: const Text('Erneut versuchen'),
                    ),
                  ],
                ),
              ),
            );
          }
          final page = snapshot.data;
          if (page == null) return const Center(child: CircularProgressIndicator());
          final text = Theme.of(context).textTheme;
          return Markdown(
            data: page.content,
            // A single line break stays one, as in an address.
            softLineBreak: true,
            onTapLink: _openLink,
            styleSheet: MarkdownStyleSheet.fromTheme(
              Theme.of(context),
            ).copyWith(h2: text.titleSmall, h2Padding: const EdgeInsets.only(top: 12), blockSpacing: 8),
          );
        },
      ),
    );
  }
}

class ImprintScreen extends StatelessWidget {
  const ImprintScreen({super.key});

  @override
  Widget build(BuildContext context) => const _LegalPage(title: 'Impressum', slug: 'impressum');
}

class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) => const _LegalPage(title: 'Datenschutzerklärung', slug: 'datenschutz');
}
