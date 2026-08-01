from __future__ import annotations

import io
import json
from pathlib import Path
from typing import Any


API_ROOT = "https://api.sofascore.com/api/v1/"


class FixtureTransport:
    def __init__(self, fixture_dir: Path):
        self.responses: dict[str, Any] = {}
        self.calls: list[dict[str, Any]] = []
        for fixture in fixture_dir.glob("*.json"):
            if fixture.name in {"manifest.json", "failures.json"}:
                continue
            bundle = json.loads(fixture.read_text())
            for row in bundle["endpoints"]:
                self.responses[row["endpoint"]] = row["response"]

    def register(self, endpoint: str, response: Any) -> None:
        self.responses[endpoint] = response

    def get(
        self,
        url: str,
        filepath: Path | None = None,
        max_age: Any = None,
        no_cache: bool = False,
        var: Any = None,
    ) -> io.BytesIO:
        if not url.startswith(API_ROOT):
            raise AssertionError(f"unregistered provider URL: {url}")
        endpoint = url.removeprefix(API_ROOT)
        if endpoint not in self.responses:
            raise AssertionError(f"unregistered provider endpoint: {endpoint}")
        self.calls.append(
            {
                "endpoint": endpoint,
                "filepath": str(filepath) if filepath else None,
                "max_age": max_age,
                "no_cache": no_cache,
                "var": var,
            }
        )
        if filepath is not None and filepath.exists() and not no_cache:
            return io.BytesIO(filepath.read_bytes())
        response = self.responses[endpoint]
        if isinstance(response, Exception):
            raise response
        if isinstance(response, str):
            encoded = response.encode()
        elif isinstance(response, bytes):
            encoded = response
        else:
            encoded = json.dumps(response, ensure_ascii=False).encode()
        if filepath is not None:
            filepath.parent.mkdir(parents=True, exist_ok=True)
            filepath.write_bytes(encoded)
        return io.BytesIO(encoded)
