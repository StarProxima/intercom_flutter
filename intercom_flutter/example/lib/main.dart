import 'package:flutter/material.dart';
import 'package:intercom_flutter/intercom_flutter.dart';

import 'package:intercom_flutter_webview/intercom_flutter_webview.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Intercom.instance.initialize('hc41m06w');
  // Логиним анонимного юзера, чтобы мессенджер загрузился
  await Intercom.instance.loginUnidentifiedUser();
  runApp(SampleApp());
}

class SampleApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      // Поддержка dark mode для проверки color_scheme
      themeMode: ThemeMode.system,
      theme: ThemeData.light(useMaterial3: true),
      darkTheme: ThemeData.dark(useMaterial3: true),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Intercom test'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // --- Native SDK ---
            const Text(
              'Native SDK',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: () => Intercom.instance.displayMessenger(),
              child: const Text('Open Messenger'),
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: () => Intercom.instance.displayHome(),
              child: const Text('Open Home'),
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: () => Intercom.instance.displayHelpCenter(),
              child: const Text('Open Help Center'),
            ),

            const SizedBox(height: 32),
            const Divider(),
            const SizedBox(height: 16),

            // --- WebView ---
            const Text(
              'WebView (кроссплатформенный)',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const IntercomWebViewScreen(
                      appId: 'hc41m06w',
                      // proxyConfig: ProxyConfig(host: '...', port: 8080),
                    ),
                  ),
                );
              },
              child: const Text('Open WebView Messenger'),
            ),
          ],
        ),
      ),
    );
  }
}
