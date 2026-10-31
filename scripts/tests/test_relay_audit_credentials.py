"""Run the real audit shells with disposable CLI doubles; never use real credentials or remote network."""
import json
import os
from pathlib import Path
import subprocess
import signal
import shutil
import socket
import threading
import time
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
TOKEN = 'disposable-audit-token'


class RelayAuditCredentialsTests(unittest.TestCase):
    def run_audit(self, name, mode='ok', token=TOKEN, network_url=''):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            # Only disposable source copies use a short Wrangler deadline.
            source = ROOT / 'CloudflareRelay/scripts'
            (path / name).write_text((source / name).read_text())
            helper = (source / 'read-deployment-status.mjs').read_text()
            self.assertIn('const deadlineMilliseconds = 30_000;', helper)
            (path / 'read-deployment-status.mjs').write_text(
                helper.replace('const deadlineMilliseconds = 30_000;',
                               'const deadlineMilliseconds = 1_000;'))
            (path / 'npx').write_text('''#!/usr/bin/env python3
import json, os, signal, subprocess, sys, time
mode = os.environ['AUDIT_TEST_MODE']
assert sys.argv[1:5] == ['--no-install', 'wrangler', 'deployments', 'status']
if mode in ('wrangler_hang', 'wrangler_orphan'):
 signal.signal(signal.SIGTERM, signal.SIG_IGN)
 if mode == 'wrangler_orphan':
  child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])
  open(os.environ['AUDIT_PID_FILE'], 'w').write(str(child.pid))
  print('{"versions":[{"percentage":100,"version_id":"test-version"}]}', flush=True)
  sys.exit(0)
 open(os.environ['AUDIT_PID_FILE'], 'w').write(str(os.getpid()))
 time.sleep(60)
if mode == 'wrangler_error':
 print(os.environ['HARC_CLOUDFLARE_API_TOKEN'], file=sys.stderr)
 sys.exit(7)
print('{"versions":[{"percentage":100,"version_id":"test-version"}]}')
''')
            (path / 'curl').write_text('''#!/usr/bin/env python3
import json, os, subprocess, sys
args = sys.argv[1:]
assert args[0] == '--disable'
assert args[args.index('--connect-timeout') + 1] == '5'
assert args[args.index('--max-time') + 1] == '20'
mode = os.environ['AUDIT_TEST_MODE']
if mode == 'network_timeout':
 # Preserve and assert production bounds above; scale only this disposable double.
 args[args.index('--connect-timeout') + 1] = '0.1'
 args[args.index('--max-time') + 1] = '0.2'
 args[-1] = os.environ['AUDIT_NETWORK_URL']
 result = subprocess.run([os.environ['AUDIT_REAL_CURL'], '--noproxy', '*', *args],
                         input=sys.stdin.read(), text=True, capture_output=True)
 sys.stdout.write(result.stdout)
 sys.stderr.write(result.stderr)
 sys.exit(result.returncode)
if mode == 'health_timeout' and '/health' in args[-1]: sys.exit(28)
assert os.environ['HARC_CLOUDFLARE_API_TOKEN'] not in ' '.join(args)
if '/health' in args[-1]:
 print('{"status":"ok"}')
else:
 assert args[args.index('--header') + 1] == '@-'
 assert sys.stdin.read() == 'Authorization: Bearer ' + os.environ['HARC_CLOUDFLARE_API_TOKEN'] + '\\n'
 mode = os.environ['AUDIT_TEST_MODE']
 if mode == 'empty': sys.exit(0)
 if mode == 'http_error': sys.exit(22)
 if mode == 'malformed':
  print('{invalid-json')
  sys.exit(0)
 if mode == 'request_timeout':
  # A partial/complete-looking payload cannot turn a failed request green.
  print('{"success":true,"result":[]}')
  sys.exit(28)
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
                       HARC_CLOUDFLARE_API_TOKEN=token, AUDIT_TEST_MODE=mode,
                       AUDIT_PID_FILE=str(path / 'pid'), AUDIT_NETWORK_URL=network_url,
                       AUDIT_REAL_CURL=shutil.which('curl') or '')
            # Explicitly prevent inherited audit overrides from affecting the fixture.
            for key in ('HARC_RELAY_EXPECTED_TAIL_CONSUMER', 'HARC_RELAY_HEALTH_URL'):
                env.pop(key, None)
            result = subprocess.run(['bash', '-x', str(path / name)],
                                    env=env, text=True, capture_output=True, timeout=15)
            if (path / 'pid').exists():
                pid = int((path / 'pid').read_text())
                # Linux may retain a killed orphan as a zombie until PID 1 reaps it.
                for _ in range(100):
                    try:
                        os.kill(pid, 0)
                        stat = Path(f'/proc/{pid}/stat')
                        if stat.exists() and stat.read_text().split()[2] == 'Z':
                            break
                    except ProcessLookupError:
                        break
                    time.sleep(.01)
                else:
                    os.kill(pid, signal.SIGKILL)
                    self.fail('audit deadline left its owned process alive')
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

    def test_stalled_loopback_http_exits_with_timeout_without_success(self):
        # No remote requests: real curl is pointed at a local peer that never replies.
        for script in ('check-deployed-privacy.sh', 'check-account-logpush.sh'):
            with self.subTest(script=script), socket.socket() as listener:
                listener.bind(('127.0.0.1', 0))
                listener.listen(1)
                listener.settimeout(3)
                stop = threading.Event()
                accepted = threading.Event()

                def stall():
                    try:
                        connection, _ = listener.accept()
                        with connection:
                            accepted.set()
                            stop.wait(3)
                    except OSError:
                        pass

                peer = threading.Thread(target=stall, daemon=True)
                peer.start()
                try:
                    started = time.monotonic()
                    result = self.run_audit(script, 'network_timeout',
                                            network_url=f'http://127.0.0.1:{listener.getsockname()[1]}/')
                    self.assertTrue(accepted.is_set(), 'curl never reached the loopback peer')
                    self.assertLess(time.monotonic() - started, 3)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('20-second total deadline', result.stderr)
                    self.assertNotIn('privacy check passed', result.stdout)
                    self.assertNotIn('audit completed', result.stdout)
                    self.assertNotIn('no account-level Workers export', result.stdout)
                finally:
                    stop.set()
                    peer.join(4)
                    self.assertFalse(peer.is_alive())

    def test_wrangler_deadline_kills_hung_command_and_inherited_pipe(self):
        for mode in ('wrangler_hang', 'wrangler_orphan'):
            with self.subTest(mode=mode):
                started = time.monotonic()
                result = self.run_audit('check-deployed-privacy.sh', mode)
                self.assertEqual(result.returncode, 124)
                self.assertLess(time.monotonic() - started, 3)
                self.assertIn('30-second deadline', result.stderr)
                self.assertNotIn('privacy check passed', result.stdout)

    def test_wrangler_failure_does_not_print_cli_credentials(self):
        result = self.run_audit('check-deployed-privacy.sh', 'wrangler_error')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('deployment status failed', result.stderr)
        self.assertNotIn('privacy check passed', result.stdout)

    def test_request_timeout_never_publishes_success_even_with_json(self):
        for script in ('check-deployed-privacy.sh', 'check-account-logpush.sh'):
            with self.subTest(script=script):
                result = self.run_audit(script, 'request_timeout')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('20-second total deadline', result.stderr)
                self.assertNotIn('privacy check passed', result.stdout)
                self.assertNotIn('audit completed', result.stdout)
                self.assertNotIn('no account-level Workers export', result.stdout)

    def test_health_timeout_cannot_publish_privacy_success(self):
        result = self.run_audit('check-deployed-privacy.sh', 'health_timeout')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('relay health request failed', result.stderr)
        self.assertNotIn('privacy check passed', result.stdout)

    def test_malformed_responses_fail_closed(self):
        for script in ('check-deployed-privacy.sh', 'check-account-logpush.sh'):
            with self.subTest(script=script):
                result = self.run_audit(script, 'malformed')
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('privacy check passed', result.stdout)
                self.assertNotIn('no account-level Workers export', result.stdout)

    def test_multiline_token_cannot_inject_headers(self):
        for script in ('check-deployed-privacy.sh', 'check-account-logpush.sh'):
            for separator in ('\n', '\r'):
                with self.subTest(script=script, separator=repr(separator)):
                    result = self.run_audit(script, token=TOKEN + separator + 'Injected: value')
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('invalid multiline', result.stderr)


if __name__ == '__main__':
    unittest.main()
