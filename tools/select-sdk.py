#!/usr/bin/env python3
"""Print a macOS SDK that the installed Swift toolchain can compile Harmony against."""
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import tempfile

# Command Line Tools installed without Xcode can make a newer SDK the default while lacking
# the compiler plugin that SDK's SwiftUI needs for @State. An SDK installed beside it still works.
PROBE = ('import SwiftUI\n'
         'struct Probe: View {\n'
         '    @State private var on = false\n'
         '    var body: some View { Toggle("", isOn: $on) }\n'
         '}\n')
MINIMUM_MAJOR = 26


def run(arguments):
    return subprocess.run(arguments, capture_output=True, text=True, check=False)


def compiles(sdk, command):
    with tempfile.TemporaryDirectory(prefix='harmony-sdk-check-') as directory:
        source = Path(directory) / 'probe.swift'
        source.write_text(PROBE)
        result = command(['swiftc', '-typecheck', '-sdk', str(sdk),
                          '-target', f'{platform.machine()}-apple-macosx13.0', str(source)])
        return result.returncode == 0


def version(sdk):
    found = re.fullmatch(r'MacOSX(\d+)(?:\.(\d+))?\.sdk', Path(sdk).name)
    return (int(found[1]), int(found[2] or 0)) if found else (0, 0)


def select_sdk(override=None, command=run):
    if override:
        return override
    default = command(['xcrun', '--sdk', 'macosx', '--show-sdk-path'])
    if default.returncode or not default.stdout.strip():
        raise ValueError('Could not find a macOS SDK. Install Apple Command Line Tools with: xcode-select --install')
    default_sdk = Path(default.stdout.strip())
    if compiles(default_sdk, command):
        return str(default_sdk)
    others = {path.resolve() for path in default_sdk.parent.glob('MacOSX*.sdk')} - {default_sdk.resolve()}
    for sdk in sorted((path for path in others if version(path)[0] >= MINIMUM_MAJOR), key=version, reverse=True):
        if compiles(sdk, command):
            print(f'The default macOS SDK cannot compile SwiftUI with the installed developer tools; using {sdk.name}.',
                  file=sys.stderr)
            return str(sdk)
    raise ValueError('The default macOS SDK cannot compile SwiftUI with the installed developer tools, and no other '
                     f'installed SDK ({MINIMUM_MAJOR} or newer) can. Install Xcode {MINIMUM_MAJOR} or newer, or set '
                     'SDKROOT to a working SDK. Nothing was built.')


def main():
    if len(sys.argv) != 1:
        raise ValueError('Usage: select-sdk.py')
    print(select_sdk(os.environ.get('SDKROOT')))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
