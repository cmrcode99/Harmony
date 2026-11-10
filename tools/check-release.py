#!/usr/bin/env python3
"""Check an export or staged app for private files and local absolute paths."""
from pathlib import Path
import re
import sys

EXCLUDED = {'.git', '.serena', '.build', '__pycache__', 'dist', 'assets'}
PRIVATE_FILES = {'configuration.json', 'phone-vault.json', 'keychain-password', 'recovery-password.txt'}


def check(root: Path) -> list:
    problems = []
    for path in root.rglob('*'):
        if any(part in EXCLUDED for part in path.relative_to(root).parts):
            continue
        if not path.is_file():
            continue
        if path.is_symlink() or path.name in PRIVATE_FILES or 'keychain' in path.name:
            problems.append(str(path.relative_to(root)) + ': private file or symlink')
            continue
        if path.suffix.lower() in {'.mp4', '.icns'}:
            continue
        data = path.read_bytes()
        if re.search(rb'/(?:Users|home)/[A-Za-z0-9_.-]+/', data):
            problems.append(str(path.relative_to(root)) + ': machine-specific home path')
        if re.search(rb'let unlockDigest\s*=\s*"[a-f0-9]{64}"', data):
            problems.append(str(path.relative_to(root)) + ': embedded password hash')
    return problems


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('Usage: check-release.py DIRECTORY')
    root = Path(sys.argv[1]).resolve()
    if not root.is_dir():
        raise SystemExit('Directory does not exist.')
    problems = check(root)
    if problems:
        raise SystemExit('\n'.join(problems))
    print('Release check passed: no private settings, embedded password hash, or personal home paths.')
