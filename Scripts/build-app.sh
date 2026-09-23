#!/usr/bin/env bash
set -euo pipefail

# Builds MacGriddle in release mode and wraps the resulting executable in a
# minimal, hand-rolled .app bundle. There is no Xcode project on this dev
# machine to do this packaging step automatically, so this script does what
# Xcode's build system would otherwise do for a native app target.
#
# NOT signed and NOT notarized — intentionally, for local dev builds only.
# See docs/architecture/chunks/project-structure.md §5 for why, and what
# changes before this app is ever handed to another machine.

PRODUCT_NAME="MacGriddle"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_CONFIG="release"

echo "==> Building ${PRODUCT_NAME} (${BUILD_CONFIG})"
swift build --package-path "${ROOT_DIR}" -c "${BUILD_CONFIG}"

BIN_PATH="$(swift build --package-path "${ROOT_DIR}" -c "${BUILD_CONFIG}" --show-bin-path)"
BUILT_BINARY="${BIN_PATH}/${PRODUCT_NAME}"

if [[ ! -f "${BUILT_BINARY}" ]]; then
    echo "error: expected built executable at ${BUILT_BINARY}, not found" >&2
    exit 1
fi

APP_BUNDLE="${ROOT_DIR}/.build/${PRODUCT_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "==> Assembling ${PRODUCT_NAME}.app at ${APP_BUNDLE}"
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp "${BUILT_BINARY}" "${MACOS_DIR}/${PRODUCT_NAME}"
cp "${ROOT_DIR}/Packaging/Info.plist" "${CONTENTS_DIR}/Info.plist"

# Force-register with Launch Services. The .app lives under .build/, which
# gets wiped and recreated on every rebuild — without this, Launch Services
# (and by extension tccutil, and TCC's own bundle-identity tracking for
# Accessibility/Input Monitoring) can lose track of it entirely, causing
# permission grants in System Settings to silently not take effect against
# whatever's actually running. Confirmed root cause of a real "onboarding
# loop" bug during manual testing — see docs/REVIEW.md.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
if [[ -x "${LSREGISTER}" ]]; then
    "${LSREGISTER}" -f "${APP_BUNDLE}"
fi

echo "==> Done: ${APP_BUNDLE}"
echo "    Run with: open \"${APP_BUNDLE}\""
echo "    Unsigned build — see project-structure.md §5 before distributing this to anyone else."
