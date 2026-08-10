#!/usr/bin/env sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
image=n8n-ftm-sofascore-enrichment:local
run_id="m7-sofascore-smoke-$$"
container="transfers-$run_id"
restart_container="transfers-$run_id-restart"
cache_volume="transfers_${run_id}_cache"

cleanup() {
  docker rm -f "$container" "$restart_container" >/dev/null 2>&1 || true
  docker volume rm "$cache_volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

required_env="N8N_RUNNERS_AUTH_TOKEN=test X_COLLECTOR=twscrape TWSCRAPE_AUTH_TOKEN=test TWSCRAPE_CT0=test DISCORD_TRANSFERS_WEBHOOK_URL=http://example.invalid/transfers DISCORD_ERRORS_WEBHOOK_URL=http://example.invalid/errors PLAYER_ENRICHMENT_MODE=off"
compose_json=$(env $required_env docker compose \
  -f "$root_dir/deploy/n8n/compose.yaml" \
  --profile enrichment \
  config --format json)
printf '%s' "$compose_json" | python3 -c '
import json
import sys
service = json.load(sys.stdin)["services"]["sofascore-enrichment"]
assert not service.get("ports")
assert set(service["networks"]) == {"transfers_net"}
assert service["cpus"] == 1
assert service["mem_limit"] == "1073741824"
assert "n8n" not in service.get("depends_on", {})
'

docker run --rm --network none --entrypoint python "$image" -c '
import hashlib
import importlib.metadata
import os
from tls_requests import TLSLibrary
path = os.environ["TLS_LIBRARY_PATH"]
assert importlib.metadata.version("soccerdata") == "1.9.1"
assert hashlib.sha256(open(path, "rb").read()).hexdigest() == "3f9bf4a741002b1d57043571d69e6ebe8f1df416aa1ca9ca9766dba36e4d4941"
assert TLSLibrary.load() is not None
'

if docker run --rm --network none --read-only --entrypoint python "$image" -c '
from pathlib import Path
from app import RuntimeChecks
try:
    RuntimeChecks(Path("/proc/sofascore-cache")).run()
except OSError:
    raise SystemExit(1)
raise SystemExit(0)
'; then
  echo "Unwritable cache was not rejected" >&2
  exit 1
fi

start_service() {
  name=$1
  docker run -d \
    --name "$name" \
    --network none \
    --read-only \
    --tmpfs /tmp \
    --cpus 1 \
    --memory 1g \
    -e PLAYER_ENRICHMENT_MODE=off \
    -v "$cache_volume:/data/soccerdata" \
    "$image" >/dev/null

  attempts=0
  until docker exec "$name" python -c \
    "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/readyz', timeout=2).close()" \
    >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 30 ]; then
      docker logs "$name"
      echo "Sofascore service did not become ready offline" >&2
      exit 1
    fi
    sleep 1
  done
  docker exec "$name" python -c \
    "import json, urllib.request; payload=json.load(urllib.request.urlopen('http://127.0.0.1:8080/healthz', timeout=2)); assert payload['status'] == 'ok'; assert payload['soccerdata_version'] == '1.9.1'"
}

start_service "$container"

test "$(docker exec "$container" id -u)" = "10001"
test "$(docker inspect --format '{{json .NetworkSettings.Ports}}' "$container")" = "{}"
test "$(docker inspect --format '{{.HostConfig.NanoCpus}}' "$container")" = "1000000000"
test "$(docker inspect --format '{{.HostConfig.Memory}}' "$container")" = "1073741824"

cold_stats=$(docker stats --no-stream --format '{{.CPUPerc}} {{.MemUsage}}' "$container")
docker exec "$container" sh -c 'printf smoke > /data/soccerdata/smoke-sentinel'

docker exec "$container" python -c '
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from adapter import SofascoreAdapter
from tests.fixture_transport import FixtureTransport

class MeasuredFixtureTransport(FixtureTransport):
    def get(self, *args, **kwargs):
        time.sleep(0.02)
        return super().get(*args, **kwargs)

cache = Path("/data/soccerdata")
transport = MeasuredFixtureTransport(Path("/app/tests/fixtures"))
adapter = SofascoreAdapter(
    transport,
    cache,
    min_interval_seconds=0,
    jitter_seconds=0,
    now=lambda: datetime(2026, 7, 30, tzinfo=timezone.utc),
)
items = []
for index in range(25):
    player_id = str(900000 + index)
    team_id = str(800000 + index)
    tournament_id = str(700000 + index // 5)
    season_id = str(600000 + index // 5)
    name = f"Measured Player {index}"
    transport.register(f"search/all?q=Measured%20Player%20{index}", {
        "results": [{
            "type": "player",
            "entity": {
                "id": int(player_id),
                "name": name,
                "team": {
                    "id": int(team_id),
                    "name": f"Measured Club {index}",
                    "sport": {"slug": "football"},
                    "gender": "M",
                },
            },
        }],
    })
    transport.register(f"player/{player_id}", {"player": {
        "id": int(player_id),
        "name": name,
        "team": {
            "id": int(team_id),
            "name": f"Measured Club {index}",
            "national": False,
            "gender": "M",
            "sport": {"slug": "football"},
            "primaryUniqueTournament": {
                "id": int(tournament_id),
                "name": f"Measured League {index // 5}",
                "category": {"alpha2": "TS"},
            },
        },
    }})
    transport.register(f"unique-tournament/{tournament_id}", {"uniqueTournament": {
        "id": int(tournament_id),
        "name": f"Measured League {index // 5}",
        "tier": 1,
        "gender": "M",
        "startDateTimestamp": 1751328000,
        "endDateTimestamp": 1782864000,
        "category": {"alpha2": "TS", "sport": {"slug": "football"}},
    }})
    transport.register(f"unique-tournament/{tournament_id}/seasons", {"seasons": [
        {"id": int(season_id), "year": "25/26"},
        {"id": int(season_id) - 1, "year": "24/25"},
    ]})
    transport.register(
        f"player/{player_id}/unique-tournament/{tournament_id}/season/{season_id}/statistics/overall",
        {"statistics": {"appearances": index + 1, "minutesPlayed": (index + 1) * 90}},
    )
    items.append({
        "item_key": f"smoke:{index}",
        "reported_name": name,
        "aliases": [],
        "team_mapping": {
            "provider_team_id": team_id,
            "provider_unique_tournament_id": tournament_id,
        },
    })

(Path("/tmp") / "sofascore-25-started").write_text("started")
for item in items:
    result = adapter.enrich(item)
    assert result["status"] == "fresh"
assert len({item["item_key"] for item in items}) == 25
assert len({item["known_provider_player_id"] for item in items if item.get("known_provider_player_id")}) == 0
assert adapter.provider_calls == 85
' &
workload_pid=$!

attempts=0
until docker exec "$container" test -f /tmp/sofascore-25-started >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  if [ "$attempts" -ge 30 ]; then
    wait "$workload_pid" || true
    echo "25-item offline workload did not complete" >&2
    exit 1
  fi
  sleep 1
done
workload_stats=$(docker stats --no-stream --format '{{.CPUPerc}} {{.MemUsage}}' "$container")
wait "$workload_pid"

docker stop --time 15 "$container" >/dev/null
test "$(docker inspect --format '{{.State.ExitCode}}' "$container")" = "0"
docker rm "$container" >/dev/null

start_service "$restart_container"
test "$(docker exec "$restart_container" cat /data/soccerdata/smoke-sentinel)" = "smoke"
docker stop --time 15 "$restart_container" >/dev/null
test "$(docker inspect --format '{{.State.ExitCode}}' "$restart_container")" = "0"

echo "Docker smoke passed: cold=$cold_stats; 25-item=$workload_stats"
