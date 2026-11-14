#!/usr/bin/env python3
"""Local test server that behaves like a Takeout download, for Tests/run.sh only.

  /takeout/download?i=N   needs the cookie SID=geheim (otherwise an HTML "sign-in page"),
                          redirects to /direct/<token>/<name> (counts as a link request)
  /direct/<token>/<name>  needs the cookie as well, supports Range, drops the connection after
                          --drop bytes per response; a token is valid for --direct-uses requests
  /stats                  counters as JSON
"""
import argparse
import hashlib
import json
import random
import secrets
import socket
import socketserver
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

parser = argparse.ArgumentParser()
parser.add_argument("--size", type=int, default=12 << 20)
parser.add_argument("--file", help="statt Zufallsdaten diese Datei ausliefern")
parser.add_argument("--drop", type=int, default=0, help="Verbindung nach so vielen Bytes je Antwort abbrechen")
parser.add_argument("--drop-once", action="store_true", help="nur die erste Antwort abbrechen")
parser.add_argument("--rate", type=int, default=0, help="Bytes pro Sekunde (0 = unbegrenzt)")
parser.add_argument("--direct-uses", type=int, default=0, help="Abrufe je Direktlink (0 = unbegrenzt)")
parser.add_argument("--no-range", action="store_true", help="Range ignorieren (immer 200 und alles)")
parser.add_argument("--name", default="takeout-001.zip")
parser.add_argument("--no-auth", action="store_true", help="ohne Cookie ausliefern (für scripts/snapshot.sh)")
parser.add_argument("--other-size", type=int, default=0, help="ab dem zweiten Direktabruf eine andere Datei dieser Größe")
args = parser.parse_args()

if args.file:
    with open(args.file, "rb") as handle:
        DATA = handle.read()
else:
    DATA = random.Random(42).randbytes(args.size)
OTHER = random.Random(7).randbytes(args.other_size) if args.other_size else None

stats = {"link_requests": 0, "direct_requests": 0, "range_requests": 0, "responses": 0}
tokens = {}
lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def has_cookie(self):
        return args.no_auth or "SID=geheim" in (self.headers.get("Cookie") or "")

    def login_page(self):
        body = b"<html><body>Bitte anmelden</body></html>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urlparse(self.path)
        if url.path == "/stats":
            body = json.dumps(stats).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if url.path == "/takeout/download":
            with lock:
                stats["link_requests"] += 1
            if not self.has_cookie():
                return self.login_page()
            token = secrets.token_hex(8)
            with lock:
                tokens[token] = args.direct_uses or 10**9
            self.send_response(302)
            self.send_header("Location", f"/direct/{token}/{args.name}")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if url.path.startswith("/direct/"):
            with lock:
                stats["direct_requests"] += 1
            if not self.has_cookie():
                return self.login_page()
            token = url.path.split("/")[2]
            with lock:
                left = tokens.get(token, 0)
                if left <= 0:
                    expired = True
                else:
                    tokens[token] = left - 1
                    expired = False
            if expired:
                self.send_response(403)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            with lock:
                later = stats["direct_requests"] > 1
            return self.serve(OTHER if OTHER is not None and later else DATA)
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def serve(self, data):
        total = len(data)
        start = 0
        header = self.headers.get("Range")
        if header and not args.no_range:
            with lock:
                stats["range_requests"] += 1
            start = int(header.split("=")[1].split("-")[0])
            if start >= total:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{total}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {start}-{total - 1}/{total}")
        else:
            self.send_response(200)
        self.send_header("Content-Type", "application/zip")
        self.send_header("Content-Disposition", f'attachment; filename="{args.name}"')
        self.send_header("Content-Length", str(total - start))
        self.end_headers()
        with lock:
            stats["responses"] += 1
            number = stats["responses"]
        limit = args.drop if args.drop and (not args.drop_once or number == 1) else None
        try:
            self.send_body(data, start, total, limit)
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True

    def send_body(self, data, start, total, limit):
        sent = 0
        position = start
        chunk = 64 * 1024
        began = time.time()
        while position < total:
            piece = data[position:position + chunk]
            if limit is not None and sent + len(piece) > limit:
                piece = piece[: max(0, limit - sent)]
                self.wfile.write(piece)
                self.wfile.flush()
                # Drop the connection right away, in the middle of the announced length
                self.connection.shutdown(socket.SHUT_RDWR)
                self.close_connection = True
                return
            self.wfile.write(piece)
            sent += len(piece)
            position += len(piece)
            if args.rate:
                wait = sent / args.rate - (time.time() - began)
                if wait > 0:
                    time.sleep(wait)


class Server(ThreadingHTTPServer):
    def server_bind(self):
        # Otherwise HTTPServer looks up its name via getfqdn(), which hangs for up to 35 s without DNS.
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


server = Server(("127.0.0.1", 0), Handler)
print(json.dumps({"port": server.server_address[1], "sha256": hashlib.sha256(DATA).hexdigest(), "size": len(DATA)}),
      flush=True)
server.serve_forever()
