#!/usr/bin/env bash
#
# Bundle the per-arch backend executables + ffmpeg into the built macOS .app so
# the packaged app is self-contained (PHASE2_PLAN.md §1, M2). The Dart
# BackendLauncher resolves these at:
#   <App>.app/Contents/Resources/backend/zeb-echo-backend-{arm64,x64}
#   <App>.app/Contents/Resources/backend/ffmpeg
# (see client/lib/services/backend_launcher_io.dart _defaultExecutablePath).
#
# IMPORTANT: the backend is shipped as TWO per-arch binaries, NOT a lipo'd fat
# binary. `pkg` appends its JS payload at a byte offset that a universal binary
# corrupts, crashing with "Invalid or unexpected token" in pkg/prelude. The
# launcher picks the slice matching the Mac's CPU at runtime. ffmpeg is a normal
# binary, so a lipo'd universal ffmpeg is fine.
#
# Usage:
#   scripts/bundle_macos.sh <path-to-.app> <backend-arm64> <backend-x64> \
#       <ffmpeg> <sck-helper>
# <sck-helper> is the compiled ScreenCaptureKit helper (universal preferred);
# omit it (legacy 4-arg form) to bundle without native system-audio capture.
set -euo pipefail

APP_PATH="${1:?usage: bundle_macos.sh <app> <backend-arm64> <backend-x64> <ffmpeg> [sck-helper]}"
BACKEND_ARM64="${2:?missing arm64 backend exe path}"
BACKEND_X64="${3:?missing x64 backend exe path}"
FFMPEG_BIN="${4:?missing ffmpeg path}"
SCK_HELPER="${5:-}"

RES_DIR="${APP_PATH}/Contents/Resources/backend"

echo "[bundle:macos] app:           ${APP_PATH}"
echo "[bundle:macos] backend arm64: ${BACKEND_ARM64}"
echo "[bundle:macos] backend x64:   ${BACKEND_X64}"
echo "[bundle:macos] ffmpeg:        ${FFMPEG_BIN}"
echo "[bundle:macos] sck helper:    ${SCK_HELPER:-(none)}"

[ -d "${APP_PATH}" ] || { echo "ERROR: .app not found: ${APP_PATH}" >&2; exit 1; }
[ -f "${BACKEND_ARM64}" ] || { echo "ERROR: arm64 backend not found: ${BACKEND_ARM64}" >&2; exit 1; }
[ -f "${BACKEND_X64}" ] || { echo "ERROR: x64 backend not found: ${BACKEND_X64}" >&2; exit 1; }
[ -f "${FFMPEG_BIN}" ] || { echo "ERROR: ffmpeg not found: ${FFMPEG_BIN}" >&2; exit 1; }

mkdir -p "${RES_DIR}"
cp "${BACKEND_ARM64}" "${RES_DIR}/zeb-echo-backend-arm64"
cp "${BACKEND_X64}" "${RES_DIR}/zeb-echo-backend-x64"
cp "${FFMPEG_BIN}" "${RES_DIR}/ffmpeg"
chmod +x "${RES_DIR}/zeb-echo-backend-arm64" \
  "${RES_DIR}/zeb-echo-backend-x64" "${RES_DIR}/ffmpeg"

if [ -n "${SCK_HELPER}" ]; then
  [ -f "${SCK_HELPER}" ] || { echo "ERROR: sck helper not found: ${SCK_HELPER}" >&2; exit 1; }
  cp "${SCK_HELPER}" "${RES_DIR}/zeb-audio-capture"
  chmod +x "${RES_DIR}/zeb-audio-capture"
fi

echo "[bundle:macos] bundled into ${RES_DIR}:"
ls -la "${RES_DIR}"
echo "[bundle:macos] done."
