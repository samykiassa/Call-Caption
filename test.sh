#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$DIR/.build/clang-module-cache}"
export SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-$DIR/.build/swift-module-cache}"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFT_MODULECACHE_PATH"
DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-arm64-apple-macos26.0}"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/callcaption-tests.XXXXXX")"
OBJ_HELPER="$TEST_DIR/AudioTapHelper_test.o"
TEST_BIN="$TEST_DIR/TestRunner"
TEST_SUITE="com.callcaption.tests.$$"

cleanup() {
    rm -f "$OBJ_HELPER" "$TEST_BIN"
    rm -rf "$TEST_DIR"
    defaults delete "$TEST_SUITE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

CLANG_SANITIZER_FLAGS=()
SWIFT_SANITIZER_FLAGS=()
if [ -n "${SANITIZE:-}" ]; then
    CLANG_SANITIZER_FLAGS=(-fsanitize="$SANITIZE" -g)
    SWIFT_SANITIZER_FLAGS=(-sanitize="$SANITIZE" -g)
fi

clang -Wall -Wextra -Werror -fobjc-arc -O2 \
    -target "$DEPLOYMENT_TARGET" \
    ${CLANG_SANITIZER_FLAGS[@]+"${CLANG_SANITIZER_FLAGS[@]}"} \
    -c "$DIR/Sources/AudioTapHelper.m" \
    -o "$OBJ_HELPER"

SWIFT_SOURCES=()
for f in "$DIR"/Sources/*.swift; do
    if [ "$(basename "$f")" != "main.swift" ]; then
        SWIFT_SOURCES+=("$f")
    fi
done

JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

swiftc \
    -DCALLCAPTION_TESTING \
    -warnings-as-errors \
    -swift-version 6 \
    -j "$JOBS" \
    -target "$DEPLOYMENT_TARGET" \
    -import-objc-header "$DIR/Sources/AudioTapHelper.h" \
    "$OBJ_HELPER" \
    "${SWIFT_SOURCES[@]}" \
    "$DIR/Tests/CallCaptionTests.swift" \
    -framework Cocoa \
    -framework SwiftUI \
    -framework AVFoundation \
    -framework Speech \
    -framework CoreAudio \
    -framework AudioToolbox \
    -framework Translation \
    -framework Network \
    -framework Security \
    -framework CryptoKit \
    ${SWIFT_SANITIZER_FLAGS[@]+"${SWIFT_SANITIZER_FLAGS[@]}"} \
    -o "$TEST_BIN"

CALLCAPTION_TEST=1 \
CALLCAPTION_TEST_DIR="$TEST_DIR" \
CALLCAPTION_TEST_SUITE="$TEST_SUITE" \
"$TEST_BIN"
