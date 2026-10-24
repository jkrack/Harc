"""Offline regression fixtures execute the production metadata helpers and gate."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/preflight-harcmobile-app-store.sh'
CURRENT = (ROOT / 'docs/app-store/harcmobile-metadata.md').read_text()
FIELDS = {'Name': 'Harc', 'Subtitle': 'Private meeting memory',
          'Promotional text': 'Record privately.', 'Description': 'Private recorder.\n\n- Offline capture',
          'Keywords': 'meeting,recorder', 'Review notes': 'Open the offline sample.'}
REQUIRED = ('Name', 'Description', 'Keywords', 'Review notes')


def deck(fields):
    return '\n\n'.join('**' + key + '**\n' + value for key, value in fields.items()) + '\n'


class MetadataSectionsTests(unittest.TestCase):
    def run_gate(self, copy):
        source = SCRIPT.read_text()
        helpers = source[source.index('# A value ends'):source.index('\necho "==> HarcMobile repository preflight"')]
        gate = source[source.index('METADATA="$REPO_ROOT/docs/app-store'):source.index('\nif [[ -n "$SCREENSHOTS_DIR"')]
        with tempfile.TemporaryDirectory(prefix='harc-metadata-') as scratch:
            root = Path(scratch)
            path = root / 'docs/app-store/harcmobile-metadata.md'
            path.parent.mkdir(parents=True)
            if copy is not None:
                path.write_text(copy)
            support = root / 'docs/support/harcmobile-support.md'
            support.parent.mkdir(parents=True)
            support.write_text('Email [support@cloudarchitech.com](mailto:support@cloudarchitech.com).\n')
            # Use the real metadata gate, including limits and required-value
            # failures. Supply its unrelated support URL fixture explicitly.
            if copy is not None:
                with path.open('a') as output:
                    output.write('\n## URLs\n- Support URL: <https://github.com/jkrack/Harc/blob/main/docs/support/harcmobile-support.md>\n')
            harness = 'FAILURES=0\npass() { echo "PASS $1"; }\nfail() { echo "OPEN $1"; FAILURES=$((FAILURES+1)); }\n'
            return subprocess.run(['bash', '-c', harness + helpers + gate + '\nexit "$FAILURES"'],
                                  env=dict(os.environ, REPO_ROOT=str(root)), capture_output=True, text=True)

    def assert_valid(self, copy):
        result = self.run_gate(copy)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def assert_invalid(self, copy, message):
        result = self.run_gate(copy)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(message, result.stdout)

    def test_current_copy(self):
        self.assert_valid(CURRENT)

    def test_minimal_required_copy_without_optional_fields(self):
        self.assert_valid(deck({key: FIELDS[key] for key in REQUIRED}))

    def test_blank_optional_fields(self):
        self.assert_valid(deck(dict(FIELDS, Subtitle=' \t', **{'Promotional text': ''})))

    def test_missing_deck(self):
        self.assert_invalid(None, 'metadata deck is missing')

    def test_missing_required_sections(self):
        for field in REQUIRED:
            with self.subTest(field=field):
                self.assert_invalid(deck({k: v for k, v in FIELDS.items() if k != field}), 'missing metadata section: ' + field)

    def test_blank_required_sections(self):
        for field in REQUIRED:
            for blank in ('', ' \t\n \t'):
                with self.subTest(field=field, blank=blank):
                    self.assert_invalid(deck(dict(FIELDS, **{field: blank})), 'blank metadata section: ' + field)

    def test_duplicate_sections(self):
        for field in FIELDS:
            with self.subTest(field=field):
                self.assert_invalid(deck(FIELDS) + '\n**' + field + '**\nOther', 'duplicate metadata section: ' + field)

    def test_malformed_required_markers(self):
        for field in REQUIRED:
            for marker in ('*' + field + '*', '**' + field + '*', '## ' + field, '**' + field + '**:'):
                with self.subTest(field=field, marker=marker):
                    self.assert_invalid(deck(FIELDS).replace('**' + field + '**', marker), 'metadata section')

    def test_malformed_duplicate_cannot_hide_behind_valid_field(self):
        for marker in ('*Name*', '**Name**:'):
            with self.subTest(marker=marker):
                self.assert_invalid(deck(FIELDS) + '\n' + marker + '\nOther', 'malformed metadata section: Name')

    def test_single_line_fields_reject_extra_value_lines(self):
        for field in ('Name', 'Subtitle', 'Keywords'):
            with self.subTest(field=field):
                self.assert_invalid(deck(dict(FIELDS, **{field: 'one\ntwo'})), 'must be a single line: ' + field)

    def test_limits_still_enforced(self):
        for field, size in [('Name', 31), ('Subtitle', 31), ('Promotional text', 171), ('Description', 4001), ('Keywords', 101), ('Review notes', 4001)]:
            with self.subTest(field=field):
                self.assert_invalid(deck(dict(FIELDS, **{field: 'x' * size})), 'limit' if field != 'Review notes' else '1-4000 bytes')

    def test_utf8_keyword_limit_is_bytes(self):
        self.assert_invalid(deck(dict(FIELDS, Keywords='é' * 51)), '102/100 bytes')

    def test_exact_limits_and_multiline_description(self):
        self.assert_valid(deck(dict(FIELDS, Name='n' * 30, Subtitle='s' * 30,
                                    **{'Promotional text': 'p' * 170, 'Description': 'd' * 4000,
                                       'Keywords': 'k' * 100, 'Review notes': 'r' * 4000})))

    def test_trailing_whitespace_and_crlf(self):
        self.assert_valid(deck(FIELDS).replace('**\n', '**  \n').replace('\n', '\r\n'))


if __name__ == '__main__':
    unittest.main()
