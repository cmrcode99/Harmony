#!/bin/zsh
set -eu
cd "${0:A:h:h}"
output_dir="${1:-$PWD/dist}"
mkdir -p "$output_dir"
output_dir="${output_dir:A}"
stage=$(mktemp -d "${TMPDIR:-/tmp}/harmony-package.XXXXXX")
trap 'rm -rf "$stage"' EXIT
package="$stage/Harmony"
mkdir -p "$package"
./build.sh --stage-only "$package/Harmony.app"
cp sharing/* "$package/"
cp bin/harmony "$package/harmony"
chmod +x "$package/"*.command "$package/harmony"
python3 tools/check-release.py "$package"
architecture="${HARMONY_ARCH:-$(uname -m)}"
archive="$output_dir/Harmony-$architecture.zip"
/usr/bin/ditto --norsrc --noextattr -c -k --keepParent "$package" "$archive"
(cd "$output_dir" && /usr/bin/shasum -a 256 "${archive:t}" > "${archive:t}.sha256")
print "$archive"
