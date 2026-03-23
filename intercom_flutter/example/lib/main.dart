import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intercom_flutter/intercom_flutter.dart';
import 'package:intercom_flutter_webview/intercom_flutter_webview.dart';

const _appId = 'hc41m06w';
const _localProxyHost = '127.0.0.1';
const _localProxyPort = 8080;

const _proxyConfig = ProxyConfig(
  host: '195.49.213.205',
  port: 9000,
  scheme: 'http',
  username: 'E2FO2Z1WP3D02HKCLOGAMUBZ',
  password: 'WE6NW05Y3Y8ZCY1Q407WV9BH',
);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SampleApp());
}

class SampleApp extends StatefulWidget {
  const SampleApp({super.key});

  @override
  State<SampleApp> createState() => _SampleAppState();
}

class _SampleAppState extends State<SampleApp> {
  ThemeMode _themeMode = ThemeMode.system;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: ThemeData.light(useMaterial3: true),
      darkTheme: ThemeData.dark(useMaterial3: true),
      home: HomeScreen(
        themeMode: _themeMode,
        onThemeModeChanged: (mode) => setState(() => _themeMode = mode),
      ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;

  const HomeScreen({
    super.key,
    required this.themeMode,
    required this.onThemeModeChanged,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _nativeSdkInitialized = false;
  bool _overlayLoading = false;

  ProxyConfig? get _demoProxyConfig {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) {
      return null;
    }
    return const ProxyConfig(host: _localProxyHost, port: _localProxyPort);
  }

  Future<void> _initNativeSdk() async {
    try {
      await Intercom.instance.initialize(_appId);
      await Intercom.instance.loginUnidentifiedUser();
      setState(() => _nativeSdkInitialized = true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Native SDK initialized'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) _showError('Native SDK init failed', e);
    }
  }

  Future<void> _openOverlay() async {
    setState(() => _overlayLoading = true);
    try {
      await IntercomWebViewOverlay.show(
        context,
        appId: _appId,
        proxyConfig: _demoProxyConfig,
      );
    } on IntercomLoadException catch (e) {
      if (mounted) _showError('Intercom', e.message);
    } finally {
      if (mounted) setState(() => _overlayLoading = false);
    }
  }

  Future<void> _runSafe(String label, Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) _showError(label, e);
    }
  }

  void _showError(String label, Object error) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label: $error'),
        behavior: SnackBarBehavior.floating,
        backgroundColor: Theme.of(context).colorScheme.error,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Intercom Example'),
        actions: [
          _ThemeToggle(
            themeMode: widget.themeMode,
            onChanged: widget.onThemeModeChanged,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        children: [
          // --- WebView ---
          const _SectionHeader(
            title: 'WebView Messenger',
            subtitle: 'Кроссплатформенный, без нативного SDK',
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const IntercomWebViewScreen(
                    appId: _appId,
                    proxyConfig: _proxyConfig,
                  ),
                ),
              );
            },
            icon: const Icon(Icons.chat_outlined),
            label: const Text('Open WebView Messenger'),
          ),
          const SizedBox(height: 8),
          _LoadingButton(
            loading: _overlayLoading,
            onPressed: _openOverlay,
            icon: Icons.layers_outlined,
            label: 'Open as Overlay',
          ),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => IntercomWebViewScreen(
                    appId: _appId,
                    proxyConfig: _demoProxyConfig,
                  ),
                ),
              );
            },
            icon: const Icon(Icons.vpn_lock_outlined),
            label: const Text('WebView + Proxy (demo)'),
          ),

          const SizedBox(height: 32),

          // --- Native SDK ---
          const _SectionHeader(
            title: 'Native SDK',
            subtitle: 'Android / iOS only',
          ),
          const SizedBox(height: 12),
          if (!_nativeSdkInitialized) ...[
            OutlinedButton.icon(
              onPressed: _initNativeSdk,
              icon: const Icon(Icons.power_settings_new),
              label: const Text('Initialize Native SDK'),
            ),
            const SizedBox(height: 8),
            Text(
              'SDK не инициализирован. Нажми кнопку выше.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
          ] else ...[
            OutlinedButton.icon(
              onPressed: () => _runSafe(
                'displayMessenger',
                Intercom.instance.displayMessenger,
              ),
              icon: const Icon(Icons.chat_bubble_outline),
              label: const Text('Open Messenger'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () =>
                  _runSafe('displayHome', Intercom.instance.displayHome),
              icon: const Icon(Icons.home_outlined),
              label: const Text('Open Home'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => _runSafe(
                'displayHelpCenter',
                Intercom.instance.displayHelpCenter,
              ),
              icon: const Icon(Icons.help_outline),
              label: const Text('Open Help Center'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => _runSafe(
                'displayMessages',
                Intercom.instance.displayMessages,
              ),
              icon: const Icon(Icons.message_outlined),
              label: const Text('Open Messages'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () =>
                  _runSafe('displayTickets', Intercom.instance.displayTickets),
              icon: const Icon(Icons.confirmation_number_outlined),
              label: const Text('Open Tickets'),
            ),
          ],
        ],
      ),
    );
  }
}

/// Кнопка с индикатором загрузки внутри.
class _LoadingButton extends StatelessWidget {
  final bool loading;
  final VoidCallback onPressed;
  final IconData icon;
  final String label;

  const _LoadingButton({
    required this.loading,
    required this.onPressed,
    required this.icon,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: loading ? null : onPressed,
      icon: loading
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : Icon(icon),
      label: Text(label),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final String subtitle;

  const _SectionHeader({required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 2),
        Text(
          subtitle,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.outline,
          ),
        ),
      ],
    );
  }
}

class _ThemeToggle extends StatelessWidget {
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onChanged;

  const _ThemeToggle({required this.themeMode, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final icon = switch (themeMode) {
      ThemeMode.light => Icons.light_mode,
      ThemeMode.dark => Icons.dark_mode,
      ThemeMode.system => Icons.brightness_auto,
    };

    return IconButton(
      icon: Icon(icon),
      tooltip: 'Theme: ${themeMode.name}',
      onPressed: () {
        final next = switch (themeMode) {
          ThemeMode.system => ThemeMode.light,
          ThemeMode.light => ThemeMode.dark,
          ThemeMode.dark => ThemeMode.system,
        };
        onChanged(next);
      },
    );
  }
}
