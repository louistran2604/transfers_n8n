import asyncio
import json
import os
import re
from collections.abc import AsyncIterator
from contextlib import aclosing
from datetime import datetime, timezone
from typing import Any

from aiohttp import web
from twscrape import API
from twscrape.accounts_pool import NoAccountError


ACCOUNT_NAME = "dedicated-x-account"
ACCOUNT_DB_PATH = "/data/accounts.db"
MAX_POSTS_PER_SOURCE = 20
REQUEST_CONCURRENCY = 2
PER_SOURCE_TIMEOUT_SECONDS = 30
RUN_TIMEOUT_SECONDS = 300
DECIMAL_ID = re.compile(r"^\d+$")


def required_environment(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(f"{name} is required")
    return value


def as_utc_iso(value: Any) -> str | None:
    if isinstance(value, datetime):
        parsed = value
    elif isinstance(value, str):
        try:
            parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            return None
    else:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def string_x_ids(value: Any, key: str | None = None) -> Any:
    if isinstance(value, dict):
        return {name: string_x_ids(item, name) for name, item in value.items()}
    if isinstance(value, list):
        return [string_x_ids(item, key) for item in value]
    if key and "id" in key.lower() and isinstance(value, int):
        return str(value)
    return value


def tweet_payload(tweet: Any) -> dict[str, Any]:
    try:
        serialized = tweet.json()
        payload = json.loads(serialized) if isinstance(serialized, str) else serialized
    except (AttributeError, TypeError, ValueError, json.JSONDecodeError):
        payload = {}
    return string_x_ids(payload) if isinstance(payload, dict) else {}


def normalize_tweet(source: dict[str, str], tweet: Any) -> dict[str, Any] | None:
    post_id = str(getattr(tweet, "id_str", "")).strip()
    content = str(getattr(tweet, "rawContent", "") or "").strip()
    if not DECIMAL_ID.fullmatch(post_id) or not content:
        return None
    if getattr(tweet, "retweetedTweet", None) is not None or re.match(r"^RT\s+@", content, re.IGNORECASE):
        return None
    posted_at = as_utc_iso(getattr(tweet, "date", None))
    if not posted_at:
        return None
    quoted = getattr(tweet, "quotedTweet", None)
    quoted_content = str(getattr(quoted, "rawContent", "") or "").strip()
    username = source["username"]
    post_url = getattr(tweet, "url", None)
    if not isinstance(post_url, str) or not post_url.startswith("https://"):
        post_url = f"https://x.com/{username}/status/{post_id}"
    return {
        "source_id": source["source_id"],
        "username": username,
        "x_user_id": source["x_user_id"],
        "external_post_id": post_id,
        "post_url": post_url,
        "content": f"{content}\n\nQuoted post:\n{quoted_content}" if quoted_content else content,
        "posted_at": posted_at,
        "is_quote": bool(quoted_content),
        "raw_payload": tweet_payload(tweet),
    }


def validate_collect_request(value: Any) -> tuple[list[dict[str, str]], int]:
    if not isinstance(value, dict):
        raise ValueError("request body must be an object")
    limit = value.get("limit", MAX_POSTS_PER_SOURCE)
    if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= MAX_POSTS_PER_SOURCE:
        raise ValueError(f"limit must be an integer from 1 to {MAX_POSTS_PER_SOURCE}")
    sources = value.get("sources")
    if not isinstance(sources, list) or not sources:
        raise ValueError("sources must be a non-empty array")
    if len(sources) > 100:
        raise ValueError("sources must contain at most 100 entries")
    normalized: list[dict[str, str]] = []
    for index, source in enumerate(sources):
        if not isinstance(source, dict):
            raise ValueError(f"sources[{index}] must be an object")
        source_id = source.get("source_id")
        username = source.get("username")
        x_user_id = source.get("x_user_id")
        if not all(isinstance(item, str) and item.strip() for item in (source_id, username, x_user_id)):
            raise ValueError(f"sources[{index}] has invalid identifiers")
        if not DECIMAL_ID.fullmatch(x_user_id):
            raise ValueError(f"sources[{index}].x_user_id must be a decimal string")
        normalized.append({
            "source_id": source_id,
            "username": username,
            "x_user_id": x_user_id,
        })
    return normalized, limit


def source_error(source: dict[str, str], code: str, message: str, retryable: bool) -> dict[str, Any]:
    return {
        "source_id": source["source_id"],
        "username": source["username"],
        "x_user_id": source["x_user_id"],
        "code": code,
        "message": message,
        "retryable": retryable,
    }


class Collector:
    def __init__(self, api: API, concurrency: int = REQUEST_CONCURRENCY):
        self.api = api
        self.semaphore = asyncio.Semaphore(concurrency)

    async def collect_source(self, source: dict[str, str], limit: int) -> tuple[list[dict[str, Any]], dict[str, Any] | None]:
        try:
            async with self.semaphore, asyncio.timeout(PER_SOURCE_TIMEOUT_SECONDS):
                tweets: list[Any] = []
                timeline: AsyncIterator[Any] = self.api.user_tweets(int(source["x_user_id"]), limit=limit)
                async with aclosing(timeline):
                    async for tweet in timeline:
                        tweets.append(tweet)
        except NoAccountError:
            return [], source_error(source, "account_unavailable", "X account unavailable", True)
        except TimeoutError:
            return [], source_error(source, "timeout", "X collection timed out", True)
        except Exception:
            return [], source_error(source, "collection_failed", "X collection failed", True)

        posts: list[dict[str, Any]] = []
        seen_post_ids: set[str] = set()
        for tweet in tweets[:limit]:
            post = normalize_tweet(source, tweet)
            if post is None or post["external_post_id"] in seen_post_ids:
                continue
            seen_post_ids.add(post["external_post_id"])
            posts.append(post)
        return posts, None

    async def collect(self, sources: list[dict[str, str]], limit: int) -> dict[str, list[dict[str, Any]]]:
        tasks = [asyncio.create_task(self.collect_source(source, limit)) for source in sources]
        done, pending = await asyncio.wait(tasks, timeout=RUN_TIMEOUT_SECONDS)
        for task in pending:
            task.cancel()
        if pending:
            await asyncio.gather(*pending, return_exceptions=True)

        posts: list[dict[str, Any]] = []
        errors: list[dict[str, Any]] = []
        for source, task in zip(sources, tasks):
            if task not in done:
                errors.append(source_error(source, "run_timeout", "X collection run timed out", True))
                continue
            source_posts, error = task.result()
            posts.extend(source_posts)
            if error:
                errors.append(error)
        return {"posts": posts, "errors": errors}


async def configure_account(api: API, auth_token: str, ct0: str) -> None:
    account = await api.pool.get_account(ACCOUNT_NAME)
    if account is None:
        await api.pool.add_account_cookies(ACCOUNT_NAME, f"auth_token={auth_token}; ct0={ct0}")
        return
    if (
        account.cookies.get("auth_token") == auth_token
        and account.cookies.get("ct0") == ct0
        and account.active
    ):
        return
    account.cookies = {**account.cookies, "auth_token": auth_token, "ct0": ct0}
    account.active = True
    account.error_msg = None
    account.headers = {}
    account.locks = {}
    await api.pool.save(account)


async def on_startup(app: web.Application) -> None:
    auth_token = required_environment("TWSCRAPE_AUTH_TOKEN")
    ct0 = required_environment("TWSCRAPE_CT0")
    api = API(
        ACCOUNT_DB_PATH,
        raise_when_no_account=True,
        wait_timeout=10,
        wait_interval=1,
    )
    await configure_account(api, auth_token, ct0)
    app["collector"] = Collector(api)
    app["api"] = api


async def collect_handler(request: web.Request) -> web.Response:
    try:
        body = await request.json()
        sources, limit = validate_collect_request(body)
    except (json.JSONDecodeError, ValueError):
        return web.json_response({"error": {"code": "invalid_request", "message": "Invalid collection request"}}, status=400)
    result = await request.app["collector"].collect(sources, limit)
    return web.json_response(result)


async def health_handler(request: web.Request) -> web.Response:
    stats = await request.app["api"].pool.stats()
    active_accounts = int(stats.get("active", 0))
    status = 200 if active_accounts else 503
    return web.json_response({"status": "ok" if active_accounts else "unavailable", "active_accounts": active_accounts}, status=status)


def create_app() -> web.Application:
    app = web.Application()
    app.on_startup.append(on_startup)
    app.router.add_post("/collect", collect_handler)
    app.router.add_get("/health", health_handler)
    return app


if __name__ == "__main__":
    web.run_app(create_app(), host="0.0.0.0", port=int(os.environ.get("PORT", "8080")), access_log=None)
