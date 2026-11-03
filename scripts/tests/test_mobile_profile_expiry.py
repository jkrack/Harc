"""Exercise the real macOS preflight expiry helper under different time zones."""
from datetime import datetime, timedelta, timezone
import os
from pathlib import Path
import subprocess
import sys
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'preflight-harcmobile-app-store.sh'


@unittest.skipUnless(sys.platform == 'darwin', 'App Store preflight uses macOS BSD date')
class MobileProfileExpiryTests(unittest.TestCase):
    def run_gate(self, expiration, zone):
        source = SCRIPT.read_text()
        start = source.index('require_future_profile_date() {')
        helper = source[start:source.index('\n# A value ends', start)]
        harness = ('FAILURES=0\npass() { :; }\n'
                   'fail() { FAILURES=$((FAILURES + 1)); }\n'
                   + helper + '\nrequire_future_profile_date "$1" fixture\n'
                   'exit "$FAILURES"\n')
        return subprocess.run(['bash', '-c', harness, 'fixture', expiration],
                              env={**os.environ, 'TZ': zone},
                              capture_output=True, text=True).returncode

    def test_expired_profile_is_rejected_in_every_time_zone(self):
        expiration = (datetime.now(timezone.utc) - timedelta(minutes=30)).strftime('%Y-%m-%dT%H:%M:%SZ')
        for zone in ['UTC', 'America/Los_Angeles', 'Asia/Tokyo']:
            with self.subTest(zone=zone):
                self.assertNotEqual(self.run_gate(expiration, zone), 0)

    def test_future_profile_is_accepted_in_every_time_zone(self):
        expiration = (datetime.now(timezone.utc) + timedelta(minutes=30)).strftime('%Y-%m-%dT%H:%M:%SZ')
        for zone in ['UTC', 'America/Los_Angeles', 'Asia/Tokyo']:
            with self.subTest(zone=zone):
                self.assertEqual(self.run_gate(expiration, zone), 0)

    def test_missing_and_malformed_expiration_fail_closed(self):
        for expiration in ['', 'not-a-date']:
            with self.subTest(expiration=expiration):
                self.assertNotEqual(self.run_gate(expiration, 'America/Los_Angeles'), 0)


if __name__ == '__main__':
    unittest.main()
