"""Run the real audit shells with disposable CLI doubles; never use credentials/network."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
TOKEN = 'disposable-audit-token'


class RelayAuditCredentialsTests(unittest.TestCase):
    def run_audit(self, name, mode='ok', token=TOKEN):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / 'npx').write_text('#!/bin/sh\nprintf \'%s\\n\' \'{"versions":[{"percentage":100,"version_id":"test-version"}]}\'\n')
            (path / 'curl').write_text('''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
assert args[0] == '--disable'
assert os.environ['HARC_CLOUDFLARE_API_TOKEN'] not in ' '.join(args)
if '/health' in args[-1]:
 print('{"status":"ok"}')
else:
 assert args[args.index('--header') + 1] == '@-'
 assert sys.stdin.read() == 'Authorization: Bearer ' + os.environ['HARC_CLOUDFLARE_API_TOKEN'] + '\\n'
 mode = os.environ['AUDIT_TEST_MODE']
 if mode == 'empty': sys.exit(0)
 if mode == 'http_error': sys.exit(22)
 if args[-1].endswith('/logpush/jobs'):
  jobs = [{'dataset':'workers_trace_events','enabled':True}] if mode == 'export' else []
  print(json.dumps({'success':True,'result':jobs}))
 else:
  settings = {'logpush':False,'tail_consumers':[], 'observability':{'enabled':False}}
  if mode != 'missing_streaming': settings['streaming_tail_consumers'] = [{'service':'observer'}] if mode == 'streaming' else []
  print(json.dumps({'success':True,'result':settings}))
''')
            for name_in_path in ('npx', 'curl'):
                (path / name_in_path).chmod(0o700)
            env = dict(os.environ, PATH=str(path) + os.pathsep + os.environ['PATH'],
                       HARC_CLOUDFLARE_API_TOKEN=token, AUDIT_TEST_MODE=mode)
            # Explicitly prevent inherited audit overrides from affecting the fixture.
            for key in ('HARC_RELAY_EXPECTED_TAIL_CONSUMER', 'HARC_RELAY_HEALTH_URL'):
                env.pop(key, None)
            result = subprocess.run(['bash', '-x', str(ROOT / 'CloudflareRelay/scripts' / name)],
                                    env=env, text=True, capture_output=True, timeout=15)
            self.assertNotIn(token, result.stdout + result.stderr)
            return result

    def test_both_audits_use_stdin_without_tracing_token(self):
        for script in ('check-deployed-privacy.sh', 'check-account-logpush.sh'):
            with self.subTest(script=script):
                self.assertEqual(self.run_audit(script).returncode, 0)

    def test_empty_account_response_fails_closed(self):
        result = self.run_audit('check-account-logpush.sh', 'empty')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('no account-level Workers export', result.stdout)

    def test_http_failure_and_existing_export_fail_closed(self):
        for mode in ('http_error', 'export'):
            with self.subTest(mode=mode):
                self.assertNotEqual(self.run_audit('check-account-logpush.sh', mode).returncode, 0)

    def test_streaming_observer_or_missing_readback_blocks_qualification(self):
        for mode in ('streaming', 'missing_streaming'):
            with self.subTest(mode=mode):
                result = self.run_audit('check-deployed-privacy.sh', mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('privacy check passed', result.stdout)

    def test_multiline_token_cannot_inject_headers(self):
        for script in ('check-deployed-privacy.sh', 'check-account-logpush.sh'):
            for separator in ('\n', '\r'):
                with self.subTest(script=script, separator=repr(separator)):
                    result = self.run_audit(script, token=TOKEN + separator + 'Injected: value')
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('invalid multiline', result.stderr)


if __name__ == '__main__':
    unittest.main()
