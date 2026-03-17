import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import 'intercom_html_builder.dart';
import 'proxy_config.dart';

/// Исключение при неудачной загрузке Intercom.
class IntercomLoadException implements Exception {
  final String message;
  const IntercomLoadException(this.message);

  @override
  String toString() => 'IntercomLoadException: $message';
}

/// Intercom Web Messenger как fullscreen оверлей.
///
/// Использует [Overlay] - не блокирует тапы пока Intercom грузится.
/// WebView прозрачный, Intercom JS сам анимирует свой slide-up при открытии.
///
/// - [show] возвращает Future который завершается когда Intercom отобразился.
///   Бросает [IntercomLoadException] если SDK не загрузился (нет сети, блокировка).
/// - Автоопределение цвета фона Intercom с fallback на тему.
/// - Автозакрытие по таймауту если Intercom не загрузился.
class IntercomWebViewOverlay extends StatefulWidget {
  final String appId;
  final String? userId;
  final String? email;
  final String? userHash;
  final String? userName;
  final ProxyConfig? proxyConfig;
  final Duration fallbackCloseDelay;
  final VoidCallback? onReady;
  final void Function(Object error)? onError;
  final VoidCallback? onClose;

  const IntercomWebViewOverlay({
    super.key,
    required this.appId,
    this.userId,
    this.email,
    this.userHash,
    this.userName,
    this.proxyConfig,
    this.fallbackCloseDelay = const Duration(seconds: 12),
    this.onReady,
    this.onError,
    this.onClose,
  });

  /// Показать Intercom оверлей.
  ///
  /// Возвращает Future который завершается когда виджет Intercom
  /// появился на экране. Пока грузится - тапы проходят на экран ниже.
  ///
  /// Бросает [IntercomLoadException] если:
  /// - SDK не загрузился (сеть, блокировка intercomcdn.com)
  /// - Таймаут загрузки истёк
  static Future<void> show(
    BuildContext context, {
    required String appId,
    String? userId,
    String? email,
    String? userHash,
    String? userName,
    ProxyConfig? proxyConfig,
    Duration fallbackCloseDelay = const Duration(seconds: 15),
  }) async {
    final overlay = Overlay.of(context);
    final readyCompleter = Completer<void>();

    late OverlayEntry entry;

    void removeEntry() {
      entry.remove();
      entry.dispose();
    }

    final overlayWidget = IntercomWebViewOverlay(
      appId: appId,
      userId: userId,
      email: email,
      userHash: userHash,
      userName: userName,
      proxyConfig: proxyConfig,
      fallbackCloseDelay: fallbackCloseDelay,
      onReady: () {
        if (!readyCompleter.isCompleted) readyCompleter.complete();
      },
      onError: (error) {
        removeEntry();
        if (!readyCompleter.isCompleted) {
          readyCompleter.completeError(error);
        }
      },
      onClose: () {
        removeEntry();
        if (!readyCompleter.isCompleted) readyCompleter.complete();
      },
    );

    entry = OverlayEntry(builder: (_) => overlayWidget);

    overlay.insert(entry);
    await readyCompleter.future;
  }

  @override
  State<IntercomWebViewOverlay> createState() => _IntercomWebViewOverlayState();
}

class _IntercomWebViewOverlayState extends State<IntercomWebViewOverlay>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late final AnimationController _slideController;

  // GlobalKey на WebView чтобы iOS не пересоздавала его при rebuild Overlay
  final _webViewKey = GlobalKey();

  bool _proxyReady = false;
  bool _intercomReady = false;
  bool _closing = false;
  Timer? _fallbackTimer;
  Color? _intercomBgColor;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _slideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _setupProxy();
    _startFallbackTimer();
  }

  @override
  void dispose() {
    _slideController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _fallbackTimer?.cancel();
    if (widget.proxyConfig != null) {
      ProxyConfig.clearProxy();
    }
    super.dispose();
  }

  @override
  Future<bool> didPopRoute() async {
    _close();
    return true;
  }

  void _startFallbackTimer() {
    _fallbackTimer = Timer(widget.fallbackCloseDelay, () {
      if (!_intercomReady && mounted && !_closing) {
        widget.onError?.call(
          const IntercomLoadException(
            'Intercom failed to load (timeout). '
            'Check network connection or proxy settings.',
          ),
        );
      }
    });
  }

  Future<void> _setupProxy() async {
    final proxy = widget.proxyConfig;
    if (proxy != null) await proxy.applyProxy();
    if (mounted) setState(() => _proxyReady = true);
  }

  void _onIntercomReady() {
    if (!mounted || _intercomReady) return;
    setState(() => _intercomReady = true);
    _fallbackTimer?.cancel();
    widget.onReady?.call();
  }

  void _onIntercomError(String message) {
    if (!mounted || _intercomReady || _closing) return;
    _fallbackTimer?.cancel();
    widget.onError?.call(IntercomLoadException(message));
  }

  Future<void> _close() async {
    if (!mounted || _closing) return;
    _closing = true;
    await _slideController.forward();
    widget.onClose?.call();
  }

  Color? _parseColor(String css) {
    final rgbMatch = RegExp(r'rgba?\((\d+),\s*(\d+),\s*(\d+)').firstMatch(css);
    if (rgbMatch != null) {
      return Color.fromARGB(
        255,
        int.parse(rgbMatch.group(1)!),
        int.parse(rgbMatch.group(2)!),
        int.parse(rgbMatch.group(3)!),
      );
    }
    if (css.startsWith('#') && css.length == 7) {
      final hex = int.tryParse(css.substring(1), radix: 16);
      if (hex != null) return Color(0xFF000000 | hex);
    }
    return null;
  }

  void _applyBgColor(Color color) {
    if (!mounted) return;
    setState(() => _intercomBgColor = color);
    final iconBrightness =
        ThemeData.estimateBrightnessForColor(color) == Brightness.dark
        ? Brightness.light
        : Brightness.dark;
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: color,
        statusBarIconBrightness: iconBrightness,
        systemNavigationBarColor: color,
        systemNavigationBarIconBrightness: iconBrightness,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_proxyReady) return const SizedBox.shrink();

    return SlideTransition(
      position: Tween<Offset>(begin: Offset.zero, end: const Offset(0, 1))
          .animate(
            CurvedAnimation(
              parent: _slideController,
              curve: Curves.easeInCubic,
            ),
          ),
      child: IgnorePointer(
        ignoring: !_intercomReady || _closing,
        child: Stack(
          children: [
            Positioned.fill(
              child: ColoredBox(color: _intercomBgColor ?? Colors.transparent),
            ),
            Positioned.fill(
              child: InAppWebView(
                key: _webViewKey,
                initialSettings: _buildSettings(),
                onWebViewCreated: _onWebViewCreated,
                onConsoleMessage: (_, msg) {
                  debugPrint('[Intercom WebView] ${msg.message}');
                },
                shouldOverrideUrlLoading: _handleUrlLoading,
              ),
            ),
            // Стабильный третий child (не менять кол-во children в Stack)
            const SizedBox.shrink(),
          ],
        ),
      ),
    );
  }

  void _onWebViewCreated(InAppWebViewController controller) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final padding = MediaQuery.of(context).padding;

    controller.addJavaScriptHandler(
      handlerName: 'onIntercomHide',
      callback: (_) => _close(),
    );
    controller.addJavaScriptHandler(
      handlerName: 'onIntercomReady',
      callback: (_) => _onIntercomReady(),
    );
    controller.addJavaScriptHandler(
      handlerName: 'onIntercomColor',
      callback: (args) {
        if (args.isNotEmpty && mounted) {
          final color = _parseColor(args[0] as String);
          if (color != null) _applyBgColor(color);
        }
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'onIntercomError',
      callback: (args) {
        final msg = args.isNotEmpty ? args[0] as String : 'Unknown error';
        _onIntercomError(msg);
      },
    );

    final html = IntercomHtmlBuilder(
      appId: widget.appId,
      userId: widget.userId,
      email: widget.email,
      userHash: widget.userHash,
      userName: widget.userName,
      colorScheme: isDark ? 'dark' : 'light',
      topInset: padding.top,
      bottomInset: padding.bottom,
    ).build();

    controller.loadData(
      data: html,
      baseUrl: WebUri('https://app.intercom.io'),
      mimeType: 'text/html',
      encoding: 'utf-8',
    );
  }

  Future<NavigationActionPolicy> _handleUrlLoading(
    InAppWebViewController controller,
    NavigationAction action,
  ) async {
    final uri = action.request.url;
    if (uri == null) return NavigationActionPolicy.ALLOW;

    final urlString = uri.toString();

    if (urlString.isEmpty ||
        urlString.startsWith('about:') ||
        urlString.startsWith('data:')) {
      return NavigationActionPolicy.ALLOW;
    }

    if (urlString.contains('intercom.io') ||
        urlString.contains('intercomcdn.com') ||
        urlString.contains('intercomassets.com') ||
        urlString.contains('intercom-messenger.com')) {
      return NavigationActionPolicy.ALLOW;
    }

    final launchUri = Uri.tryParse(urlString);
    if (launchUri != null && launchUri.hasScheme) {
      await launchUrl(launchUri, mode: LaunchMode.externalApplication);
    }
    return NavigationActionPolicy.CANCEL;
  }

  InAppWebViewSettings _buildSettings() {
    return InAppWebViewSettings(
      javaScriptEnabled: true,
      mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
      useHybridComposition: true,
      domStorageEnabled: true,
      supportZoom: false,
      transparentBackground: true,
    );
  }
}
