import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import 'intercom_html_builder.dart';
import 'proxy_config.dart';

/// Intercom Web Messenger как fullscreen прозрачный оверлей.
///
/// Полностью прозрачный - виден предыдущий экран пока Intercom грузится.
/// Intercom сам рисует свой UI и кнопку закрытия. При закрытии чата
/// в Intercom (onHide) оверлей автоматически закрывается.
///
/// Safe area insets передаются в HTML чтобы Intercom фрейм не залезал
/// под status bar и navigation indicator.
///
/// Если загрузка зависла (дольше [fallbackCloseDelay]), появляется
/// плавающая кнопка закрытия.
class IntercomWebViewOverlay extends StatefulWidget {
  final String appId;
  final String? userId;
  final String? email;
  final String? userHash;
  final String? userName;
  final ProxyConfig? proxyConfig;

  /// Через сколько показать fallback-кнопку закрытия если Intercom не загрузился.
  final Duration fallbackCloseDelay;

  const IntercomWebViewOverlay({
    super.key,
    required this.appId,
    this.userId,
    this.email,
    this.userHash,
    this.userName,
    this.proxyConfig,
    this.fallbackCloseDelay = const Duration(seconds: 8),
  });

  /// Показать оверлей поверх текущего экрана.
  static Future<void> show(
    BuildContext context, {
    required String appId,
    String? userId,
    String? email,
    String? userHash,
    String? userName,
    ProxyConfig? proxyConfig,
    Duration fallbackCloseDelay = const Duration(seconds: 8),
  }) {
    return showGeneralDialog(
      context: context,
      barrierDismissible: false,
      barrierLabel: 'Intercom',
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, animation, secondaryAnimation) {
        return IntercomWebViewOverlay(
          appId: appId,
          userId: userId,
          email: email,
          userHash: userHash,
          userName: userName,
          proxyConfig: proxyConfig,
          fallbackCloseDelay: fallbackCloseDelay,
        );
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(opacity: curved, child: child);
      },
    );
  }

  @override
  State<IntercomWebViewOverlay> createState() => _IntercomWebViewOverlayState();
}

class _IntercomWebViewOverlayState extends State<IntercomWebViewOverlay> {
  bool _proxyReady = false;
  bool _intercomReady = false;
  bool _showFallbackClose = false;
  Timer? _fallbackTimer;
  Color? _intercomBgColor;

  @override
  void initState() {
    super.initState();
    _setupProxy();
    _startFallbackTimer();
  }

  void _startFallbackTimer() {
    _fallbackTimer = Timer(widget.fallbackCloseDelay, () {
      if (!_intercomReady && mounted) {
        setState(() => _showFallbackClose = true);
      }
    });
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
    _fallbackTimer?.cancel();
    if (widget.proxyConfig != null) {
      ProxyConfig.clearProxy();
    }
    super.dispose();
  }

  void _close() {
    if (mounted) Navigator.of(context).pop();
  }

  /// Парсит CSS цвет вида "rgb(R, G, B)" или "rgba(R, G, B, A)".
  Color? _parseRgba(String css) {
    final match = RegExp(r'rgba?\((\d+),\s*(\d+),\s*(\d+)').firstMatch(css);
    if (match == null) return null;
    return Color.fromARGB(
      255,
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    );
  }

  void _updateSystemChrome(Color color) {
    final brightness =
        ThemeData.estimateBrightnessForColor(color) == Brightness.dark
            ? Brightness.light
            : Brightness.dark;
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      statusBarColor: color,
      statusBarIconBrightness: brightness,
      systemNavigationBarColor: color,
      systemNavigationBarIconBrightness: brightness,
    ));
  }

  @override
  Widget build(BuildContext context) {
    // Ждём применения прокси перед созданием WebView -
    // на Windows прокси инжектится в browser args при создании environment
    if (!_proxyReady) {
      return const SizedBox.shrink();
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final padding = MediaQuery.of(context).padding;

    final htmlBuilder = IntercomHtmlBuilder(
      appId: widget.appId,
      userId: widget.userId,
      email: widget.email,
      userHash: widget.userHash,
      userName: widget.userName,
      colorScheme: isDark ? 'dark' : 'light',
      topInset: padding.top,
      bottomInset: padding.bottom,
    );

    return Material(
      color: _intercomBgColor ?? Colors.transparent,
      child: Stack(
        children: [
          Positioned.fill(
            child: InAppWebView(
              initialSettings: _buildSettings(),
              onWebViewCreated: (controller) {
                controller.addJavaScriptHandler(
                  handlerName: 'onIntercomHide',
                  callback: (_) => _close(),
                );

                controller.addJavaScriptHandler(
                  handlerName: 'onIntercomReady',
                  callback: (_) {
                    if (mounted) {
                      setState(() {
                        _intercomReady = true;
                        _showFallbackClose = false;
                      });
                      _fallbackTimer?.cancel();
                    }
                  },
                );

                // Intercom отрендерился - JS детектит цвет фона и шлёт сюда
                controller.addJavaScriptHandler(
                  handlerName: 'onIntercomColor',
                  callback: (args) {
                    if (args.isNotEmpty && mounted) {
                      final color = _parseRgba(args[0] as String);
                      if (color != null) {
                        setState(() => _intercomBgColor = color);
                        _updateSystemChrome(color);
                      }
                    }
                  },
                );

                controller.loadData(
                  data: htmlBuilder.build(),
                  baseUrl: WebUri('https://app.intercom.io'),
                  mimeType: 'text/html',
                  encoding: 'utf-8',
                );
              },
              onConsoleMessage: (controller, message) {
                debugPrint('[Intercom WebView] ${message.message}');
              },
              shouldOverrideUrlLoading: (controller, action) async {
                final uri = action.request.url;
                if (uri == null) return NavigationActionPolicy.ALLOW;

                final urlString = uri.toString();
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
            ),
          ),

          if (_showFallbackClose)
            Positioned(
              top: padding.top + 8,
              right: 8,
              child: _FallbackCloseButton(onPressed: _close),
            ),
        ],
      ),
    );
  }

  InAppWebViewSettings _buildSettings() {
    return InAppWebViewSettings(
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
  }
}

class _FallbackCloseButton extends StatelessWidget {
  final VoidCallback onPressed;

  const _FallbackCloseButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 300),
      builder: (context, opacity, child) {
        return Opacity(opacity: opacity, child: child);
      },
      child: Container(
        decoration: const BoxDecoration(
          color: Colors.black54,
          shape: BoxShape.circle,
        ),
        child: IconButton(
          icon: const Icon(Icons.close, color: Colors.white, size: 20),
          onPressed: onPressed,
          padding: const EdgeInsets.all(8),
          constraints: const BoxConstraints(),
        ),
      ),
    );
  }
}
