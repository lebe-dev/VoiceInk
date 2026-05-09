#!/usr/bin/env bash
# Download and prepare sherpa-onnx + onnxruntime static libraries for VoiceInk.
#
# sherpa-onnx is shipped as a static xcframework, but its libsherpa-onnx.a
# does not bundle ONNX Runtime — `OrtGetApiBase` etc. live in libonnxruntime.a
# from a separate release. We download both and merge them into a single
# combined static library inside the xcframework so the rest of the build only
# has to link against one xcframework.
#
# Idempotent: skips work if the combined framework + modulemap are already in
# place for the current pinned versions.

set -euo pipefail

SHERPA_VERSION="v1.13.0"
SHERPA_ASSET="sherpa-onnx-${SHERPA_VERSION}-macos-xcframework-static.tar.bz2"
SHERPA_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/${SHERPA_VERSION}/${SHERPA_ASSET}"
# Pinned SHA-256 of the upstream release asset. Verified against the published
# asset on 2026-05-09. If the upstream release is ever republished, the
# digest must be updated by hand — never silently bypass this check.
SHERPA_SHA256="a203a19db9ff66d548e448bffa8bdff801a2e2f07172d5eefe136ccf6e4086cf"

ORT_VERSION="1.24.4"
ORT_ASSET="onnxruntime-osx-universal2-static_lib-${ORT_VERSION}.zip"
ORT_URL="https://github.com/csukuangfj/onnxruntime-libs/releases/download/v${ORT_VERSION}/${ORT_ASSET}"
ORT_SHA256="df4e20a6583ddc81fae7b1dfa776f6c06fa9c7cd32a3af44c9369c9e75731426"

DEST_ROOT="${SHERPA_ONNX_DIR:-$HOME/VoiceInk-Dependencies/sherpa-onnx}"
XCFRAMEWORK_PATH="${DEST_ROOT}/sherpa-onnx.xcframework"
ARCH_DIR="${XCFRAMEWORK_PATH}/macos-arm64_x86_64"
HEADERS_DIR="${ARCH_DIR}/Headers"
MODULE_MAP_PATH="${HEADERS_DIR}/module.modulemap"
COMBINED_STAMP="${DEST_ROOT}/.combined-${SHERPA_VERSION}-ort${ORT_VERSION}.stamp"

if [[ -f "${COMBINED_STAMP}" && -f "${MODULE_MAP_PATH}" && -f "${ARCH_DIR}/libsherpa-onnx.a" ]]; then
  echo "sherpa-onnx + onnxruntime already prepared at ${XCFRAMEWORK_PATH}, skipping."
  exit 0
fi

mkdir -p "${DEST_ROOT}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

verify_sha256() {
  local file="$1"
  local expected="$2"
  local actual
  actual="$(shasum -a 256 "${file}" | awk '{print $1}')"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "Error: SHA-256 mismatch for ${file}" >&2
    echo "  expected: ${expected}" >&2
    echo "  actual:   ${actual}" >&2
    exit 1
  fi
}

echo "Downloading ${SHERPA_URL} ..."
curl -fL --retry 3 --retry-delay 2 -o "${TMP_DIR}/${SHERPA_ASSET}" "${SHERPA_URL}"
verify_sha256 "${TMP_DIR}/${SHERPA_ASSET}" "${SHERPA_SHA256}"

echo "Extracting ${SHERPA_ASSET} ..."
tar xjf "${TMP_DIR}/${SHERPA_ASSET}" -C "${TMP_DIR}"

EXTRACTED_DIR="${TMP_DIR}/sherpa-onnx-${SHERPA_VERSION}-macos-xcframework-static"
SRC_XCFW="${EXTRACTED_DIR}/sherpa-onnx.xcframework"
if [[ ! -d "${SRC_XCFW}" ]]; then
  echo "Error: expected ${SRC_XCFW} not found." >&2
  exit 1
fi

echo "Downloading ${ORT_URL} ..."
curl -fL --retry 3 --retry-delay 2 -o "${TMP_DIR}/${ORT_ASSET}" "${ORT_URL}"
verify_sha256 "${TMP_DIR}/${ORT_ASSET}" "${ORT_SHA256}"

echo "Extracting ${ORT_ASSET} ..."
unzip -q "${TMP_DIR}/${ORT_ASSET}" -d "${TMP_DIR}/onnxruntime"

ORT_LIB="$(find "${TMP_DIR}/onnxruntime" -name 'libonnxruntime.a' -print -quit)"
if [[ -z "${ORT_LIB}" ]]; then
  echo "Error: libonnxruntime.a not found inside ${ORT_ASSET}." >&2
  exit 1
fi

# Replace the xcframework in DEST_ROOT with a fresh copy and merge libs.
rm -rf "${XCFRAMEWORK_PATH}"
mv "${SRC_XCFW}" "${XCFRAMEWORK_PATH}"

SHERPA_LIB="${ARCH_DIR}/libsherpa-onnx.a"
COMBINED_LIB="${TMP_DIR}/libsherpa-onnx-combined.a"
echo "Merging libsherpa-onnx.a + libonnxruntime.a into ${SHERPA_LIB} ..."
libtool -static -o "${COMBINED_LIB}" "${SHERPA_LIB}" "${ORT_LIB}"
mv "${COMBINED_LIB}" "${SHERPA_LIB}"

cat > "${MODULE_MAP_PATH}" <<'EOF'
module SherpaOnnx {
    header "sherpa-onnx/c-api/c-api.h"
    export *
}
EOF

touch "${COMBINED_STAMP}"
echo "sherpa-onnx.xcframework (with onnxruntime) ready at ${XCFRAMEWORK_PATH}"
