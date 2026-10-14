#!/bin/zsh
set -euo pipefail
DUOBAR_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
DUOBAR_BUILD="$DUOBAR_ROOT/build"
mkdir -p "$DUOBAR_BUILD"
DUOBAR_STAGE=$(mktemp -d "$DUOBAR_BUILD/app-stage.XXXXXX")
trap 'rm -rf "$DUOBAR_STAGE"' EXIT
DUOBAR_APP="$DUOBAR_STAGE/MyDuoBar.app"
source "$DUOBAR_ROOT/scripts/toolchain.sh"
mkdir -p "$DUOBAR_APP/Contents/MacOS" "$DUOBAR_APP/Contents/Resources" "$DUOBAR_BUILD/module-cache" "$DUOBAR_BUILD/bin"
for DUOBAR_ARCH in arm64 x86_64; do
    xcrun swiftc -O -whole-module-optimization -swift-version 6 \
        -target "$DUOBAR_ARCH-apple-macosx$DUOBAR_DEPLOYMENT_TARGET" -sdk "$DUOBAR_SDK" \
        -module-cache-path "$DUOBAR_BUILD/module-cache" \
        -framework AppKit -framework CoreWLAN -framework CoreAudio -framework IOKit -framework IOBluetooth -framework CoreBluetooth \
        -framework Network -framework SystemConfiguration -framework ServiceManagement -framework CoreLocation \
        "$DUOBAR_ROOT"/Sources/*.swift -o "$DUOBAR_BUILD/bin/MyDuoBar-$DUOBAR_ARCH"
done
xcrun lipo -create "$DUOBAR_BUILD/bin/MyDuoBar-arm64" "$DUOBAR_BUILD/bin/MyDuoBar-x86_64" -output "$DUOBAR_APP/Contents/MacOS/MyDuoBar"
cp -X "$DUOBAR_ROOT/Resources/Info.plist" "$DUOBAR_APP/Contents/Info.plist"
# Keep the bundle's minimum system version in lockstep with the compiler deployment target.
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $DUOBAR_DEPLOYMENT_TARGET" "$DUOBAR_APP/Contents/Info.plist"
cp -X "$DUOBAR_ROOT/Resources/AppIcon.icns" "$DUOBAR_APP/Contents/Resources/AppIcon.icns"
for DUOBAR_LPROJ in zh-Hant en ja; do
    mkdir -p "$DUOBAR_APP/Contents/Resources/$DUOBAR_LPROJ.lproj"
    cp -X "$DUOBAR_ROOT/Resources/$DUOBAR_LPROJ.lproj/InfoPlist.strings" "$DUOBAR_APP/Contents/Resources/$DUOBAR_LPROJ.lproj/InfoPlist.strings"
    /usr/bin/plutil -lint "$DUOBAR_APP/Contents/Resources/$DUOBAR_LPROJ.lproj/InfoPlist.strings"
done
/usr/bin/plutil -lint "$DUOBAR_APP/Contents/Info.plist"
# Sign with a stable identity when one is available: macOS keys Accessibility access to the signature,
# and an ad-hoc signature changes with every build, so the permission would have to be granted again.
# Set DUOBAR_SIGN_IDENTITY to choose one, or to "-" for an ad-hoc signature.
DUOBAR_SIGN_IDENTITY="${DUOBAR_SIGN_IDENTITY:-$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null | /usr/bin/awk -F'"' '/Apple Development|Developer ID Application/ { print $2; exit }')}"
/usr/bin/codesign --force --timestamp=none --sign "${DUOBAR_SIGN_IDENTITY:--}" "$DUOBAR_APP"
printf 'Signed: %s\n' "${DUOBAR_SIGN_IDENTITY:--}"
"$DUOBAR_ROOT/scripts/verify-app.sh" "$DUOBAR_APP"
# Replace only the generated app, after the fresh bundle has passed validation.
rm -rf "$DUOBAR_BUILD/MyDuoBar.app"
mv "$DUOBAR_APP" "$DUOBAR_BUILD/MyDuoBar.app"
printf 'Built: %s\n' "$DUOBAR_BUILD/MyDuoBar.app"
