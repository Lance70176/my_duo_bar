#!/bin/zsh
set -euo pipefail
DUOBAR_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
if [[ "${1:-}" != "--skip-build" ]]; then "$DUOBAR_ROOT/scripts/build.sh"; fi
DUOBAR_APP="$DUOBAR_ROOT/build/DuoBar.app"
DUOBAR_VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$DUOBAR_APP/Contents/Info.plist")
DUOBAR_NAME="DuoBar-$DUOBAR_VERSION-universal"
DUOBAR_STAGE=$(mktemp -d "$DUOBAR_ROOT/build/dmg-stage.XXXXXX")
trap 'rm -rf "$DUOBAR_STAGE"' EXIT
mkdir -p "$DUOBAR_ROOT/dist"
/usr/bin/ditto "$DUOBAR_APP" "$DUOBAR_STAGE/DuoBar.app"
ln -s /Applications "$DUOBAR_STAGE/Applications"
cp "$DUOBAR_ROOT/docs/安装说明.txt" "$DUOBAR_STAGE/安装说明.txt"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$DUOBAR_APP" "$DUOBAR_ROOT/dist/$DUOBAR_NAME.zip"
/usr/bin/hdiutil create -volname "DuoBar $DUOBAR_VERSION" -srcfolder "$DUOBAR_STAGE" -ov -format UDZO "$DUOBAR_ROOT/dist/$DUOBAR_NAME.dmg"
/usr/bin/hdiutil verify "$DUOBAR_ROOT/dist/$DUOBAR_NAME.dmg"
printf 'Packages: %s\n' "$DUOBAR_ROOT/dist/$DUOBAR_NAME.dmg" "$DUOBAR_ROOT/dist/$DUOBAR_NAME.zip"
