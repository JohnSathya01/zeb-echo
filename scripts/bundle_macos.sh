#!/usr/bin/env bash
#
# Bundle the backend executable + ffmpeg into the built macOS .app so the
# packaged app is self-contained (PHASE2_PLAN.md §1, M2). The Dart
# BackendLauncher resolves these at:
#   <App>.app/Contents/Resources/backend/{zeb-echo-backend, ffmpeg}
# (see client/lib/services/backend_launcher_io.dart _defaultExecutablePath).
#
# Usage:
#   scripts/bundle_macos.sh <path-to-.app> <path-to-backend-exe> <path-to-ffmpeg>
#
# The backend exe and ffmpeg should already be built/fetched (universal binaries
# preferred so the app runs on both Apple Silicon and Intel). The release
# workflow builds the universal backend via lipo and downloads a static ffmpeg.
set -euo pipefail

APP_PATH="${1:?usage: bundle_macos.sh <app> <backend-exe> <ffmpeg>}"
BACKEND_EXE="${2:?missing backend exe path}"
FFMPEG_BIN="${3:?missing ffmpeg path}"

RES_DIR="${APP_PATH}/Contents/Resources/backend"

echo "[bundle:macos] app:     ${APP_PATH}"
echo "[bundle:macos] backend: ${BACKEND_EXE}"
echo "[bundle:macos] ffmpeg:  ${FFMPEG_BIN}"

[ -d "${APP_PATH}" ] || { echo "ERROR: .app not found: ${APP_PATH}" >&2; exit 1; }
[ -f "${BACKEND_EXE}" ] || { echo "ERROR: backend exe not found: ${BACKEND_EXE}" >&2; exit 1; }
[ -f "${FFMPEG_BIN}" ] || { echo "ERROR: ffmpeg not found: ${FFMPEG_BIN}" >&2; exit 1; }

mkdir -p "${RES_DIR}"
cp "${BACKEND_EXE}" "${RES_DIR}/zeb-echo-backend"
cp "${FFMPEG_BIN}" "${RES_DIR}/ffmpeg"
chmod +x "${RES_DIR}/zeb-echo-backend" "${RES_DIR}/ffmpeg"

echo "[bundle:macos] bundled into ${RES_DIR}:"
ls -la "${RES_DIR}"
echo "[bundle:macos] done."
