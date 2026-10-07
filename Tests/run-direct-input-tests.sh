#!/bin/sh
set -eu
test_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/moshroom-input-tests.XXXXXX")
trap 'rm -rf "$test_tmp"' EXIT HUP INT TERM
swiftc "$test_root/Moshroom/MoshroomInputBuffer.swift" "$test_root/Tests/DirectInputCoreTests.swift" -o "$test_tmp/direct-input-tests"
"$test_tmp/direct-input-tests"
