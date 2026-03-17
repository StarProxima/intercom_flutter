/// Генерирует HTML-страницу с Intercom Web Messenger.
///
/// Подход: загружаем Intercom JS SDK в WebView через loadData(),
/// что позволяет использовать Intercom на любой платформе с WebView
/// (Android, iOS, Windows, macOS) без нативного SDK.
class IntercomHtmlBuilder {
  final String appId;
  final String? userId;
  final String? email;
  final String? userHash;
  final String? userName;

  /// 'light' или 'dark' - синхронизация с темой приложения
  final String colorScheme;

  const IntercomHtmlBuilder({
    required this.appId,
    this.userId,
    this.email,
    this.userHash,
    this.userName,
    this.colorScheme = 'light',
  });

  String build() {
    final settingsEntries = <String>[
      "app_id: '$appId'",
      // Прячем дефолтный лаунчер - мы сами вызываем show()
      'hide_default_launcher: true',
      "color_scheme: '$colorScheme'",
    ];

    if (userId != null) settingsEntries.add("user_id: '$userId'");
    if (email != null) settingsEntries.add("email: '$email'");
    if (userHash != null) settingsEntries.add("user_hash: '$userHash'");
    if (userName != null) settingsEntries.add("name: '$userName'");

    final intercomSettings = settingsEntries.join(',\n        ');

    final bgColor = colorScheme == 'dark' ? '#1a1a1a' : '#ffffff';
    final textColor = colorScheme == 'dark' ? '#ffffff' : '#000000';

    return '''
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
  <title>Support</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      background: $bgColor;
      color: $textColor;
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
    }
    #loading {
      display: flex;
      justify-content: center;
      align-items: center;
      height: 100vh;
      font-size: 16px;
      opacity: 0.5;
    }
    /* Intercom фрейм растягиваем на весь экран */
    .intercom-lightweight-app-launcher,
    .intercom-launcher-frame {
      display: none !important;
    }
    .intercom-messenger-frame {
      position: fixed !important;
      top: 0 !important;
      left: 0 !important;
      right: 0 !important;
      bottom: 0 !important;
      width: 100% !important;
      height: 100% !important;
      max-height: 100% !important;
      border-radius: 0 !important;
      box-shadow: none !important;
    }
  </style>
</head>
<body>
  <div id="loading">Loading...</div>

  <script>
    window.intercomSettings = {
        $intercomSettings
    };

    (function() {
      var w = window;
      var ic = w.Intercom;
      if (typeof ic === "function") {
        ic('reattach_activator');
        ic('update', w.intercomSettings);
      } else {
        var d = document;
        var i = function() { i.c(arguments); };
        i.q = [];
        i.c = function(args) { i.q.push(args); };
        w.Intercom = i;

        var s = d.createElement('script');
        s.type = 'text/javascript';
        s.async = true;
        s.src = 'https://widget.intercom.io/widget/$appId';
        s.onload = function() {
          // SDK загружен - открываем мессенджер
          document.getElementById('loading').style.display = 'none';
          window.Intercom('show');
        };
        s.onerror = function() {
          document.getElementById('loading').textContent = 'Failed to load. Check your connection.';
        };
        var x = d.getElementsByTagName('script')[0];
        x.parentNode.insertBefore(s, x);
      }
    })();

    // Перехват закрытия мессенджера - уведомляем Flutter
    window.Intercom('onHide', function() {
      if (window.flutter_inappwebview) {
        window.flutter_inappwebview.callHandler('onIntercomHide');
      }
    });
  </script>
</body>
</html>
''';
  }
}
