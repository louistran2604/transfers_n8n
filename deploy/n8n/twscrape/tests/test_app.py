import asyncio
import json
import sys
import unittest
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import app


def source(source_id="source-1", x_user_id="330262748"):
    return {"source_id": source_id, "username": "transfer_source", "x_user_id": x_user_id}


class FakeTweet:
    def __init__(self, post_id, content, *, quote=None, retweet=None):
        self.id_str = post_id
        self.rawContent = content
        self.date = datetime(2026, 7, 27, 12, 0, tzinfo=timezone.utc)
        self.url = f"https://x.com/transfer_source/status/{post_id}"
        self.quotedTweet = quote
        self.retweetedTweet = retweet

    def json(self):
        return json.dumps({"id": int(self.id_str), "id_str": self.id_str, "rawContent": self.rawContent})


class FakeAPI:
    def __init__(self):
        self.limits = []

    async def user_tweets(self, user_id, limit):
        self.limits.append((user_id, limit))
        if user_id == 222:
            raise app.NoAccountError()
        if user_id == 333:
            await asyncio.sleep(0.01)
        yield FakeTweet("900000000000000001", "Direct transfer report")
        yield FakeTweet("900000000000000002", "Quote comment", quote=SimpleNamespace(rawContent="Quoted transfer report"))
        yield FakeTweet("900000000000000003", "RT @source: ignored", retweet=object())


class TwscrapeServiceTests(unittest.IsolatedAsyncioTestCase):
    def test_normalization_preserves_string_ids_handles_quotes_and_drops_retweets(self):
        direct = app.normalize_tweet(source(), FakeTweet("900000000000000001", "Direct transfer report"))
        self.assertIsNotNone(direct)
        self.assertIsInstance(direct["x_user_id"], str)
        self.assertIsInstance(direct["external_post_id"], str)
        self.assertEqual(direct["raw_payload"]["id"], "900000000000000001")

        quoted = app.normalize_tweet(source(), FakeTweet("900000000000000002", "Quote comment", quote=SimpleNamespace(rawContent="Quoted transfer report")))
        self.assertTrue(quoted["is_quote"])
        self.assertIn("Quoted post:\nQuoted transfer report", quoted["content"])

        retweet = app.normalize_tweet(source(), FakeTweet("900000000000000003", "RT @source: ignored", retweet=object()))
        self.assertIsNone(retweet)

    def test_request_validation_keeps_user_ids_as_strings_and_limits_to_twenty(self):
        sources, limit = app.validate_collect_request({"sources": [source()], "limit": 20})
        self.assertEqual(limit, 20)
        self.assertEqual(sources[0]["x_user_id"], "330262748")
        self.assertIsInstance(sources[0]["x_user_id"], str)
        with self.assertRaises(ValueError):
            app.validate_collect_request({"sources": [source()], "limit": 21})
        with self.assertRaises(ValueError):
            app.validate_collect_request({"sources": [{**source(), "x_user_id": 330262748}], "limit": 20})

    async def test_partial_source_failure_keeps_successful_posts(self):
        api = FakeAPI()
        result = await app.Collector(api, concurrency=2).collect([
            source("source-1", "111"),
            source("source-2", "222"),
            source("source-3", "333"),
        ], 20)
        self.assertEqual(len(result["posts"]), 4)
        self.assertEqual(result["errors"], [{
            "source_id": "source-2",
            "username": "transfer_source",
            "x_user_id": "222",
            "code": "account_unavailable",
            "message": "X account unavailable",
            "retryable": True,
        }])
        self.assertEqual(api.limits, [(111, 20), (222, 20), (333, 20)])


if __name__ == "__main__":
    unittest.main()
