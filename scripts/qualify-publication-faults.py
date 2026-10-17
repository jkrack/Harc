#!/usr/bin/env python3
"""Kill/restart the real publication code using disposable files and processes.
This is process-interruption evidence, not power-loss or Library qualification.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import tempfile
import time

REPO = Path(__file__).resolve().parent.parent
SOURCES = [
    'Sources/HarcCore/CaptureDestinationBinding.swift',
    'Sources/HarcCore/DurableFileIO.swift',
    'Sources/HarcCore/CaptureIntegrityReport.swift',
    'Sources/HarcCore/RecordingPublication.swift',
    'scripts/qualification/PublicationFaultDriver.swift',
]


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def run():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence-dir', type=Path)
    args = parser.parse_args()
    stats = os.statvfs(REPO)
    if stats.f_bavail * stats.f_frsize < 5 * 1024**3:
        raise SystemExit('Requires at least 5 GiB free')
    evidence = (args.evidence_dir or REPO / 'build/qualification' /
                time.strftime('publication-faults-%Y%m%dT%H%M%SZ', time.gmtime())).resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    manifest = {
        'classification': 'diagnostic real process termination and restart',
        'limitations': ['not power-loss proof', 'no Library commit or live capture',
                        'not a sealed release candidate'],
        'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=REPO, text=True).strip(),
        'files': {p: digest(REPO / p) for p in SOURCES + ['scripts/qualify-publication-faults.py']},
        'cases': [],
    }
    (evidence / 'worktree.txt').write_text(subprocess.check_output(
        ['git', 'status', '--short'], cwd=REPO, text=True))
    (evidence / 'toolchain.txt').write_text(subprocess.check_output(['swiftc', '--version'], text=True))
    with tempfile.TemporaryDirectory(prefix='harc-publication-faults-', dir='/private/tmp') as temp:
        root = Path(temp)
        binary = root / 'publication-driver'
        with (evidence / 'compile.log').open('w') as log:
            subprocess.run(['swiftc', '-j', '2', '-o', str(binary)] +
                           [str(REPO / p) for p in SOURCES], stdout=log, stderr=subprocess.STDOUT,
                           check=True, timeout=120)
        manifest['driver_sha256'] = digest(binary)
        for boundary in ['prepared', 'renamed', 'published']:
            case = root / boundary
            case.mkdir()
            source = case / 'source.wav'
            destination = case / 'public' / 'final.wav'
            # Deterministic bytes exercise publication; this is not a WAV codec test.
            block = bytes(range(256)) * 4096
            with source.open('wb') as f:
                for _ in range(8):
                    f.write(block)
            expected = digest(source)
            journal = Path(str(source) + '.publication.json')
            with (evidence / (boundary + '-child.log')).open('w') as log:
                child = subprocess.Popen([str(binary), boundary, str(source), str(destination)],
                                         stdout=subprocess.PIPE, stderr=log)
                try:
                    readable, _, _ = select.select([child.stdout], [], [], 30)
                    if not readable or child.stdout.readline() != b'CHECKPOINT\n':
                        raise RuntimeError(f'{boundary}: did not reach the real publication boundary')
                    # waitpid proves this exact child is stopped at SIGSTOP.
                    pid, status = os.waitpid(child.pid, os.WUNTRACED)
                    if pid != child.pid or not os.WIFSTOPPED(status):
                        raise RuntimeError(f'{boundary}: child did not stop')
                    child.kill()
                    if child.wait(timeout=10) != -signal.SIGKILL:
                        raise RuntimeError(f'{boundary}: child was not terminated by SIGKILL')
                finally:
                    if child.poll() is None:
                        child.kill()
                        child.wait(timeout=10)
                    child.stdout.close()
            before = {'source_exists': source.exists(), 'destination_exists': destination.exists(),
                      'journal_exists': journal.exists()}
            assert before['journal_exists'], boundary
            assert before['source_exists'] == (boundary != 'published'), boundary
            assert before['destination_exists'] == (boundary != 'prepared'), boundary
            saved_journal = journal.read_bytes()
            with (evidence / (boundary + '-restart.log')).open('w') as log:
                for _ in range(2):
                    subprocess.run([str(binary), 'resume', str(source), str(destination)],
                                   stdout=log, stderr=subprocess.STDOUT, check=True, timeout=30)
            assert digest(destination) == expected, boundary
            assert not source.exists() and journal.read_bytes() == saved_journal, boundary
            assert list(destination.parent.iterdir()) == [destination], boundary
            manifest['cases'].append({'boundary': boundary, 'termination': 'SIGKILL',
                                      'before_restart': before, 'restart_count': 2,
                                      'sha256': expected, 'bytes': destination.stat().st_size,
                                      'result': 'passed; immutable intent retained for Library commit'})
            print(f'{boundary}: SIGKILL and two independent restarts passed', flush=True)
    (evidence / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'Publication interruption diagnostic passed: {evidence}')


if __name__ == '__main__':
    run()
