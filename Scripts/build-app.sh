#!/usr/bin/env bash
set -euo pipefail

# Builds MacGriddle in release mode and wraps the resulting executable in a
# minimal, hand-rolled .app bundle. There is no Xcode project on this dev
# machine to do this packaging step automatically, so this script does what
# Xcode's build system would otherwise do for a native app target.
#
# Signed with a stable, local, self-signed certificate — NOT notarized, and
# NOT a real Developer ID. See "Local code signing" below for why this
# exists and §5 in project-structure.md for what changes before this app is
# ever handed to another machine (a Developer ID / notarized build, signed
# with a completely different identity).

PRODUCT_NAME="MacGriddle"
SIGNING_IDENTITY="MacGriddle Local Dev"

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

# Local code signing — stabilizes TCC identity across rebuilds.
#
# Fully unsigned (and equally, ad-hoc `codesign --sign -`) binaries get a
# code identity keyed to the exact hash of their own bytes. Since every
# rebuild produces different bytes, macOS's TCC treats every single rebuild
# as a brand-new, never-before-seen app — every previously granted
# Accessibility/Input Monitoring permission silently stops applying, with
# no error surfaced anywhere, immediately after any rebuild. Confirmed as
# the root cause of a real "granted it, but nothing works" bug during manual
# testing that looked identical to two earlier, *different* permission bugs
# (Launch Services never having registered the bundle; two conflicting
# registrations for the same bundle ID) — see docs/REVIEW.md for all three.
#
# Signing with ANY stable certificate (real Developer ID, a free
# Xcode-issued "Apple Development" cert, or — as here, since neither was
# available on this machine — a local self-signed one) gives the app a
# designated requirement anchored to that certificate instead of to the
# binary's content, so it survives every future rebuild unchanged. The
# certificate itself was created once, out of band, and lives in the login
# keychain — this script only ever *uses* it, never creates it.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "${SIGNING_IDENTITY}"; then
    # No --deep: this bundle has no nested frameworks/helpers to recurse
    # into, and --deep here actively failed (errSecInternal) when re-signing
    # over a previous ad-hoc signature — signing the bundle directly is both
    # sufficient and the one that actually works.
    codesign --force --sign "${SIGNING_IDENTITY}" "${APP_BUNDLE}"
else
    echo "warning: signing identity '${SIGNING_IDENTITY}' not found in keychain — building unsigned." >&2
    echo "         TCC permission grants will NOT survive the next rebuild until this identity exists." >&2
fi

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
echo "    Signed with local dev certificate '${SIGNING_IDENTITY}' — see project-structure.md §5 before distributing this to anyone else."
