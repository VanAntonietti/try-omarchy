import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SURFACE = Path(__file__).resolve().parents[1] / 'native-overlay/usr/share/try-omarchy/omarchy-link-calendar'


class CalendarCreateSurfaceTests(unittest.TestCase):
    def test_private_review_shows_canonical_fields_and_accepts_only_explicit_approval(self):
        proposal = {'id': 'one-shot', 'title': '<b>Invented</b>',
                    'startsAt': '2026-09-14T09:00:00Z', 'endsAt': '2026-09-14T10:00:00Z',
                    'calendar': {'id': 'invented', 'title': 'Invented calendar'}}
        with tempfile.TemporaryDirectory(dir='/tmp', prefix='link-review-') as directory:
            for decision, expected in [('approve', 0), ('reject', 1), ('', 1)]:
                # Invented Quickshell boundary; exercise the actual pipe renderer.
                renderer = '''import json, os, subprocess, sys
p = subprocess.Popen([sys.executable, '-B', sys.argv[1], '--view'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
value = json.loads(p.stdout.readline())
assert value['title'] == '<b>Invented</b>'
assert value['calendar']['title'] == 'Invented calendar'
assert value['startsAt'] == '2026-09-14T09:00:00Z'
assert value['endsAt'] == '2026-09-14T10:00:00Z'
out, err = p.communicate(sys.argv[2] + '\\n', timeout=3)
assert not out and not err
'''
                runner = "import sys; sys.path.insert(0, sys.argv[1]); import review; sys.exit(review.run([sys.executable, '-c', sys.argv[2], sys.argv[1] + '/review.py', sys.argv[3]]))"
                result = subprocess.run([sys.executable, '-B', '-c', runner, str(SURFACE), renderer, decision],
                    input=json.dumps(proposal), capture_output=True, text=True, timeout=8,
                    env={**os.environ, 'XDG_RUNTIME_DIR': directory, 'PYTHONDONTWRITEBYTECODE': '1'})
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertEqual(result.stdout, '')
                self.assertEqual(result.stderr, '')
                self.assertEqual(list(Path(directory).iterdir()), [])


if __name__ == '__main__':
    unittest.main()
