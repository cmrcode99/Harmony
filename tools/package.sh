#!/bin/zsh
# Build a local release; no upload, installation, or replacement of old archives.
set -eu
cd "${0:A:h:h}"
if (( $# == 1 )) && [[ "$1" == --help || "$1" == -h ]]; then
  print 'Usage: ./tools/package.sh [OUTPUT_DIRECTORY]'
  print 'Creates Harmony-VERSION-ARCH.zip and .sha256; refuses to overwrite either file.'
  print 'HARMONY_ARCH: arm64 or x86_64. SOURCE_DATE_EPOCH: optional ZIP timestamp (1980–2107).'
  exit 0
fi
if (( $# > 1 )); then
  print -u2 'Usage: ./tools/package.sh [OUTPUT_DIRECTORY]'
  exit 2
fi
architecture="${HARMONY_ARCH:-$(uname -m)}"
case "$architecture" in
  arm64|x86_64) ;;
  *) print -u2 'HARMONY_ARCH must be arm64 or x86_64.'; exit 2 ;;
esac
version=$(python3 - <<'PY'
import plistlib,re
with open('Info.plist','rb') as source:
    version=plistlib.load(source)['CFBundleShortVersionString']
if not isinstance(version,str) or not re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}',version):
    raise SystemExit('Info.plist must contain a numeric release version.')
print(version)
PY
)
python3 tools/check-release.py . --mode source
output_dir="${1:-$PWD/dist}"
mkdir -p "$output_dir"
output_dir="${output_dir:A}"
archive="$output_dir/Harmony-$version-$architecture.zip"
if [[ -e "$archive" || -L "$archive" || -e "$archive.sha256" || -L "$archive.sha256" ]]; then
  print -u2 'Release archive or checksum already exists; choose a new output directory.'
  exit 1
fi
stage=$(mktemp -d "${TMPDIR:-/tmp}/harmony-package.XXXXXX")
trap 'rm -rf "$stage"' EXIT
package="$stage/Harmony"
mkdir -p "$package"
HARMONY_ARCH="$architecture" ./build.sh --stage-only "$package/Harmony.app"
actual_arch=$(/usr/bin/lipo -archs "$package/Harmony.app/Contents/MacOS/HarmonyFocus")
if [[ "$actual_arch" != "$architecture" ]]; then
  print -u2 "Built architecture ($actual_arch) does not match requested release ($architecture)."
  exit 1
fi
built_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$package/Harmony.app/Contents/Info.plist")
if [[ "$built_version" != "$version" ]]; then
  print -u2 'Built app version does not match the release filename.'
  exit 1
fi
/usr/bin/codesign --verify --deep --strict "$package/Harmony.app"
cp sharing/* "$package/"
cp LICENSE "$package/LICENSE"
cp bin/harmony "$package/harmony"
chmod +x "$package/"*.command "$package/harmony"
python3 tools/check-release.py "$package" --mode package --archive "$archive"
