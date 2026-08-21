#!/usr/bin/env bash
set -Eeuo pipefail

MODEL_REPOSITORY="unsloth/Qwen3.8-27B-GGUF"
MODEL_REVISION="f975863083b62f54a5e6fac11671c750c2bbc59c"
MODEL_FILE="Qwen3.8-27B-UD-Q3_K_XL.gguf"
EXPECTED_SHA256="00cf92e666c6af6566996c38c89a44ccdb6449ea25ef0f112a452c853b2a71e2"
MODEL_URL="https://huggingface.co/${MODEL_REPOSITORY}/resolve/${MODEL_REVISION}/${MODEL_FILE}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
MODEL_DIR="${PROJECT_DIR}/models"
MODEL_PATH="${MODEL_DIR}/${MODEL_FILE}"
PARTIAL_PATH="${MODEL_PATH}.part"

checksum() {
  sha256sum "$1" | awk '{print $1}'
}

mkdir -p "${MODEL_DIR}"

if [[ -f "${MODEL_PATH}" ]]; then
  actual_sha256="$(checksum "${MODEL_PATH}")"
  if [[ "${actual_sha256}" == "${EXPECTED_SHA256}" ]]; then
    printf 'Model already verified: %s\n' "${MODEL_PATH}"
    exit 0
  fi

  printf 'Checksum mismatch for existing model: %s\n' "${MODEL_PATH}" >&2
  printf 'Expected: %s\nActual:   %s\n' "${EXPECTED_SHA256}" "${actual_sha256}" >&2
  printf 'Move or delete the invalid file, then run this script again.\n' >&2
  exit 1
fi

printf 'Downloading %s to %s\n' "${MODEL_FILE}" "${PARTIAL_PATH}"
curl \
  --fail \
  --location \
  --continue-at - \
  --retry 5 \
  --retry-all-errors \
  --connect-timeout 30 \
  --output "${PARTIAL_PATH}" \
  "${MODEL_URL}"

actual_sha256="$(checksum "${PARTIAL_PATH}")"
if [[ "${actual_sha256}" != "${EXPECTED_SHA256}" ]]; then
  printf 'Downloaded model checksum mismatch: %s\n' "${PARTIAL_PATH}" >&2
  printf 'Expected: %s\nActual:   %s\n' "${EXPECTED_SHA256}" "${actual_sha256}" >&2
  exit 1
fi

mv "${PARTIAL_PATH}" "${MODEL_PATH}"
printf 'Model downloaded and verified: %s\n' "${MODEL_PATH}"
