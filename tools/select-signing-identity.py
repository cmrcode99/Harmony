#!/usr/bin/env python3
"""Reuse an installed app's available signing identity without touching Keychain."""
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def run(arguments):
    return subprocess.run(arguments, capture_output=True, text=True, check=False)


def select_identity(installed_app=None, override=None, command=run):
    if override:
        return override
    if installed_app is None or not Path(installed_app).exists():
        return '-'
    with tempfile.TemporaryDirectory(prefix='harmony-signing-check-') as directory:
        prefix = str(Path(directory) / 'certificate')
        result = command(['/usr/bin/codesign', '--display', '--extract-certificates=' + prefix, str(installed_app)])
        if result.returncode:
            raise ValueError('Could not inspect the installed Harmony signature; the app was left unchanged.')
        certificate = Path(prefix + '0')
        if not certificate.exists():
            return '-'
        fingerprint = hashlib.sha1(certificate.read_bytes()).hexdigest().upper()
    identities = command(['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning'])
    available = re.findall(r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"', identities.stdout, re.MULTILINE)
    if identities.returncode == 0 and fingerprint in [value.upper() for value in available]:
        print('Reusing the installed Harmony signing identity.', file=sys.stderr)
        return fingerprint
    raise ValueError('The installed Harmony signing identity is unavailable. Unlock its keychain or set '
                     'HARMONY_SIGN_IDENTITY to an existing identity. To deliberately use ad-hoc signing, '
                     'set HARMONY_SIGN_IDENTITY=-; macOS permissions may need approval again. '
                     'The installed app was left unchanged.')


def main():
    if len(sys.argv) > 2:
        raise ValueError('Usage: select-signing-identity.py [installed-Harmony.app]')
    print(select_identity(sys.argv[1] if len(sys.argv) == 2 else None, os.environ.get('HARMONY_SIGN_IDENTITY')))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
