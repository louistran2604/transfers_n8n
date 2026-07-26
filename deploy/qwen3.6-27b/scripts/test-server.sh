#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_DIR}"

for command_name in curl docker jq nvidia-smi; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    printf 'Required command not found: %s\n' "${command_name}" >&2
    exit 1
  fi
done

wait_for_health() {
  local attempts=120
  local status

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    status="$(
      docker inspect \
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

  docker compose logs --tail=200 llama >&2
  printf 'Timed out waiting 600 seconds for a healthy container.\n' >&2
  return 1
}

check_gpu_offload() {
  local container_command
  local logs
  local llama_vram_mib

  logs="$(docker compose logs llama)"
  if grep -Eiq 'out of memory|cuda[^[:space:]]* error|failed to allocate' <<<"${logs}"; then
    printf 'CUDA allocation or out-of-memory error found in llama logs.\n' >&2
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

  llama_vram_mib="$(
    nvidia-smi \
      --query-compute-apps=process_name,used_memory \
      --format=csv,noheader,nounits |
      awk -F, '/llama-server/ {gsub(/ /, "", $2); print $2; exit}'
  )"
  if [[ -z "${llama_vram_mib}" || "${llama_vram_mib}" -lt 10000 ]]; then
    printf 'llama-server GPU residency is too low: %s MiB.\n' "${llama_vram_mib:-0}" >&2
    return 1
  fi

  printf 'GPU offload confirmed: all layers requested; llama-server uses %s MiB VRAM.\n' \
    "${llama_vram_mib}"
}

printf '1/5 Validating Compose, GPU access, health, and network binding...\n'
docker compose config --quiet
service_image="$(docker compose config --images | head -n 1)"
docker run --rm --pull=never --gpus all "${service_image}" --list-devices
wait_for_health

published_port="$(docker port transfers-llama 8080/tcp)"
if [[ "${published_port}" != "127.0.0.1:8081" ]]; then
  printf 'Unsafe or unexpected port binding: %s\n' "${published_port}" >&2
  exit 1
fi
curl --fail --silent --show-error http://127.0.0.1:8081/health | jq -e '.status == "ok"'
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

printf '2/5 Confirming full GPU offload and absence of OOM errors...\n'
check_gpu_offload

printf '3/5 Testing the OpenAI-compatible chat endpoint...\n'
basic_response="$(
  curl \
    --fail \
    --silent \
    --show-error \
    --header 'Content-Type: application/json' \
    --data-binary @- \
    http://127.0.0.1:8081/v1/chat/completions <<'JSON'
{
  "model": "qwen3.6-27b",
  "messages": [
    {
      "role": "user",
      "content": "Reply with the single word ready."
    }
  ],
  "max_tokens": 16,
  "temperature": 0
}
JSON
)"
jq -e '.choices[0].message.content | type == "string" and length > 0' <<<"${basic_response}"

printf '4/5 Testing schema-constrained football-transfer JSON...\n'
schema_response="$(
  curl \
    --fail \
    --silent \
    --show-error \
    --header 'Content-Type: application/json' \
    --data-binary @- \
    http://127.0.0.1:8081/v1/chat/completions <<'JSON'
{
  "model": "qwen3.6-27b",
  "messages": [
    {
      "role": "system",
      "content": "Extract football transfer information. Return only the requested JSON object. Fees and add-ons are numeric values in millions."
    },
    {
      "role": "user",
      "content": "Manchester United have reached an agreement to sign Example Player from Example FC for €50m plus €5m in add-ons. Medical scheduled tomorrow."
    }
  ],
  "response_format": {
    "type": "json_schema",
    "json_schema": {
      "name": "football_transfer",
      "strict": true,
      "schema": {
        "type": "object",
        "properties": {
          "transfer_related": {"type": "boolean"},
          "status": {"type": "string"},
          "player": {"type": "string"},
          "current_club": {"type": "string"},
          "destination_club": {"type": "string"},
          "transfer_type": {"type": "string"},
          "fee": {"type": "number"},
          "currency": {"type": "string"},
          "addons": {"type": "number"},
          "medical_status": {"type": "string"},
          "confidence": {"type": "number", "minimum": 0, "maximum": 1}
        },
        "required": [
          "transfer_related",
          "status",
          "player",
          "current_club",
          "destination_club",
          "transfer_type",
          "fee",
          "currency",
          "addons",
          "medical_status",
          "confidence"
        ],
        "additionalProperties": false
      }
    }
  },
  "max_tokens": 2048,
  "temperature": 0
}
JSON
)"
structured_content="$(jq -er '.choices[0].message.content' <<<"${schema_response}")"
jq -e '
  type == "object" and
  (.transfer_related | type == "boolean") and
  (.status | type == "string") and
  (.player | type == "string") and
  (.current_club | type == "string") and
  (.destination_club | type == "string") and
  (.transfer_type | type == "string") and
  (.fee | type == "number") and
  (.currency | type == "string") and
  (.addons | type == "number") and
  (.medical_status | type == "string") and
  (.confidence | type == "number" and . >= 0 and . <= 1)
' <<<"${structured_content}"
printf '%s\n' "${structured_content}" | jq .

printf '5/5 Showing VRAM, restarting, and checking health again...\n'
nvidia-smi \
  --query-compute-apps=pid,process_name,used_memory \
  --format=csv,noheader
nvidia-smi \
  --query-gpu=name,memory.total,memory.used,memory.free \
  --format=csv,noheader
docker compose restart llama
wait_for_health
curl --fail --silent --show-error http://127.0.0.1:8081/health | jq -e '.status == "ok"'
check_gpu_offload

printf 'All llama.cpp service tests passed.\n'
