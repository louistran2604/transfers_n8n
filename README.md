# Football Transfer Monitor

A self-hosted project for collecting football transfer reports, comparing
sources, and publishing a Discord digest every six hours.

The aim is to reduce a busy transfer-news cycle into a short digest that keeps
the useful details and links back to every source. Official club accounts are
preferred first, followed by David Ornstein and Fabrizio Romano when many
people report the same story.

## Current status

This repository is still being built. It currently contains:

- the n8n and external task-runner deployment;
- a local Qwen3.6-27B service powered by llama.cpp;
- the journalist and organization source list;
- RapidAPI response samples for workflow development; and
- a PostgreSQL persistence layer with restart-safe deduplication.

The importable n8n workflow is not finished yet.

## Planned workflow

Every six hours, n8n will:

1. collect recent posts from the configured X accounts;
2. identify and classify transfer-related reports;
3. merge reports about the same transfer while retaining all sources;
4. store processed reports in PostgreSQL; and
5. send up to 15 new stories to Discord.

The digest will distinguish confirmed transfers, advanced negotiations,
rumours, failed moves, renewals, and loans. It will include the transfer terms,
player details, source links, and a confidence level.

## Repository layout

```text
deploy/
  n8n/             n8n and task-runner containers
  qwen3.6-27b/     llama.cpp model service
  support/         PostgreSQL deployment
database/          PostgreSQL schema
workflow/          importable n8n workflow
docs/              source registry and RapidAPI samples
```

Some directories are currently empty and will appear in Git once their
components are added.

## Local services

All containers that need to communicate join the external Docker network
`transfers_net`:

```bash
docker network create transfers_net
```

The n8n deployment lives in `deploy/n8n/`. Its local `.env` supplies the
RapidAPI key, Discord webhooks, and runner token.

The model service lives in `deploy/qwen3.6-27b/`. From the host it listens on
`http://127.0.0.1:8081`; from another container on `transfers_net`, it is
available at `http://llama:8080`. See its own README for download, startup,
and test commands.

## Secrets and generated data

Real credentials stay in local `.env` files and must never be committed.
Downloaded GGUF models, PostgreSQL data, logs, test results, and Compose backup
files are also ignored.

Before every commit, check:

```bash
git status --short --ignored
```

Files beginning with `!!` are ignored. Confirm that `.env`, `models/`, and
other runtime data remain in that group.
