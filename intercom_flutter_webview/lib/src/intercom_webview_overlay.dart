import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
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
    // origin документа WebView - должен быть в authorized domains workspace
    // Intercom, иначе messenger/web/ping -> 403 "domain not allowed".
    String baseUrl = 'https://app.intercom.io',
    // Фон под мессенджером - ставится сразу, без вспышки белого на первых
    // заходах. Конкретный цвет под тему workspace задаёт приложение (тут только
    // нейтральный fallback - пакет не знает палитру воркспейса).
    Color backgroundColor = const Color(0xFF000000),
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
      baseUrl: baseUrl,
      backgroundColor: backgroundColor,
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
  final String baseUrl;
  final Color backgroundColor;
  final Duration fallbackCloseDelay;

  const _OverlayWidget({
    required this.appId,
    this.userId,
    this.email,
    this.userHash,
    this.userName,
    this.customAttributes,
    this.proxyConfig,
    this.baseUrl = 'https://app.intercom.io',
    this.backgroundColor = const Color(0xFF000000),
    this.fallbackCloseDelay = const Duration(seconds: 15),
  });

  @override
  State<_OverlayWidget> createState() => _OverlayWidgetState();
}

class _OverlayWidgetState extends State<_OverlayWidget>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  // Фон фейдится при появлении (transparent -> backgroundColor, 300ms).
  // Сам WebView появляется без анимации.
  late final AnimationController _appearController;
  // Закрытие - дефолтный transition экрана (fade + zoom-out).
  late final AnimationController _closeController;
  final _webViewKey = GlobalKey();

  InAppWebViewController? _controller;
  bool _proxyReady = false;
  bool _sdkLoaded = false;
  bool _intercomVisible = false;
  bool _closing = false;
  // Текущий show отменён (таймаут/ошибка). Поздний _onIntercomReady
  // не должен всплывать поверх caller'а, ушедшего на webapp-fallback.
  bool _showCancelled = false;
  Timer? _fallbackTimer;
  IntercomLocalPageServer? _pageServer;
  Uri? _pageUri;
  // Момент старта загрузки (создание виджета) для относительных таймингов в логах.
  DateTime? _showStartedAt;

  bool get _useLocalPageMode => Platform.isWindows;

  @override
  void initState() {
    super.initState();
    _showStartedAt = DateTime.now();
    IntercomWebViewOverlay._state = this;
    WidgetsBinding.instance.addObserver(this);
    _appearController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _closeController = AnimationController(
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
    _appearController.dispose();
    _closeController.dispose();
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

  /// Прошло ms с момента старта show (создания виджета).
  int _elapsedMs() => _showStartedAt == null
      ? 0
      : DateTime.now().difference(_showStartedAt!).inMilliseconds;

  void _onIntercomReady() {
    if (!mounted) return;
    // SDK догрузился: запоминаем это и гасим fallback-таймер, чтобы будущий
    // show шёл по мгновенной ветке - даже если текущий show уже отменён.
    _sdkLoaded = true;
    _fallbackTimer?.cancel();
    if (kDebugMode) {
      debugPrint(
        '[Intercom WebView] onIntercomReady +${_elapsedMs()}ms '
        '(cancelled=$_showCancelled)',
      );
    }
    // Текущий show отменён (таймаут/ошибка) - caller уже ушёл на webapp.
    // Тихо догрелись в фоне, но не всплываем: прячем Intercom в JS.
    if (_showCancelled) {
      _controller?.evaluateJavascript(
        source: "window.Intercom('hide');",
      );
      return;
    }
    _applySystemChrome();
    setState(() => _intercomVisible = true);
    _appearController.forward(from: 0);
    _completeReady();
  }

  /// Повторное открытие через JS (SDK уже загружен).
  void _showIntercom() {
    if (_controller == null) return;
    // Переоткрытие после отмены прошлого show: снова разрешаем показ виджета.
    _showCancelled = false;
    _applySystemChrome();
    setState(() {
      _intercomVisible = true;
      _closing = false;
    });
    _closeController.value = 0;
    _appearController.forward(from: 0);
    // SDK уже загружен с темой из intercomSettings, но при reuse тему дублируем
    // через update - на случай если тема приложения сменилась между показами.
    final themeMode =
        Theme.of(context).brightness == Brightness.dark ? 'dark' : 'light';
    _controller!.evaluateJavascript(
      source: '''
      window.Intercom('update', {theme_mode: '$themeMode'});
      window.Intercom('show');
      window.Intercom('onShow', function() {
        _whenMessengerPainted(function() {
          if (window.flutter_inappwebview) {
            window.flutter_inappwebview.callHandler('onIntercomReady');
          }
        });
      });
    ''',
    );
  }

  /// Скрыть Intercom (не уничтожая WebView). Закрытие проигрывает Cupertino-pop
  /// slide вправо (см. build).
  Future<void> _hide() async {
    if (!mounted || _closing || !_intercomVisible) return;
    setState(() => _closing = true);
    await _closeController.forward(from: 0);
    if (mounted) {
      setState(() {
        _intercomVisible = false;
        _closing = false;
      });
      _closeController.value = 0;
      _appearController.value = 0;
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
    // Не держим завершённый completer и помечаем show отменённым: поздний
    // _onIntercomReady не должен всплыть поверх caller'а на webapp-fallback.
    IntercomWebViewOverlay._readyCompleter = null;
    _showCancelled = true;
    // Прячем виджет, но WebView НЕ убиваем - SDK догревается в фоне offstage,
    // чтобы повторное открытие осталось моментальным.
    if (mounted) setState(() => _intercomVisible = false);
  }

  /// Красит статус/нав-бар под фон чата. Цвет фиксированный (widget.backgroundColor),
  /// поэтому ставим сразу - без чтения реального фона мессенджера (оно ловило
  /// белый фрейм на первых заходах -> вспышка).
  void _applySystemChrome() {
    final color = widget.backgroundColor;
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
      // Греем webview сразу на полный размер (offstage всё равно рендерит
      // платформенный view, как и при 1x1). Так messenger верстается на
      // fullscreen ещё до показа - при reveal нет reflow/мигания, и фон не
      // появляется раньше виджета.
      final size = MediaQuery.of(context).size;
      return Offstage(
        child: SizedBox(
          width: size.width,
          height: size.height,
          child: _buildWebView(),
        ),
      );
    }

    final content = Stack(
      children: [
        Positioned.fill(
          child: ColoredBox(color: widget.backgroundColor),
        ),
        Positioned.fill(child: _buildWebView()),
      ],
    );

    if (_closing) {
      // Закрытие - slide вправо как дефолтный Cupertino-pop (translate
      // надёжно работает на платформенном webview, в отличие от fade/scale).
      return IgnorePointer(
        child: SlideTransition(
          position: Tween<Offset>(begin: Offset.zero, end: const Offset(1, 0))
              .animate(
                CurvedAnimation(
                  parent: _closeController,
                  curve: Curves.easeInOut,
                ),
              ),
          child: content,
        ),
      );
    }

    // Появление: без слайда, весь overlay плавно фейдится (messenger уже
    // отрисован на fullscreen - показывается вместе с фоном, без рассинхрона).
    return FadeTransition(opacity: _appearController, child: content);
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
        if (kDebugMode) {
          debugPrint(
            '[Intercom WebView] console(${msg.messageLevel}): ${msg.message}',
          );
        }
      },
      onLoadStart: (_, url) {
        if (kDebugMode) {
          debugPrint('[Intercom WebView] +${_elapsedMs()}ms loadStart: $url');
        }
      },
      onLoadStop: (_, url) {
        if (kDebugMode) {
          debugPrint('[Intercom WebView] +${_elapsedMs()}ms loadStop: $url');
        }
      },
      onReceivedError: (_, request, error) {
        if (kDebugMode) {
          debugPrint(
            '[Intercom WebView] +${_elapsedMs()}ms loadError: url=${request.url} '
            'type=${error.type} desc=${error.description}',
          );
        }
      },
      onReceivedHttpError: (_, request, errorResponse) {
        if (kDebugMode) {
          debugPrint(
            '[Intercom WebView] +${_elapsedMs()}ms httpError: url=${request.url} '
            'status=${errorResponse.statusCode} reason=${errorResponse.reasonPhrase}',
          );
        }
      },
      onReceivedServerTrustAuthRequest: (_, challenge) async {
        final sslError = challenge.protectionSpace.sslError;
        if (kDebugMode) {
          debugPrint(
            '[Intercom WebView] +${_elapsedMs()}ms serverTrust: '
            'host=${challenge.protectionSpace.host}:'
            '${challenge.protectionSpace.port} sslError=${sslError?.message}',
          );
        }
        // PROCEED только если система валидировала цепочку (sslError == null).
        // Иначе CANCEL - не доверяем подделанному серверу/прокси.
        return ServerTrustAuthResponse(
          action: sslError == null
              ? ServerTrustAuthResponseAction.PROCEED
              : ServerTrustAuthResponseAction.CANCEL,
        );
      },
      shouldOverrideUrlLoading: _handleUrlLoading,
      onReceivedHttpAuthRequest: (controller, challenge) async {
        final proxy = widget.proxyConfig;
        if (kDebugMode) {
          // Каждый CONNECT-туннель прокси к домену Intercom бьёт сюда -
          // по этим строкам видно водопад подключений и его тайминги.
          debugPrint(
            '[Intercom WebView] +${_elapsedMs()}ms proxy auth request from '
            '${challenge.protectionSpace.host}:${challenge.protectionSpace.port}',
          );
        }
        if (proxy != null && proxy.hasAuth) {
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
      baseUrl: WebUri(widget.baseUrl),
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
      // Все домены Intercom HTTPS-only, plain HTTP внутри не ожидается -
      // блокируем mixed content, иначе MITM сможет инжектить http-ресурсы.
      mixedContentMode: MixedContentMode.MIXED_CONTENT_NEVER_ALLOW,
      useHybridComposition: true,
      domStorageEnabled: true,
      supportZoom: false,
      transparentBackground: true,
    );
  }

  String _buildOverlayHtml() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final padding = MediaQuery.of(context).padding;
    final argb = widget.backgroundColor.toARGB32();
    final bgCss = '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

    return IntercomHtmlBuilder(
      appId: widget.appId,
      userId: widget.userId,
      email: widget.email,
      userHash: widget.userHash,
      userName: widget.userName,
      customAttributes: widget.customAttributes,
      colorScheme: isDark ? 'dark' : 'light',
      backgroundColorCss: bgCss,
      topInset: padding.top,
      bottomInset: padding.bottom,
    ).build();
  }

  bool _isLoopbackUri(WebUri uri) {
    final host = uri.host.toLowerCase();
    return host == '127.0.0.1' || host == 'localhost';
  }
}
