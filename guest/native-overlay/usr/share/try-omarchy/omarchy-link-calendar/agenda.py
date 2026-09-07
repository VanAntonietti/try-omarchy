"""Memory-only Calendar surface model and Owner-local IPC driver."""
from datetime import datetime, time, timedelta, timezone


class Agenda:
    def __init__(self):
        self.range = 'today'
        self.calendar = ''
        self.generation = 0
        self.closed = False
        self.snapshot = {'calendars': [], 'events': []}
        self.last_refresh = float('-inf')
        self.revision = None
        self.dirty = True

    def select(self, date_range, calendar):
        if date_range not in ('today', 'seven-days') or not isinstance(calendar, str) or len(calendar.encode()) > 64:
            raise ValueError('invalid selection')
        self.range, self.calendar = date_range, calendar
        self.generation += 1
        self.dirty = True
        self.snapshot = {'calendars': [], 'events': []}

    def lock(self):
        self.closed = True
        self.generation += 1
        self.snapshot = {'calendars': [], 'events': []}

    def accept(self, generation, calendars, events):
        if self.closed or generation != self.generation:
            return False
        self.snapshot = {'calendars': calendars, 'events': [event for event in events
                         if not self.calendar or event['calendarId'] == self.calendar]}
        return True

    def refresh_due(self, monotonic, revision):
        if self.closed or monotonic - self.last_refresh < 2:
            return False
        if self.dirty or revision != self.revision or monotonic - self.last_refresh >= 60:
            self.last_refresh, self.revision, self.dirty = monotonic, revision, False
            return True
        return False

    def query(self, now):
        start = datetime.combine(now.date(), time.min, now.tzinfo)
        end = start + timedelta(days=1 if self.range == 'today' else 7)
        utc = lambda value: value.astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        return {'method': 'calendar.events.list', 'start': utc(start), 'end': utc(end),
                'calendarIds': [self.calendar] if self.calendar else []}
