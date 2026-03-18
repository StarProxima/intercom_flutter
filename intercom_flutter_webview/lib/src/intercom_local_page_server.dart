import 'dart:async';
import 'dart:io';

class IntercomLocalPageServer {
  final HttpServer _server;
  final String _html;
  late final StreamSubscription<HttpRequest> _subscription;

  IntercomLocalPageServer._(this._server, this._html) {
    _subscription = _server.listen(_handleRequest);
  }

  static Future<IntercomLocalPageServer> start({
    required String html,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return IntercomLocalPageServer._(server, html);
  }

  Uri get entryUri => Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: _server.port,
        path: '/',
      );

  Future<void> close() async {
    await _subscription.cancel();
    await _server.close(force: true);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      if (request.method != 'GET') {
        request.response.statusCode = HttpStatus.methodNotAllowed;
        await request.response.close();
        return;
      }

      if (request.uri.path == '/' || request.uri.path == '/index.html') {
        request.response.headers.contentType = ContentType.html;
        request.response.headers.set('Cache-Control', 'no-store');
        request.response.write(_html);
        await request.response.close();
        return;
      }

      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    } catch (_) {
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {}
    }
  }
}
