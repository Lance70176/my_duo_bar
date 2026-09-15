#!/bin/zsh
# Sourced by build.sh and test.sh. Picks a Swift compiler and macOS SDK that belong together.
#
# MyDuoBar is built primarily against the macOS 27 SDK. A machine can have an older Xcode selected
# while Command Line Tools carry the macOS 27 SDK (or the reverse); mixing the two fails with
# "this SDK is not supported by the compiler". We therefore probe each developer directory with
# its own SDK and keep the first pair that actually compiles.
#
# Overrides:
#   DUOBAR_SDK=/path/MacOSX.sdk DEVELOPER_DIR=/path   use exactly this pair
#   DUOBAR_MIN_SDK_MAJOR=26                             accept an older SDK (e.g. CI images)
#   DUOBAR_DEPLOYMENT_TARGET=27.0                       change the minimum macOS version

: "${DUOBAR_MIN_SDK_MAJOR:=27}"
: "${DUOBAR_DEPLOYMENT_TARGET:=26.0}"

duobar_select_toolchain() {
    if [[ -n "${DUOBAR_SDK:-}" ]]; then
        export DUOBAR_SDK DUOBAR_DEPLOYMENT_TARGET
        return 0
    fi
    local probe_dir probe_file candidate sdk version major
    probe_dir=$(mktemp -d)
    probe_file="$probe_dir/probe.swift"
    print 'import AppKit\nlet _ = NSApplication.shared' > "$probe_file"
    for candidate in "${DEVELOPER_DIR:-$(xcode-select -p)}" /Library/Developer/CommandLineTools; do
        for sdk in "$candidate/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk" "$candidate/SDKs/MacOSX.sdk"; do
            [[ -f "$sdk/SDKSettings.plist" ]] || continue
            version=$(/usr/libexec/PlistBuddy -c 'Print Version' "$sdk/SDKSettings.plist" 2>/dev/null) || continue
            major=${version%%.*}
            (( major >= DUOBAR_MIN_SDK_MAJOR )) || continue
            if DEVELOPER_DIR="$candidate" xcrun swiftc -typecheck -swift-version 6 \
                -target "$(uname -m)-apple-macosx$DUOBAR_DEPLOYMENT_TARGET" -sdk "$sdk" \
                -module-cache-path "$probe_dir/cache" "$probe_file" >/dev/null 2>&1; then
                export DEVELOPER_DIR="$candidate" DUOBAR_SDK="$sdk" DUOBAR_DEPLOYMENT_TARGET
                rm -rf "$probe_dir"
                print "Toolchain: $(xcrun swiftc --version 2>/dev/null | head -1 | sed -E 's/.*(Apple Swift version [0-9.]+).*/\1/') · macOS SDK $version · target macOS $DUOBAR_DEPLOYMENT_TARGET"
                return 0
            fi
        done
    done
    rm -rf "$probe_dir"
    print -u2 "No Swift compiler can build against a macOS $DUOBAR_MIN_SDK_MAJOR+ SDK on this Mac."
    print -u2 "Install Xcode 27 or Command Line Tools for macOS 27, or set DUOBAR_MIN_SDK_MAJOR=26."
    return 1
}

duobar_select_toolchain
