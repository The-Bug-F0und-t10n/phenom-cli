#!/usr/bin/env python3
import json
import os
import selectors
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

binary = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/phenom")
work = tempfile.mkdtemp(prefix="phenom-cli-stream-")
ready = threading.Event()
port_holder = []
first_sent = []


def receive_request(conn):
    data = b""
    while b"\r\n\r\n" not in data:
        data += conn.recv(4096)
    head, body = data.split(b"\r\n\r\n", 1)
    lines = head.decode("iso-8859-1").split("\r\n")
    length = next((int(line.split(":", 1)[1]) for line in lines if line.lower().startswith("content-length:")), 0)
    while len(body) < length:
        body += conn.recv(length - len(body))
    return lines[0]


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
    sock.listen(8)
    port_holder.append(sock.getsockname()[1])
    ready.set()
    completion_count = 0
    while completion_count < 1:
        conn, _ = sock.accept()
        with conn:
            conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            request_line = receive_request(conn)
            method, path, *_ = request_line.split()
            if method == "GET" and path == "/props":
                send(conn, "200 OK", "application/json", '{"n_ctx":65536}')
            elif method == "POST" and path == "/tokenize":
                send(conn, "200 OK", "application/json", '{"tokens":[1,2,3,4]}')
            elif method == "POST" and path == "/v1/chat/completions":
                conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n")
                first = "STREAMEARLYMARKER " + ("a" * 96)
                conn.sendall(("data: " + json.dumps({"choices": [{"delta": {"content": first}, "finish_reason": None}]}) + "\n\n").encode())
                first_sent.append(time.monotonic())
                time.sleep(2.0)
                conn.sendall(("data: " + json.dumps({"choices": [{"delta": {"content": " STREAMFINALMARKER"}, "finish_reason": "stop"}]}) + "\n\n").encode())
                conn.sendall(b"data: [DONE]\n\n")
                completion_count += 1
            else:
                send(conn, "404 Not Found", "text/plain", "not found")
    sock.close()


thread = threading.Thread(target=server, daemon=True)
thread.start()
ready.wait(5)
if not port_holder:
    raise SystemExit("cli-streaming: backend did not start")

process = subprocess.Popen(
    [binary, "chat", "--backend", "llamacpp", "--host", f"127.0.0.1:{port_holder[0]}", "--model", "scripted", "--session", "cli-streaming", "--prompt", "responda em streaming", "--thinking", "off", "--max-tokens", "64", "--no-color"],
    cwd=work,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
)
selector = selectors.DefaultSelector()
selector.register(process.stdout, selectors.EVENT_READ)
started = time.monotonic()
early_at = None
output = bytearray()
try:
    deadline = started + 10
    while time.monotonic() < deadline and process.poll() is None:
        for key, _ in selector.select(0.1):
            chunk = os.read(key.fileobj.fileno(), 65536)
            if not chunk:
                continue
            output.extend(chunk)
            if early_at is None and b"STREAMEARLYMARKER" in output:
                early_at = time.monotonic()
        if early_at is not None and b"STREAMFINALMARKER" in output:
            break
    process.wait(timeout=5)
    output.extend(process.stdout.read() or b"")
    if early_at is None:
        raise AssertionError("primeiro delta não apareceu")
    if not first_sent:
        raise AssertionError("backend não registrou o primeiro delta")
    stream_delay = early_at - first_sent[0]
    if stream_delay >= 1.5:
        raise AssertionError(f"primeiro delta foi bufferizado por {stream_delay:.3f}s")
    if b"STREAMFINALMARKER" not in output:
        raise AssertionError("delta final não apareceu")
    print(f"cli-streaming: ok first_delta={stream_delay:.3f}s server_pause=2.000s")
finally:
    if process.poll() is None:
        process.kill()
        process.wait()
    thread.join(timeout=3)
    shutil.rmtree(work, ignore_errors=True)
