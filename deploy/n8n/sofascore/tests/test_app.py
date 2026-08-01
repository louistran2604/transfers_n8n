from __future__ import annotations

import asyncio
import os
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from aiohttp.test_utils import TestClient, TestServer

from app import (
    BODY_LIMIT_BYTES,
    CircuitBreaker,
    ServiceConfig,
    WorkerTimeout,
    create_app,
)
from models import MAX_BATCH_SIZE


def request_item(index: int = 1) -> dict:
    return {
        "item_key": f"provider:{index}",
        "reported_name": f"Player {index}",
        "known_provider_player_id": str(index),
    }


class ReadyChecks:
    package_ready = True
    native_ready = True
    fixture_ready = True
    cache_writable = True

    def run(self):
        return True

    def ready(self):
        return True


class UnreadyChecks(ReadyChecks):
    cache_writable = False

    def ready(self):
        return False


class StubWorker:
    def __init__(self, results=None):
        self.results = list(results or [])
        self.calls = []
        self.stopped = False

    def is_alive(self):
        return True

    def execute(self, item, timeout):
        self.calls.append((item, timeout))
        result = self.results.pop(0) if self.results else {"status": "fresh"}
        if isinstance(result, Exception):
            raise result
        return {
            "item_key": item["item_key"],
            "identity": None,
            "profile": None,
            "statistics": None,
            **result,
        }

    def stop(self):
        self.stopped = True


class DeadWorker(StubWorker):
    def is_alive(self):
        return False


class ServiceConfigTests(unittest.TestCase):
    def test_defaults_match_deadline_cache_and_circuit_contract(self):
        with patch.dict(os.environ, {}, clear=True):
            config = ServiceConfig.from_environment()
        self.assertEqual(Path("/data/soccerdata"), config.cache_dir)
        self.assertEqual(15, config.call_timeout_seconds)
        self.assertEqual(75, config.batch_timeout_seconds)
        self.assertEqual(600, config.circuit_open_seconds)
        self.assertEqual((24, 12, 24), (
            config.profile_max_age_hours,
            config.stats_max_age_hours,
            config.mapping_max_age_hours,
        ))

    def test_invalid_environment_fails_closed(self):
        cases = {
            "SOCCERDATA_DIR": "relative",
            "SOFASCORE_CALL_TIMEOUT_SECONDS": "0",
            "SOFASCORE_BATCH_TIMEOUT_SECONDS": "invalid",
            "SOFASCORE_MIN_INTERVAL_SECONDS": "-1",
            "PORT": "70000",
            "LOG_LEVEL": "verbose",
        }
        for name, value in cases.items():
            with self.subTest(name=name), patch.dict(os.environ, {name: value}, clear=True):
                with self.assertRaises(RuntimeError):
                    ServiceConfig.from_environment()

    def test_circuit_opens_after_three_failures_and_resets_after_window(self):
        circuit = CircuitBreaker(0.01)
        circuit.failure()
        circuit.failure()
        self.assertTrue(circuit.allow())
        circuit.failure()
        self.assertFalse(circuit.allow())
        time.sleep(0.02)
        self.assertTrue(circuit.allow())
        self.assertEqual("closed", circuit.state)


class HttpContractTests(unittest.IsolatedAsyncioTestCase):
    async def start_client(self, worker=None, checks=None, *, batch_timeout=1):
        self.temporary = tempfile.TemporaryDirectory()
        self.worker = worker or StubWorker()
        config = ServiceConfig(
            cache_dir=Path(self.temporary.name),
            call_timeout_seconds=0.1,
            batch_timeout_seconds=batch_timeout,
            min_interval_seconds=0,
            jitter_seconds=0,
            circuit_open_seconds=60,
        )
        app = create_app(
            config=config,
            worker=self.worker,
            checks=checks or ReadyChecks(),
            manage_worker=False,
        )
        self.client = TestClient(TestServer(app))
        await self.client.start_server()

    async def asyncTearDown(self):
        if hasattr(self, "client"):
            await self.client.close()
        if hasattr(self, "temporary"):
            self.temporary.cleanup()

    async def post(self, players, **extra):
        return await self.client.post(
            "/v1/enrich",
            json={"request_id": "run:1", "players": players, **extra},
        )

    async def test_health_and_readiness_have_stable_types_and_no_worker_call(self):
        await self.start_client()
        health = await self.client.get("/healthz")
        ready = await self.client.get("/readyz")
        self.assertEqual(200, health.status)
        self.assertEqual(
            {"status", "service_version", "soccerdata_version", "requests_total", "items_total"},
            set(await health.json()),
        )
        ready_payload = await ready.json()
        self.assertEqual(200, ready.status)
        self.assertEqual("ready", ready_payload["status"])
        for component in (
            "package_ready",
            "native_ready",
            "fixture_ready",
            "cache_writable",
            "worker_ready",
        ):
            self.assertIs(ready_payload[component], True)
        self.assertEqual("closed", ready_payload["circuit"])
        self.assertIsNone(ready_payload["last_provider_success_at"])
        self.assertEqual([], self.worker.calls)

    async def test_unready_response_reports_each_local_component_without_work(self):
        await self.start_client(checks=UnreadyChecks())
        response = await self.client.get("/readyz")
        payload = await response.json()
        self.assertEqual(503, response.status)
        self.assertEqual("unavailable", payload["status"])
        self.assertFalse(payload["cache_writable"])
        self.assertTrue(payload["package_ready"])
        self.assertTrue(payload["native_ready"])
        self.assertTrue(payload["fixture_ready"])
        self.assertEqual([], self.worker.calls)

    async def test_success_partial_unresolved_ambiguous_and_deferred_shapes_are_stable(self):
        statuses = ["fresh", "partial", "unresolved", "ambiguous", "deferred"]
        await self.start_client(
            worker=StubWorker([{"status": status} for status in statuses])
        )
        response = await self.post(
            [request_item(index) for index in range(1, len(statuses) + 1)]
        )
        payload = await response.json()
        self.assertEqual(200, response.status)
        self.assertEqual(statuses, [item["status"] for item in payload["items"]])
        self.assertEqual(
            {"request_id", "status", "items", "summary"},
            set(payload),
        )
        self.assertEqual(
            {"requested": 5, "fresh": 1, "failed": 0, "deferred": 1},
            payload["summary"],
        )
        for index, item in enumerate(payload["items"], 1):
            self.assertEqual(f"provider:{index}", item["item_key"])
            self.assertIn("identity", item)
            self.assertIn("profile", item)
            self.assertIn("statistics", item)

    async def test_invalid_oversized_body_and_unavailable_service_are_typed(self):
        await self.start_client()
        invalid = await self.client.post("/v1/enrich", data=b"{broken")
        self.assertEqual(400, invalid.status)
        self.assertEqual("invalid_request", (await invalid.json())["error"]["code"])

        oversized_batch = await self.post(
            [request_item(index) for index in range(MAX_BATCH_SIZE + 1)]
        )
        self.assertEqual(413, oversized_batch.status)
        self.assertEqual("batch_too_large", (await oversized_batch.json())["error"]["code"])

        body_too_large = await self.client.post(
            "/v1/enrich",
            data=b"x" * (BODY_LIMIT_BYTES + 1),
            headers={"content-type": "application/json"},
        )
        self.assertEqual(413, body_too_large.status)
        self.assertEqual("body_too_large", (await body_too_large.json())["error"]["code"])

        await self.client.close()
        self.temporary.cleanup()
        await self.start_client(worker=DeadWorker())
        unavailable = await self.post([request_item()])
        self.assertEqual(503, unavailable.status)
        self.assertEqual("service_unavailable", (await unavailable.json())["error"]["code"])

    async def test_identical_item_dedupe_preserves_first_order_and_summary(self):
        await self.start_client()
        players = [request_item(2), request_item(1), request_item(2)]
        response = await self.post(players)
        payload = await response.json()
        self.assertEqual(200, response.status)
        self.assertEqual(["provider:2", "provider:1"], [item["item_key"] for item in payload["items"]])
        self.assertEqual(
            {"requested": 2, "fresh": 2, "failed": 0, "deferred": 0},
            payload["summary"],
        )
        self.assertEqual("complete", payload["status"])

    async def test_mixed_and_all_item_failure_remain_http_200(self):
        await self.start_client(
            worker=StubWorker(
                [
                    {"status": "fresh"},
                    {"status": "provider_failure"},
                    {"status": "ambiguous"},
                ]
            )
        )
        mixed = await self.post([request_item(1), request_item(2), request_item(3)])
        payload = await mixed.json()
        self.assertEqual(200, mixed.status)
        self.assertEqual("partial", payload["status"])
        self.assertEqual({"requested": 3, "fresh": 1, "failed": 1, "deferred": 0}, payload["summary"])

        await self.client.close()
        self.temporary.cleanup()
        await self.start_client(worker=StubWorker([WorkerTimeout(), RuntimeError(), WorkerTimeout()]))
        failed = await self.post([request_item(4), request_item(5), request_item(6)])
        payload = await failed.json()
        self.assertEqual(200, failed.status)
        self.assertEqual(["timeout", "provider_failure", "timeout"], [item["status"] for item in payload["items"]])
        self.assertEqual(3, payload["summary"]["failed"])

    async def test_three_terminal_failures_open_circuit_for_remaining_items(self):
        await self.start_client(
            worker=StubWorker([WorkerTimeout(), WorkerTimeout(), WorkerTimeout()])
        )
        response = await self.post([request_item(index) for index in range(1, 6)])
        payload = await response.json()
        self.assertEqual(
            ["timeout", "timeout", "timeout", "deferred", "deferred"],
            [item["status"] for item in payload["items"]],
        )
        self.assertEqual(3, len(self.worker.calls))
        self.assertEqual(2, payload["summary"]["deferred"])

    async def test_batch_deadline_defers_unfinished_items(self):
        class SlowWorker(StubWorker):
            def execute(self, item, timeout):
                self.calls.append((item, timeout))
                time.sleep(0.08)
                return {
                    "item_key": item["item_key"],
                    "status": "fresh",
                    "identity": None,
                    "profile": None,
                    "statistics": None,
                }

        await self.start_client(worker=SlowWorker(), batch_timeout=0.05)
        response = await self.post([request_item(1), request_item(2)], deadline_ms=50)
        payload = await response.json()
        self.assertEqual(200, response.status)
        self.assertEqual(["deferred", "deferred"], [item["status"] for item in payload["items"]])
        self.assertTrue(all(item["error"]["code"] == "batch_deadline_exceeded" for item in payload["items"]))

    async def test_managed_shutdown_stops_worker(self):
        self.temporary = tempfile.TemporaryDirectory()
        worker = StubWorker()
        config = ServiceConfig(
            cache_dir=Path(self.temporary.name),
            call_timeout_seconds=1,
            batch_timeout_seconds=1,
            min_interval_seconds=0,
            jitter_seconds=0,
            circuit_open_seconds=1,
        )
        app = create_app(
            config=config,
            worker=worker,
            checks=ReadyChecks(),
            manage_worker=True,
        )
        self.client = TestClient(TestServer(app))
        await self.client.start_server()
        await self.client.close()
        self.assertTrue(worker.stopped)


if __name__ == "__main__":
    unittest.main()
