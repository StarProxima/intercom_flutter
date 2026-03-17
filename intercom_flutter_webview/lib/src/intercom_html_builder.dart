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

  /// 'light' или 'dark'
  final String colorScheme;

  /// Отступ сверху в пикселях (для status bar).
  final double topInset;

  /// Отступ снизу в пикселях (для navigation indicator).
  final double bottomInset;

  const IntercomHtmlBuilder({
    required this.appId,
    this.userId,
    this.email,
    this.userHash,
    this.userName,
    this.colorScheme = 'light',
    this.topInset = 0,
    this.bottomInset = 0,
  });

  /// Экранирует строку для вставки в JS литерал внутри одинарных кавычек.
  static String _escapeJs(String value) {
    return value
        .replaceAll(r'\', r'\\')
        .replaceAll("'", r"\'")
        .replaceAll('\n', r'\n')
        .replaceAll('\r', r'\r')
        .replaceAll('</', r'<\/');
  }

  String build() {
    final safeAppId = _escapeJs(appId);
    final settingsEntries = <String>[
      "app_id: '$safeAppId'",
      'hide_default_launcher: true',
    ];

    if (userId != null) settingsEntries.add("user_id: '${_escapeJs(userId!)}'");
    if (email != null) settingsEntries.add("email: '${_escapeJs(email!)}'");
    if (userHash != null) {
      settingsEntries.add("user_hash: '${_escapeJs(userHash!)}'");
    }
    if (userName != null) settingsEntries.add("name: '${_escapeJs(userName!)}'");

    final intercomSettings = settingsEntries.join(',\n        ');

    final topPx = topInset.toInt();
    final bottomPx = bottomInset.toInt();

    // Fallback цвет когда JS-детект не сработал
    final fallbackBg = colorScheme == 'dark' ? '#1a1a1a' : '#ffffff';

    const showJs = '''
          window.Intercom('show');
          window.Intercom('onShow', function() {
            applyIntercomBg();
            _notifyFlutter('onIntercomReady');
          });''';

    return '''
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover">
  <title>Support</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    html, body {
      background: transparent;
      width: 100%;
      height: 100%;
    }
    .intercom-lightweight-app-launcher,
    .intercom-launcher-frame {
      display: none !important;
    }
    .intercom-messenger-frame {
      position: fixed !important;
      top: ${topPx}px !important;
      left: 0 !important;
      right: 0 !important;
      bottom: ${bottomPx}px !important;
      width: 100% !important;
      height: calc(100% - ${topPx + bottomPx}px) !important;
      max-height: calc(100% - ${topPx + bottomPx}px) !important;
      border-radius: 0 !important;
      box-shadow: none !important;
    }
  </style>
</head>
<body>
  <script>
    window.intercomSettings = {
        $intercomSettings
    };

    function _notifyFlutter(handler, data) {
      if (window.flutter_inappwebview) {
        window.flutter_inappwebview.callHandler(handler, data);
      }
    }

    // Определяет background-color из Intercom контейнерных элементов.
    // Стратегия: сканируем все intercom-элементы в нашем DOM,
    // ищем первый с не-прозрачным background.
    function detectIntercomBg() {
      var els = document.querySelectorAll(
        '#intercom-container, #intercom-frame, ' +
        '.intercom-messenger-frame, [class*="intercom"]'
      );
      for (var i = 0; i < els.length; i++) {
        var bg = getComputedStyle(els[i]).backgroundColor;
        if (bg && bg !== 'rgba(0, 0, 0, 0)' && bg !== 'transparent') {
          return bg;
        }
      }
      return null;
    }

    function applyIntercomBg() {
      var attempts = 0;
      var applied = false;
      var interval = setInterval(function() {
        if (applied) { clearInterval(interval); return; }
        var bg = detectIntercomBg();
        if (bg) {
          document.body.style.background = bg;
          _notifyFlutter('onIntercomColor', bg);
          applied = true;
          clearInterval(interval);
        }
        if (++attempts > 30) {
          clearInterval(interval);
          // Fallback - используем цвет на основе темы
          if (!applied) {
            document.body.style.background = '$fallbackBg';
            _notifyFlutter('onIntercomColor', '$fallbackBg');
          }
        }
      }, 150);
    }

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
        s.src = 'https://widget.intercom.io/widget/$safeAppId';
        s.onload = function() {
          $showJs
        };
        s.onerror = function() {
          _notifyFlutter('onIntercomError',
            'Failed to load Intercom SDK from intercomcdn.com. ' +
            'Check network connection or proxy settings.');
        };
        var x = d.getElementsByTagName('script')[0];
        x.parentNode.insertBefore(s, x);
      }
    })();

    window.Intercom('onHide', function() {
      _notifyFlutter('onIntercomHide');
    });
  </script>
</body>
</html>
''';
  }
}
