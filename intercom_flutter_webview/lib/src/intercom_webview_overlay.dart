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

/// Строит заглушку поверх вебвью на момент показа. [reveal] - прогресс раскрытия
/// (0 - закрыто, 1 - на весь экран), [fade] - кросс-фейд контента (0 - прозрачно,
/// виден вебвью; 1 - непрозрачно). Пакет владеет хореографией (гонит контроллеры),
/// а сам визуал перехода задаёт приложение - чтобы анимация, привязанная к
/// конкретной кнопке, жила в app, а не в пакете. null - дефолтная заглушка.
typedef IntercomCoverBuilder =
    Widget Function(
      BuildContext context,
      Animation<double> reveal,
      Animation<double> fade,
    );

/// Сколько держать webview тёплым после закрытия чата, прежде чем уничтожить.
///
/// В этом окне повторное открытие мгновенно (native webview reattach'ится из
/// keepAlive-пула, SDK уже загружен). По истечении - полный [IntercomWebViewOverlay.destroy],
/// чтобы не держать память/JS/chromium-треды ради редкого повторного захода. Подобрано
/// эмпирически: типовой пользователь возвращается в чат за секунды, не за минуты.
const _warmWindow = Duration(seconds: 90);

/// Intercom Web Messenger как fullscreen оверлей с тёплым (warm) WebView.
///
/// WebView создаётся при первом [show]. При закрытии чата НЕ уничтожается сразу,
/// а уходит из дерева в keepAlive-пул и живёт ещё [_warmWindow] - повторный заход
/// в этом окне мгновенный (reattach тёплого инстанса). После окна webview
/// уничтожается; следующий [show] грузит SDK заново.
///
/// - [show] - открыть Intercom. Первый вызов (и после warm-окна) грузит SDK,
///   повторный в окне - мгновенный.
/// - [destroy] - уничтожить WebView и освободить память немедленно.
/// - [onUnreadCountChange] - статический callback для отслеживания
///   непрочитанных разговоров.
class IntercomWebViewOverlay {
  IntercomWebViewOverlay._();

  static _OverlayWidgetState? _state;
  static OverlayEntry? _entry;
  static Completer<void>? _readyCompleter;

  /// Callback при изменении количества непрочитанных разговоров.
  /// Работает после первого вызова [show].
  static ValueChanged<int>? onUnreadCountChange;

  /// Вызывается, когда мессенджер реально отрисован на экране (фрейм появился
  /// и отрисован), а не просто `onShow`. Хук для аналитики - отсюда приложение
  /// может слать эвент «виджет поддержки действительно показался».
  static VoidCallback? onShown;

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
    // Визуал перехода показа/закрытия (см. [IntercomCoverBuilder]). Задаёт
    // приложение; null - дефолтная заглушка цвета фона без морфинга.
    IntercomCoverBuilder? coverBuilder,
  }) async {
    _readyCompleter = Completer<void>();

    // Переиспользуем тёплый оверлей только если identity/appId/baseUrl те же.
    // Иначе (logout->login, смена юзера) показали бы чат прошлого юзера -
    // пересоздаём ниже с новой identity.
    if (_state != null &&
        _state!.mounted &&
        _state!._sdkLoaded &&
        _state!._matchesShowConfig(
          appId: appId,
          userId: userId,
          email: email,
          userHash: userHash,
          baseUrl: baseUrl,
        )) {
      _state!._coverBuilder = coverBuilder;
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
      coverBuilder: coverBuilder,
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
  final IntercomCoverBuilder? coverBuilder;

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
    this.coverBuilder,
  });

  @override
  State<_OverlayWidget> createState() => _OverlayWidgetState();
}

class _OverlayWidgetState extends State<_OverlayWidget>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  // Позиция вебвью: 0 - на экране, 1 - за нижней границей. Меняется мгновенно
  // (snap) и всегда под непрозрачной заглушкой, поэтому не анимируется - вебвью
  // (platform view) только транслируется, без ресайза/масштаба.
  late final AnimationController _slideController;
  // Прогресс раскрытия заглушки: 0 - закрыто, 1 - на весь экран. Открытие -
  // forward, закрытие - reverse. Визуал по нему рисует coverBuilder приложения.
  late final AnimationController _revealController;
  // Кросс-фейд контента: 0 - заглушка прозрачна (виден вебвью), 1 - непрозрачна.
  // На открытии гасим в 0 в конце (контент проявляется), на закрытии поднимаем в
  // 1 в начале (контент уходит под заглушку перед схлопыванием).
  late final AnimationController _fadeController;
  // Визуал перехода от приложения. null - дефолтная заглушка без морфинга.
  IntercomCoverBuilder? _coverBuilder;
  final _webViewKey = GlobalKey();

  InAppWebViewController? _controller;
  // Токен тёплого инстанса: при unmount native webview паркуется в keepAlive-пуле
  // (не уничтожается), при reattach возвращается тем же. Один объект на всю жизнь
  // оверлея - освобождается в dispose через disposeKeepAlive.
  late final InAppWebViewKeepAlive _keepAlive;
  // Чат закрыт, webview спит: убран из дерева (платформ-вью вне сцены, композитинг
  // прекращён), но тёплый в пуле. Повторный show в окне _warmWindow будит его.
  bool _sleeping = false;
  // initial loadData делаем один раз. На reattach onWebViewCreated приходит снова с
  // новым контроллером, но страница уже загружена и JS-handlers пакет восстановил
  // сам - повторный loadData был бы холодной перезагрузкой.
  bool _initialLoadDone = false;
  // Просыпаемся по show: дождаться свежего контроллера из onWebViewCreated и только
  // тогда дёрнуть Intercom('show') - на detached-контроллер спящего вью полагаться нельзя.
  bool _pendingShowAfterWake = false;
  // Отложенное уничтожение по истечении _warmWindow.
  Timer? _sleepTimer;
  // Идентифицирует текущую операцию закрытия: повторный show до конца анимации
  // инвалидирует её токен, чтобы отложенный finishClose не закрыл уже переоткрытый чат.
  Object? _closeToken;
  bool _proxyReady = false;
  // Системный стиль баров до открытия чата - восстанавливаем на закрытии, иначе
  // статус/нав-бар остаются крашены в фон чата (_applySystemChrome).
  SystemUiOverlayStyle? _previousChrome;
  bool _sdkLoaded = false;
  bool _intercomVisible = false;
  bool _closing = false;
  // Заглушка поверх вебвью - живёт только на МОМЕНТ показа чата. Прикрывает
  // белую вспышку: вебвью грелся за экраном, его surface остаётся дефолтно-белым
  // и при выводе на экран мелькает; заглушка перекрывает его, пока on-screen не
  // скомпозится тёмный контент, и снимается по _uncoverTimer (в _runReveal). Сам
  // визуал (морфинг из кнопки и т.п.) рисует coverBuilder приложения. На фазе
  // ЗАГРУЗКИ заглушки нет: оверлей за экраном, приложение видно и доступно.
  bool _covered = false;
  Timer? _uncoverTimer;
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
    _coverBuilder = widget.coverBuilder;
    _keepAlive = InAppWebViewKeepAlive();
    IntercomWebViewOverlay._state = this;
    WidgetsBinding.instance.addObserver(this);
    _slideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _revealController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
    );
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 160),
    );
    // Стартуем за экраном (value=1): вебвью греется fullscreen за нижней границей,
    // приложение под оверлеем полностью видно и доступно. Показ - раскрытие
    // заглушки из кнопки + snap вебвью в 0 под уже-фуллскрин-заглушкой.
    _slideController.value = 1;
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
    _revealController.dispose();
    _fadeController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _fallbackTimer?.cancel();
    _uncoverTimer?.cancel();
    _sleepTimer?.cancel();
    // keepAlive держит native webview живым после unmount - на полном teardown
    // освобождаем его, иначе native webview + JS утекут в пул. К этому моменту
    // InAppWebView уже unmount'нут (dispose детей раньше родителя), поэтому
    // disposeKeepAlive безопасен (вью вне дерева).
    unawaited(InAppWebViewController.disposeKeepAlive(_keepAlive));
    unawaited(_pageServer?.close() ?? Future<void>.value());
    if (widget.proxyConfig != null) {
      ProxyConfig.clearProxy(owner: this);
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Свернули приложение, пока webview спит off-screen - уничтожаем сразу, не ждём
    // _warmWindow: иначе тёплый webview зря висит в фоне, а deferred-таймер в фоне
    // фризится и мог бы проснуться спустя часы, убив инстанс не вовремя. Открытый
    // чат на фоне не трогаем - пользователь вернётся в свой разговор.
    if (state == AppLifecycleState.paused && _sleeping) {
      IntercomWebViewOverlay.destroy();
    }
  }

  // Legacy system back (кнопка/жест без predictive back).
  @override
  Future<bool> didPopRoute() async {
    if (_intercomVisible) {
      _hide();
      return true;
    }
    return false;
  }

  // Predictive back (Android 13+/жест). Пока чат открыт - «клеймим» жест на себя,
  // иначе он уходит в Navigator/систему и закрывает всё приложение, а не оверлей.
  // Без клейма didPopRoute сюда не доходит (вызывается лишь как fallback, когда
  // жест не заклеймлен).
  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) => _intercomVisible;

  @override
  void handleCommitBackGesture() {
    if (_intercomVisible) _hide();
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
    if (proxy != null) {
      final applied = await proxy.applyProxy(owner: this);
      // Прокси не встал - грузить Intercom напрямую нельзя (тихий обход прокси).
      // Рвём show с ошибкой: caller уйдёт на webapp-fallback, а вебвью так и не
      // монтируется (build ждёт _proxyReady), прямого коннекта не будет.
      if (!applied) {
        _completeWithError(
          const IntercomLoadException(
            'Failed to apply proxy. Check proxy settings or platform support.',
          ),
        );

        return;
      }
    }
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
    // Сообщаем движку, что back обрабатываем мы (иначе при predictive back ОС
    // покажет «приложение закроется» и закроет его, минуя наш handleStartBackGesture).
    SystemNavigator.setFrameworkHandlesBack(true);
    setState(() {
      _covered = true;
      _intercomVisible = true;
    });
    _runReveal();
    _completeReady();
  }

  /// Показ container-transform'ом: контейнер-заглушка раскрывается из rect кнопки
  /// в фуллскрин (вебвью держим за экраном - platform view нельзя масштабировать).
  /// Когда контейнер стал фуллскрин - снапаем вебвью под него, ждём прокраски
  /// surface (минуя белую реализацию) и плавно гасим заглушку: контент проявляется.
  void _runReveal() {
    _uncoverTimer?.cancel();
    _fadeController.value = 1; // заглушка непрозрачна
    _slideController.value = 1; // вебвью за экраном на время морфинга

    void onMorphed() {
      if (!mounted) return;
      _slideController.value = 0; // снап вебвью под фуллскрин-заглушку
      _uncoverTimer = Timer(const Duration(milliseconds: 250), () {
        if (!mounted) return;
        _fadeController.reverse().whenComplete(() {
          if (mounted) setState(() => _covered = false);
        });
      });
    }

    // Без кастомного визуала - без морфинга: сразу фуллскрин-заглушка.
    if (_coverBuilder == null) {
      _revealController.value = 1;
      onMorphed();
      return;
    }
    _revealController.forward(from: 0).whenComplete(onMorphed);
  }

  /// Тёплый оверлей валиден для reuse только при совпадении identity/appId/baseUrl.
  bool _matchesShowConfig({
    required String appId,
    required String? userId,
    required String? email,
    required String? userHash,
    required String baseUrl,
  }) =>
      widget.appId == appId &&
      widget.userId == userId &&
      widget.email == email &&
      widget.userHash == userHash &&
      widget.baseUrl == baseUrl;

  /// Повторное открытие. Из сна - будит webview (reattach из keepAlive), иначе -
  /// сразу JS-показ на тёплом контроллере.
  void _showIntercom() {
    _showCancelled = false;
    _cancelSleepTimer();
    _interruptClose();
    // На тёплом reopen initState-таймера уже нет (отменён в _onIntercomReady), а
    // onShow на warm-state SDK может не прийти - ставим свой таймаут, иначе caller
    // (await show) висит вечно со спиннером.
    _fallbackTimer?.cancel();
    _fallbackTimer = Timer(widget.fallbackCloseDelay, () {
      if (mounted && !_intercomVisible && !_showCancelled) {
        _completeWithError(
          const IntercomLoadException('Intercom failed to reopen (timeout).'),
        );
      }
    });

    if (_sleeping) {
      // Спим: возвращаем InAppWebView в дерево (reattach тёплого инстанса), показ
      // дёрнем в _onWebViewCreated, когда придёт свежий контроллер. Заглушку
      // поднимаем сразу - прячет мелькание surface при ремаунте платформ-вью.
      _pendingShowAfterWake = true;
      setState(() {
        _sleeping = false;
        _covered = true;
      });
      return;
    }

    if (_controller == null) return;
    _doShowJs();
  }

  /// JS-показ на текущем (тёплом) контроллере. onShow-хук стоит с initial-загрузки
  /// и сработает -> onIntercomReady -> reveal. Тему дублируем через update на случай
  /// смены темы приложения между показами.
  void _doShowJs() {
    final controller = _controller;
    if (controller == null) return;
    final themeMode =
        Theme.of(context).brightness == Brightness.dark ? 'dark' : 'light';
    controller.evaluateJavascript(
      source: '''
      window.Intercom('update', {theme_mode: '$themeMode'});
      window.Intercom('show');
    ''',
    );
  }

  void _cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
  }

  /// Гасит незавершённую анимацию закрытия: инвалидирует её токен (отложенные
  /// collapse/finishClose увидят чужой токен и выйдут) и останавливает контроллеры.
  void _interruptClose() {
    if (!_closing && _closeToken == null) return;
    _closeToken = null;
    _fadeController.stop();
    _revealController.stop();
    _closing = false;
  }

  /// Уход в сон: убираем webview из дерева (платформ-вью покидает сцену, композитинг
  /// прекращается; native паркуется в keepAlive-пуле тёплым) и заводим таймер на
  /// полное уничтожение по истечении _warmWindow.
  void _enterSleep() {
    if (!mounted) return;
    setState(() => _sleeping = true);
    _cancelSleepTimer();
    _sleepTimer = Timer(_warmWindow, () {
      // Окно вышло без повторного открытия - уничтожаем webview целиком (память/JS/
      // chromium-треды). Гард _sleeping закрывает гонку с reopen ровно на тике: если
      // успели проснуться, не трогаем. Следующий show грузит SDK заново.
      if (!mounted || !_sleeping) return;
      IntercomWebViewOverlay.destroy();
    });
  }

  /// Закрытие container-transform'ом (зеркально показу): поднимаем заглушку над
  /// контентом (fade) и схлопываем контейнер обратно в rect кнопки, после чего
  /// webview уходит в сон (_enterSleep) - тёплым, но вне сцены. Отложенные шаги
  /// сверяют _closeToken: повторный show до конца анимации его инвалидирует, и
  /// устаревший finishClose не закроет уже переоткрытый чат.
  void _hide() {
    if (!mounted || _closing || !_intercomVisible) return;
    _uncoverTimer?.cancel();
    final token = Object();
    _closeToken = token;

    void finishClose() {
      if (!mounted || _closeToken != token) return;
      _closeToken = null;
      // Чат закрыт - back снова обрабатывает система/Navigator.
      SystemNavigator.setFrameworkHandlesBack(false);
      // Возвращаем стиль баров приложения (на открытии красили в фон чата).
      final previous = _previousChrome;
      if (previous != null) SystemChrome.setSystemUIOverlayStyle(previous);
      setState(() {
        _covered = false;
        _intercomVisible = false;
        _closing = false;
      });
      _controller?.evaluateJavascript(source: "window.Intercom('hide');");
      _completeReady();
      _enterSleep();
    }

    // Закрытие во время показа (заглушка ещё поднята) - прячем оверлей мгновенно.
    if (_covered) {
      _revealController.stop();
      _fadeController.stop();
      finishClose();

      return;
    }

    setState(() {
      _closing = true;
      _covered = true; // поднимаем заглушку над контентом
    });

    void collapse() {
      if (!mounted || _closeToken != token) return;
      if (_coverBuilder == null) {
        _revealController.value = 0;
        finishClose();
      } else {
        _revealController.reverse().whenComplete(finishClose);
      }
    }

    // 1) Контент уходит под заглушку (fade in), 2) схлопываем контейнер в кнопку.
    _fadeController.forward(from: 0).whenComplete(collapse);
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
    _pendingShowAfterWake = false;
    _uncoverTimer?.cancel();
    // Снимаем заглушку и уводим webview в сон - приложение снова доступно (caller
    // ушёл на webapp). НЕ держим тёплым за экраном, как раньше: иначе off-screen
    // платформ-вью композитится впустую. Спящий вью вне сцены, а _warmWindow его
    // потом уничтожит (быстрый повторный заход в окне всё ещё мгновенный).
    if (mounted) {
      setState(() {
        _intercomVisible = false;
        _covered = false;
      });
      _enterSleep();
    }
  }

  /// Красит статус/нав-бар под фон чата. Цвет фиксированный (widget.backgroundColor),
  /// поэтому ставим сразу - без чтения реального фона мессенджера (оно ловило
  /// белый фрейм на первых заходах -> вспышка).
  void _applySystemChrome() {
    // Снимок стиля приложения до первого оверрайда - вернём его в finishClose.
    _previousChrome ??= SystemChrome.latestStyle;
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

    // Спим: webview убран из дерева (платформ-вью вне сцены - композитинг прекращён),
    // native тёплый в keepAlive-пуле. Оверлей ничего не рисует, приложение доступно.
    if (_sleeping) return const SizedBox.shrink();

    // Пока поднята заглушка (момент показа) или идёт закрытие - глушим тачи во
    // всём оверлее, чтобы они не проваливались на приложение под ним. В открытом
    // чате (заглушка снята) вебвью интерактивен. За экраном (загрузка/закрыт)
    // оверлей не ловит тачи - приложение доступно.
    return AbsorbPointer(
      absorbing: _covered || _closing,
      child: Stack(
        children: [
          // Webview fullscreen, пока чат живой (открыт/греется/закрывается). На сон
          // он убирается из дерева целиком (см. _sleeping выше), а не ресайзится -
          // ресайз/Offstage платформ-вью давал рывок и белые полосы по краям.
          // Видимостью на экране управляет слайд: value=1 - за нижней границей,
          // value=0 - на экране.
          Positioned.fill(
            child: SlideTransition(
              position:
                  Tween<Offset>(begin: Offset.zero, end: const Offset(0, 1))
                      .animate(
                        CurvedAnimation(
                          parent: _slideController,
                          curve: Curves.easeInCubic,
                        ),
                      ),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: ColoredBox(color: widget.backgroundColor),
                  ),
                  // Оверлей не Scaffold, поэтому сам под клавиатуру не ужимается,
                  // а вебвью фуллскрин. На iOS клавиатура оверлеит контент
                  // (WKWebView не двигает инпут, composer уходит под клаву); на
                  // Android нативный WebView сам скроллит контент, утягивая хедер
                  // вверх. Ужимаем вебвью снизу на высоту клавиатуры: фрейм
                  // уменьшается -> инпут встаёт над клавой, хедер остаётся на месте.
                  // Инсет только когда чат - интерактивная foreground-поверхность
                  // (открыт, заглушка снята, не закрывается); иначе (греется
                  // off-screen / под заглушкой / закрывается) ambient-клавиатура
                  // приложения снизу зря ресайзила бы вебвью.
                  Positioned.fill(
                    child: Padding(
                      padding: EdgeInsets.only(
                        bottom: _intercomVisible && !_covered && !_closing
                            ? MediaQuery.viewInsetsOf(context).bottom
                            : 0.0,
                      ),
                      child: _IntercomWebView(
                        webViewKey: _webViewKey,
                        keepAlive: _keepAlive,
                        initialUrlRequest: _useLocalPageMode
                            ? URLRequest(url: WebUri(_pageUri.toString()))
                            : null,
                        proxyConfig: widget.proxyConfig,
                        originHost: Uri.parse(widget.baseUrl).host,
                        onCreated: _onWebViewCreated,
                        elapsedMs: _elapsedMs,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Заглушка поверх вебвью на момент показа: визуал задаёт приложение
          // (coverBuilder), пакет лишь гонит контроллеры. Без билдера - дефолтная
          // заглушка цвета фона. Прячет белую реализацию surface при выводе.
          if (_covered)
            _coverBuilder?.call(context, _revealController, _fadeController) ??
                _DefaultCover(
                  fade: _fadeController,
                  color: widget.backgroundColor,
                ),
        ],
      ),
    );
  }

  void _onWebViewCreated(InAppWebViewController controller) {
    _controller = controller;

    // Reattach из keepAlive-пула (пробуждение из сна): onWebViewCreated приходит
    // снова с новым контроллером, но страница уже загружена, а JS-handlers пакет
    // восстановил в новом контроллере сам. Перевешивать handlers и звать loadData
    // тут нельзя - это была бы холодная перезагрузка. Только дёргаем отложенный
    // показ на свежем контроллере.
    if (_initialLoadDone) {
      if (_pendingShowAfterWake) {
        _pendingShowAfterWake = false;
        _doShowJs();
      }
      return;
    }
    _initialLoadDone = true;

    controller.addJavaScriptHandler(
      handlerName: 'onIntercomHide',
      callback: (_) => _hide(),
    );
    controller.addJavaScriptHandler(
      handlerName: 'onIntercomReady',
      callback: (_) => _onIntercomReady(),
    );
    controller.addJavaScriptHandler(
      handlerName: 'onIntercomShown',
      callback: (_) {
        if (kDebugMode) {
          debugPrint('[Intercom WebView] onIntercomShown +${_elapsedMs()}ms');
        }
        // Мессенджер реально отрисован - дёргаем хук аналитики. Заглушку здесь НЕ
        // снимаем: onIntercomShown ловит отрисовку DOM (она на прогреве за экраном
        // уже была), а нам нужно дождаться композита surface ON-SCREEN после
        // снапа - этим занимается _uncoverTimer в _runReveal.
        if (!_showCancelled) IntercomWebViewOverlay.onShown?.call();
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
      baseUrl: WebUri(widget.baseUrl),
      mimeType: 'text/html',
      encoding: 'utf-8',
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
}

/// WebView с Intercom Web Messenger: загрузка по [initialUrlRequest] (локальный
/// режим) либо через `loadData` в [onCreated]. Внешние ссылки уходят в системный
/// браузер, прокси-авторизация и server-trust обрабатываются здесь. [elapsedMs] -
/// для относительных таймингов в debug-логах.
class _IntercomWebView extends StatelessWidget {
  const _IntercomWebView({
    required this.webViewKey,
    required this.keepAlive,
    required this.initialUrlRequest,
    required this.proxyConfig,
    required this.originHost,
    required this.onCreated,
    required this.elapsedMs,
  });

  final Key webViewKey;
  // Тёплый токен: при unmount native webview паркуется в пуле, при remount
  // (пробуждение из сна) возвращается тем же - без перезагрузки SDK.
  final InAppWebViewKeepAlive keepAlive;
  final URLRequest? initialUrlRequest;
  final ProxyConfig? proxyConfig;
  // Хост страницы мессенджера (из baseUrl) - его навигации держим в вебвью,
  // остальные внешние хосты уводим в системный браузер (см. _shouldKeepInWebView).
  final String originHost;
  final void Function(InAppWebViewController controller) onCreated;
  final int Function() elapsedMs;

  @override
  Widget build(BuildContext context) {
    return InAppWebView(
      key: webViewKey,
      keepAlive: keepAlive,
      initialUrlRequest: initialUrlRequest,
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        // Все домены Intercom HTTPS-only, plain HTTP внутри не ожидается -
        // блокируем mixed content, иначе MITM сможет инжектить http-ресурсы.
        mixedContentMode: MixedContentMode.MIXED_CONTENT_NEVER_ALLOW,
        useHybridComposition: true,
        domStorageEnabled: true,
        supportZoom: false,
        transparentBackground: true,
        // Без этого shouldOverrideUrlLoading на Android может не вызываться, и
        // внешние ссылки из чата грузились бы внутри вебвью (где их режет прокси).
        useShouldOverrideUrlLoading: true,
        // Ссылки Intercom (справка/агентские) часто target=_blank -> onCreateWindow.
        // Эти два флага нужны, чтобы колбэк сработал, а не молча проглотился.
        supportMultipleWindows: true,
        javaScriptCanOpenWindowsAutomatically: true,
      ),
      onWebViewCreated: onCreated,
      // target=_blank / window.open: новое окно в вебвью не создаём, внешний хост
      // уводим в системный браузер (как и обычные внешние навигации).
      onCreateWindow: (_, action) async {
        final uri = action.request.url;
        if (uri != null && !_shouldKeepInWebView(uri) && uri.hasScheme) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }

        return false;
      },
      onConsoleMessage: (_, msg) {
        if (kDebugMode) {
          debugPrint(
            '[Intercom WebView] console(${msg.messageLevel}): ${msg.message}',
          );
        }
      },
      onLoadStart: (_, url) {
        if (kDebugMode) {
          debugPrint('[Intercom WebView] +${elapsedMs()}ms loadStart: $url');
        }
      },
      onLoadStop: (_, url) {
        if (kDebugMode) {
          debugPrint('[Intercom WebView] +${elapsedMs()}ms loadStop: $url');
        }
      },
      onReceivedError: (_, request, error) {
        if (kDebugMode) {
          debugPrint(
            '[Intercom WebView] +${elapsedMs()}ms loadError: url=${request.url} '
            'type=${error.type} desc=${error.description}',
          );
        }
      },
      onReceivedHttpError: (_, request, errorResponse) {
        if (kDebugMode) {
          debugPrint(
            '[Intercom WebView] +${elapsedMs()}ms httpError: url=${request.url} '
            'status=${errorResponse.statusCode} reason=${errorResponse.reasonPhrase}',
          );
        }
      },
      onReceivedServerTrustAuthRequest: (_, challenge) async {
        final sslError = challenge.protectionSpace.sslError;
        if (kDebugMode) {
          debugPrint(
            '[Intercom WebView] +${elapsedMs()}ms serverTrust: '
            'host=${challenge.protectionSpace.host}:'
            '${challenge.protectionSpace.port} sslError=${sslError?.message}',
          );
        }
        // iOS для валидного системно-доверенного серта отдаёт не null, а
        // UNSPECIFIED (kSecTrustResultUnspecified: «оценка успешна, серт
        // доверенный») - это успех. Android для валидных даёт null. PROCEED в
        // обоих успешных случаях; иначе (expired/untrusted/mismatch/...) CANCEL -
        // не доверяем подделанному серверу/прокси. Без UNSPECIFIED на iOS
        // рубились ВСЕ https-загрузки (скрипты Intercom) -> чат не открывался.
        final trusted =
            sslError == null || sslError.code == SslErrorType.UNSPECIFIED;

        return ServerTrustAuthResponse(
          action: trusted
              ? ServerTrustAuthResponseAction.PROCEED
              : ServerTrustAuthResponseAction.CANCEL,
        );
      },
      shouldOverrideUrlLoading: _handleUrlLoading,
      onReceivedHttpAuthRequest: (controller, challenge) async {
        final proxy = proxyConfig;
        final space = challenge.protectionSpace;
        if (kDebugMode) {
          // Каждый CONNECT-туннель прокси к домену Intercom бьёт сюда -
          // по этим строкам видно водопад подключений и его тайминги.
          debugPrint(
            '[Intercom WebView] +${elapsedMs()}ms proxy auth request from '
            '${space.host}:${space.port}',
          );
        }
        // Креды прокси отдаём ТОЛЬКО на челлендж от самого прокси - сверяем по
        // host (он уникален, не пересекается с Intercom-доменами); иначе origin-
        // сервер с Basic-челленджем выманил бы прокси-креды. Порт сверяем
        // толерантно: Android в proxy-челлендже отдаёт port=-1/null (не указан).
        final port = space.port;
        final isProxyChallenge = proxy != null &&
            space.host == proxy.host &&
            (port == null || port <= 0 || port == proxy.port);
        if (isProxyChallenge && proxy.hasAuth) {
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

  Future<NavigationActionPolicy> _handleUrlLoading(
    InAppWebViewController controller,
    NavigationAction action,
  ) async {
    final uri = action.request.url;
    if (uri == null) return NavigationActionPolicy.ALLOW;

    if (kDebugMode) {
      debugPrint(
        '[Intercom WebView] urlLoading: type=${action.navigationType} '
        'mainFrame=${action.isForMainFrame} url=$uri',
      );
    }

    if (_shouldKeepInWebView(uri)) return NavigationActionPolicy.ALLOW;

    // Навигация на внешний хост (ссылка из чата на справку / агентская ссылка) -
    // в системный браузер, а не внутрь вебвью: там её режет прокси (CONNECT
    // только к Intercom-доменам) -> "access denied" и перекрытие чата.
    if (uri.hasScheme) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
    return NavigationActionPolicy.CANCEL;
  }

  // В вебвью держим только страницу мессенджера (origin) + домены Intercom +
  // служебные схемы; остальное уводим наружу. Решаем по ХОСТУ (не substring:
  // 'intercom.io.evil.test' не должен пройти) и НЕ по navigationType: ссылки
  // Intercom часто открываются через JS (target=_blank) как OTHER, а не
  // LINK_ACTIVATED. Origin в allowlist'е чинит и initial loadData(baseUrl) на
  // iOS (иначе он улетал в Safari, оставляя вебвью пустым).
  bool _shouldKeepInWebView(WebUri uri) {
    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'about' || scheme == 'data' || scheme == 'blob') return true;
    if (_isLoopbackUri(uri)) return true;

    final host = uri.host.toLowerCase();

    return host == originHost || _isIntercomHost(host);
  }

  bool _isIntercomHost(String host) {
    const domains = [
      'intercom.io',
      'intercomcdn.com',
      'intercomassets.com',
      'intercom-messenger.com',
    ];

    return domains.any((d) => host == d || host.endsWith('.$d'));
  }

  bool _isLoopbackUri(WebUri uri) {
    final host = uri.host.toLowerCase();
    return host == '127.0.0.1' || host == 'localhost';
  }
}

/// Дефолтная заглушка (когда [IntercomCoverBuilder] не задан): на весь экран
/// цвета [color], гаснет по [fade] при показе/закрытии. Без морфинга.
class _DefaultCover extends StatelessWidget {
  const _DefaultCover({required this.fade, required this.color});

  final Animation<double> fade;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: AnimatedBuilder(
        animation: fade,
        builder: (context, _) => ColoredBox(
          color: color.withValues(alpha: fade.value.clamp(0.0, 1.0)),
        ),
      ),
    );
  }
}
