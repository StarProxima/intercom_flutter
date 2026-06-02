import 'package:flutter/foundation.dart';
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

  /// origin документа WebView - должен быть в authorized domains workspace
  /// Intercom, иначе messenger/web/ping -> 403 "domain not allowed".
  final String baseUrl;

  /// Фон под мессенджером (совпадает с тёмным фоном виджета Intercom).
  final Color backgroundColor;

  const IntercomWebViewScreen({
    super.key,
    required this.appId,
    this.userId,
    this.email,
    this.userHash,
    this.userName,
    this.proxyConfig,
    this.baseUrl = 'https://app.intercom.io',
    this.backgroundColor = const Color(0xFF000000),
  });

  @override
  State<IntercomWebViewScreen> createState() => _IntercomWebViewScreenState();
}

class _IntercomWebViewScreenState extends State<IntercomWebViewScreen> {
  bool _isLoading = true;
  bool _proxyReady = false;
  bool _proxyFailed = false;

  @override
  void initState() {
    super.initState();
    _setupProxy();
  }

  Future<void> _setupProxy() async {
    final proxy = widget.proxyConfig;
    if (proxy != null) {
      final applied = await proxy.applyProxy(owner: this);
      // Прокси не встал - не грузим вебвью напрямую (тихий обход), показываем ошибку.
      if (!applied) {
        if (mounted) setState(() => _proxyFailed = true);

        return;
      }
    }
    if (mounted) {
      setState(() => _proxyReady = true);
    }
  }

  @override
  void dispose() {
    if (widget.proxyConfig != null) {
      ProxyConfig.clearProxy(owner: this);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_proxyFailed) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Support'),
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
        body: const Center(child: Text('Не удалось применить прокси')),
      );
    }

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

    final argb = widget.backgroundColor.toARGB32();
    final bgCss = '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

    final htmlBuilder = IntercomHtmlBuilder(
      appId: widget.appId,
      userId: widget.userId,
      email: widget.email,
      userHash: widget.userHash,
      userName: widget.userName,
      colorScheme: isDark ? 'dark' : 'light',
      backgroundColorCss: bgCss,
    );

    return Scaffold(
      backgroundColor: widget.backgroundColor,
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
                baseUrl: WebUri(widget.baseUrl),
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
              if (kDebugMode) {
                debugPrint('[Intercom WebView] ${message.message}');
              }
            },
            onLoadStart: (_, url) {
              if (kDebugMode) {
                debugPrint('[Intercom WebView] loadStart: $url');
              }
            },
            onReceivedError: (_, request, error) {
              if (kDebugMode) {
                debugPrint(
                  '[Intercom WebView] loadError: url=${request.url} '
                  'type=${error.type} desc=${error.description}',
                );
              }
            },
            onReceivedHttpError: (_, request, errorResponse) {
              if (kDebugMode) {
                debugPrint(
                  '[Intercom WebView] httpError: url=${request.url} '
                  'status=${errorResponse.statusCode}',
                );
              }
            },
            onReceivedServerTrustAuthRequest: (controller, challenge) async {
              final sslError = challenge.protectionSpace.sslError;
              if (kDebugMode) {
                debugPrint(
                  '[Intercom WebView] serverTrust: '
                  '${challenge.protectionSpace.host}:'
                  '${challenge.protectionSpace.port} sslError=$sslError',
                );
              }
              // iOS для валидного серта отдаёт UNSPECIFIED (успех), Android - null.
              // PROCEED на оба; иначе CANCEL. Без UNSPECIFIED на iOS рубились все
              // https-загрузки. См. подробный коммент в intercom_webview_overlay.
              final trusted =
                  sslError == null || sslError.code == SslErrorType.UNSPECIFIED;

              return ServerTrustAuthResponse(
                action: trusted
                    ? ServerTrustAuthResponseAction.PROCEED
                    : ServerTrustAuthResponseAction.CANCEL,
              );
            },
            // В браузер уводим только явные клики по ссылкам (см. оверлей):
            // иначе на iOS initial loadData с baseUrl=origin улетает в Safari.
            shouldOverrideUrlLoading: (controller, action) async {
              final uri = action.request.url;
              if (uri == null) {
                return NavigationActionPolicy.ALLOW;
              }

              final urlString = uri.toString();
              if (kDebugMode) {
                debugPrint(
                  '[Intercom WebView] urlLoading: type=${action.navigationType} '
                  'mainFrame=${action.isForMainFrame} url=$urlString',
                );
              }

              if (action.navigationType != NavigationType.LINK_ACTIVATED) {
                return NavigationActionPolicy.ALLOW;
              }

              if (urlString.contains('intercom.io') ||
                  urlString.startsWith('about:') ||
                  urlString.startsWith('data:')) {
                return NavigationActionPolicy.ALLOW;
              }

              final launchUri = Uri.tryParse(urlString);
              if (launchUri != null) {
                await launchUrl(
                  launchUri,
                  mode: LaunchMode.externalApplication,
                );
              }
              return NavigationActionPolicy.CANCEL;
            },
            onReceivedHttpAuthRequest: (controller, challenge) async {
              final proxy = widget.proxyConfig;
              if (proxy != null && proxy.hasAuth) {
                if (kDebugMode) {
                  debugPrint('[Intercom WebView] Proxy auth request');
                }
                return HttpAuthResponse(
                  username: proxy.username!,
                  password: proxy.password!,
                  action: HttpAuthResponseAction.PROCEED,
                  permanentPersistence: true,
                );
              }
              return HttpAuthResponse(action: HttpAuthResponseAction.CANCEL);
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
      // Все домены Intercom HTTPS-only, plain HTTP внутри не ожидается -
      // блокируем mixed content, иначе MITM сможет инжектить http-ресурсы.
      mixedContentMode: MixedContentMode.MIXED_CONTENT_NEVER_ALLOW,
      useHybridComposition: true,
      domStorageEnabled: true,
      // Дефолтный UA от WebView движка (десктоп подставит десктопный)
      supportZoom: false,
      transparentBackground: true,
    );

    return settings;
  }
}
