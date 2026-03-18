#!/usr/bin/env python3
import argparse
import select
import socket
import socketserver
import sys
import threading
from http.server import BaseHTTPRequestHandler


BUFFER_SIZE = 64 * 1024


class ThreadingHTTPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True


class ConnectProxyHandler(BaseHTTPRequestHandler):
    server_version = "IntercomConnectProxy/0.1"
    timeout = 10

    def do_CONNECT(self) -> None:
      target_host, target_port = self._parse_connect_target(self.path)
      if target_host is None or target_port is None:
        self.send_error(400, "Invalid CONNECT target")
        return

      upstream = None
      try:
        upstream = socket.create_connection((target_host, target_port), timeout=self.timeout)
        upstream.setblocking(False)
        self.connection.setblocking(False)

        self.send_response(200, "Connection Established")
        self.end_headers()

        self.log_message("CONNECT established %s:%s", target_host, target_port)
        self._relay_tunnel(upstream)
      except OSError as error:
        self.log_error("CONNECT failed %s:%s %s", target_host, target_port, error)
        if not self.wfile.closed:
          self.send_error(502, f"Unable to connect to upstream: {error}")
      finally:
        if upstream is not None:
          try:
            upstream.close()
          except OSError:
            pass

    def do_GET(self) -> None:
      self.send_error(405, "Only CONNECT is supported")

    def do_POST(self) -> None:
      self.send_error(405, "Only CONNECT is supported")

    def do_PUT(self) -> None:
      self.send_error(405, "Only CONNECT is supported")

    def do_DELETE(self) -> None:
      self.send_error(405, "Only CONNECT is supported")

    def do_PATCH(self) -> None:
      self.send_error(405, "Only CONNECT is supported")

    def do_OPTIONS(self) -> None:
      self.send_error(405, "Only CONNECT is supported")

    def do_HEAD(self) -> None:
      self.send_error(405, "Only CONNECT is supported")

    def log_message(self, fmt: str, *args) -> None:
      message = fmt % args
      sys.stdout.write(
        f"[{threading.current_thread().name}] {self.client_address[0]}:{self.client_address[1]} {message}\n"
      )
      sys.stdout.flush()

    def _parse_connect_target(self, target: str):
      if ":" not in target:
        return None, None
      host, port_raw = target.rsplit(":", 1)
      if not host:
        return None, None
      try:
        port = int(port_raw)
      except ValueError:
        return None, None
      return host, port

    def _relay_tunnel(self, upstream: socket.socket) -> None:
      sockets = [self.connection, upstream]
      while True:
        readable, _, exceptional = select.select(sockets, [], sockets, 1.0)
        if exceptional:
          return

        if not readable:
          continue

        for sock in readable:
          other = upstream if sock is self.connection else self.connection
          try:
            data = sock.recv(BUFFER_SIZE)
          except OSError:
            return

          if not data:
            return

          try:
            other.sendall(data)
          except OSError:
            return


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Minimal HTTP CONNECT forward proxy for Intercom testing.",
    )
    parser.add_argument("--host", default="0.0.0.0", help="Host to bind. Default: 0.0.0.0")
    parser.add_argument("--port", type=int, default=8080, help="Port to bind. Default: 8080")
    args = parser.parse_args()

    with ThreadingHTTPServer((args.host, args.port), ConnectProxyHandler) as server:
        print(f"CONNECT proxy listening on {args.host}:{args.port}")
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            print("Shutting down proxy")


if __name__ == "__main__":
    main()
