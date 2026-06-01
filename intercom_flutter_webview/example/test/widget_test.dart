import 'package:flutter_test/flutter_test.dart';

import 'package:intercom_webview_example/main.dart';

void main() {
  testWidgets('рендерит экран с конфигом и кнопками', (tester) async {
    await tester.pumpWidget(const IntercomWebViewExampleApp());

    expect(find.text('Intercom WebView Example'), findsOneWidget);
    expect(find.text('Open overlay'), findsOneWidget);
    expect(find.text('Open screen'), findsOneWidget);
  });
}
