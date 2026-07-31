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
work = tempfile.mkdtemp(prefix="phenom-cli-tty-stream-")
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
    conn.sendall(f"HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nContent-Length: {len(raw)}\r\nConnection: close\r\n\r\n".encode() + raw)

def server():
    sock = socket.socket()
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", 0))
    sock.listen(8)
    port_holder.append(sock.getsockname()[1])
    ready.set()
    while True:
        conn, _ = sock.accept()
        with conn:
            method, path, *_ = receive_request(conn).split()
            if method == "GET" and path == "/props":
                send(conn, "200 OK", "application/json", '{"n_ctx":65536}')
            elif method == "POST" and path == "/tokenize":
                send(conn, "200 OK", "application/json", '{"tokens":[1,2,3,4]}')
            elif method == "POST" and path == "/v1/chat/completions":
                conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n")
                conn.sendall(("data: " + json.dumps({"choices": [{"delta": {"content": "<think>TTYTHINK</think>"}, "finish_reason": None}]}) + "\n\n").encode())
                conn.sendall(("data: " + json.dumps({"choices": [{"delta": {"content": "TTYEARLY"}, "finish_reason": None}]}) + "\n\n").encode())
                first_sent.append(time.monotonic())
                time.sleep(2)
                conn.sendall(("data: " + json.dumps({"choices": [{"delta": {"content": " TTYFINAL"}, "finish_reason": "stop"}]}) + "\n\n").encode())
                conn.sendall(b"data: [DONE]\n\n")
                return
            else:
                send(conn, "404 Not Found", "text/plain", "not found")

thread = threading.Thread(target=server, daemon=True)
thread.start()
ready.wait(5)
master, slave = pty.openpty()
process = subprocess.Popen(
    [binary, "chat", "--backend", "llamacpp", "--host", f"127.0.0.1:{port_holder[0]}", "--model", "scripted", "--session", "tty-streaming", "--thinking", "on", "--max-tokens", "64", "--no-color"],
    cwd=work, stdin=slave, stdout=slave, stderr=slave, close_fds=True,
)
os.close(slave)
output = bytearray()
early_at = None
try:
    time.sleep(0.3)
    os.write(master, b"responda em streaming\r")
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline and b"TTYFINAL" not in output:
        readable, _, _ = select.select([master], [], [], 0.1)
        if not readable:
            continue
        try:
            output.extend(os.read(master, 65536))
        except OSError:
            break
        if early_at is None and b"TTYEARLY" in output:
            early_at = time.monotonic()
    if early_at is None or not first_sent:
        raise AssertionError("primeiro delta não apareceu no PTY")
    if b"TTYTHINK" not in output:
        raise AssertionError("reasoning_content não apareceu no bloco thinking do PTY")
    if b"<think>" in output or b"</think>" in output:
        raise AssertionError("tags think vazaram no PTY")
    delay = early_at - first_sent[0]
    if delay >= 1.5:
        raise AssertionError(f"primeiro delta PTY foi bufferizado por {delay:.3f}s")
    if b"TTYFINAL" not in output:
        raise AssertionError("delta final não apareceu no PTY")
    print(f"cli-tty-streaming: ok first_delta={delay:.3f}s server_pause=2.000s")
finally:
    if process.poll() is None:
        process.kill()
        process.wait()
    os.close(master)
    thread.join(timeout=3)
    shutil.rmtree(work, ignore_errors=True)
