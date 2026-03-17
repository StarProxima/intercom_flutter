import 'dart:io';

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

  const ProxyConfig({
    required this.host,
    required this.port,
    this.scheme = 'http',
  });

  String get proxyUrl => '$scheme://$host:$port';

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
      final proxyController = ProxyController.instance();
      final proxySettings = ProxySettings(
        proxyRules: [ProxyRule(url: proxyUrl)],
      );
      await proxyController.setProxyOverride(settings: proxySettings);
      return true;
    } catch (_) {
      // iOS < 17 / macOS < 14: ProxyController недоступен
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
    } catch (_) {
      // iOS < 17 / macOS < 14: ProxyController недоступен
    }
  }

  @Deprecated('Use clearProxy() instead')
  static Future<void> clearAndroidProxy() => clearProxy();
}
