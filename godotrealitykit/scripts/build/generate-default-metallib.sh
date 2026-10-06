#!/bin/bash

#===----------------------------------------------------------------------===#
# Copyright © 2026 Apple Inc.
#
# Licensed under the MIT license (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# LICENSE
#
#===----------------------------------------------------------------------===#

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(realpath "$SCRIPT_DIR/../../")"

cd "$REPO_DIR/GodotRealityKit"

airFiles=()

# Compile for the platform being built: a macOS metallib fails to load on the
# visionOS simulator (newDefaultLibraryWithBundle returns nil).
case "${PLATFORM_NAME:-macosx}" in
    xrsimulator)
        metalSDK=xrsimulator
        metalTarget="air64-apple-xros${XROS_DEPLOYMENT_TARGET:-2.0}-simulator"
        ;;
    xros)
        metalSDK=xros
        metalTarget="air64-apple-xros${XROS_DEPLOYMENT_TARGET:-2.0}"
        ;;
    *)
        metalSDK=macosx
        metalTarget="air64-apple-macos15.0"
        ;;
esac

mkdir -p "$METAL_LIBRARY_OUTPUT_DIR"

for metalFile in "$REPO_DIR/GodotRealityKit/Metal/"*.metal ; do
    f="$(basename "$metalFile")"
    airFile="$BUILT_PRODUCTS_DIR/${f%.metal}.air"
    airFiles+=("$airFile")

    xcrun -sdk "$metalSDK" metal \
          -c "$metalFile" \
          -o "$airFile" \
          -std=metal3.0 \
          -target "$metalTarget"
done

xcrun -sdk "$metalSDK" metallib \
            "${airFiles[@]}" \
            -o "$METAL_LIBRARY_OUTPUT_DIR/default.metallib"
