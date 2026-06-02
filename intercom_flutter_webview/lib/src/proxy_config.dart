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

  /// Применяет прокси через ProxyController.
  /// Работает на Android, iOS 17+, macOS 14+, Windows.
  ///
  /// Возвращает false, если прокси применить не удалось: платформа без поддержки
  /// (iOS < 17 / macOS < 14), нет WebView-фичи PROXY_OVERRIDE, либо нативная
  /// ошибка. Caller ОБЯЗАН проверить результат - при false прокси не встал и
  /// грузить контент напрямую нельзя (иначе тихий обход прокси).
  Future<bool> applyProxy() async {
    if (!Platform.isAndroid &&
        !Platform.isIOS &&
        !Platform.isMacOS &&
        !Platform.isWindows) {
      return false;
    }

    try {
      if (kDebugMode) {
        debugPrint('[ProxyConfig] Applying proxy: $host:$port '
            '(${hasAuth ? "with auth" : "no auth"})');
      }
      final proxyController = ProxyController.instance();
      await proxyController.setProxyOverride(settings: _buildSettings());
      if (kDebugMode) debugPrint('[ProxyConfig] Proxy applied successfully');
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('[ProxyConfig] Failed to apply proxy: $e');
      return false;
    }
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

  /// Сброс прокси.
  static Future<void> clearProxy() async {
    if (!Platform.isAndroid &&
        !Platform.isIOS &&
        !Platform.isMacOS &&
        !Platform.isWindows) {
      return;
    }

    try {
      final proxyController = ProxyController.instance();
      await proxyController.clearProxyOverride();
      if (kDebugMode) debugPrint('[ProxyConfig] Proxy cleared');
    } catch (e) {
      if (kDebugMode) debugPrint('[ProxyConfig] Failed to clear proxy: $e');
    }
  }

  @Deprecated('Use clearProxy() instead')
  static Future<void> clearAndroidProxy() => clearProxy();
}
