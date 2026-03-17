import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import 'intercom_html_builder.dart';
import 'proxy_config.dart';

/// Экран с Intercom Web Messenger через InAppWebView.
///
/// Работает на всех платформах где есть WebView: Android, iOS, Windows, macOS.
/// Нативный Intercom SDK не нужен - загружаем JS виджет в WebView.
class IntercomWebViewScreen extends StatefulWidget {
  final String appId;
  final String? userId;
  final String? email;
  final String? userHash;
  final String? userName;
  final ProxyConfig? proxyConfig;

  const IntercomWebViewScreen({
    super.key,
    required this.appId,
    this.userId,
    this.email,
    this.userHash,
    this.userName,
    this.proxyConfig,
  });

  @override
  State<IntercomWebViewScreen> createState() => _IntercomWebViewScreenState();
}

class _IntercomWebViewScreenState extends State<IntercomWebViewScreen> {
  bool _isLoading = true;
  bool _proxyReady = false;

  @override
  void initState() {
    super.initState();
    _setupProxy();
  }

  Future<void> _setupProxy() async {
    final proxy = widget.proxyConfig;
    if (proxy != null) {
      await proxy.applyProxy();
    }
    if (mounted) {
      setState(() => _proxyReady = true);
    }
  }

  @override
  void dispose() {
    if (widget.proxyConfig != null) {
      ProxyConfig.clearProxy();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Ждём применения прокси перед созданием WebView -
    // на Windows прокси инжектится в browser args при создании environment
    if (!_proxyReady) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Support'),
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;

    final htmlBuilder = IntercomHtmlBuilder(
      appId: widget.appId,
      userId: widget.userId,
      email: widget.email,
      userHash: widget.userHash,
      userName: widget.userName,
      colorScheme: isDark ? 'dark' : 'light',
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Support'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Stack(
        children: [
          InAppWebView(
            initialSettings: _buildSettings(),
            onWebViewCreated: (controller) {
              // Хендлер закрытия Intercom мессенджера
              controller.addJavaScriptHandler(
                handlerName: 'onIntercomHide',
                callback: (_) {
                  if (mounted) Navigator.of(context).pop();
                },
              );

              // Загружаем HTML с Intercom виджетом
              controller.loadData(
                data: htmlBuilder.build(),
                baseUrl: WebUri('https://app.intercom.io'),
                mimeType: 'text/html',
                encoding: 'utf-8',
              );
            },
            onLoadStop: (controller, url) {
              if (_isLoading && mounted) {
                setState(() => _isLoading = false);
              }
            },
            onConsoleMessage: (controller, message) {
              debugPrint('[Intercom WebView] ${message.message}');
            },
            // Внешние ссылки открываем в системном браузере
            shouldOverrideUrlLoading: (controller, action) async {
              final uri = action.request.url;
              if (uri == null) {
                return NavigationActionPolicy.ALLOW;
              }

              final urlString = uri.toString();
              // Разрешаем загрузку Intercom ресурсов
              if (urlString.contains('intercom.io') ||
                  urlString.startsWith('about:') ||
                  urlString.startsWith('data:')) {
                return NavigationActionPolicy.ALLOW;
              }

              // Все остальные ссылки - в системный браузер
              final launchUri = Uri.tryParse(urlString);
              if (launchUri != null) {
                await launchUrl(
                  launchUri,
                  mode: LaunchMode.externalApplication,
                );
              }
              return NavigationActionPolicy.CANCEL;
            },
          ),
          if (_isLoading)
            const Center(
              child: CircularProgressIndicator(),
            ),
        ],
      ),
    );
  }

  InAppWebViewSettings _buildSettings() {
    final settings = InAppWebViewSettings(
      javaScriptEnabled: true,
      mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
      useHybridComposition: true,
      domStorageEnabled: true,
      userAgent:
          'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
      supportZoom: false,
      transparentBackground: true,
    );

    return settings;
  }
}
