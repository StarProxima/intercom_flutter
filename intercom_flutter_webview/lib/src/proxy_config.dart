import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Конфигурация прокси для WebView.
///
/// Нужна для обхода блокировок Intercom в РФ.
/// Поддержка:
/// - Android: ProxyController через androidx.webkit
/// - iOS 17+: ProxyController через WKWebsiteDataStore.proxyConfigurations
/// - macOS 14+: ProxyController через WKWebsiteDataStore.proxyConfigurations
/// - Windows: ProxyController через --proxy-server browser arg (WebView2)
class ProxyConfig {
  final String host;
  final int port;
  final String scheme;
  final String? username;
  final String? password;

  const ProxyConfig({
    required this.host,
    required this.port,
    this.scheme = 'http',
    this.username,
    this.password,
  });

  /// URL для ProxyController без credentials: Android/Windows не принимают
  /// user:pass@ в proxy URL (там авторизация идёт через onReceivedHttpAuthRequest).
  /// На iOS/macOS креды кладутся прямо в [ProxyRule] - см. [_buildSettings].
  String get proxyUrl => '$scheme://$host:$port';

  bool get hasAuth => username != null && password != null;

  static bool get _isSupported =>
      Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isMacOS ||
      Platform.isWindows;

  // ProxyController - процесс-глобальный (один на процесс). [_owner] + сериализация
  // [_serialize] защищают от гонки: при retry старый оверлей на dispose зовёт
  // clearProxy, новый - applyProxy. Без этого clear мог стереть свежий set, и
  // загрузка пошла бы мимо прокси.
  static Object? _owner;
  static Future<void> _opChain = Future<void>.value();

  static Future<T> _serialize<T>(Future<T> Function() op) {
    final next = _opChain.then((_) => op());
    _opChain = next.then((_) {}, onError: (_) {});

    return next;
  }

  /// Применяет прокси через ProxyController.
  /// Работает на Android, iOS 17+, macOS 14+, Windows.
  ///
  /// Возвращает false, если прокси применить не удалось: платформа без поддержки
  /// (iOS < 17 / macOS < 14), нет WebView-фичи PROXY_OVERRIDE, либо нативная
  /// ошибка. Caller ОБЯЗАН проверить результат - при false прокси не встал и
  /// грузить контент напрямую нельзя (иначе тихий обход прокси).
  ///
  /// [owner] - токен владельца override (обычно `this` оверлея); по нему
  /// [clearProxy] понимает, не перебил ли его другой оверлей.
  Future<bool> applyProxy({required Object owner}) {
    if (!_isSupported) return Future<bool>.value(false);

    return _serialize(() async {
      try {
        if (kDebugMode) {
          debugPrint('[ProxyConfig] Applying proxy: $host:$port '
              '(${hasAuth ? "with auth" : "no auth"})');
        }
        await ProxyController.instance().setProxyOverride(
          settings: _buildSettings(),
        );
        _owner = owner;
        if (kDebugMode) debugPrint('[ProxyConfig] Proxy applied successfully');

        return true;
      } catch (e) {
        if (kDebugMode) debugPrint('[ProxyConfig] Failed to apply proxy: $e');

        return false;
      }
    });
  }

  // iOS/macOS принимают креды прямо в ProxyRule (нативно applyCredential), и это
  // единственный путь авторизации на них. Android/Windows их в ProxyRule
  // игнорируют - там 407 от прокси разруливает onReceivedHttpAuthRequest.
  ProxySettings _buildSettings() {
    final useRuleCredentials = hasAuth && (Platform.isIOS || Platform.isMacOS);
    final rule = useRuleCredentials
        ? ProxyRule(url: proxyUrl, username: username, password: password)
        : ProxyRule(url: proxyUrl);

    return ProxySettings(proxyRules: [rule]);
  }

  /// Сброс прокси. Чистит override только если [owner] всё ещё владеет им -
  /// иначе (другой оверлей уже поставил свой прокси) это был бы no-op-стирание
  /// чужого override (гонка на retry).
  static Future<void> clearProxy({required Object owner}) {
    if (!_isSupported) return Future<void>.value();

    return _serialize(() async {
      if (!identical(_owner, owner)) {
        if (kDebugMode) {
          debugPrint('[ProxyConfig] clearProxy skipped: not current owner');
        }

        return;
      }
      try {
        await ProxyController.instance().clearProxyOverride();
        _owner = null;
        if (kDebugMode) debugPrint('[ProxyConfig] Proxy cleared');
      } catch (e) {
        if (kDebugMode) debugPrint('[ProxyConfig] Failed to clear proxy: $e');
      }
    });
  }
}
