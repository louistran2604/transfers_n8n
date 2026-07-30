from __future__ import annotations

import asyncio
import hashlib
import importlib.metadata
import json
import multiprocessing
import os
import queue
import tempfile
import threading
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

from aiohttp import web

from __init__ import SERVICE_VERSION, SOCCERDATA_VERSION
from adapter import ProviderError, SofascoreAdapter, create_reader
from models import validate_batch


TLS_ASSET_SHA256 = "3f9bf4a741002b1d57043571d69e6ebe8f1df416aa1ca9ca9766dba36e4d4941"
FIXTURE_MANIFEST = Path(__file__).parent / "tests" / "fixtures" / "manifest.json"
BODY_LIMIT_BYTES = 256 * 1024


def _positive_float(name: str, default: str, *, allow_zero: bool = False) -> float:
    try:
        value = float(os.environ.get(name, default))
    except ValueError as error:
        raise RuntimeError(f"{name} must be numeric") from error
    if value < 0 or (value == 0 and not allow_zero):
        raise RuntimeError(f"{name} must be {'non-negative' if allow_zero else 'positive'}")
    return value


def _port() -> int:
    try:
        value = int(os.environ.get("PORT", "8080"))
    except ValueError as error:
        raise RuntimeError("PORT must be an integer") from error
    if not 1 <= value <= 65535:
        raise RuntimeError("PORT must be from 1 to 65535")
    return value


@dataclass(frozen=True)
class ServiceConfig:
    cache_dir: Path
    call_timeout_seconds: float
    batch_timeout_seconds: float
    min_interval_seconds: float
    jitter_seconds: float
    circuit_open_seconds: float
    profile_max_age_hours: float = 24
    stats_max_age_hours: float = 12
    mapping_max_age_hours: float = 24
    port: int = 8080
    log_level: str = "INFO"

    @classmethod
    def from_environment(cls) -> "ServiceConfig":
        cache_dir = Path(os.environ.get("SOCCERDATA_DIR", "/data/soccerdata"))
        if not cache_dir.is_absolute():
            raise RuntimeError("SOCCERDATA_DIR must be an absolute path")
        log_level = os.environ.get("LOG_LEVEL", "INFO").upper()
        if log_level not in {"DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"}:
            raise RuntimeError("LOG_LEVEL is invalid")
        return cls(
            cache_dir=cache_dir,
            call_timeout_seconds=_positive_float(
                "SOFASCORE_CALL_TIMEOUT_SECONDS", "15"
            ),
            batch_timeout_seconds=_positive_float(
                "SOFASCORE_BATCH_TIMEOUT_SECONDS", "75"
            ),
            min_interval_seconds=_positive_float(
                "SOFASCORE_MIN_INTERVAL_SECONDS", "1.0", allow_zero=True
            ),
            jitter_seconds=_positive_float(
                "SOFASCORE_REQUEST_JITTER_SECONDS", "0.25", allow_zero=True
            ),
            circuit_open_seconds=_positive_float(
                "SOFASCORE_CIRCUIT_OPEN_SECONDS", "600"
            ),
            profile_max_age_hours=_positive_float(
                "SOFASCORE_PROFILE_MAX_AGE_HOURS", "24"
            ),
            stats_max_age_hours=_positive_float(
                "SOFASCORE_STATS_MAX_AGE_HOURS", "12"
            ),
            mapping_max_age_hours=_positive_float(
                "SOFASCORE_MAPPING_MAX_AGE_HOURS", "24"
            ),
            port=_port(),
            log_level=log_level,
        )


class RuntimeChecks:
    def __init__(self, cache_dir: Path, tls_path: Path | None = None):
        self.cache_dir = cache_dir
        configured = tls_path or Path(os.environ.get("TLS_LIBRARY_PATH", ""))
        self.tls_path = configured if str(configured) else None
        self.cache_writable = False
        self.fixture_ready = False
        self.native_ready = False
        self.package_ready = False

    def run(self) -> bool:
        self.package_ready = (
            importlib.metadata.version("soccerdata") == SOCCERDATA_VERSION
        )
        manifest = json.loads(FIXTURE_MANIFEST.read_text())
        self.fixture_ready = (
            manifest.get("schema_version") == "sofascore-fixtures-v1"
            and len(manifest.get("fixtures", [])) == 7
        )
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(dir=self.cache_dir):
            self.cache_writable = True
        if self.tls_path is None or not self.tls_path.is_file():
            self.native_ready = False
        else:
            self.native_ready = (
                hashlib.sha256(self.tls_path.read_bytes()).hexdigest()
                == TLS_ASSET_SHA256
            )
            if self.native_ready:
                from tls_requests import TLSLibrary

                self.native_ready = TLSLibrary.load() is not None
        return self.ready()

    def ready(self) -> bool:
        return all(
            (
                self.package_ready,
                self.fixture_ready,
                self.cache_writable,
                self.native_ready,
            )
        )


def provider_child(
    input_queue: Any, output_queue: Any, config: ServiceConfig
) -> None:
    try:
        reader = create_reader(config.cache_dir)
        adapter = SofascoreAdapter(
            reader,
            config.cache_dir,
            call_timeout_seconds=config.call_timeout_seconds,
            min_interval_seconds=config.min_interval_seconds,
            jitter_seconds=config.jitter_seconds,
            profile_max_age_hours=config.profile_max_age_hours,
            stats_max_age_hours=config.stats_max_age_hours,
            mapping_max_age_hours=config.mapping_max_age_hours,
        )
    except Exception:
        output_queue.put({"type": "startup", "ready": False})
        return
    output_queue.put({"type": "startup", "ready": True})
    while True:
        task = input_queue.get()
        if task is None:
            return
        try:
            result = adapter.enrich(task["item"])
        except TimeoutError:
            result = {
                "item_key": task["item"]["item_key"],
                "status": "timeout",
                "identity": None,
                "profile": None,
                "statistics": None,
                "error": {"code": "provider_timeout", "retryable": True},
            }
        except ProviderError:
            result = {
                "item_key": task["item"]["item_key"],
                "status": "schema_failure",
                "identity": None,
                "profile": None,
                "statistics": None,
                "error": {"code": "provider_schema_failure", "retryable": True},
            }
        except Exception:
            result = {
                "item_key": task["item"]["item_key"],
                "status": "provider_failure",
                "identity": None,
                "profile": None,
                "statistics": None,
                "error": {"code": "provider_connection_failed", "retryable": True},
            }
        output_queue.put({"type": "result", "task_id": task["task_id"], "result": result})


class WorkerTimeout(TimeoutError):
    pass


class ProviderWorker:
    def __init__(
        self,
        config: ServiceConfig,
        target: Callable[[Any, Any, ServiceConfig], None] = provider_child,
    ):
        self.config = config
        self.target = target
        self.context = multiprocessing.get_context("spawn")
        self.process: multiprocessing.Process | None = None
        self.input_queue: Any = None
        self.output_queue: Any = None
        self.lock = threading.Lock()
        self.generation = 0

    def start(self) -> None:
        self.input_queue = self.context.Queue()
        self.output_queue = self.context.Queue()
        self.process = self.context.Process(
            target=self.target,
            args=(self.input_queue, self.output_queue, self.config),
            daemon=True,
        )
        self.process.start()
        try:
            startup = self.output_queue.get(timeout=5)
        except queue.Empty as error:
            self._terminate()
            raise RuntimeError("provider child startup timed out") from error
        if startup != {"type": "startup", "ready": True}:
            self._terminate()
            raise RuntimeError("provider child startup failed")
        self.generation += 1

    def is_alive(self) -> bool:
        return bool(self.process and self.process.is_alive())

    def execute(self, item: dict[str, Any], timeout: float) -> dict[str, Any]:
        with self.lock:
            if not self.is_alive():
                self.replace()
            task_id = uuid.uuid4().hex
            self.input_queue.put({"task_id": task_id, "item": item})
            try:
                response = self.output_queue.get(timeout=timeout)
            except queue.Empty as error:
                self.replace()
                raise WorkerTimeout("provider child timed out") from error
            if response.get("type") != "result" or response.get("task_id") != task_id:
                self.replace()
                raise RuntimeError("provider child returned an invalid response")
            return response["result"]

    def replace(self) -> None:
        self._terminate()
        self.start()

    def stop(self) -> None:
        if self.is_alive():
            self.input_queue.put(None)
            self.process.join(timeout=3)
        self._terminate()

    def _terminate(self) -> None:
        if self.process and self.process.is_alive():
            self.process.terminate()
            self.process.join(timeout=3)
        self.process = None
        for value in (self.input_queue, self.output_queue):
            if value is not None:
                value.close()
        self.input_queue = None
        self.output_queue = None


class CircuitBreaker:
    def __init__(self, open_seconds: float, threshold: int = 3):
        self.open_seconds = open_seconds
        self.threshold = threshold
        self.failures = 0
        self.opened_at: float | None = None

    def allow(self) -> bool:
        if self.opened_at is None:
            return True
        if time.monotonic() - self.opened_at >= self.open_seconds:
            self.failures = 0
            self.opened_at = None
            return True
        return False

    def success(self) -> None:
        self.failures = 0
        self.opened_at = None

    def failure(self) -> None:
        self.failures += 1
        if self.failures >= self.threshold:
            self.opened_at = time.monotonic()

    @property
    def state(self) -> str:
        return "closed" if self.allow() else "open"


async def health_handler(request: web.Request) -> web.Response:
    return web.json_response(
        {
            "status": "ok",
            "service_version": SERVICE_VERSION,
            "soccerdata_version": SOCCERDATA_VERSION,
            "requests_total": request.app["requests_total"],
            "items_total": request.app["items_total"],
        }
    )


async def ready_handler(request: web.Request) -> web.Response:
    checks = request.app["checks"]
    worker = request.app["worker"]
    ready = checks.ready() and worker.is_alive()
    return web.json_response(
        {
            "status": "ready" if ready else "unavailable",
            "cache_writable": checks.cache_writable,
            "worker_ready": worker.is_alive(),
            "circuit": request.app["circuit"].state,
            "last_provider_success_at": request.app["last_provider_success_at"],
        },
        status=200 if ready else 503,
    )


def failure_item(item: dict[str, Any], status: str, code: str) -> dict[str, Any]:
    return {
        "item_key": item["item_key"],
        "status": status,
        "identity": None,
        "profile": None,
        "statistics": None,
        "error": {"code": code, "retryable": True},
    }


async def enrich_handler(request: web.Request) -> web.Response:
    try:
        body = await request.json()
        request_id, deadline_ms, players = validate_batch(body)
    except OverflowError:
        return web.json_response(
            {"error": {"code": "batch_too_large", "message": "At most 25 players are allowed"}},
            status=413,
        )
    except (json.JSONDecodeError, ValueError):
        return web.json_response(
            {"error": {"code": "invalid_request", "message": "Invalid enrichment request"}},
            status=400,
        )
    checks = request.app["checks"]
    worker = request.app["worker"]
    if not checks.ready() or not worker.is_alive():
        return web.json_response(
            {"error": {"code": "service_unavailable", "message": "Local prerequisites unavailable"}},
            status=503,
        )

    request.app["requests_total"] += 1
    request.app["items_total"] += len(players)
    circuit = request.app["circuit"]
    results: list[dict[str, Any]] = []

    async def run_batch() -> None:
        for item in players:
            if not circuit.allow():
                results.append(failure_item(item, "deferred", "circuit_open"))
                continue
            try:
                result = await asyncio.to_thread(
                    worker.execute, item, request.app["config"].call_timeout_seconds
                )
            except WorkerTimeout:
                circuit.failure()
                result = failure_item(item, "timeout", "provider_timeout")
            except Exception:
                circuit.failure()
                result = failure_item(item, "provider_failure", "provider_worker_failed")
            else:
                if result["status"] in {"fresh", "partial"}:
                    circuit.success()
                    request.app["last_provider_success_at"] = (
                        time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
                    )
                elif result["status"] in {
                    "provider_failure",
                    "rate_limited",
                    "timeout",
                    "schema_failure",
                }:
                    circuit.failure()
            results.append(result)

    timeout = min(deadline_ms / 1000, request.app["config"].batch_timeout_seconds)
    try:
        async with asyncio.timeout(timeout):
            await run_batch()
    except TimeoutError:
        completed = {result["item_key"] for result in results}
        results.extend(
            failure_item(item, "deferred", "batch_deadline_exceeded")
            for item in players
            if item["item_key"] not in completed
        )

    fresh = sum(result["status"] == "fresh" for result in results)
    deferred = sum(result["status"] == "deferred" for result in results)
    failed = sum(
        result["status"]
        not in {"fresh", "partial", "ambiguous", "unresolved", "deferred"}
        for result in results
    )
    status = "complete" if fresh == len(results) else "partial"
    return web.json_response(
        {
            "request_id": request_id,
            "status": status,
            "items": results,
            "summary": {
                "requested": len(players),
                "fresh": fresh,
                "failed": failed,
                "deferred": deferred,
            },
        }
    )


@web.middleware
async def body_limit_middleware(
    request: web.Request, handler: Callable[[web.Request], Any]
) -> web.StreamResponse:
    try:
        return await handler(request)
    except web.HTTPRequestEntityTooLarge:
        return web.json_response(
            {"error": {"code": "body_too_large", "message": "Request body is too large"}},
            status=413,
        )


async def on_startup(app: web.Application) -> None:
    app["startup_error"] = None
    try:
        if not app["checks"].run():
            raise RuntimeError("runtime prerequisites failed")
        await asyncio.to_thread(app["worker"].start)
    except Exception:
        app["startup_error"] = "runtime prerequisites unavailable"


async def on_shutdown(app: web.Application) -> None:
    await asyncio.to_thread(app["worker"].stop)


def create_app(
    *,
    config: ServiceConfig | None = None,
    worker: ProviderWorker | None = None,
    checks: RuntimeChecks | None = None,
    manage_worker: bool = True,
) -> web.Application:
    config = config or ServiceConfig.from_environment()
    app = web.Application(
        client_max_size=BODY_LIMIT_BYTES, middlewares=[body_limit_middleware]
    )
    app["config"] = config
    app["worker"] = worker or ProviderWorker(config)
    app["checks"] = checks or RuntimeChecks(config.cache_dir)
    app["circuit"] = CircuitBreaker(config.circuit_open_seconds)
    app["requests_total"] = 0
    app["items_total"] = 0
    app["last_provider_success_at"] = None
    if manage_worker:
        app.on_startup.append(on_startup)
        app.on_shutdown.append(on_shutdown)
    app.router.add_get("/healthz", health_handler)
    app.router.add_get("/readyz", ready_handler)
    app.router.add_post("/v1/enrich", enrich_handler)
    return app


if __name__ == "__main__":
    runtime_config = ServiceConfig.from_environment()
    web.run_app(
        create_app(config=runtime_config),
        host="0.0.0.0",
        port=runtime_config.port,
        access_log=None,
    )
