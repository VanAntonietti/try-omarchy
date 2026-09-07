"""Broker-owned review. Content uses anonymous pipes and a private Unix socket."""
import json
import os
from pathlib import Path
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time


def run(renderer=None):
    root = Path(os.environ['XDG_RUNTIME_DIR'])
    mode = root.lstat()
    if not root.is_absolute() or not stat.S_ISDIR(mode.st_mode) or mode.st_uid != os.getuid() or stat.S_IMODE(mode.st_mode) != 0o700:
        return 1
    body = sys.stdin.buffer.read(4097)
    if len(body) > 4096:
        return 1
    proposal = json.loads(body)
    body = json.dumps(proposal, separators=(',', ':')).encode() + b'\n'
    # Only the socket pathname is stored in runtime state, never the proposal.
    with tempfile.TemporaryDirectory(prefix='link-review-', dir=root) as directory:
        path = str(Path(directory) / 'socket')
        with socket.socket(socket.AF_UNIX) as listener:
            listener.bind(path)
            os.chmod(path, 0o600)
            listener.listen(1)
            listener.settimeout(0.1)
            process = subprocess.Popen(renderer or ['/usr/bin/quickshell', '-n', '-p', str(Path(__file__).with_name('review.qml'))],
                env={**os.environ, 'OMARCHY_LINK_REVIEW_SOCKET': path},
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 105
                while process.poll() is None and time.monotonic() < deadline:
                    try:
                        stream, _ = listener.accept()
                        break
                    except TimeoutError:
                        continue
                else:
                    return 1
                with stream:
                    stream.settimeout(1)
                    stream.sendall(body)
                    decision = bytearray()
                    while time.monotonic() < deadline and len(decision) <= 16:
                        try:
                            part = stream.recv(16)
                        except TimeoutError:
                            if process.poll() is not None:
                                return 1
                            continue
                        if not part:
                            return 1
                        decision.extend(part)
                        if b'\n' in decision:
                            return 0 if decision == b'approve\n' else 1
                return 1
            finally:
                if process.poll() is None:
                    process.terminate()
                try:
                    process.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


def view():
    with socket.socket(socket.AF_UNIX) as stream:
        stream.settimeout(110)
        stream.connect(os.environ['OMARCHY_LINK_REVIEW_SOCKET'])
        with stream.makefile('rb') as source:
            body = source.readline(4097)
            if not body.endswith(b'\n') or len(body) > 4096:
                return 1
            # Quickshell treats every field as plain text, never markup.
            print(json.dumps(json.loads(body)), flush=True)
            decision = sys.stdin.readline(17)
            stream.sendall(b'approve\n' if decision == 'approve\n' else b'reject\n')
    return 0


if __name__ == '__main__':
    def terminate(_signal, _frame):
        raise SystemExit(1)
    signal.signal(signal.SIGTERM, terminate)
    try:
        code = view() if sys.argv[1:] == ['--view'] else run()
    except Exception:
        # Decoding/transport exceptions may contain private text. Stay quiet.
        code = 1
    sys.exit(code)
