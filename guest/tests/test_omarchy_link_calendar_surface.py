import importlib.util
from pathlib import Path
import unittest
from datetime import datetime
from zoneinfo import ZoneInfo

PATH = Path(__file__).resolve().parents[1] / 'native-overlay/usr/share/try-omarchy/omarchy-link-calendar/agenda.py'

class CalendarSurfaceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location('calendar_surface', PATH)
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    def test_seven_local_days_cross_dst_without_losing_the_last_hour(self):
        model = self.module.Agenda()
        model.select('seven-days', 'disposable')
        query = model.query(datetime(2026, 11, 1, 12, tzinfo=ZoneInfo('America/New_York')))
        self.assertEqual(query, {'method': 'calendar.events.list', 'start': '2026-11-01T04:00:00Z', 'end': '2026-11-08T05:00:00Z', 'calendarIds': ['disposable']})

    def test_today_uses_local_midnight_in_positive_offset_and_spring_dst(self):
        model = self.module.Agenda()
        query = model.query(datetime(2026, 3, 8, 12, tzinfo=ZoneInfo('America/New_York')))
        self.assertEqual((query['start'], query['end']), ('2026-03-08T05:00:00Z', '2026-03-09T04:00:00Z'))
        query = model.query(datetime(2026, 9, 14, 12, tzinfo=ZoneInfo('Asia/Tokyo')))
        self.assertEqual((query['start'], query['end']), ('2026-09-13T15:00:00Z', '2026-09-14T15:00:00Z'))

    def test_lock_clears_content_and_rejects_late_results_until_explicit_reopen(self):
        model = self.module.Agenda()
        generation = model.generation
        model.accept(generation, [{'id': 'a', 'title': 'Invented'}], [{'calendarId': 'a', 'title': 'Invented secret'}])
        self.assertEqual(len(model.snapshot['events']), 1)
        model.lock()
        self.assertEqual(model.snapshot, {'calendars': [], 'events': []})
        self.assertFalse(model.accept(generation, [], [{'title': 'Late secret'}]))
        self.assertFalse(model.refresh_due(100, 20))

    def test_selection_drops_stale_results_and_invalidations_coalesce(self):
        model = self.module.Agenda()
        generation = model.generation
        self.assertTrue(model.refresh_due(0, 0))
        model.select('today', 'a')
        self.assertFalse(model.accept(generation, [], [{'title': 'Stale'}]))
        self.assertFalse(model.refresh_due(1, 10))
        self.assertTrue(model.refresh_due(2, 20))
        self.assertFalse(model.refresh_due(2.1, 21))
        self.assertTrue(model.refresh_due(4, 21))
        model.accept(model.generation, [{'id': 'a', 'title': 'A'}, {'id': 'b', 'title': 'B'}],
                     [{'calendarId': 'b', 'title': 'Hidden'}, {'calendarId': 'a', 'title': 'Shown'}])
        self.assertEqual([e['title'] for e in model.snapshot['events']], ['Shown'])

    def test_private_bridge_stream_exits_on_lock_without_late_content(self):
        import json
        import os
        import socket
        import struct
        import subprocess
        import tempfile
        import threading
        with tempfile.TemporaryDirectory(prefix='link-surface-', dir='/tmp') as directory:
            root = Path(directory)
            (root / 'omarchy-link').mkdir(mode=0o700)
            listener = socket.socket(socket.AF_UNIX)
            listener.bind(str(root / 'omarchy-link/socket'))
            listener.listen()
            listener.settimeout(0.1)
            locked = threading.Event()
            stopped = threading.Event()
            def serve():
                while not stopped.is_set():
                    try:
                        stream, _ = listener.accept()
                    except TimeoutError:
                        continue
                    with stream:
                        stream.settimeout(2)
                        reader = stream.makefile('rb')
                        size, = struct.unpack('!I', reader.read(4))
                        request = json.loads(reader.read(size))
                        if request['method'] == 'status':
                            response = {'contentAllowed': not locked.is_set(), 'hostAvailable': True, 'calendarRevision': 0}
                        elif request['method'] == 'calendar.calendars.list':
                            response = {'calendars': [{'id': 'a', 'title': 'Invented calendar'}]}
                        else:
                            response = {'events': [{'calendarId': 'a', 'title': 'Invented private event'}]}
                        body = json.dumps(response).encode()
                        stream.sendall(struct.pack('!I', len(body)) + body)
                        reader.close()
            server = threading.Thread(target=serve)
            server.start()
            process = subprocess.Popen([os.sys.executable, '-B', str(PATH.with_name('bridge.py'))],
                env={**os.environ, 'XDG_RUNTIME_DIR': directory}, stdin=subprocess.PIPE,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                # A pipe readiness deadline, not an assumed UI settling delay.
                import select
                self.assertTrue(select.select([process.stdout], [], [], 5)[0])
                snapshot = json.loads(process.stdout.readline())
                self.assertEqual(snapshot['events'][0]['title'], 'Invented private event')
                locked.set()
                output, errors = process.communicate(timeout=5)
                self.assertEqual(json.loads(output), {'closed': True})
                self.assertEqual(errors, '')
                self.assertEqual(process.returncode, 0)
            finally:
                process.kill() if process.poll() is None else None
                process.wait()
                stopped.set()
                server.join(timeout=3)
                listener.close()

if __name__ == '__main__':
    unittest.main()
