#!/usr/bin/env python3
"""Local-only proxy integration tests. No VPN or system preferences are changed."""
import argparse
import base64
import concurrent.futures
import hashlib
import http.server
import json
import os
from pathlib import Path
import shutil
import socket
import ssl
import subprocess
import tempfile
import threading
import time
import unittest


def unused_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def read_headers(sock):
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(4096)
        if not chunk:
            raise AssertionError("Connection closed before complete headers")
        data += chunk
    return data.split(b"\r\n\r\n", 1)


class TestHTTPServer(http.server.ThreadingHTTPServer):
    # Default Python backlog is only five, which resets burst connections on macOS.
    request_queue_size = 128


class Origin(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path == "/ws":
            key = self.headers["Sec-WebSocket-Key"]
            accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
            self.send_response(101)
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.send_header("Sec-WebSocket-Accept", accept)
            self.end_headers()
            first, second = self.rfile.read(2)
            size = second & 127
            mask = self.rfile.read(4)
            payload = self.rfile.read(size)
            decoded = bytes(byte ^ mask[i % 4] for i, byte in enumerate(payload))
            self.wfile.write(bytes([first & 0x8F, len(decoded)]) + decoded)
            self.wfile.flush()
            self.close_connection = True
            return
        data = json.dumps({"path": self.path, "proxy_auth": self.headers.get("Proxy-Authorization"), "host": self.headers.get("Host")}).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)
        self.close_connection = True

    def do_POST(self):
        data = self.rfile.read(int(self.headers["Content-Length"]))
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)
        self.close_connection = True


class Integration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="pointswoman-test-")
        root = Path(cls.temp.name)
        cls.origin = TestHTTPServer(("127.0.0.1", 0), Origin)
        threading.Thread(target=cls.origin.serve_forever, daemon=True).start()
        cls.origin_port = cls.origin.server_port
        cert, key, conf = root / "cert.pem", root / "key.pem", root / "openssl.cnf"
        conf.write_text("[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=localhost\n[ext]\nsubjectAltName=DNS:localhost\nbasicConstraints=critical,CA:TRUE\n")
        subprocess.run(["/usr/bin/openssl", "req", "-x509", "-nodes", "-newkey", "rsa:2048", "-keyout", str(key), "-out", str(cert), "-days", "1", "-config", str(conf)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cls.cert = cert
        cls.tls = TestHTTPServer(("127.0.0.1", 0), Origin)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(str(cert), str(key))
        cls.tls.socket = context.wrap_socket(cls.tls.socket, server_side=True)
        threading.Thread(target=cls.tls.serve_forever, daemon=True).start()
        cls.tls_port = cls.tls.server_port
        cls.proxy_port = unused_port()
        cls.trace_log = open(root / "proxy-trace.txt", "w+")
        cls.process = subprocess.Popen([BINARY, "serve", "--interface", "lo0", "--port", str(cls.proxy_port), "--domain", "localhost", "--config", str(root / "config.json")], stdout=subprocess.PIPE, stderr=cls.trace_log, text=True)
        for _ in range(100):
            if cls.process.poll() is not None:
                raise RuntimeError(cls.process.communicate())
            try:
                with socket.create_connection(("127.0.0.1", cls.proxy_port), timeout=0.2):
                    break
            except OSError:
                time.sleep(0.05)
        else:
            raise RuntimeError("Proxy did not start")

    @classmethod
    def tearDownClass(cls):
        cls.process.terminate()
        cls.process.communicate(timeout=5)
        cls.trace_log.seek(0)
        trace = cls.trace_log.read()
        if trace:
            print("PROXY TRACE:\n" + trace)
        cls.trace_log.close()
        cls.origin.shutdown()
        cls.origin.server_close()
        cls.tls.shutdown()
        cls.tls.server_close()
        cls.temp.cleanup()

    def exchange(self, data):
        with socket.create_connection(("127.0.0.1", self.proxy_port), timeout=5) as sock:
            sock.sendall(data)
            output = b""
            while True:
                block = sock.recv(65536)
                if not block:
                    return output
                output += block

    def test_health_and_pac(self):
        health = self.exchange(b"GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        self.assertIn(b"200 OK", health)
        self.assertIn(b"interface=lo0", health)
        pac = self.exchange(b"GET /proxy.pac HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        self.assertIn(b"application/x-ns-proxy-autoconfig", pac)
        self.assertIn(b"FindProxyForURL", pac)

    def test_http_path_and_proxy_credentials(self):
        response = self.exchange((f"GET http://localhost:{self.origin_port}/a%20b?q=%2F HTTP/1.1\r\nHost: localhost:{self.origin_port}\r\nProxy-Authorization: secret\r\n\r\n").encode())
        self.assertIn(b"200 OK", response)
        data = json.loads(response.split(b"\r\n\r\n", 1)[1])
        self.assertEqual(data["path"], "/a%20b?q=%2F")
        self.assertIsNone(data["proxy_auth"])

    def test_large_upload_and_download(self):
        payload = os.urandom(1024 * 1024)
        response = self.exchange((f"POST http://localhost:{self.origin_port}/upload HTTP/1.1\r\nContent-Length: {len(payload)}\r\n\r\n").encode() + payload)
        self.assertIn(b"200 OK", response)
        self.assertEqual(hashlib.sha256(response.split(b"\r\n\r\n", 1)[1]).digest(), hashlib.sha256(payload).digest())

    def test_https_connect_preserves_origin_certificate(self):
        context = ssl.create_default_context(cafile=str(self.cert))
        with socket.create_connection(("127.0.0.1", self.proxy_port), timeout=5) as sock:
            sock.sendall((f"CONNECT localhost:{self.tls_port} HTTP/1.1\r\nHost: localhost:{self.tls_port}\r\n\r\n").encode())
            headers, tail = read_headers(sock)
            self.assertIn(b"200 Connection Established", headers)
            self.assertEqual(tail, b"")
            with context.wrap_socket(sock, server_hostname="localhost") as tls:
                expected = ssl.PEM_cert_to_DER_cert(self.cert.read_text())
                self.assertEqual(tls.getpeercert(binary_form=True), expected)
                tls.sendall(b"GET /tls HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
                response = b""
                while True:
                    block = tls.recv(8192)
                    if not block:
                        break
                    response += block
                self.assertIn(b"200 OK", response)
                self.assertIn(b'"path": "/tls"', response)

    def test_websocket_upgrade_and_binary_relay(self):
        with socket.create_connection(("127.0.0.1", self.proxy_port), timeout=5) as sock:
            key = base64.b64encode(os.urandom(16)).decode()
            sock.sendall((f"GET http://localhost:{self.origin_port}/ws HTTP/1.1\r\nHost: localhost:{self.origin_port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
            headers, _ = read_headers(sock)
            self.assertIn(b"101 Switching Protocols", headers)
            payload, mask = os.urandom(100), os.urandom(4)
            sock.sendall(bytes([0x82, 0x80 | len(payload)]) + mask + bytes(byte ^ mask[i % 4] for i, byte in enumerate(payload)))
            output = b""
            while len(output) < 102:
                output += sock.recv(102 - len(output))
            self.assertEqual(output, bytes([0x82, len(payload)]) + payload)

    def test_unlisted_destination_denied(self):
        response = self.exchange(b"CONNECT example.com:443 HTTP/1.1\r\n\r\n")
        self.assertIn(b"403 Forbidden", response)

    def test_unavailable_destination_fails_without_fallback(self):
        port = unused_port()
        response = self.exchange((f"CONNECT localhost:{port} HTTP/1.1\r\n\r\n").encode())
        self.assertIn(b"502 Bad Gateway", response)
        self.assertIn(b"No alternate interface was used", response)

    def test_oversized_header_rejected(self):
        response = self.exchange(b"GET /health HTTP/1.1\r\nX-Large: " + b"a" * 66000 + b"\r\n\r\n")
        self.assertIn(b"431 Request Header Fields Too Large", response)

    def test_malformed_and_mismatched_host_rejected(self):
        response = self.exchange(b"GET http://localhost/ HTTP/1.1\r\nHost: attacker.example\r\n\r\n")
        self.assertIn(b"400 Bad Request", response)

    def test_concurrent_requests(self):
        def fetch(number):
            response = self.exchange((f"GET http://localhost:{self.origin_port}/{number} HTTP/1.1\r\n\r\n").encode())
            self.assertIn(b"200 OK", response)
        with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
            list(pool.map(fetch, range(32)))

    def test_occupied_port_and_missing_interface(self):
        for args in [["--interface", "lo0", "--port", str(self.proxy_port)], ["--interface", "en99999"]]:
            run = subprocess.run([BINARY, "serve"] + args, capture_output=True, text=True, timeout=5)
            self.assertNotEqual(run.returncode, 0)

    def test_application_proxy_accepts_domains_outside_website_list(self):
        port = unused_port()
        with tempfile.TemporaryDirectory() as root:
            process = subprocess.Popen([BINARY, "serve-apps", "--interface", "lo0", "--app-port", str(port), "--config", str(Path(root) / "config.json"), "--apps-config", str(Path(root) / "apps.json")], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            try:
                for _ in range(50):
                    if process.poll() is not None:
                        self.fail(process.communicate()[1])
                    try:
                        with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                            break
                    except OSError:
                        time.sleep(0.05)
                with socket.create_connection(("127.0.0.1", port), timeout=5) as sock:
                    sock.sendall((f"GET http://localhost:{self.origin_port}/app HTTP/1.1\r\n\r\n").encode())
                    headers, _ = read_headers(sock)
                    self.assertIn(b"200 OK", headers)
            finally:
                process.terminate()
                process.communicate(timeout=5)

    def test_domain_proxy_cannot_be_used_as_app_proxy(self):
        run = subprocess.run([BINARY, "apps", "launch", "--app", "/Applications/Mattermost.app", "--app-port", str(self.proxy_port)], capture_output=True, text=True, timeout=5)
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("selected-domain proxy is not an application proxy", run.stderr)

    def test_cli_install_and_collision_protection(self):
        with tempfile.TemporaryDirectory() as root:
            command = [BINARY, "install-cli", "--directory", root]
            subprocess.run(command, check=True, capture_output=True)
            alias = Path(root) / "pointswoman"
            self.assertTrue(alias.is_symlink())
            self.assertIn("serve-apps", subprocess.check_output([str(alias), "--help"], text=True))
            subprocess.run(command, check=True, capture_output=True)
            alias.unlink()
            alias.write_text("existing command")
            run = subprocess.run(command, capture_output=True)
            self.assertNotEqual(run.returncode, 0)
            self.assertEqual(alias.read_text(), "existing command")

    @unittest.skipUnless(shutil.which("node"), "Node needed to evaluate generated PAC")
    def test_pac_execution(self):
        pac = subprocess.check_output([BINARY, "pac", "--domain", "example.com", "--subdomains"], text=True)
        script = "function dnsDomainIs(host,suffix){return host.endsWith(suffix);}\n" + pac + "\n" + """
        const cases = [['example.com',true], ['files.example.com',true], ['EXAMPLE.COM.',true], ['evilexample.com',false], ['example.com.evil',false], ['unlisted.test',false]];
        for (const [host, selected] of cases) {
          const actual = FindProxyForURL('https://' + host, host);
          const expected = selected ? 'PROXY 127.0.0.1:17839' : 'DIRECT';
          if (actual !== expected) throw Error(host + ': ' + actual);
        }
        """
        subprocess.run(["node", "-e", script], check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", help="Path to pointswomanctl")
    args, remaining = parser.parse_known_args()
    BINARY = str(Path(args.binary).resolve())
    unittest.main(argv=[__file__] + remaining, verbosity=2)
