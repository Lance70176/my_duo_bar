#!/bin/zsh
set -euo pipefail
DUOBAR_APP="${1:?Usage: verify-app.sh /path/to/MyDuoBar.app}"
# A distributable app contains only these four files. Reject stale build files,
# embedded tools and symlinks, including when packaging with --skip-build.
DUOBAR_ACTUAL=$(cd "$DUOBAR_APP" && /usr/bin/find . -mindepth 1 ! -type d | LC_ALL=C /usr/bin/sort)
DUOBAR_EXPECTED='./Contents/Info.plist
./Contents/MacOS/MyDuoBar
./Contents/Resources/AppIcon.icns
./Contents/_CodeSignature/CodeResources'
if [[ "$DUOBAR_ACTUAL" != "$DUOBAR_EXPECTED" ]]; then
    print -u2 'Unexpected application contents; rebuild before packaging.'
    print -u2 -- "$DUOBAR_ACTUAL"
    exit 1
fi
if [[ -n "$(/usr/bin/find "$DUOBAR_APP" -type l -print)" ]]; then
    print -u2 'Application must not contain symlinks.'
    exit 1
fi
/usr/bin/plutil -lint "$DUOBAR_APP/Contents/Info.plist"
xcrun lipo "$DUOBAR_APP/Contents/MacOS/MyDuoBar" -verify_arch arm64 x86_64
/usr/bin/codesign --verify --deep --strict "$DUOBAR_APP"
DUOBAR_EXTERNAL=$(xcrun otool -L "$DUOBAR_APP/Contents/MacOS/MyDuoBar" | /usr/bin/awk '/^[[:space:]]/ { if ($1 !~ /^\/System\/Library\// && $1 !~ /^\/usr\/lib\//) print $1 }')
if [[ -n "$DUOBAR_EXTERNAL" ]]; then
    print -u2 'Unexpected non-system runtime dependency:'
    print -u2 -- "$DUOBAR_EXTERNAL"
    exit 1
fi
print 'Verified: four app files, both architectures, valid signature, system libraries only.'
