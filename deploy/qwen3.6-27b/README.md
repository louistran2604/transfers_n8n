# llama.cpp service for n8n transfer extraction

This Compose project runs Qwen3.6-27B through the official llama.cpp CUDA
server. The host API is available only on localhost. Containers attached to
the existing `transfers_net` network use the `llama` hostname.

Expected project directory:

```bash
cd ~/projects/transfers_n8n/deploy/qwen3.6-27b
```

## 1. Prerequisite checks

Required host commands are Docker, Docker Compose, `curl`, `jq`,
`sha256sum`, and `nvidia-smi`.

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

The model is public and requires no Hugging Face token.

```bash
./scripts/download-model.sh
```

The script downloads
`models/Qwen3.6-27B-UD-IQ3_XXS.gguf`, resumes an interrupted `.part`
download, and verifies:

```text
5d591dd11918e196a7b7c9d2f02e4390e7264960eb354c72d65e81a9331978f5
```

An already verified model is never downloaded again.

## 3. Start, stop, and inspect logs

The defaults work without a `.env` file. To make local overrides explicit:

```bash
cp .env.example .env
docker compose config
docker compose up -d
```

Common lifecycle commands:

```bash
docker compose ps
docker compose logs -f llama
docker compose restart llama
docker compose stop
docker compose down
```

`docker compose down` removes the container but leaves `models/` untouched,
so restarting never requires another model download.

## 4. Health, GPU, and VRAM checks

Wait for the model to finish loading:

```bash
docker compose ps
curl --fail http://127.0.0.1:8081/health
```

A ready server returns `{"status":"ok"}`. During loading, `/health` returns
HTTP 503. Confirm the logs contain a full `offloaded N/N layers to GPU`
message and no CUDA allocation error:

```bash
docker compose logs llama | grep -E \
  'offloaded [0-9]+/[0-9]+ layers to GPU|out of memory|failed to allocate'
nvidia-smi
```

The configuration uses an 8192-token context, q8_0 K/V caches, one parallel
slot, Flash Attention, all GPU layers, fit-to-VRAM, and a 1024 MiB target
margin. The server limits generation to 2048 tokens. Thinking is disabled
because extraction needs schema-constrained output.

## 5. Test host, Docker-network, and OpenAI endpoints

Host health:

```bash
curl --fail http://127.0.0.1:8081/health
```

Health from a temporary container on `transfers_net`:

```bash
docker run --rm --pull=never --network transfers_net \
  --entrypoint curl "$(docker compose config --images | head -n 1)" \
  --fail http://llama:8080/health
```

Run the complete acceptance test, including OpenAI chat, schema-constrained
football-transfer JSON, GPU offload, VRAM reporting, and restart recovery:

```bash
./scripts/test-server.sh
```

The API endpoints are:

```text
Host: http://127.0.0.1:8081/v1/chat/completions
n8n: http://llama:8080/v1/chat/completions
```

In n8n, set the OpenAI-compatible base URL to `http://llama:8080/v1`.
Use model name `qwen3.6-27b`. No API key is required while access remains
limited to localhost and `transfers_net`.

## Updating the pinned llama.cpp version

llama.cpp uses rolling build tags. Test upgrades instead of using a floating
tag:

1. Choose an official `server-cuda12-bNNNNN` release from the
   `ggml-org/llama.cpp` GitHub Container Registry package.
2. Pull its immutable digest and run both `--version` and `--help`.
3. Confirm every configured argument still exists, then update the complete
   tag-and-digest reference in `compose.yaml` and `.env.example`.
4. Run `docker compose config`, recreate the service, and run
   `./scripts/test-server.sh`.

Never replace the pinned reference with `latest` or an unversioned
`server-cuda` tag.

## Replacing the model

Place the replacement GGUF in `models/`, verify its publisher-provided
SHA-256, and set `MODEL_FILE` and `MODEL_ALIAS` in `.env`. The supplied
download script intentionally remains locked to the documented Qwen3.6 file
and checksum. Re-run the full test because quantization and context size
change VRAM use.

## Troubleshooting

- CUDA: if no CUDA device appears, check `nvidia-smi`, Docker's `nvidia`
  runtime, NVIDIA Container Toolkit, and `docker run --gpus all`.
- Networking: verify `transfers_net` exists and n8n is attached. Inside that
  network use `llama:8080`, never the host-only `127.0.0.1:8081` address.
- Checksum: a mismatch leaves the invalid file or `.part` file in place.
  Inspect it, remove only that bad file, and rerun the download script.
- Out of memory: stop other GPU workloads first. Then inspect llama logs and
  `nvidia-smi`; reducing context size is the first configuration change.
- Unhealthy container: run `docker compose logs --tail=200 llama`. HTTP 503
  means the model is still loading; CUDA allocation errors require addressing
  VRAM before restarting.

The published port is deliberately bound to `127.0.0.1`, not `0.0.0.0`, and
browser CORS is restricted to localhost. Authentication and TLS are required
before any public exposure. Do not add a public port binding without both
controls.
