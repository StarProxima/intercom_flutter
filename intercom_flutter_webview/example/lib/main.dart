import 'package:flutter/material.dart';
import 'package:intercom_flutter_webview/intercom_flutter_webview.dart';

void main() => runApp(const IntercomWebViewExampleApp());

/// Standalone-демо Intercom через WebView с HTTP CONNECT прокси. Зависит только
/// от intercom_flutter_webview - нативный intercom_flutter SDK не линкуется.
class IntercomWebViewExampleApp extends StatelessWidget {
  const IntercomWebViewExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Intercom WebView Example',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // Публичный appId Intercom (виден в JS на клиенте, не секрет).
  final _appId = TextEditingController(text: 'bk580gxm');
  // origin документа - должен быть в authorized domains workspace Intercom.
  final _origin = TextEditingController(text: 'https://blancvpn.app');
  final _host = TextEditingController();
  final _port = TextEditingController(text: '443');
  final _scheme = TextEditingController(text: 'https');
  final _username = TextEditingController();
  final _password = TextEditingController();

  bool _loading = false;
  String? _status;

  @override
  void dispose() {
    for (final c in [
      _appId,
      _origin,
      _host,
      _port,
      _scheme,
      _username,
      _password,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  ProxyConfig? _buildProxy() {
    final host = _host.text.trim();
    if (host.isEmpty) return null;
    final username = _username.text.trim();
    final password = _password.text.trim();
    final scheme = _scheme.text.trim();
    return ProxyConfig(
      host: host,
      port: int.tryParse(_port.text.trim()) ?? 443,
      scheme: scheme.isEmpty ? 'https' : scheme,
      username: username.isEmpty ? null : username,
      password: password.isEmpty ? null : password,
    );
  }

  Future<void> _openOverlay() async {
    setState(() {
      _loading = true;
      _status = null;
    });
    try {
      await IntercomWebViewOverlay.show(
        context,
        appId: _appId.text.trim(),
        baseUrl: _origin.text.trim(),
        proxyConfig: _buildProxy(),
      );
      setState(() => _status = 'Overlay загрузился');
    } on Object catch (e) {
      setState(() => _status = 'Overlay error: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _openScreen() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => IntercomWebViewScreen(
          appId: _appId.text.trim(),
          baseUrl: _origin.text.trim(),
          proxyConfig: _buildProxy(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Intercom WebView Example')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _field(_appId, 'appId'),
          _field(_origin, 'origin_url (baseUrl, authorized domain)'),
          _field(_host, 'proxy host (без схемы), пусто = без прокси'),
          _field(_port, 'proxy port'),
          _field(_scheme, 'proxy scheme (http/https)'),
          _field(_username, 'proxy username'),
          _field(_password, 'proxy password'),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: _loading ? null : _openOverlay,
                icon: const Icon(Icons.chat_bubble_outline),
                label: const Text('Open overlay'),
              ),
              OutlinedButton.icon(
                onPressed: _loading ? null : _openScreen,
                icon: const Icon(Icons.open_in_new),
                label: const Text('Open screen'),
              ),
            ],
          ),
          if (_loading) ...[
            const SizedBox(height: 16),
            const Center(child: CircularProgressIndicator()),
          ],
          if (_status != null) ...[
            const SizedBox(height: 16),
            Text(_status!),
          ],
        ],
      ),
    );
  }

  Widget _field(TextEditingController controller, String hint) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: controller,
        decoration: InputDecoration(
          labelText: hint,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}
