#!/bin/sh
set -eu
test_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/moshroom-scroll-tests.XXXXXX")
trap 'rm -rf "$test_tmp"' EXIT HUP INT TERM
swiftc "$test_root/Moshroom/Commands/tmux/TmuxControlParser.swift" \
  "$test_root/Moshroom/Commands/tmux/TmuxResync.swift" \
  "$test_root/Tests/TmuxScrollFixtures.swift" -o "$test_tmp/fixtures"
"$test_tmp/fixtures" > "$test_tmp/fixtures.json"
node "$test_root/Tests/terminal-scroll-tests.mjs" "$test_tmp/fixtures.json"
