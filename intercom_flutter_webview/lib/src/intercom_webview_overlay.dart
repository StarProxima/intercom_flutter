import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import 'intercom_html_builder.dart';
import 'proxy_config.dart';

/// Intercom Web Messenger как fullscreen оверлей.
///
/// Использует [Overlay] - не блокирует тапы пока Intercom грузится.
/// WebView прозрачный, Intercom JS сам анимирует свой slide-up при открытии.
///
/// - [show] возвращает Future который завершается когда Intercom отобразился
/// - Автоопределение цвета фона Intercom с fallback на тему
/// - [preload] для предзагрузки SDK
class IntercomWebViewOverlay extends StatefulWidget {
  final String appId;
  final String? userId;
  final String? email;
  final String? userHash;
  final String? userName;
  final ProxyConfig? proxyConfig;
  final Duration fallbackCloseDelay;
  final VoidCallback? onReady;
  final VoidCallback? onClose;

  const IntercomWebViewOverlay({
    super.key,
    required this.appId,
    this.userId,
    this.email,
    this.userHash,
    this.userName,
    this.proxyConfig,
    this.fallbackCloseDelay = const Duration(seconds: 10),
    this.onReady,
    this.onClose,
  });

  /// Показать Intercom оверлей.
  ///
  /// Возвращает Future который завершается когда виджет Intercom
  /// появился на экране. Пока грузится - тапы проходят на экран ниже.
  static Future<void> show(
    BuildContext context, {
    required String appId,
    String? userId,
    String? email,
    String? userHash,
    String? userName,
    ProxyConfig? proxyConfig,
    Duration fallbackCloseDelay = const Duration(seconds: 10),
  }) async {
    final overlay = Overlay.of(context);
    final readyCompleter = Completer<void>();

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => IntercomWebViewOverlay(
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
        onClose: () {
          entry.remove();
          entry.dispose();
          if (!readyCompleter.isCompleted) readyCompleter.complete();
        },
      ),
    );

    overlay.insert(entry);
    await readyCompleter.future;
  }


  @override
  State<IntercomWebViewOverlay> createState() => _IntercomWebViewOverlayState();
}

class _IntercomWebViewOverlayState extends State<IntercomWebViewOverlay>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late final AnimationController _slideController;

  bool _proxyReady = false;
  bool _intercomReady = false;
  bool _closing = false;
  bool _showFallbackClose = false;
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
      if (!_intercomReady && mounted) {
        setState(() => _showFallbackClose = true);
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
    setState(() {
      _intercomReady = true;
      _showFallbackClose = false;
    });
    _fallbackTimer?.cancel();
    widget.onReady?.call();
  }

  Future<void> _close() async {
    if (!mounted || _closing) return;
    _closing = true;
    await _slideController.forward(); // slide down
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

    final padding = MediaQuery.of(context).padding;

    return SlideTransition(
      position:
          Tween<Offset>(
            begin: Offset.zero,
            end: const Offset(0, 1), // уезжает вниз-вправо
          ).animate(
            CurvedAnimation(
              parent: _slideController,
              curve: Curves.easeInCubic,
            ),
          ),
      child: IgnorePointer(
        ignoring: !_intercomReady || _closing,
        child: Stack(
          children: [
            // Фон за safe area (цвет Intercom).
            // Всегда в дереве чтобы не менять индексы children в Stack -
            // иначе InAppWebView пересоздаётся (Flutter матчит по индексу).
            Positioned.fill(
              child: ColoredBox(color: _intercomBgColor ?? Colors.transparent),
            ),

            // WebView - прозрачный, Intercom анимирует себя сам
            Positioned.fill(
              child: InAppWebView(
                initialSettings: _buildSettings(),
                onWebViewCreated: _onWebViewCreated,
                onConsoleMessage: (_, msg) {
                  debugPrint('[Intercom WebView] ${msg.message}');
                },
                shouldOverrideUrlLoading: _handleUrlLoading,
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
    if (urlString.contains('intercom.io') ||
        urlString.startsWith('about:') ||
        urlString.startsWith('data:')) {
      return NavigationActionPolicy.ALLOW;
    }

    final launchUri = Uri.tryParse(urlString);
    if (launchUri != null) {
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
      // Дефолтный UA от WebView движка (десктоп подставит десктопный)
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
      builder: (context, value, child) => Opacity(opacity: value, child: child),
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
