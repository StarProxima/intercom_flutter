import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Конфигурация прокси для WebView.
///
/// Нужна для обхода блокировок Intercom в РФ.
/// Поддержка зависит от платформы:
/// - Android: ProxyController (системный уровень)
/// - Windows: --proxy-server browser arg
/// - iOS/macOS: не поддерживается в flutter_inappwebview (нужен форк или нативный код)
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

  /// Применяет прокси для Android через ProxyController.
  /// Для Windows прокси задается через browser args в настройках WebView.
  /// Возвращает true если прокси применен.
  Future<bool> applyProxy() async {
    if (Platform.isAndroid) {
      return _applyAndroidProxy();
    }
    // Windows - прокси через browser args, см. getWindowsBrowserArgs()
    // iOS/macOS - не поддерживается flutter_inappwebview
    return false;
  }

  /// Browser args для Windows - передать в InAppWebViewSettings.
  /// Пример: ['--proxy-server=http://proxy:8080']
  List<String> getWindowsBrowserArgs() {
    return ['--proxy-server=$proxyUrl'];
  }

  Future<bool> _applyAndroidProxy() async {
    final proxyController = ProxyController.instance();
    final proxySettings = ProxySettings(
      proxyRules: [
        ProxyRule(url: proxyUrl),
      ],
    );
    await proxyController.setProxyOverride(settings: proxySettings);
    return true;
  }

  /// Сброс прокси на Android.
  static Future<void> clearAndroidProxy() async {
    if (Platform.isAndroid) {
      final proxyController = ProxyController.instance();
      await proxyController.clearProxyOverride();
    }
  }
}
