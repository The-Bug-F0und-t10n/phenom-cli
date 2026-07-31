#!/usr/bin/env python3
import json
import fcntl
import os
import pty
import re
import select
import signal
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import termios

binary = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/phenom")
work = tempfile.mkdtemp(prefix="phenom-multiline-tty-")
expected = "cabecalho\n\n" + "\n".join(f"  linha {index:04d}: ação íntegra" for index in range(1000)) + "\nrodape"
expected_wrapped = "abcdefghXijkl"
expected_navigation = "abcdXe\nxy\n12345"
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

def send_stream(conn, parts):
    raw_parts = [("data: " + json.dumps({"content": text, "stop": stop}) + "\n\n").encode() for text, stop in parts]
    length = sum(len(part) for part in raw_parts)
    conn.sendall(f"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {length}\r\nConnection: close\r\n\r\n".encode())
    for part in raw_parts:
        conn.sendall(part)
        time.sleep(0.4)


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
            elif method == "POST" and path == "/v1/chat/completions":
                requests.append(json.loads(body))
                if len(requests) == 4:
                    send_stream(conn, [
                        ("OUTPUT_RESIZE_BEGIN texto inicial estável antes do resize ", False),
                        ("continuação longa renderizada depois da nova largura OUTPUT_RESIZE_END", True),
                    ])
                    continue
                markers = ["WRAPPED_NAVIGATION_TTY_OK", "NAVIGATION_TTY_OK", "MULTILINE_TTY_OK"]
                marker = markers[min(len(requests) - 1, len(markers) - 1)]
                payload = "data: " + json.dumps({"content": marker, "stop": True}) + "\n\n"
                send(conn, "200 OK", "text/event-stream", payload)
            else:
                send(conn, "404 Not Found", "text/plain", "not found")
    sock.close()


def contains_exact(value, expected_value):
    if isinstance(value, str):
        return expected_value in value
    if isinstance(value, list):
        return any(contains_exact(item, expected_value) for item in value)
    if isinstance(value, dict):
        return any(contains_exact(item, expected_value) for item in value.values())
    return False


thread = threading.Thread(target=server, daemon=True)
thread.start()
ready.wait(5)
if not port_holder:
    raise SystemExit("multiline-tty: backend did not start")

master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 8, 0, 0))
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

def compact_transcript():
    without_ansi = re.sub(rb"\x1b(?:\[[0-?]*[ -/]*[@-~]|7|8)", b"", bytes(output))
    return b"".join(without_ansi.split())

def read_until(marker, timeout=30):
    deadline = time.time() + timeout
    while time.time() < deadline and marker not in output and marker not in compact_transcript():
        readable, _, _ = select.select([master], [], [], 0.2)
        if readable:
            try:
                output.extend(os.read(master, 65536))
            except OSError:
                break
    if marker not in output and marker not in compact_transcript():
        raise AssertionError(f"resposta final não apareceu no PTY: {marker.decode()} requests={len(requests)} tail={bytes(output[-2000:])!r}")

def write_chunks(chunks):
    for chunk in chunks:
        os.write(master, chunk)
        time.sleep(0.03)

try:
    time.sleep(0.5)
    write_chunks([
        b"abcdefghijkl",
        b"\x1b[A",
        b"\x1b[A",
        b"\x1b[B",
        b"X\r",
    ])
    read_until(b"WRAPPED_NAVIGATION_TTY_OK")
    resize_offset = len(output)
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
    os.kill(process.pid, signal.SIGWINCH)
    resize_deadline = time.time() + 2
    while time.time() < resize_deadline:
        readable, _, _ = select.select([master], [], [], 0.1)
        if readable:
            output.extend(os.read(master, 65536))
        resized = bytes(output[resize_offset:])
        if b"\x1b[r" in resized and b"\x1b[J" in resized and b"scripted" in resized:
            break
    resized = bytes(output[resize_offset:])
    if b"\x1b[r" not in resized or b"\x1b[J" not in resized or b"scripted" not in resized:
        raise AssertionError(f"resize ocioso não redesenhou layout completo: {resized[-1000:]!r}")
    if process.poll() is not None:
        raise AssertionError(f"CLI terminou durante resize com código {process.returncode}")

    write_chunks([
        b"\x1b[200~abcde\nxy\n12345\x1b[201~",
        b"\x1b", b"[A",
        b"\x1bO", b"A",
        b"\x1b[1;1D",
        b"X\r",
    ])
    read_until(b"NAVIGATION_TTY_OK")

    write_chunks([
        b"\x1b[200~lixo\npara apagar\x1b[201~",
        b"\x01",
        b"\x7f",
    ])
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
    read_until(b"MULTILINE_TTY_OK")
    write_chunks([b"teste de resize durante output\r"])
    read_until(b"OUTPUT_RESIZE_BEGIN")
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 18, 24, 0, 0))
    os.kill(process.pid, signal.SIGWINCH)
    read_until(b"OUTPUT_RESIZE_END")
    if process.poll() is not None:
        raise AssertionError(f"CLI terminou durante streaming redimensionado com código {process.returncode}")
    os.write(master, b"/exit\r")
    process.wait(timeout=10)
    while True:
        readable, _, _ = select.select([master], [], [], 0.05)
        if not readable:
            break
        try:
            output.extend(os.read(master, 65536))
        except OSError:
            break
    if process.returncode != 0:
        raise AssertionError(f"CLI terminou com código {process.returncode}")
    if len(requests) != 4:
        raise AssertionError(f"backend recebeu {len(requests)} requests; esperado 4")
    if not contains_exact(requests[0], expected_wrapped):
        raise AssertionError("setas não navegaram pelas linhas criadas por wrapping")
    if not contains_exact(requests[1], expected_navigation):
        raise AssertionError("setas não editaram o prompt multiline na posição esperada")
    if not contains_exact(requests[2], expected):
        raise AssertionError("Ctrl-A não removeu o conteúdo anterior antes da nova query")
    if b"\x1b[?7l" not in output or b"\x1b[?7h" not in output:
        raise AssertionError("CLI não controlou deterministicamente o autowrap do terminal")
    print(f"multiline-tty: ok wrapped={expected_wrapped!r} navigation={expected_navigation!r} lines=1003 bytes={len(expected.encode())} requests={len(requests)}")
finally:
    stop.set()
    thread.join(timeout=2)
    if process.poll() is None:
        process.kill()
        process.wait()
    os.close(master)
    shutil.rmtree(work, ignore_errors=True)
