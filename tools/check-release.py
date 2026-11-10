#!/usr/bin/env python3
"""Inspect source/package exports and create deterministic, non-overwriting ZIPs."""
import argparse
from datetime import datetime, timezone
import hashlib
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import zipfile

SOURCE_IGNORED = {'.git', '.serena', '.build', '__pycache__'}
PRIVATE_FILES = {'configuration.json', 'phone-vault.json', 'keychain-password', 'recovery-password.txt'}
PRIVATE_SUFFIXES = {'.pem', '.p12', '.pfx', '.key'}
MEDIA_SUFFIXES = {'.mp4', '.icns'}
HOME_PATH = re.compile(rb'/(?:Users|home)/[A-Za-z0-9_.-]+/')
EMBEDDED_DIGEST = re.compile(rb'let unlockDigest\s*=\s*"[a-fA-F0-9]{64}"')


def _private_name(path: Path) -> bool:
    return (path.name.lower() in PRIVATE_FILES or 'keychain' in path.name.lower()
            or path.suffix.lower() in PRIVATE_SUFFIXES
            or (path.name.startswith('.env') and path.name != '.env.example'))


def check(root: Path, mode: str = 'source') -> list:
    """Return path-only findings. Never follow symlinks or read outside root."""
    root = Path(os.path.abspath(root))
    if mode not in {'source', 'package'}:
        raise ValueError('Unknown release check mode.')
    if root.is_symlink():
        return ['.: export root is a symlink']
    if not root.is_dir():
        return ['.: export directory does not exist']
    problems = []
    tracked = set()
    if mode == 'source' and (root / '.git').exists():
        result = subprocess.run(['git', '-C', str(root), 'ls-files', '-z'], capture_output=True, check=True)
        tracked = set(result.stdout.decode().split('\0')) - {''}

    def unreadable(error):
        relative = Path(error.filename).relative_to(root)
        problems.append(str(relative) + ': unreadable directory')

    for directory, names, files in os.walk(root, followlinks=False, onerror=unreadable):
        base = Path(directory)
        for name in list(names) + files:
            path = base / name
            relative = path.relative_to(root)
            if path.is_symlink():
                problems.append(str(relative) + ': symlink')
                if name in names:
                    names.remove(name)
                continue
            ignored = (name in SOURCE_IGNORED or (path.parent == root and name == 'dist'))
            if ignored:
                if name in names:
                    names.remove(name)
                if mode == 'package':
                    problems.append(str(relative) + ': repository/build metadata in package')
                elif any(item == relative.as_posix() or item.startswith(relative.as_posix() + '/') for item in tracked):
                    problems.append(str(relative) + ': generated metadata is tracked in source')
                continue
            if _private_name(path):
                problems.append(str(relative) + ': private file or directory')
                if name in names:
                    names.remove(name)
                continue
            if name in names:
                continue
            if name == '.DS_Store':
                if mode == 'package':
                    problems.append(str(relative) + ': Finder metadata in package')
                continue
            if not path.is_file():
                problems.append(str(relative) + ': unsupported file type')
                continue
            if path.suffix.lower() in MEDIA_SUFFIXES:
                if relative.as_posix() in tracked:
                    problems.append(str(relative) + ': media asset is tracked in source')
                continue
            # Chunking also covers executable strings without loading large files.
            tail = b''
            with path.open('rb') as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                    data = tail + chunk
                    if HOME_PATH.search(data):
                        problems.append(str(relative) + ': machine-specific home path')
                        break
                    if EMBEDDED_DIGEST.search(data):
                        problems.append(str(relative) + ': embedded password hash')
                        break
                    tail = data[-1024:]
    return sorted(problems)


def write_archive(root: Path, destination: Path, epoch: int = 315532800) -> Path:
    """ZIP one checked package, normalizing order, timestamps and permissions.

    Output and checksum are installed exclusively; an existing release is never
    overwritten. Equal package bytes/modes and epoch produce equal archives.
    """
    root, destination = Path(root).absolute(), Path(destination).absolute()
    if destination.resolve().is_relative_to(root.resolve()):
        raise ValueError('Release output must be outside the package being archived.')
    failures = check(root, mode='package')
    if failures:
        raise ValueError('\n'.join(failures))
    if not 315532800 <= epoch <= 4354819198:
        raise ValueError('SOURCE_DATE_EPOCH must be within ZIP years 1980–2107.')
    timestamp = datetime.fromtimestamp(epoch, timezone.utc).timetuple()[:6]
    checksum = destination.with_name(destination.name + '.sha256')
    destination.parent.mkdir(parents=True, exist_ok=True)
    if os.path.lexists(destination) or os.path.lexists(checksum):
        raise FileExistsError('Release archive or checksum already exists; choose a new output directory.')
    temporary = []
    published = []
    try:
        descriptor, name = tempfile.mkstemp(prefix='.harmony-release-', dir=destination.parent)
        os.close(descriptor)
        archive = Path(name)
        archive.chmod(0o644)
        temporary.append(archive)
        with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as output:
            for path in [root, *sorted(root.rglob('*'))]:
                if path.is_symlink():
                    raise ValueError('Package changed during archiving: symlink found.')
                is_directory = path.is_dir()
                relative = Path(root.name) / path.relative_to(root)
                info = zipfile.ZipInfo(relative.as_posix() + ('/' if is_directory else ''), date_time=timestamp)
                info.create_system = 3
                executable = bool(path.stat().st_mode & 0o111)
                mode = (stat.S_IFDIR | 0o755) if is_directory else (stat.S_IFREG | (0o755 if executable else 0o644))
                info.external_attr = mode << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                if is_directory:
                    info.external_attr |= 0x10
                    output.writestr(info, b'')
                else:
                    with path.open('rb') as source, output.open(info, 'w', force_zip64=True) as target:
                        for chunk in iter(lambda: source.read(1024 * 1024), b''):
                            target.write(chunk)
        digest = hashlib.sha256()
        with archive.open('rb') as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b''):
                digest.update(chunk)
        descriptor, name = tempfile.mkstemp(prefix='.harmony-checksum-', dir=destination.parent)
        checksum_temporary = Path(name)
        checksum_temporary.chmod(0o644)
        temporary.append(checksum_temporary)
        with os.fdopen(descriptor, 'w') as stream:
            stream.write(f'{digest.hexdigest()}  {destination.name}\n')
        # Hard-link publication has O_EXCL behavior, even if another publisher raced us.
        for source, target in [(archive, destination), (checksum_temporary, checksum)]:
            os.link(source, target)
            published.append(target)
        return checksum
    except BaseException:
        for path in published:
            path.unlink(missing_ok=True)
        raise
    finally:
        for path in temporary:
            path.unlink(missing_ok=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--mode', choices=('source', 'package'), default='source')
    parser.add_argument('--archive', type=Path, help='Create a checked package ZIP and SHA-256 checksum.')
    args = parser.parse_args()
    try:
        failures = check(args.directory, args.mode)
        if failures:
            raise ValueError('\n'.join(failures))
        if args.archive:
            epoch = int(os.environ.get('SOURCE_DATE_EPOCH', '315532800'))
            write_archive(args.directory, args.archive, epoch)
            print(args.archive)
        else:
            print(f'{args.mode.capitalize()} check passed: no private files, symlinks, embedded password hash, or personal home paths.')
    except (OSError, ValueError) as error:
        raise SystemExit(str(error))


if __name__ == '__main__':
    main()
