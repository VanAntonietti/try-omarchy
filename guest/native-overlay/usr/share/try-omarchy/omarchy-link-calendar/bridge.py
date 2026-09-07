"""Private pipes only: never invoke this content stream as a logged service."""
import concurrent.futures
from datetime import datetime
import json
import os
from pathlib import Path
import queue
import socket
import stat
import struct
import sys
import threading
import time
from zoneinfo import ZoneInfo

from agenda import Agenda


def call(request):
    root = Path(os.environ['XDG_RUNTIME_DIR'])
    if not root.is_absolute():
        raise ValueError('runtime')
    for path in (root, root / 'omarchy-link'):
        mode = path.lstat()
        if not stat.S_ISDIR(mode.st_mode) or mode.st_uid != os.getuid() or stat.S_IMODE(mode.st_mode) != 0o700:
            raise ValueError('runtime')
    with socket.socket(socket.AF_UNIX) as stream:
        stream.settimeout(2)
        stream.connect(str(root / 'omarchy-link/socket'))
        body = json.dumps(request).encode()
        stream.sendall(struct.pack('!I', len(body)) + body)
        def receive(size):
            data = bytearray()
            while len(data) < size:
                chunk = stream.recv(size - len(data))
                if not chunk:
                    raise ValueError('closed')
                data.extend(chunk)
            return data
        size, = struct.unpack('!I', receive(4))
        if not 0 < size <= 65536:
            raise ValueError('frame')
        return json.loads(receive(size))


def emit(value):
    print(json.dumps(value, separators=(',', ':')), flush=True)


def selections(commands):
    while True:
        line = sys.stdin.readline(4097)
        if not line or len(line) > 4096:
            commands.put(None)
            return
        try:
            value = json.loads(line)
            if commands.full():
                commands.get_nowait()
            commands.put_nowait(value)
        except (ValueError, queue.Empty, queue.Full):
            continue


def fetch(request):
    calendars = call({'method': 'calendar.calendars.list'})
    events = call(request)
    if 'error' in calendars or 'error' in events:
        raise ValueError('unavailable')
    return calendars['calendars'], events['events']


def run():
    # Read the actual zone rules, not datetime.astimezone()'s fixed offset;
    # the latter silently loses DST transitions later in a seven-day range.
    with open('/etc/localtime', 'rb') as source:
        zone = ZoneInfo.from_file(source)
    model = Agenda()
    commands = queue.Queue(maxsize=1)
    threading.Thread(target=selections, args=(commands,), daemon=True).start()
    executor = concurrent.futures.ThreadPoolExecutor(max_workers=1)
    pending = None
    while True:
        status = call({'method': 'status'})
        if not status.get('contentAllowed') or not status.get('hostAvailable'):
            model.lock()
            emit({'closed': True})
            # Terminate even an outstanding content fetch; no late response
            # survives lock, and unlock requires explicitly reopening the UI.
            os._exit(0)
        try:
            selection = commands.get_nowait()
            if selection is None:
                return
            model.select(selection['range'], selection['calendar'])
            emit(model.snapshot)
        except queue.Empty:
            pass
        if pending is not None and pending.done():
            try:
                calendars, events = pending.result()
                if model.accept(generation, calendars, events):
                    emit(model.snapshot)
            except Exception:
                model.snapshot = {'calendars': [], 'events': []}
                model.dirty = True
                emit({'error': 'Calendar unavailable'})
            pending = None
        if pending is None and model.refresh_due(time.monotonic(), status.get('calendarRevision')):
            generation = model.generation
            pending = executor.submit(fetch, model.query(datetime.now(zone)))
        time.sleep(0.25)


if __name__ == '__main__':
    try:
        run()
    except Exception:
        # Never print an exception: host data can occur in decoding failures.
        emit({'closed': True})
    finally:
        os._exit(0)
