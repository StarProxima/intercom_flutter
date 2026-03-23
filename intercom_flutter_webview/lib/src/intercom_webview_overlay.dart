import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import 'intercom_html_builder.dart';
import 'intercom_local_page_server.dart';
import 'proxy_config.dart';

/// Исключение при неудачной загрузке Intercom.
class IntercomLoadException implements Exception {
  final String message;
  const IntercomLoadException(this.message);

  @override
  String toString() => 'IntercomLoadException: $message';
}

/// Intercom Web Messenger как fullscreen оверлей с persistent WebView.
///
/// WebView создаётся при первом [show] и живёт до явного [destroy].
/// Повторные вызовы [show] мгновенные - SDK уже загружен.
/// После первого открытия [onUnreadCountChange] работает фоново.
///
/// - [show] - открыть Intercom. Первый вызов грузит SDK, остальные мгновенные.
/// - [destroy] - уничтожить WebView и освободить память.
/// - [onUnreadCountChange] - статический callback для отслеживания
///   непрочитанных разговоров (работает после первого show).
class IntercomWebViewOverlay {
  IntercomWebViewOverlay._();

  static _OverlayWidgetState? _state;
  static OverlayEntry? _entry;
  static Completer<void>? _readyCompleter;

  /// Callback при изменении количества непрочитанных разговоров.
  /// Работает после первого вызова [show].
  static ValueChanged<int>? onUnreadCountChange;

  /// Показать Intercom оверлей.
  ///
  /// Первый вызов: создаёт WebView, грузит SDK, показывает Intercom.
  /// Повторные вызовы: мгновенный `Intercom('show')` через JS.
  ///
  /// Бросает [IntercomLoadException] если SDK не загрузился.
  static Future<void> show(
    BuildContext context, {
    required String appId,
    String? userId,
    String? email,
    String? userHash,
    String? userName,
    Map<String, dynamic>? customAttributes,
    ProxyConfig? proxyConfig,
    Duration fallbackCloseDelay = const Duration(seconds: 15),
  }) async {
    _readyCompleter = Completer<void>();

    if (_state != null && _state!.mounted && _state!._sdkLoaded) {
      _state!._showIntercom();
      await _readyCompleter!.future;
      return;
    }

    if (_entry != null) {
      _entry!.remove();
      _entry!.dispose();
    }

    final overlay = Overlay.of(context);
    final overlayWidget = _OverlayWidget(
      appId: appId,
      userId: userId,
      email: email,
      userHash: userHash,
      userName: userName,
      customAttributes: customAttributes,
      proxyConfig: proxyConfig,
      fallbackCloseDelay: fallbackCloseDelay,
    );

    _entry = OverlayEntry(builder: (_) => overlayWidget);
    overlay.insert(_entry!);

    await _readyCompleter!.future;
  }

  /// Уничтожить persistent WebView и освободить память.
  static void destroy() {
    _state = null;
    _entry?.remove();
    _entry?.dispose();
    _entry = null;
    _readyCompleter = null;
  }

  /// SDK загружен и WebView живой.
  static bool get isInitialized =>
      _state != null && _state!.mounted && _state!._sdkLoaded;
}

// --- Internal widgets ---

class _OverlayWidget extends StatefulWidget {
  final String appId;
  final String? userId;
  final String? email;
  final String? userHash;
  final String? userName;
  final Map<String, dynamic>? customAttributes;
  final ProxyConfig? proxyConfig;
  final Duration fallbackCloseDelay;

  const _OverlayWidget({
    required this.appId,
    this.userId,
    this.email,
    this.userHash,
    this.userName,
    this.customAttributes,
    this.proxyConfig,
    this.fallbackCloseDelay = const Duration(seconds: 15),
  });

  @override
  State<_OverlayWidget> createState() => _OverlayWidgetState();
}

class _OverlayWidgetState extends State<_OverlayWidget>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late final AnimationController _slideController;
  final _webViewKey = GlobalKey();

  InAppWebViewController? _controller;
  bool _proxyReady = false;
  bool _sdkLoaded = false;
  bool _intercomVisible = false;
  bool _closing = false;
  Timer? _fallbackTimer;
  Color? _intercomBgColor;
  IntercomLocalPageServer? _pageServer;
  Uri? _pageUri;

  bool get _useLocalPageMode => Platform.isWindows;

  @override
  void initState() {
    super.initState();
    IntercomWebViewOverlay._state = this;
    WidgetsBinding.instance.addObserver(this);
    _slideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    if (_useLocalPageMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_prepareOverlay());
      });
    } else {
      unawaited(_prepareOverlay());
    }
    _startFallbackTimer();
  }

  @override
  void dispose() {
    if (IntercomWebViewOverlay._state == this) {
      IntercomWebViewOverlay._state = null;
    }
    _slideController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _fallbackTimer?.cancel();
    unawaited(_pageServer?.close() ?? Future<void>.value());
    if (widget.proxyConfig != null) {
      ProxyConfig.clearProxy();
    }
    super.dispose();
  }

  @override
  Future<bool> didPopRoute() async {
    if (_intercomVisible) {
      _hide();
      return true;
    }
    return false;
  }

  void _startFallbackTimer() {
    _fallbackTimer = Timer(widget.fallbackCloseDelay, () {
      if (!_sdkLoaded && mounted && !_closing) {
        _completeWithError(
          const IntercomLoadException(
            'Intercom failed to load (timeout). '
            'Check network connection or proxy settings.',
          ),
        );
      }
    });
  }

  Future<void> _prepareOverlay() async {
    final proxy = widget.proxyConfig;
    if (proxy != null) await proxy.applyProxy();
    if (_useLocalPageMode) {
      await _setupLocalPage();
    }
    if (mounted) setState(() => _proxyReady = true);
  }

  Future<void> _setupLocalPage() async {
    final pageServer = await IntercomLocalPageServer.start(
      html: _buildOverlayHtml(),
    );

    if (!mounted) {
      await pageServer.close();
      return;
    }

    _pageServer = pageServer;
    _pageUri = pageServer.entryUri;
  }

  void _onIntercomReady() {
    if (!mounted) return;
    _sdkLoaded = true;
    _fallbackTimer?.cancel();
    setState(() => _intercomVisible = true);
    _completeReady();
  }

  /// Повторное открытие через JS (SDK уже загружен).
  void _showIntercom() {
    if (_controller == null) return;
    setState(() {
      _intercomVisible = true;
      _closing = false;
    });
    _slideController.value = 0;
    _controller!.evaluateJavascript(
      source: '''
      window.Intercom('show');
      window.Intercom('onShow', function() {
        applyIntercomBg();
        if (window.flutter_inappwebview) {
          window.flutter_inappwebview.callHandler('onIntercomReady');
        }
      });
    ''',
    );
  }

  /// Скрыть Intercom (не уничтожая WebView).
  Future<void> _hide() async {
    if (!mounted || _closing || !_intercomVisible) return;
    _closing = true;
    await _slideController.forward(); // slide out
    if (mounted) {
      setState(() {
        _intercomVisible = false;
        _closing = false;
      });
      _slideController.value = 0;
    }
    _controller?.evaluateJavascript(source: "window.Intercom('hide');");
    _completeReady();
  }

  void _completeReady() {
    final c = IntercomWebViewOverlay._readyCompleter;
    if (c != null && !c.isCompleted) c.complete();
  }

  void _completeWithError(Object error) {
    final c = IntercomWebViewOverlay._readyCompleter;
    if (c != null && !c.isCompleted) c.completeError(error);
    if (mounted) setState(() => _intercomVisible = false);
  }

  Color? _parseColor(String css) {
    final rgbMatch =
        RegExp(r'rgba?\((\d+),\s*(\d+),\s*(\d+)').firstMatch(css);
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
    if (!_proxyReady || (_useLocalPageMode && _pageUri == null)) {
      return const SizedBox.shrink();
    }

    if (!_intercomVisible && !_closing) {
      return Offstage(
        child: SizedBox(width: 1, height: 1, child: _buildWebView()),
      );
    }

    return SlideTransition(
      position: Tween<Offset>(begin: Offset.zero, end: const Offset(0, 1))
          .animate(
            CurvedAnimation(
              parent: _slideController,
              curve: Curves.easeInCubic,
            ),
          ),
      child: IgnorePointer(
        ignoring: _closing,
        child: Stack(
          children: [
            Positioned.fill(
              child: ColoredBox(color: _intercomBgColor ?? Colors.transparent),
            ),
            Positioned.fill(child: _buildWebView()),
            const SizedBox.shrink(),
          ],
        ),
      ),
    );
  }

  Widget _buildWebView() {
    return InAppWebView(
      key: _webViewKey,
      initialUrlRequest: _useLocalPageMode
          ? URLRequest(url: WebUri(_pageUri.toString()))
          : null,
      initialSettings: _buildSettings(),
      onWebViewCreated: _onWebViewCreated,
      onConsoleMessage: (_, msg) {
        debugPrint('[Intercom WebView] ${msg.message}');
      },
      shouldOverrideUrlLoading: _handleUrlLoading,
      onReceivedHttpAuthRequest: (controller, challenge) async {
        final proxy = widget.proxyConfig;
        if (proxy != null && proxy.hasAuth) {
          debugPrint('[Intercom WebView] Proxy auth request from '
              '${challenge.protectionSpace.host}');
          return HttpAuthResponse(
            username: proxy.username!,
            password: proxy.password!,
            action: HttpAuthResponseAction.PROCEED,
            permanentPersistence: true,
          );
        }
        return HttpAuthResponse(action: HttpAuthResponseAction.CANCEL);
      },
    );
  }

  void _onWebViewCreated(InAppWebViewController controller) {
    _controller = controller;

    controller.addJavaScriptHandler(
      handlerName: 'onIntercomHide',
      callback: (_) => _hide(),
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
        _completeWithError(IntercomLoadException(msg));
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'onUnreadCountChange',
      callback: (args) {
        if (args.isNotEmpty) {
          final count = (args[0] as num?)?.toInt() ?? 0;
          IntercomWebViewOverlay.onUnreadCountChange?.call(count);
        }
      },
    );

    if (_useLocalPageMode) return;

    controller.loadData(
      data: _buildOverlayHtml(),
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

    if (_isLoopbackUri(uri)) {
      return NavigationActionPolicy.ALLOW;
    }

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

  String _buildOverlayHtml() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final padding = MediaQuery.of(context).padding;

    return IntercomHtmlBuilder(
      appId: widget.appId,
      userId: widget.userId,
      email: widget.email,
      userHash: widget.userHash,
      userName: widget.userName,
      customAttributes: widget.customAttributes,
      colorScheme: isDark ? 'dark' : 'light',
      topInset: padding.top,
      bottomInset: padding.bottom,
    ).build();
  }

  bool _isLoopbackUri(WebUri uri) {
    final host = uri.host.toLowerCase();
    return host == '127.0.0.1' || host == 'localhost';
  }
}
