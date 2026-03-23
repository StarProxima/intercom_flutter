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

  /// URL для ProxyController (без credentials - Android не поддерживает
  /// user:pass@ в proxy URL). Авторизация через onReceivedHttpAuthRequest.
  String get proxyUrl => '$scheme://$host:$port';

  bool get hasAuth => username != null && password != null;

  /// Применяет прокси через ProxyController.
  /// Работает на Android, iOS 17+, macOS 14+, Windows.
  /// На iOS < 17 / macOS < 14 вернёт false (API недоступен).
  Future<bool> applyProxy() async {
    if (!Platform.isAndroid &&
        !Platform.isIOS &&
        !Platform.isMacOS &&
        !Platform.isWindows) {
      return false;
    }

    try {
      debugPrint('[ProxyConfig] Applying proxy: $host:$port '
          '(${username != null ? "with auth" : "no auth"})');
      final proxyController = ProxyController.instance();
      final proxySettings = ProxySettings(
        proxyRules: [ProxyRule(url: proxyUrl)],
      );
      await proxyController.setProxyOverride(settings: proxySettings);
      debugPrint('[ProxyConfig] Proxy applied successfully');
      return true;
    } catch (e) {
      debugPrint('[ProxyConfig] Failed to apply proxy: $e');
      return false;
    }
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
      debugPrint('[ProxyConfig] Proxy cleared');
    } catch (e) {
      debugPrint('[ProxyConfig] Failed to clear proxy: $e');
    }
  }

  @Deprecated('Use clearProxy() instead')
  static Future<void> clearAndroidProxy() => clearProxy();
}
