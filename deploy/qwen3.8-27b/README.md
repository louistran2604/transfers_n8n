# llama.cpp service for n8n transfer extraction

This Compose project runs the production extraction model **Qwen3.8-27B** from
the Unsloth **UD-Q3_K_XL** GGUF through the official llama.cpp CUDA 12 server.
Reasoning is disabled and the extraction context is fixed at 8192 tokens. The
host API is available only on localhost; containers on `transfers_net` use the
`llama` hostname.

Expected project directory:

```bash
cd ~/projects/transfers_n8n/deploy/qwen3.8-27b
```

## Pinned runtime and model

The deployment uses this immutable amd64 image reference:

```text
ghcr.io/ggml-org/llama.cpp:server-cuda12-b10524@sha256:9810cc5f409cbebb6412ee351190698b381aa0261fa96ea150738094bde1269d
```

It contains llama-server build `10524`, source commit
`9ee9fc04c136ef2ae729bfc60d18961b23c13ddf`, and CUDA 12.8.1. The official
multi-architecture manifest for the same build is
`sha256:ea610f2c82d033b6765b24fa7c0ab15c267d564f883de7c494f1e3073d496374`.
The platform-specific digest is used in `compose.yaml` because production runs
on the Linux amd64 RTX host.

Before changing the pin, verify the exact image locally:

```bash
docker pull --platform linux/amd64 \
  ghcr.io/ggml-org/llama.cpp:server-cuda12-b10524@sha256:9810cc5f409cbebb6412ee351190698b381aa0261fa96ea150738094bde1269d
docker run --rm --pull=never \
  ghcr.io/ggml-org/llama.cpp:server-cuda12-b10524@sha256:9810cc5f409cbebb6412ee351190698b381aa0261fa96ea150738094bde1269d \
  --version
docker run --rm --pull=never \
  ghcr.io/ggml-org/llama.cpp:server-cuda12-b10524@sha256:9810cc5f409cbebb6412ee351190698b381aa0261fa96ea150738094bde1269d \
  --help | grep -E -- '--(ctx-size|n-predict|flash-attn|cache-type-k|cache-type-v|gpu-layers|parallel|fit|fit-target|reasoning|sleep-idle-seconds)'
```

The selected build reports all configured arguments and maps the GGUF
`qwen35` architecture used by Qwen3.8.

The downloader is pinned to the immutable Hugging Face revision
`f975863083b62f54a5e6fac11671c750c2bbc59c` because the repository's current
`main` revision has since replaced the same filename. The configured file is
`models/Qwen3.8-27B-UD-Q3_K_XL.gguf` and must have this SHA-256:

```text
00cf92e666c6af6566996c38c89a44ccdb6449ea25ef0f112a452c853b2a71e2
```

The file is ignored by Git and is never part of a commit.

## 1. Prerequisite checks

Required host commands are Docker, Docker Compose, `curl`, `jq`, `sha256sum`,
Node.js 20+, and `nvidia-smi`.

```bash
docker version
docker compose version
nvidia-smi
docker network inspect transfers_net
ss -ltn '( sport = :8081 )'
```

Confirm Docker can pass the GPU into the pinned image:

```bash
docker compose config --images
docker run --rm --pull=never --gpus all \
  "$(docker compose config --images | head -n 1)" --list-devices
```

The service requires the existing external network `transfers_net`; Compose
does not create it. Port 8081 must be free.

## 2. Download the model

The model is public and requires no Hugging Face token:

```bash
./scripts/download-model.sh
```

The script uses resumable curl downloads and `.part` handling. It verifies the
expected SHA before accepting an existing file or moving a completed download
into place. A bad existing file is refused rather than silently reused.

## 3. Start, stop, and inspect logs

```bash
docker compose config
docker compose up -d
docker compose ps
docker compose logs -f llama
```

The defaults preserve the proven extraction configuration:

```text
--sleep-idle-seconds 30
--ctx-size 8192
--gpu-layers all
--flash-attn on
--cache-type-k q8_0
--cache-type-v q8_0
--parallel 1
--fit on
--fit-target 1024
--n-predict 2048
--reasoning off
```

No MTP or speculative decoding is enabled. The container remains running while
llama.cpp unloads the model and KV cache after 30 idle seconds. A new request
reloads the model without Docker-control permissions. The service remains
offline, has no web UI, publishes only `127.0.0.1:8081`, and keeps the existing
health check, security restrictions, `transfers_net`, and `llama` network alias.

## 4. Health, GPU, and VRAM checks

```bash
curl --fail http://127.0.0.1:8081/health
docker inspect transfers-llama --format '{{json .Config.Cmd}}' | jq
nvidia-smi
```

`./scripts/test-server.sh` reports the actual llama-server VRAM use, total GPU
memory, available headroom on the 16 GB RTX 5060 Ti, basic completion timing,
schema-regression timing, and structured reload timing. It verifies the running
`--gpu-layers all` command, rejects CPU-offload/CUDA/OOM log evidence, and
requires llama-server VRAM to remain at least 90% of the GGUF size. It fails if
VRAM headroom is too small or the 30-second unload/reload cycle does not work.

## 5. Extraction regression corpus

The deterministic corpus in `tests/extraction-fixtures.json` covers non-transfer
posts, rumors, negotiations, official moves, failures, loans, renewals, fees,
release clauses, nulls, quotes, multiple reports, ambiguous surnames, aliases,
women's-football exclusion, and adversarial wording. Each case is sent to
Qwen3.8 with the real `workflow/qwen-response-schema.json`. The test validates
the schema, important semantic fields, and the absence of reasoning fields or
thinking tags.

Run the corpus directly after the service is healthy:

```bash
LLAMA_BASE_URL=http://127.0.0.1:8081 MODEL_ALIAS=qwen3.8-27b \
  node scripts/test-extraction.mjs
```

## 6. API and n8n endpoints

```text
Host health/API: http://127.0.0.1:8081
n8n chat endpoint: http://llama:8080/v1/chat/completions
Model alias: qwen3.8-27b
```

In n8n, set the OpenAI-compatible base URL to `http://llama:8080/v1` and use
`qwen3.8-27b`. No API key is required while access remains limited to
localhost and `transfers_net`.

## Updating the pinned llama.cpp version

llama.cpp publishes rolling build tags. For an upgrade:

1. Choose an official `server-cuda12-bNNNNN` build from the `ggml-org/llama.cpp`
   GitHub Container Registry package.
2. Pull its immutable platform digest and run `--version`, `--help`, and
   `--list-devices`.
3. Confirm every configured argument still exists, including `--reasoning off`
   and `--sleep-idle-seconds`.
4. Run the full schema corpus and `./scripts/test-server.sh` before changing
   the Compose pin.

Never replace the pinned reference with `latest` or an unversioned tag. Do not
enable MTP/speculative decoding as part of a plain model migration.

## Troubleshooting

- CUDA: if no CUDA device appears, check `nvidia-smi`, Docker's NVIDIA runtime,
  the NVIDIA Container Toolkit, the driver's CUDA compatibility, and
  `docker run --gpus all`.
- Networking: verify `transfers_net` exists and n8n is attached. Inside that
  network use `llama:8080`, never the host-only `127.0.0.1:8081` address.
- Checksum: a mismatch leaves the invalid file or `.part` file in place. Move
  only that bad model file and rerun the downloader.
- Out of memory: stop other GPU workloads first, inspect llama logs and
  `nvidia-smi`, and do not accept CPU layer offload as a workaround.
- Unhealthy container: run `docker compose logs --tail=200 llama`. HTTP 503
  means the model is still loading; CUDA allocation errors must be fixed before
  restarting.

The published port is deliberately bound to `127.0.0.1`, not `0.0.0.0`, and
browser CORS is restricted to localhost. Authentication and TLS are required
before any public exposure. Do not add a public port binding without both
controls.
