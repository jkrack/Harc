#!/usr/bin/env python3
"""Exercise ENOSPC and destination detachment on an owned 128 MiB APFS image."""
import argparse
from build_concurrency import job_arguments
import errno
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time

REPO = Path(__file__).resolve().parent.parent
SOURCES = ['Sources/HarcCore/CaptureDestinationBinding.swift', 'Sources/HarcCore/DurableFileIO.swift', 'Sources/HarcCore/CaptureIntegrityReport.swift',
           'Sources/HarcCore/RecordingPublication.swift', 'scripts/qualification/PublicationFaultDriver.swift']


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for data in iter(lambda: f.read(1024 * 1024), b''):
            h.update(data)
    return h.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence-dir', type=Path)
    args = parser.parse_args()
    try:
        build_jobs = job_arguments("-j")
    except ValueError as error:
        parser.error(str(error))
    if shutil.disk_usage(REPO).free < 6 * 1024**3:
        raise SystemExit('Requires 6 GiB free; only the owned 128 MiB image will be filled')
    evidence = (args.evidence_dir or REPO / 'build/qualification' /
                time.strftime('publication-storage-%Y%m%dT%H%M%SZ', time.gmtime())).resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix='harc-publication-storage-', dir='/private/tmp'))
    mount = root / 'mounted'
    image = root / 'destination.sparseimage'
    mounted = False
    manifest = {'classification': 'diagnostic APFS image storage failure',
                'limitations': ['not physical device or power-loss proof', 'no Library commit'],
                'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=REPO, text=True).strip(),
                'files': {p: digest(REPO / p) for p in SOURCES + ['scripts/qualify-publication-storage.py', 'scripts/build_concurrency.py']},
                'cases': {}}
    def command(args, log, check=True):
        with (evidence / log).open('w') as output:
            return subprocess.run([str(x) for x in args], stdout=output, stderr=subprocess.STDOUT,
                                  timeout=120, check=check)
    def fixture(name):
        source = root / name
        with source.open('wb') as f:
            block = bytes(range(256)) * 4096
            for _ in range(32):
                f.write(block)
        return source
    try:
        binary = root / 'driver'
        command(['swiftc', *build_jobs, '-o', binary] + [REPO / p for p in SOURCES], 'compile.log')
        manifest['driver_sha256'] = digest(binary)
        command(['hdiutil', 'create', '-size', '128m', '-fs', 'APFS', '-type', 'SPARSE',
                 '-volname', 'HarcStorageQualification', image], 'create.log')
        mount.mkdir()
        # Preserve the image on ambiguous attachment failure instead of deleting it.
        mounted = True
        command(['hdiutil', 'attach', '-nobrowse', '-mountpoint', mount, '-plist', image], 'attachment.plist')
        attachment = plistlib.loads((evidence / 'attachment.plist').read_bytes())
        assert any(e.get('mount-point') == str(mount) for e in attachment['system-entities'])
        assert mount.stat().st_dev != root.stat().st_dev
        destination = mount / 'final.wav'
        source = fixture('full-source.wav')
        expected = digest(source)
        command([binary, 'prepare-only', source, destination], 'full-prepare.log')
        journal = Path(str(source) + '.publication.json')
        original_intent = journal.read_bytes()
        filler = mount / 'owned-filler.bin'
        filled = 0
        with filler.open('wb', buffering=0) as f:
            try:
                while True:
                    filled += f.write(os.urandom(1024 * 1024))
                    if filled > 128 * 1024 * 1024:
                        raise RuntimeError('Image did not enforce its expected size bound')
            except OSError as error:
                if error.errno != errno.ENOSPC:
                    raise
            # Leave less room than the master, allowing a real partial copy.
            f.truncate(max(0, f.tell() - 4 * 1024 * 1024))
        failure = command([binary, 'attempt', source, destination], 'full-attempt.log', check=False)
        errors = (evidence / 'full-attempt.log').read_text()
        assert failure.returncode == 2 and ('ERROR NSPOSIXErrorDomain 28' in errors or
                                            'ERROR NSCocoaErrorDomain 640' in errors), errors
        assert digest(source) == expected and journal.read_bytes() == original_intent
        assert not destination.exists()
        filler.unlink()
        command([binary, 'resume', source, destination], 'full-retry.log')
        assert digest(destination) == expected and not source.exists()
        manifest['cases']['enospc'] = {'result': 'passed', 'filled_bytes': filled,
                                      'source_bytes': 32 * 1024 * 1024, 'sha256': expected}
        print('ENOSPC: source and journal survived; retry after freeing image space passed', flush=True)
        source = fixture('detached-source.wav')
        destination = mount / 'detached.wav'
        expected = digest(source)
        command([binary, 'prepare-only', source, destination], 'detach-prepare.log')
        command(['hdiutil', 'detach', mount], 'detach.log')
        mounted = False
        result = command([binary, 'attempt', source, destination], 'detached-attempt.log', check=False)
        passed = result.returncode != 0 and source.exists() and digest(source) == expected and not destination.exists()
        manifest['cases']['detached'] = {'result': 'passed' if passed else 'FAILED',
                                         'returncode': result.returncode, 'source_exists': source.exists(),
                                         'destination_exists_on_host': destination.exists()}
        assert passed, 'Detached destination was recreated on the host filesystem or source was consumed'
        print('Detached destination: publication refused and source preserved', flush=True)
        mount.mkdir(exist_ok=True)
        mounted = True
        command(['hdiutil', 'attach', '-nobrowse', '-mountpoint', mount, '-plist', image], 'reattachment.plist')
        attachment = plistlib.loads((evidence / 'reattachment.plist').read_bytes())
        assert any(e.get('mount-point') == str(mount) for e in attachment['system-entities'])
        command([binary, 'resume', source, destination], 'reattached-retry.log')
        assert digest(destination) == expected and not source.exists()
        manifest['cases']['reattached'] = {'result': 'passed', 'sha256': expected}
        print('Reattached original volume: exact-byte retry passed', flush=True)
        source = fixture('setup-source.wav')
        destination = mount / 'setup.wav'
        expected = digest(source)
        command([binary, 'freeze', source, destination], 'setup-freeze.log')
        command(['hdiutil', 'detach', mount], 'setup-detach.log')
        mounted = False
        result = command([binary, 'attempt', source, destination], 'setup-attempt.log', check=False)
        assert result.returncode == 2 and digest(source) == expected and not destination.exists()
        assert not Path(str(source) + '.publication.json').exists()
        mount.mkdir(exist_ok=True)
        mounted = True
        command(['hdiutil', 'attach', '-nobrowse', '-mountpoint', mount, '-plist', image], 'setup-reattachment.plist')
        attachment = plistlib.loads((evidence / 'setup-reattachment.plist').read_bytes())
        assert any(e.get('mount-point') == str(mount) for e in attachment['system-entities'])
        command([binary, 'resume', source, destination], 'setup-retry.log')
        assert digest(destination) == expected and not source.exists()
        manifest['cases']['setup_binding'] = {'result': 'passed', 'sha256': expected,
                                               'journal_absent_at_detachment': True}
        print('Setup binding: pre-journal detachment refused; original-volume retry passed', flush=True)
    finally:
        (evidence / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        if mounted:
            result = command(['hdiutil', 'detach', mount], 'cleanup.log', check=False)
            if result.returncode != 0:
                raise RuntimeError(f'Detach failed; preserving owned image at {root}')
        shutil.rmtree(root)


if __name__ == '__main__':
    main()
