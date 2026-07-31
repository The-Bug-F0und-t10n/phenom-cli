#!/usr/bin/env python3
import json
import os
import pty
import select
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

binary = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/phenom")
work = tempfile.mkdtemp(prefix="phenom-multiline-tty-")
expected = "cabecalho\n\n" + "\n".join(f"  linha {index:04d}: ação íntegra" for index in range(1000)) + "\nrodape"
requests = []
ready = threading.Event()
port_holder = []
stop = threading.Event()


def receive_request(conn):
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(65536)
        if not chunk:
            return None, b""
        data += chunk
    head, body = data.split(b"\r\n\r\n", 1)
    lines = head.decode("iso-8859-1").split("\r\n")
    length = next((int(line.split(":", 1)[1]) for line in lines if line.lower().startswith("content-length:")), 0)
    while len(body) < length:
        body += conn.recv(length - len(body))
    return lines[0], body[:length]


def send(conn, status, content_type, body):
    raw = body.encode()
    conn.sendall(
        f"HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nContent-Length: {len(raw)}\r\nConnection: close\r\n\r\n".encode()
        + raw
    )


def server():
    sock = socket.socket()
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", 0))
    sock.listen(16)
    sock.settimeout(0.2)
    port_holder.append(sock.getsockname()[1])
    ready.set()
    while not stop.is_set():
        try:
            conn, _ = sock.accept()
        except socket.timeout:
            continue
        with conn:
            request_line, body = receive_request(conn)
            if request_line is None:
                continue
            method, path, *_ = request_line.split()
            if method == "GET" and path == "/props":
                send(conn, "200 OK", "application/json", '{"n_ctx":65536}')
            elif method == "POST" and path == "/tokenize":
                send(conn, "200 OK", "application/json", '{"tokens":[1,2,3,4]}')
            elif method == "POST" and path == "/completion":
                requests.append(json.loads(body))
                payload = "data: " + json.dumps({"content": "MULTILINE_TTY_OK", "stop": True}) + "\n\n"
                send(conn, "200 OK", "text/event-stream", payload)
            else:
                send(conn, "404 Not Found", "text/plain", "not found")
    sock.close()


def contains_exact(value):
    if isinstance(value, str):
        return expected in value
    if isinstance(value, list):
        return any(contains_exact(item) for item in value)
    if isinstance(value, dict):
        return any(contains_exact(item) for item in value.values())
    return False


thread = threading.Thread(target=server, daemon=True)
thread.start()
ready.wait(5)
if not port_holder:
    raise SystemExit("multiline-tty: backend did not start")

master, slave = pty.openpty()
process = subprocess.Popen(
    [binary, "chat", "--backend", "llamacpp", "--host", f"127.0.0.1:{port_holder[0]}", "--model", "scripted", "--session", "multiline-tty", "--max-tokens", "64", "--thinking", "off", "--no-color"],
    cwd=work,
    stdin=slave,
    stdout=slave,
    stderr=slave,
    close_fds=True,
)
os.close(slave)
output = bytearray()
try:
    time.sleep(0.5)
    payload = b"\x1b[200~" + expected.encode() + b"\x1b[201~\r"
    offset = 0
    while offset < len(payload):
        readable, writable, _ = select.select([master], [master], [], 0.2)
        if readable:
            try:
                output.extend(os.read(master, 65536))
            except OSError:
                break
        if writable:
            offset += os.write(master, payload[offset : offset + 512])
    deadline = time.time() + 30
    while time.time() < deadline and b"MULTILINE_TTY_OK" not in output:
        readable, _, _ = select.select([master], [], [], 0.2)
        if readable:
            try:
                output.extend(os.read(master, 65536))
            except OSError:
                break
    if b"MULTILINE_TTY_OK" not in output:
        raise AssertionError("resposta final não apareceu no PTY")
    os.write(master, b"/exit\r")
    process.wait(timeout=10)
    if process.returncode != 0:
        raise AssertionError(f"CLI terminou com código {process.returncode}")
    if not any(contains_exact(request) for request in requests):
        raise AssertionError("backend não recebeu o prompt multiline completo e idêntico")
    print(f"multiline-tty: ok lines=1003 bytes={len(expected.encode())} requests={len(requests)}")
finally:
    stop.set()
    thread.join(timeout=2)
    if process.poll() is None:
        process.kill()
        process.wait()
    os.close(master)
    shutil.rmtree(work, ignore_errors=True)
