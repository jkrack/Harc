#!/usr/bin/env python3
"""Record or verify source identity; this does not certify release readiness."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess


def git(repo, *args):
    return subprocess.check_output(['git', '-C', str(repo), *args])


def inventory(repo):
    names = set(git(repo, 'ls-files', '--cached', '--others', '--exclude-standard', '-z').decode().split('\0')) - {''}
    result = {}
    for name in sorted(names):
        path = repo / name
        try:
            mode = path.lstat().st_mode
        except FileNotFoundError:
            continue  # A tracked deletion is represented by absence.
        if stat.S_ISLNK(mode):
            # Record both link identity and its referent bytes. External
            # referents are excluded from this repository's sealing contract.
            target = os.readlink(path)
            path.resolve(strict=True).relative_to(repo.resolve())
            kind = {'symlink': target}
        elif stat.S_ISREG(mode):
            kind = {'executable': bool(mode & 0o111)}
        else:
            raise ValueError(f'unsupported source entry: {name}')
        digest = hashlib.sha256()
        size = 0
        with path.open('rb') as source:
            for block in iter(lambda: source.read(1024 * 1024), b''):
                digest.update(block)
                size += len(block)
        result[name] = dict(kind, bytes=size, sha256=digest.hexdigest())
    return result


def tree_digest(files):
    return hashlib.sha256(json.dumps(files, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def snapshot(repo):
    head = git(repo, 'rev-parse', 'HEAD').decode().strip()
    files = inventory(repo)
    # A commit changing during the read invalidates this attempt. Callers must
    # also keep writers/builds stopped and verify the snapshot after recording.
    if git(repo, 'rev-parse', 'HEAD').decode().strip() != head:
        raise ValueError('HEAD changed during source inventory')
    return {'schemaVersion': 1, 'createdAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'head': head, 'dirty': bool(git(repo, 'status', '--porcelain', '--untracked-files=all')),
            'qualification': 'unqualified', 'treeSHA256': tree_digest(files), 'files': files}


def verify(repo, recorded):
    if recorded['schemaVersion'] != 1 or recorded['qualification'] != 'unqualified':
        raise ValueError('unsupported snapshot schema or qualification claim')
    if tree_digest(recorded['files']) != recorded['treeSHA256']:
        raise ValueError('snapshot inventory digest is inconsistent')
    current = snapshot(repo)
    old, new = recorded['files'], current['files']
    added = sorted(set(new) - set(old))
    removed = sorted(set(old) - set(new))
    changed = sorted(name for name in set(old) & set(new) if old[name] != new[name])
    head_matches = current['head'] == recorded['head']
    return {'sourceMatches': head_matches and not (added or removed or changed),
            'qualification': 'unqualified', 'headMatches': head_matches,
            'currentDirty': current['dirty'], 'added': added, 'removed': removed, 'changed': changed}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, default=Path.cwd())
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--write', type=Path)
    mode.add_argument('--check', type=Path)
    args = parser.parse_args()
    repo = Path(git(args.repo, 'rev-parse', '--show-toplevel').decode().strip())
    try:
        if args.write:
            output = args.write.resolve()
            if output.is_relative_to(repo.resolve()):
                relative = output.relative_to(repo.resolve())
                if subprocess.run(['git', '-C', str(repo), 'check-ignore', '--quiet', str(relative)]).returncode != 0:
                    raise ValueError('snapshot output inside repository must be ignored by git')
            result = snapshot(repo)
            output.parent.mkdir(parents=True, exist_ok=True)
            with output.open('x') as target:
                json.dump(result, target, indent=2)
                target.write('\n')
            print(json.dumps({'snapshot': str(output), 'files': len(result['files']),
                              'treeSHA256': result['treeSHA256'], 'dirty': result['dirty'],
                              'qualification': 'unqualified'}))
            return 0
        result = verify(repo, json.loads(args.check.read_text()))
        print(json.dumps(result, indent=2))
        return 0 if result['sourceMatches'] else 1
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        print(json.dumps({'sourceMatches': False, 'qualification': 'unqualified', 'error': str(error)}))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
