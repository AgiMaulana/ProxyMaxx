#!/bin/bash
#
# Linker flags that make SwiftPM record the real macOS SDK version in the binary.
#
# Sourced, not executed: it defines MACOS_SDK_VERSION and MACOS_SDK_LINK_FLAGS, which
# every `swift build` in this directory passes through.
#
# SwiftPM's build system links object files without `-platform_version`, so ld falls
# back to the deployment target for the SDK version it writes into LC_BUILD_VERSION.
# A local build therefore claims to be built against macOS 14 no matter which toolchain
# produced it.
#
# That field is what macOS 26 reads to decide whether an app opts into the Tahoe
# redesign. A local build (sdk 14.0) renders with the previous interface — centered
# window title, translucent sidebar, legacy popup and segmented controls — while the CI
# release, whose SwiftPM does pass the flag (sdk 26.5), renders the current design.
# Same source, two interfaces: see docs/compare-ui-debug-release.
#
# Passing the flag here restores what ld would have recorded. A toolchain that already
# emits it just receives the same values twice, which ld resolves as last-wins.
#
# MACOS_DEPLOYMENT_TARGET stays in step with Package.swift's `.macOS(.v14)`.

MACOS_DEPLOYMENT_TARGET="14.0"

MACOS_SDK_VERSION="$(xcrun --show-sdk-version 2>/dev/null || true)"
if [[ -z "$MACOS_SDK_VERSION" ]]; then
    echo "warning: no macOS SDK version from xcrun; the binary will record the deployment target as its SDK" >&2
    MACOS_SDK_VERSION="$MACOS_DEPLOYMENT_TARGET"
fi

MACOS_SDK_LINK_FLAGS=(
    -Xlinker -platform_version
    -Xlinker macos
    -Xlinker "$MACOS_DEPLOYMENT_TARGET"
    -Xlinker "$MACOS_SDK_VERSION"
)
