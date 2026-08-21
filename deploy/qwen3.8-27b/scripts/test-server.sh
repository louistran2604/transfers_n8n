#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_DIR}"

MODEL_ALIAS="${MODEL_ALIAS:-qwen3.8-27b}"
BASE_URL="${LLAMA_BASE_URL:-http://127.0.0.1:8081}"
IDLE_WAIT_SECONDS="${IDLE_WAIT_SECONDS:-35}"
MIN_VRAM_HEADROOM_MIB="${MIN_VRAM_HEADROOM_MIB:-512}"

for command_name in curl docker jq node nvidia-smi; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    printf 'Required command not found: %s\n' "${command_name}" >&2
    exit 1
  fi
done

now_milliseconds() {
  date +%s%3N
}

wait_for_health() {
  local attempts=120
  local status

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    status="$(docker inspect \
      --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' \
      transfers-llama 2>/dev/null || true
    )"
    if [[ "${status}" == "healthy" ]]; then
      return 0
    fi
    if [[ "${status}" == "unhealthy" ]]; then
      docker compose logs --tail=200 llama >&2
      printf 'Container became unhealthy.\n' >&2
      return 1
    fi
    sleep 5
  done

  docker compose logs llama >&2
  printf 'Timed out waiting 600 seconds for a healthy container.\n' >&2
  return 1
}

llama_vram_mib() {
  nvidia-smi \
    --query-compute-apps=process_name,used_memory \
    --format=csv,noheader,nounits |
    awk -F, '/llama-server/ {gsub(/[[:space:]]/, "", $2); total += $2} END {print total + 0}'
}

gpu_total_mib() {
  nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -n 1 | tr -d ' '
}

gpu_free_mib() {
  nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | head -n 1 | tr -d ' '
}

check_no_reasoning() {
  local response="$1"
  if ! jq -e '[.. | objects | keys[]? | select(test("reasoning|thinking"; "i"))] | length == 0' <<<"${response}" >/dev/null; then
    printf 'Reasoning/thinking fields leaked into the API response.\n' >&2
    return 1
  fi
  if ! jq -e '[.choices[]?.message?.content? // empty] | all(test("<\\/?think>|<\\|(?:thinking|reasoning)[^|]*\\|>"; "i") | not)' <<<"${response}" >/dev/null; then
    printf 'Reasoning/thinking tags leaked into message.content.\n' >&2
    return 1
  fi
}

check_gpu_offload() {
  local container_command
  local logs
  local llama_vram
  local model_file_mib
  local minimum_model_vram
  local gpu_total
  local gpu_free

  logs="$(docker compose logs llama)"
  if grep -Eiq 'out of memory|cuda[^[:space:]]* error|failed to allocate' <<<"${logs}"; then
    printf 'CUDA allocation or out-of-memory error found in llama logs.\n' >&2
    return 1
  fi
  if grep -Eiq 'offload(ed)?[^[:alnum:]]*(cpu|host)|cpu[^[:alnum:]]*offload' <<<"${logs}"; then
    printf 'llama-server reported CPU layer offload.\n' >&2
    return 1
  fi

  container_command="$(docker inspect transfers-llama --format '{{json .Config.Cmd}}')"
  if ! jq -e '
    (index("--gpu-layers") // -1) as $index |
    $index >= 0 and .[$index + 1] == "all"
  ' <<<"${container_command}" >/dev/null; then
    printf 'The running container is not configured with --gpu-layers all.\n' >&2
    return 1
  fi

  llama_vram="$(llama_vram_mib)"
  model_file_mib="$(( $(stat -c '%s' "${PROJECT_DIR}/models/Qwen3.8-27B-UD-Q3_K_XL.gguf") / 1048576 ))"
  minimum_model_vram="$(( model_file_mib * 90 / 100 ))"
  gpu_total="$(gpu_total_mib)"
  gpu_free="$(gpu_free_mib)"
  if [[ -z "${llama_vram}" || "${llama_vram}" -lt "${minimum_model_vram}" ]]; then
    printf 'llama-server GPU residency is too low: %s MiB (GGUF=%s MiB, minimum=%s MiB).\n' \
      "${llama_vram:-0}" "${model_file_mib}" "${minimum_model_vram}" >&2
    return 1
  fi
  if (( gpu_total < 15000 )); then
    printf 'Expected a 16 GB-class GPU, found %s MiB total.\n' "${gpu_total}" >&2
    return 1
  fi
  if (( gpu_free < MIN_VRAM_HEADROOM_MIB )); then
    printf 'Insufficient VRAM headroom: %s MiB free, need at least %s MiB.\n' \
      "${gpu_free}" "${MIN_VRAM_HEADROOM_MIB}" >&2
    return 1
  fi

  printf 'GPU residency confirmed: llama-server=%s MiB, GGUF=%s MiB, GPU total=%s MiB, headroom=%s MiB.\n' \
    "${llama_vram}" "${model_file_mib}" "${gpu_total}" "${gpu_free}"
}

check_models() {
  local models_response
  local legacy_alias
  legacy_alias="qwen3.$(printf '6')-27b"
  models_response="$(curl --fail --silent --show-error "${BASE_URL}/v1/models")"
  jq -e --arg alias "${MODEL_ALIAS}" '[.data[]?.id] | index($alias) != null' <<<"${models_response}" >/dev/null
  if jq -e --arg legacy_alias "${legacy_alias}" '[.data[]?.id // empty | select(. == $legacy_alias)] | length > 0' <<<"${models_response}" >/dev/null; then
    printf 'Obsolete legacy alias exposed by /v1/models.\n' >&2
    return 1
  fi
  printf '/v1/models exposes %s and no obsolete alias.\n' "${MODEL_ALIAS}"
}

printf '1/7 Validating Compose, GPU access, health, and network binding...\n'
docker compose config --quiet
service_image="$(docker compose config --images | head -n 1)"
docker run --rm --pull=never --gpus all "${service_image}" --list-devices
wait_for_health

published_port="$(docker port transfers-llama 8080/tcp)"
if [[ "${published_port}" != "127.0.0.1:8081" ]]; then
  printf 'Unsafe or unexpected port binding: %s\n' "${published_port}" >&2
  exit 1
fi
curl --fail --silent --show-error "${BASE_URL}/health" | jq -e '.status == "ok"'
docker run \
  --rm \
  --pull=never \
  --network transfers_net \
  --entrypoint curl \
  "${service_image}" \
  --fail \
  --silent \
  --show-error \
  http://llama:8080/health |
  jq -e '.status == "ok"'
check_models

printf '2/7 Confirming full GPU offload, VRAM headroom, and absence of OOM errors...\n'
warmup_response="$(
  curl \
    --fail \
    --silent \
    --show-error \
    --header 'Content-Type: application/json' \
    --data-binary @- \
    "${BASE_URL}/v1/chat/completions" <<JSON
{
  "model": "${MODEL_ALIAS}",
  "messages": [
    {"role": "user", "content": "Reply with the single word ready."}
  ],
  "max_tokens": 1,
  "temperature": 0
}
JSON
)"
jq -e '.choices[0].message.content | type == "string" and length > 0' <<<"${warmup_response}" >/dev/null
check_no_reasoning "${warmup_response}"
check_gpu_offload

printf '3/7 Testing the OpenAI-compatible chat endpoint with reasoning disabled...\n'
basic_started="$(now_milliseconds)"
basic_response="$(
  curl \
    --fail \
    --silent \
    --show-error \
    --header 'Content-Type: application/json' \
    --data-binary @- \
    "${BASE_URL}/v1/chat/completions" <<JSON
{
  "model": "${MODEL_ALIAS}",
  "messages": [
    {"role": "user", "content": "Reply with the single word ready."}
  ],
  "max_tokens": 16,
  "temperature": 0
}
JSON
)"
jq -e '.choices[0].message.content | type == "string" and length > 0' <<<"${basic_response}" >/dev/null
check_no_reasoning "${basic_response}"
basic_finished="$(now_milliseconds)"
printf 'Basic completion succeeded in %sms.\n' "$((basic_finished - basic_started))"

printf '4/7 Running the real-schema extraction regression corpus...\n'
LLAMA_BASE_URL="${BASE_URL}" MODEL_ALIAS="${MODEL_ALIAS}" node "${PROJECT_DIR}/scripts/test-extraction.mjs"

printf '5/7 Verifying the 30-second idle unload and structured reload...\n'
loaded_vram="$(llama_vram_mib)"
printf 'Loaded model VRAM before idle wait: %s MiB. Waiting %s seconds...\n' "${loaded_vram}" "${IDLE_WAIT_SECONDS}"
sleep "${IDLE_WAIT_SECONDS}"
idle_vram="$(llama_vram_mib)"
printf 'Idle model VRAM after unload wait: %s MiB.\n' "${idle_vram}"
if (( idle_vram >= loaded_vram - 1024 )); then
  printf 'Model did not unload after %s seconds: before=%s MiB after=%s MiB.\n' \
    "${IDLE_WAIT_SECONDS}" "${loaded_vram}" "${idle_vram}" >&2
  exit 1
fi
reload_started="$(now_milliseconds)"
EXTRACTION_FIXTURE_ID="official_confirmed" LLAMA_BASE_URL="${BASE_URL}" MODEL_ALIAS="${MODEL_ALIAS}" \
  node "${PROJECT_DIR}/scripts/test-extraction.mjs"
reload_finished="$(now_milliseconds)"
reload_vram="$(llama_vram_mib)"
printf 'Structured reload succeeded in %sms; model VRAM after reload: %s MiB.\n' \
  "$((reload_finished - reload_started))" "${reload_vram}"
check_gpu_offload

printf '6/7 Checking logs for CUDA errors or leaked thinking markers...\n'
final_logs="$(docker compose logs llama)"
if grep -Eiq 'out of memory|cuda[^[:space:]]* error|failed to allocate|</?think>|<\|(thinking|reasoning)[^|]*\|>' <<<"${final_logs}"; then
  printf 'Unsafe CUDA or reasoning marker found in llama logs.\n' >&2
  exit 1
fi

printf '7/7 Reporting steady-state GPU usage and runtime evidence...\n'
printf 'Model VRAM: %s MiB; available headroom: %s MiB.\n' "$(llama_vram_mib)" "$(gpu_free_mib)"
nvidia-smi \
  --query-compute-apps=pid,process_name,used_memory \
  --format=csv,noheader
nvidia-smi \
  --query-gpu=name,memory.total,memory.used,memory.free \
  --format=csv,noheader

printf 'All llama.cpp service and Qwen3.8 extraction tests passed.\n'
