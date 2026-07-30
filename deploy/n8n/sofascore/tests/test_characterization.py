from __future__ import annotations

import hashlib
import json
import os
import tempfile
import time
import unittest
from datetime import datetime, timezone
from pathlib import Path

from aiohttp.test_utils import TestClient, TestServer

from adapter import SofascoreAdapter
from app import ProviderWorker, RuntimeChecks, ServiceConfig, WorkerTimeout, create_app
from tests.fixture_transport import FixtureTransport


FIXTURES = Path(__file__).parent / "fixtures"
NOW = datetime(2026, 7, 30, 5, 44, tzinfo=timezone.utc)


def worker_that_hangs_once(input_queue, output_queue, config):
    config.cache_dir.mkdir(parents=True, exist_ok=True)
    marker = config.cache_dir / "hung-once"
    output_queue.put({"type": "startup", "ready": True})
    while True:
        task = input_queue.get()
        if task is None:
            return
        if not marker.exists():
            marker.touch()
            time.sleep(30)
        output_queue.put(
            {
                "type": "result",
                "task_id": task["task_id"],
                "result": {"item_key": task["item"]["item_key"], "status": "fresh"},
            }
        )


class ReadyChecks:
    cache_writable = True

    def run(self):
        return True

    def ready(self):
        return True


class StubWorker:
    def __init__(self, status="fresh"):
        self.status = status
        self.calls = []

    def is_alive(self):
        return True

    def execute(self, item, timeout):
        self.calls.append((item, timeout))
        return {
            "item_key": item["item_key"],
            "status": self.status,
            "identity": None,
            "profile": None,
            "statistics": None,
        }

    def stop(self):
        return None


class FixtureCharacterizationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.transport = FixtureTransport(FIXTURES)
        self.adapter = SofascoreAdapter(
            self.transport,
            Path(self.temporary.name),
            min_interval_seconds=0,
            jitter_seconds=0,
            now=lambda: NOW,
        )

    def tearDown(self):
        self.temporary.cleanup()

    def mapped_item(self, player_id, team_id, tournament_id, season_id, name):
        return {
            "item_key": f"provider:{player_id}",
            "reported_name": name,
            "known_provider_player_id": player_id,
            "aliases": [],
            "team_mapping": {
                "provider_team_id": team_id,
                "provider_unique_tournament_id": tournament_id,
            },
            "season_mapping": {
                "provider_season_id": season_id,
                "label": "25/26",
                "state": "latest_completed",
            },
        }

    def test_captured_fixture_manifest_is_sanitized_and_hashed(self):
        manifest = json.loads((FIXTURES / "manifest.json").read_text())
        self.assertEqual("1.9.1", manifest["soccerdata_version"])
        self.assertEqual(7, len(manifest["fixtures"]))
        self.assertEqual(6, sum(row["captured"] for row in manifest["fixtures"]))
        for row in manifest["fixtures"]:
            digest = hashlib.sha256((FIXTURES / row["fixture"]).read_bytes()).hexdigest()
            self.assertEqual(row["bundle_sha256"], digest)
            for response in row["responses"]:
                self.assertRegex(response["raw_response_sha256"], r"^[0-9a-f]{64}$")

        forbidden = {"cookie", "authorization", "auth_token", "secret", "webhook"}

        def visit(value):
            if isinstance(value, dict):
                for key, child in value.items():
                    self.assertFalse(any(term in key.casefold() for term in forbidden))
                    visit(child)
            elif isinstance(value, list):
                for child in value:
                    visit(child)

        for fixture in FIXTURES.glob("*.json"):
            visit(json.loads(fixture.read_text()))

    def test_fixture_transport_fails_closed_for_unknown_endpoint(self):
        with self.assertRaisesRegex(AssertionError, "unregistered provider endpoint"):
            self.transport.get("https://api.sofascore.com/api/v1/player/999999999")

    def test_mbappe_rich_response_normalizes_verified_fields(self):
        item = self.mapped_item("826643", "2829", "8", "77559", "Kylian Mbappé")
        result = self.adapter.enrich(item)
        self.assertEqual("fresh", result["status"])
        self.assertEqual(2, result["provider_calls"])
        self.assertEqual("Kylian Mbappé", result["profile"]["canonical_name"])
        self.assertEqual("Real Madrid", result["profile"]["current_club"]["name"])
        self.assertEqual(27, result["profile"]["age"])
        self.assertEqual(25, result["statistics"]["goals"])
        self.assertEqual(23.9453, result["statistics"]["expected_goals"])
        self.assertEqual(6.2019957, result["statistics"]["expected_assists"])
        self.assertEqual("selected_domestic_league_all_clubs", result["statistics"]["scope"])

    def test_quang_hai_sparse_response_keeps_missing_values_null(self):
        item = self.mapped_item(
            "845067", "193616", "626", "78589", "Nguyễn Quang Hải"
        )
        result = self.adapter.enrich(item)
        self.assertEqual("fresh", result["status"])
        self.assertEqual(2, result["provider_calls"])
        self.assertEqual("V-League 1", result["statistics"]["competition"])
        self.assertIsNone(result["statistics"]["expected_goals"])
        self.assertIsNone(result["statistics"]["expected_assists"])
        self.assertEqual(24, result["statistics"]["appearances"])

    def test_duplicate_name_john_smith_does_not_auto_resolve(self):
        result = self.adapter.enrich(
            {
                "item_key": "name:john-smith|club:unknown",
                "reported_name": "John Smith",
                "aliases": [],
            }
        )
        self.assertEqual("ambiguous", result["status"])
        self.assertIsNone(result["identity"])
        self.assertEqual(1, result["provider_calls"])
        self.assertEqual(
            {"2544168", "2332241"},
            {candidate["provider_player_id"] for candidate in result["candidates"]},
        )

    def test_malformed_cache_gets_one_bypass_and_preserves_last_good(self):
        endpoint = "player/826643"
        first, _ = self.adapter.fetch_json(endpoint, "cache-test", 24)
        cache_path = Path(self.temporary.name) / "cache-test.json"
        cache_path.write_text("{broken-cache")
        self.transport.register(endpoint, b"{broken-refresh")
        second, cache_status = self.adapter.fetch_json(endpoint, "cache-test", 24)
        self.assertEqual(first, second)
        self.assertEqual("stale", cache_status)
        retry_calls = self.transport.calls[-2:]
        self.assertEqual([False, True], [row["no_cache"] for row in retry_calls])

    def test_only_public_soccerdata_transport_is_present(self):
        source = "\n".join(
            path.read_text()
            for path in Path(__file__).parents[1].glob("*.py")
        )
        for forbidden in (
            "_download_and_save",
            "._session",
            "ScraperFC",
            "selenium",
            "playwright",
        ):
            self.assertNotIn(forbidden, source)
        self.assertIn("self.reader.get(", source)


class WorkerCharacterizationTests(unittest.TestCase):
    def test_hung_child_is_replaced_before_next_request(self):
        with tempfile.TemporaryDirectory() as temporary:
            config = ServiceConfig(
                cache_dir=Path(temporary),
                call_timeout_seconds=0.2,
                batch_timeout_seconds=1,
                min_interval_seconds=0,
                jitter_seconds=0,
                circuit_open_seconds=1,
            )
            worker = ProviderWorker(config, target=worker_that_hangs_once)
            worker.start()
            started = time.monotonic()
            try:
                with self.assertRaises(WorkerTimeout):
                    worker.execute({"item_key": "first"}, timeout=0.2)
                self.assertLess(time.monotonic() - started, 2)
                self.assertEqual(2, worker.generation)
                result = worker.execute({"item_key": "second"}, timeout=0.5)
                self.assertEqual("fresh", result["status"])
            finally:
                worker.stop()


class HttpCharacterizationTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.config = ServiceConfig(
            cache_dir=Path(self.temporary.name),
            call_timeout_seconds=1,
            batch_timeout_seconds=2,
            min_interval_seconds=0,
            jitter_seconds=0,
            circuit_open_seconds=1,
        )
        self.worker = StubWorker()
        self.transport = FixtureTransport(FIXTURES)
        app = create_app(
            config=self.config,
            worker=self.worker,
            checks=ReadyChecks(),
            manage_worker=False,
        )
        self.client = TestClient(TestServer(app))
        await self.client.start_server()

    async def asyncTearDown(self):
        await self.client.close()
        self.temporary.cleanup()

    async def test_health_and_readiness_do_not_contact_provider(self):
        health = await self.client.get("/healthz")
        ready = await self.client.get("/readyz")
        self.assertEqual(200, health.status)
        self.assertEqual(200, ready.status)
        self.assertEqual("ok", (await health.json())["status"])
        self.assertEqual("ready", (await ready.json())["status"])
        self.assertEqual([], self.transport.calls)

    async def test_enrich_echoes_keys_and_all_item_failure_stays_http_200(self):
        self.worker.status = "provider_failure"
        response = await self.client.post(
            "/v1/enrich",
            json={
                "request_id": "workflow-run:1",
                "deadline_ms": 1_000,
                "players": [
                    {
                        "item_key": "provider:826643",
                        "reported_name": "Kylian Mbappé",
                        "known_provider_player_id": "826643",
                    }
                ],
            },
        )
        self.assertEqual(200, response.status)
        payload = await response.json()
        self.assertEqual("workflow-run:1", payload["request_id"])
        self.assertEqual("provider:826643", payload["items"][0]["item_key"])
        self.assertEqual("partial", payload["status"])


@unittest.skipUnless(os.environ.get("TLS_LIBRARY_PATH"), "container TLS asset check")
class ContainerRuntimeCharacterizationTests(unittest.TestCase):
    def test_pinned_package_native_asset_cache_and_manifest_are_ready(self):
        with tempfile.TemporaryDirectory() as temporary:
            checks = RuntimeChecks(Path(temporary))
            self.assertTrue(checks.run())


if __name__ == "__main__":
    unittest.main()
