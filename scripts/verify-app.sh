#!/bin/zsh
set -euo pipefail
DUOBAR_APP="${1:?Usage: verify-app.sh /path/to/MyDuoBar.app}"
# A distributable app contains only these files: executable, Info.plist, icon, the three
# localized permission-prompt tables and the signature. Reject stale build files,
# embedded tools and symlinks, including when packaging with --skip-build.
DUOBAR_ACTUAL=$(cd "$DUOBAR_APP" && /usr/bin/find . -mindepth 1 ! -type d | LC_ALL=C /usr/bin/sort)
DUOBAR_EXPECTED='./Contents/Info.plist
./Contents/MacOS/MyDuoBar
./Contents/Resources/AppIcon.icns
./Contents/Resources/en.lproj/InfoPlist.strings
./Contents/Resources/ja.lproj/InfoPlist.strings
./Contents/Resources/zh-Hant.lproj/InfoPlist.strings
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
# `lipo -verify_arch` parses its operands differently across toolchain versions; compare the list instead.
DUOBAR_ARCHS=$(xcrun lipo -archs "$DUOBAR_APP/Contents/MacOS/MyDuoBar" | tr ' ' '\n' | LC_ALL=C sort | tr '\n' ' ')
if [[ "$DUOBAR_ARCHS" != "arm64 x86_64 " ]]; then
    print -u2 "Expected arm64 and x86_64 slices, found: $DUOBAR_ARCHS"
    exit 1
fi
/usr/bin/codesign --verify --deep --strict "$DUOBAR_APP"
DUOBAR_EXTERNAL=$(xcrun otool -L "$DUOBAR_APP/Contents/MacOS/MyDuoBar" | /usr/bin/awk '/^[[:space:]]/ { if ($1 !~ /^\/System\/Library\// && $1 !~ /^\/usr\/lib\//) print $1 }')
if [[ -n "$DUOBAR_EXTERNAL" ]]; then
    print -u2 'Unexpected non-system runtime dependency:'
    print -u2 -- "$DUOBAR_EXTERNAL"
    exit 1
fi
print 'Verified: expected app files, both architectures, valid signature, system libraries only.'
