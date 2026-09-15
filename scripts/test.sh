#!/bin/zsh
set -euo pipefail
DUOBAR_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
mkdir -p "$DUOBAR_ROOT/build/tests" "$DUOBAR_ROOT/build/module-cache"
source "$DUOBAR_ROOT/scripts/toolchain.sh"
DUOBAR_TEST_FLAGS=(-swift-version 6 -target "$(uname -m)-apple-macosx$DUOBAR_DEPLOYMENT_TARGET" -sdk "$DUOBAR_SDK")
xcrun swiftc "${DUOBAR_TEST_FLAGS[@]}" -parse-as-library \
    -module-cache-path "$DUOBAR_ROOT/build/module-cache" \
    "$DUOBAR_ROOT/Sources/L10n.swift" "$DUOBAR_ROOT/Sources/StatusModel.swift" "$DUOBAR_ROOT/Sources/DotPreferences.swift" "$DUOBAR_ROOT/Sources/TunnelRoutes.swift" "$DUOBAR_ROOT/Sources/WiFiNetworks.swift" "$DUOBAR_ROOT/Tests/StatusTests.swift" \
    -o "$DUOBAR_ROOT/build/tests/StatusTests"
"$DUOBAR_ROOT/build/tests/StatusTests"

xcrun swiftc -O "${DUOBAR_TEST_FLAGS[@]}" -module-cache-path "$DUOBAR_ROOT/build/module-cache" \
    "$DUOBAR_ROOT/Sources/L10n.swift" "$DUOBAR_ROOT/Sources/StatusModel.swift" "$DUOBAR_ROOT/Sources/DotPreferences.swift" \
    "$DUOBAR_ROOT/Sources/DuoIcon.swift" "$DUOBAR_ROOT/Sources/IconMotion.swift" "$DUOBAR_ROOT/Sources/StatusIconView.swift" \
    "$DUOBAR_ROOT/Tests/IconTests.swift" -o "$DUOBAR_ROOT/build/tests/IconTests"
"$DUOBAR_ROOT/build/tests/IconTests"

xcrun swiftc -O "${DUOBAR_TEST_FLAGS[@]}" -module-cache-path "$DUOBAR_ROOT/build/module-cache" \
    "$DUOBAR_ROOT/Sources/L10n.swift" "$DUOBAR_ROOT/Sources/StatusModel.swift" "$DUOBAR_ROOT/Sources/DotPreferences.swift" \
    "$DUOBAR_ROOT/Sources/DuoIcon.swift" "$DUOBAR_ROOT/Sources/IconMotion.swift" \
    "$DUOBAR_ROOT/Sources/SystemSettings.swift" "$DUOBAR_ROOT/Sources/StatusPanel.swift" \
    "$DUOBAR_ROOT/Sources/WiFiNetworks.swift" "$DUOBAR_ROOT/Sources/WiFiService.swift" "$DUOBAR_ROOT/Sources/WiFiMenu.swift" \
    "$DUOBAR_ROOT/Tests/PanelTests.swift" -o "$DUOBAR_ROOT/build/tests/PanelTests"
"$DUOBAR_ROOT/build/tests/PanelTests"

xcrun swiftc -O "${DUOBAR_TEST_FLAGS[@]}" -module-cache-path "$DUOBAR_ROOT/build/module-cache" \
    "$DUOBAR_ROOT/Sources/L10n.swift" "$DUOBAR_ROOT/Sources/StatusModel.swift" "$DUOBAR_ROOT/Sources/DotPreferences.swift" \
    "$DUOBAR_ROOT/Sources/DuoIcon.swift" "$DUOBAR_ROOT/Sources/IconMotion.swift" \
    "$DUOBAR_ROOT/Sources/SystemSettings.swift" "$DUOBAR_ROOT/Sources/StatusPanel.swift" \
    "$DUOBAR_ROOT/Sources/SettingsController.swift" \
    "$DUOBAR_ROOT/Tests/SettingsTests.swift" -o "$DUOBAR_ROOT/build/tests/SettingsTests"
"$DUOBAR_ROOT/build/tests/SettingsTests"
