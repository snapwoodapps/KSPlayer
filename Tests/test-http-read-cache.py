#!/usr/bin/env python3
"""Test production AVIO caching against HTTP/HTTPS with the bundled FFmpeg.

Optional --video exercises packet-identical forward/backward seeks through an
unaltered media file. --seconds controls playback demuxed after each seek.
Fixtures cover bearer authentication, signed links, relative/absolute redirects,
and TLS with certificate verification. Live provider/device replay is separate.
"""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import ssl
import subprocess
import tempfile
import threading
import time
from urllib.parse import urlsplit

parser = argparse.ArgumentParser()
parser.add_argument('--video', type=Path)
parser.add_argument('--seconds', type=float, default=2)
parser.add_argument('--request-delay', type=float, default=.01)
args = parser.parse_args()
repo = Path(__file__).resolve().parents[1]
requests = []
history = []
bad_headers = []
pattern = bytes(range(251)) * 4179
signature = 'sig=fixture%2Bvalue%2Fpart%3D&download=1'
# Match the app's joined header format, including no trailing CRLF.
authenticated_headers = 'Authorization: Bearer cache-test-token\r\nX-Cache-Test: preserved'


def run(command, **kwargs):
    result = subprocess.run(command, capture_output=True, text=True, **kwargs)
    if result.returncode:
        print(result.stderr, end='', flush=True)
        result.check_returncode()
    return result


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        parsed = urlsplit(self.path)
        path = parsed.path
        history.append((path, self.headers.get('Authorization'), self.headers.get('Range')))
        if path == '/missing':
            self.send_error(404)
            return
        if path.startswith(('/auth/', '/relative/', '/absolute/')):
            if self.headers.get('Authorization') != 'Bearer cache-test-token':
                self.send_error(401)
                return
        if path.startswith(('/signed/', '/signed-redirect/')):
            if parsed.query != signature or self.headers.get('Authorization') is not None:
                self.send_error(403)
                return
        if self.headers.get('X-Cache-Test') != 'preserved':
            bad_headers.append(path)
        leaf = path.rsplit('/', 1)[-1]
        location = None
        if path.startswith('/relative/'):
            location = f'../auth/{leaf}?download=1'
        elif path.startswith('/absolute/'):
            # Change host spelling, port, and (from HTTP) scheme to exercise a
            # fresh connection to the destination, as with a provider CDN.
            location = f'{secure_url}/auth/{leaf}?download=1'
        elif path.startswith('/signed-redirect/'):
            location = f'{secure_url}/signed/{leaf}?{signature}'
        if location:
            self.send_response(307 if path.startswith('/absolute/') else 302)
            self.send_header('Location', location)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        size = args.video.stat().st_size if leaf == 'video' else 8_000_000_000
        begin, end = self.headers.get('Range', 'bytes=0-')[6:].split('-')
        begin, end = int(begin), int(end) if end else size - 1
        requests.append((begin, end))
        time.sleep(args.request_delay)
        self.send_response(200 if path == '/stream' else 206)
        self.send_header('Content-Type', 'application/octet-stream')
        if path != '/stream':
            self.send_header('Accept-Ranges', 'bytes')
            self.send_header('Content-Range', f'bytes {begin}-{end}/{size}')
        self.send_header('Content-Length', str(end - begin + 1))
        self.end_headers()
        file = args.video.open('rb') if leaf == 'video' else None
        try:
            if file:
                file.seek(begin)
            if path == '/truncated':
                end = min(end, begin + 65535)
            while begin <= end:
                length = min(4096 if path == '/slow' else 256 * 1024, end - begin + 1)
                data = file.read(length) if file else pattern[begin % 251:begin % 251 + length]
                if not data:
                    break
                self.wfile.write(data)
                begin += len(data)
                if path == '/slow':
                    time.sleep(.02)
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            pass
        finally:
            if file:
                file.close()


with tempfile.TemporaryDirectory(prefix='ks-read-cache-') as temporary:
    work = Path(temporary)
    executable = work / 'probe'
    command = ['xcrun', 'clang', '-Wall', '-Wextra', '-Werror',
               '-fsanitize=address,undefined', '-g',
               str(repo / 'Tests/ReadCacheProbe.c'), str(repo / 'Sources/FFmpeg/KSReadCache.c'),
               '-I', str(repo / 'Sources/FFmpeg/include'), '-o', str(executable)]
    for library in ['Libavformat', 'Libavcodec', 'Libavutil', 'Libswresample',
                    'Libswscale', 'Libavfilter', 'Libssl', 'Libcrypto']:
        command += ['-F', str(repo / f'Sources/{library}.xcframework/macos-arm64_x86_64'), '-framework', library]
    command += ['-lz', '-lbz2', '-liconv', '-lxml2']
    for framework in ['CoreFoundation', 'Security', 'VideoToolbox', 'CoreVideo', 'CoreMedia', 'AudioToolbox']:
        command += ['-framework', framework]
    run(command)
    certificate = work / 'certificate.pem'
    key = work / 'key.pem'
    config = work / 'openssl.cnf'
    config.write_text('''[req]
distinguished_name = subject
x509_extensions = extensions
prompt = no
[subject]
CN = localhost
[extensions]
basicConstraints = critical, CA:TRUE
keyUsage = critical, digitalSignature, keyEncipherment, keyCertSign
extendedKeyUsage = serverAuth
subjectAltName = DNS:localhost, IP:127.0.0.1
''')
    run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
         '-keyout', str(key), '-out', str(certificate), '-config', str(config)])
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    secure_server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(certificate, key)
    secure_server.socket = tls.wrap_socket(secure_server.socket, server_side=True)
    for listener in [server, secure_server]:
        threading.Thread(target=listener.serve_forever, daemon=True).start()
    url = f'http://127.0.0.1:{server.server_port}'
    secure_url = f'https://localhost:{secure_server.server_port}'
    secure_origin_url = f'https://127.0.0.1:{secure_server.server_port}'
    environment = os.environ.copy()
    environment.pop('KS_READ_CACHE_TEST_HEADERS', None)
    environment['KS_READ_CACHE_TEST_CA'] = str(certificate)
    environment['no_proxy'] = '127.0.0.1,localhost'

    def probe(mode, endpoint, *arguments, headers=None, trusted=True):
        options = environment.copy()
        if headers is not None:
            options['KS_READ_CACHE_TEST_HEADERS'] = headers
        if not trusted:
            options.pop('KS_READ_CACHE_TEST_CA')
        return run([str(executable), mode, endpoint, *map(str, arguments)],
                   env=options, timeout=180 if mode == 'packets' else 30)

    def transport_cases(leaf):
        for base in [url, secure_origin_url]:
            yield f'{base}/auth/{leaf}', authenticated_headers
            yield f'{base}/relative/{leaf}', authenticated_headers
            yield f'{base}/absolute/{leaf}', authenticated_headers
            yield f'{base}/signed/{leaf}?{signature}', None
            yield f'{base}/signed-redirect/{leaf}?{signature}', None

    try:
        for mode in ['bytes', 'truncated', 'stream', 'missing', 'slow']:
            result = probe(mode, f'{url}/{mode}')
            print(result.stderr, end='', flush=True)
        for endpoint, headers in transport_cases('bytes'):
            history.clear()
            result = probe('bytes', endpoint, headers=headers)
            assert any(value and not value.startswith('bytes=0-') for _, _, value in history), 'No follow-up range request exercised'
            print(f'PASS authentication/signature and seek ranges: {endpoint}', flush=True)
        probe('reject', f'{secure_url}/auth/bytes')
        probe('reject', f'{secure_url}/signed/bytes?sig=expired')
        probe('reject', f'{secure_url}/auth/bytes', headers=authenticated_headers, trusted=False)
        print('PASS rejected missing credentials, invalid signatures, and untrusted TLS certificate', flush=True)
        if args.video:
            # Compare cached/direct demuxing through every provider-like route,
            # not just byte reads. Each must produce the same actual packets.
            reference = None
            for endpoint, headers in [(f'{url}/video', None), *transport_cases('video')]:
                for cached in [0, 1]:
                    requests.clear()
                    result = probe('packets', endpoint, cached, args.seconds, headers=headers)
                    if reference is None:
                        reference = result.stdout
                    assert reference == result.stdout, 'Transport/cache changed packet payloads, ordering, positions, or timestamps'
                    print(f'{endpoint} cached={cached} media_requests={len(requests)}\n{result.stderr}', flush=True)
            print('PASS identical packets and timestamps across authentication, redirects, HTTP/HTTPS and forward/backward seeks', flush=True)
        assert not bad_headers, 'HTTP options were not forwarded'
    finally:
        for listener in [server, secure_server]:
            listener.shutdown()
            listener.server_close()
