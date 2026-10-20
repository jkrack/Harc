import copy
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('snapshot_tool', Path(__file__).parents[1] / 'production-source-snapshot.py')
tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tool)


class SourceSnapshotTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='harc-snapshot-')
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        self.run_git('init', '--quiet')
        (self.repo / '.gitignore').write_text('build/\n')
        (self.repo / 'source.swift').write_text('original\n')
        self.run_git('add', '.')
        self.run_git('commit', '--quiet', '-m', 'fixture')
        self.recorded = tool.snapshot(self.repo)

    def run_git(self, *args):
        subprocess.run(['git', '-C', str(self.repo), '-c', 'core.hooksPath=/dev/null',
                        '-c', 'commit.gpgsign=false', '-c', 'user.name=Snapshot Test',
                        '-c', 'user.email=snapshot@example.invalid', *args], check=True, capture_output=True)

    def test_unchanged_is_identity_only(self):
        result = tool.verify(self.repo, self.recorded)
        self.assertTrue(result['sourceMatches'])
        self.assertEqual(result['qualification'], 'unqualified')

    def test_content_change_rejected(self):
        (self.repo / 'source.swift').write_text('modified\n')
        self.assertEqual(tool.verify(self.repo, self.recorded)['changed'], ['source.swift'])

    def test_new_untracked_source_rejected(self):
        (self.repo / 'new.swift').write_text('new\n')
        self.assertEqual(tool.verify(self.repo, self.recorded)['added'], ['new.swift'])

    def test_tracked_deletion_rejected(self):
        (self.repo / 'source.swift').unlink()
        self.assertEqual(tool.verify(self.repo, self.recorded)['removed'], ['source.swift'])

    def test_executable_permission_change_rejected(self):
        (self.repo / 'source.swift').chmod(0o755)
        self.assertEqual(tool.verify(self.repo, self.recorded)['changed'], ['source.swift'])

    def test_ignored_evidence_does_not_change_identity(self):
        (self.repo / 'build').mkdir()
        (self.repo / 'build/result.json').write_text('{}')
        self.assertTrue(tool.verify(self.repo, self.recorded)['sourceMatches'])

    def test_new_commit_requires_new_snapshot(self):
        self.run_git('commit', '--quiet', '--allow-empty', '-m', 'new identity')
        result = tool.verify(self.repo, self.recorded)
        self.assertFalse(result['sourceMatches'])
        self.assertFalse(result['headMatches'])

    def test_tampered_inventory_rejected(self):
        snapshot = copy.deepcopy(self.recorded)
        snapshot['files']['source.swift']['sha256'] = '0' * 64
        with self.assertRaises(ValueError):
            tool.verify(self.repo, snapshot)

    def test_qualification_claim_rejected(self):
        snapshot = copy.deepcopy(self.recorded)
        snapshot['qualification'] = 'release-ready'
        with self.assertRaises(ValueError):
            tool.verify(self.repo, snapshot)

    def test_external_symlink_rejected(self):
        (self.repo / 'outside.swift').symlink_to('/etc/hosts')
        with self.assertRaises(ValueError):
            tool.snapshot(self.repo)


if __name__ == '__main__':
    unittest.main()
