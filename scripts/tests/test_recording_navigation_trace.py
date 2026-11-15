import importlib.util
import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    'recording_navigation_trace', Path(__file__).resolve().parents[1] / 'collect-recording-navigation-trace.py')
trace = importlib.util.module_from_spec(spec)
spec.loader.exec_module(trace)


class RecordingNavigationTraceTests(unittest.TestCase):
    def event(self, **changes):
        return {'subsystem': trace.SUBSYSTEM, 'timestamp': '2026-11-15 07:53:58.781208-0800',
                'processID': 42, 'eventMessage': 'event=recentTapped requested=false setup=false library=false',
                'processImagePath': '/private/not-for-artifact', **changes}

    def test_retains_only_fixed_events_and_allowed_fields(self):
        event = self.event()
        self.assertEqual(trace.bounded_events(json.dumps(event)),
                         [{key: event[key] for key in ('timestamp', 'processID', 'eventMessage')}])

    def test_ignores_foreign_arbitrary_and_malformed_rows(self):
        rows = [self.event(subsystem='other'), self.event(eventMessage='recording title: private'),
                self.event(eventMessage=self.event()['eventMessage'] + ' path=/private'),
                self.event(processID='42'), self.event(timestamp=None), [], {'finished': 1}]
        self.assertEqual(trace.bounded_events('\n'.join(map(json.dumps, rows)) + '\ninvalid json'), [])

    @patch.object(trace.Path, 'read_text', return_value='{"udid":"invalid"}')
    @patch.object(trace.subprocess, 'run')
    def test_invalid_destination_never_runs_a_command(self, run, read_text):
        self.assertEqual(trace.collect('unused')['status'], 'destination_unavailable')
        run.assert_not_called()

    @patch.object(trace.Path, 'read_text', return_value='{"udid":42}')
    @patch.object(trace.subprocess, 'run')
    def test_numeric_destination_never_runs_a_command(self, run, read_text):
        self.assertEqual(trace.collect('unused')['status'], 'destination_unavailable')
        run.assert_not_called()

    @patch.object(trace.Path, 'read_text', return_value='{"udid":"86A177BE-AEE1-4307-8E69-C9E4CF39EFC9"}')
    @patch.object(trace.subprocess, 'run', side_effect=subprocess.TimeoutExpired('simctl', 45))
    def test_timeout_is_explicit_without_raw_diagnostics(self, run, read_text):
        report = trace.collect('unused')
        self.assertEqual(report['status'], 'collection_timed_out')
        self.assertEqual(report['events'], [])

    @patch.object(trace.Path, 'read_text', return_value='{"udid":"86A177BE-AEE1-4307-8E69-C9E4CF39EFC9"}')
    @patch.object(trace.subprocess, 'run')
    def test_empty_log_is_not_reported_as_observed_handler_absence(self, run, read_text):
        run.return_value = subprocess.CompletedProcess([], 0, stdout='')
        self.assertEqual(trace.collect('unused')['status'], 'no_matching_events')
        self.assertEqual(run.call_args_list[0].kwargs['timeout'], 45)
        self.assertEqual(run.call_args_list[1].kwargs['timeout'], 30)
