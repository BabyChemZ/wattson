#!/bin/bash
# Tests the actual production sources without requiring Xcode or XCTest.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wattson-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
sources=()
while IFS= read -r -d '' source; do
    sources+=("$source")
done < <(find Sources/wattson -name '*.swift' ! -name main.swift -print0)
swiftc -swift-version 6 -target "$(uname -m)-apple-macosx13.0" -Onone -g \
    "${sources[@]}" Tests/wattsonTests/*.swift -o "$TEST_DIR/checks"
# Keep even accidental future storage access away from the user's real data.
WATTSON_HOME="$TEST_DIR/state" "$TEST_DIR/checks"
