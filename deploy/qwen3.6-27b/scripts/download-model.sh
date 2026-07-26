#!/usr/bin/env bash
set -Eeuo pipefail

MODEL_REPOSITORY="unsloth/Qwen3.6-27B-GGUF"
MODEL_FILE="Qwen3.6-27B-UD-IQ3_XXS.gguf"
EXPECTED_SHA256="5d591dd11918e196a7b7c9d2f02e4390e7264960eb354c72d65e81a9331978f5"
MODEL_URL="https://huggingface.co/${MODEL_REPOSITORY}/resolve/main/${MODEL_FILE}"

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

