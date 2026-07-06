#!/bin/sh
#
# ci_post_clone.sh — Xcode Cloud runs this right after cloning, before it
# resolves Swift packages. It recreates the gitignored developer_setup.xcconfig
# (identity + build settings) so the cloud build has what a local build has.
#
# The five IDENTITY values come from Xcode Cloud Environment Variables (set them
# in the workflow — mark the ones you want hidden as "secret"):
#     TEAM_ID  BUNDLE_ID  GROUP_ID  CLOUD_ID  KEYCHAIN_ID1
# The rest are fixed, non-secret build flags and are written literally below.
#
# The binary xcframeworks (mosh/SSH/crypto/ios_system) are SPM binaryTargets in
# the LOCAL xcfs package, hosted on this repo's own `deps-v1` GitHub release.
# Locally, get_frameworks.sh downloads them into xcfs/.build/artifacts via
# `swift package resolve`. Xcode Cloud does NOT run get_frameworks.sh and
# xcfs/.build is not in the repo, so we MUST resolve xcfs here (see the bottom of
# this script) — otherwise the build fails with "no XCFramework found at
# xcfs/.build/artifacts/..." and "Missing package product 'ArgumentParser'".
set -eu

# Fail early with a clear message if an identity var is missing.
for v in TEAM_ID BUNDLE_ID GROUP_ID CLOUD_ID KEYCHAIN_ID1; do
  if [ -z "$(printenv "$v" || true)" ]; then
    echo "ERROR: required environment variable '$v' is not set in the Xcode Cloud workflow." >&2
    exit 1
  fi
done

CFG="$CI_PRIMARY_REPOSITORY_PATH/developer_setup.xcconfig"

# --- identity (from Xcode Cloud env vars) ---
cat > "$CFG" <<EOF
TEAM_ID = ${TEAM_ID}
BUNDLE_ID = ${BUNDLE_ID}
GROUP_ID = ${GROUP_ID}
CLOUD_ID = ${CLOUD_ID}
KEYCHAIN_ID1 = ${KEYCHAIN_ID1}
EOF

# --- fixed build settings (literal — must match developer_setup.xcconfig) ---
# NOTE: the "/$()/" in the URLs is the xcconfig trick that stops "//" being read
# as a comment; it must survive verbatim, hence this quoted heredoc.
cat >> "$CFG" <<'EOF'
SWIFT_ACTIVE_COMPILATION_CONDITIONS[config=Debug]   = MOSHROOM_PUBLISHING_OPTION_DEVELOPER
SWIFT_ACTIVE_COMPILATION_CONDITIONS[config=Release] = MOSHROOM_PUBLISHING_OPTION_TESTFLIGHT
MOSHROOM_MIGRATION_SCHEME = moshroomv15
WHATS_NEW_URL = http:/$()/localhost/whats-new
CONVERSION_OPPORTUNITY_URL = http:/$()/localhost/conversionOpportunity
WHATS_NEW_GITHUB_URL = http:/$()/localhost/conversionOpportunity
MOSHROOM_APP_FONT = JetBrains Mono
MOSHROOM_OTHER_LDFLAGS = -Xlinker -export_dynamic
ENABLE_DEBUG_DYLIB = NO
EOF

echo "ci_post_clone: wrote $CFG"
cat "$CFG"

# --- fetch the binary xcframeworks + resolve the xcfs sub-package's deps ---
# Mirrors get_frameworks.sh: downloads the 8 xcframeworks (from the deps-v1
# release) into xcfs/.build/artifacts and resolves swift-argument-parser. Without
# this, xcodebuild can't find the xcframeworks or the ArgumentParser product.
echo "ci_post_clone: resolving xcfs binary frameworks (this downloads ~104 MB)…"
( cd "$CI_PRIMARY_REPOSITORY_PATH/xcfs" && swift package resolve )
echo "ci_post_clone: xcfs resolve done"
ls -1 "$CI_PRIMARY_REPOSITORY_PATH/xcfs/.build/artifacts/xcfs" 2>/dev/null || echo "  (warning: artifacts dir not found)"
