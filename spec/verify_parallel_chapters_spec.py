"""Offline transport tests for the controlled real-service validation script."""

import base64
from concurrent.futures import ThreadPoolExecutor
from contextlib import redirect_stderr, redirect_stdout
import hashlib
import http.cookiejar
import io
import json
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
import urllib.error
import urllib.parse


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import fetch_weread_epub as reference
import verify_parallel_chapters as probe


BOOK_ID = "123"
SECRET_COOKIE = "OFFLINE_CREDENTIAL_MUST_NOT_APPEAR"
SECRET_BODY = "OFFLINE_BODY_MUST_NOT_APPEAR"


def cookie(name, value):
    return http.cookiejar.Cookie(
        version=0, name=name, value=value, port=None, port_specified=False,
        domain=".weread.qq.com", domain_specified=True, domain_initial_dot=True,
        path="/", path_specified=True, secure=True, expires=None, discard=True,
        comment=None, comment_url=None, rest={}, rfc2109=False)


def shards(text):
    encoded = base64.b64encode(text.encode("utf-8")).decode("ascii")
    positions = reference.swap_positions(encoded)
    characters = list(encoded)
    for index in range(1, len(positions), 2):
        for delta in (0, 1):
            left, right = positions[index] + delta, positions[index - 1] + delta
            characters[left], characters[right] = characters[right], characters[left]
    body = "0" + "".join(characters)
    first, second = len(body) // 3, 2 * len(body) // 3
    pieces = (body[:first], body[first:second], body[second:])
    return [hashlib.md5(piece.encode()).hexdigest().upper() + piece for piece in pieces]


class Response:
    def __init__(self, body):
        self.body = body

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def read(self):
        return self.body


class Transport:
    def __init__(self):
        self.clients, self.calls = [], []
        self.lock = threading.Lock()
        self.active = self.peak = 0
        self.fail_uid = None
        self.failures = {}
        self.wait_for_stop_ids = set()
        self.txt_uids = set()
        self.sync_ids = set()
        self.barrier = threading.Barrier(2)
        self.catalog_count = 10
        uids = [str(uid) for uid in range(1, 11)]
        self.reader_uids = {reference.reader_url_for(BOOK_ID, uid): uid for uid in uids}
        self.encoded_uids = {reference.weread_e(uid): uid for uid in uids}
        self.shards = {uid: shards(f"<p>{SECRET_BODY} {uid}</p>") for uid in uids}
        self.txt_bodies = {uid: "".join(part[32:] for part in shards(f"TXT {SECRET_BODY} {uid}"))
                           for uid in uids}

    def factory(self, source, budget):
        client = probe.ProbeClient(source, budget)
        client_number = len(self.clients)
        self.clients.append(client)
        transport = self

        class Opener:
            def open(self, request, timeout):
                return transport.open(client, client_number, request, timeout)

        client.opener = Opener()
        return client

    def open(self, client, number, request, timeout):
        method, url = request.get_method(), request.full_url
        path = urllib.parse.urlsplit(url).path
        parameters = json.loads(request.data) if request.data else None
        with self.lock:
            self.active += 1
            self.peak = max(self.peak, self.active)
            self.calls.append((number, method, path, parameters))
        try:
            if number in self.sync_ids and method == "GET":
                self.barrier.wait(timeout=2)
            time.sleep(0.005)
            assert timeout == 30
            client.cookie_jar.set_cookie(cookie("response_only", f"private-response-{number}"))
            endpoint = "reader" if method == "GET" else path.rsplit("/", 1)[-1]
            if number in self.wait_for_stop_ids:
                assert client.budget.stopped.wait(timeout=2)
            failure = self.failures.get((number, endpoint))
            if failure and "status" in failure:
                raise urllib.error.HTTPError(url, failure["status"], "denied", {}, io.BytesIO(SECRET_BODY.encode()))
            if failure and "api_code" in failure:
                return Response(json.dumps({"errCode": failure["api_code"], "errMsg": SECRET_BODY}).encode())
            if method == "GET":
                uid = self.reader_uids.get(url, "1")
                state = {"reader": {"bookInfo": {"bookId": BOOK_ID},
                                    "psvts": f"private-context-{uid}",
                                    "currentChapter": {"chapterUid": int(uid)}}}
                return Response(("window.__INITIAL_STATE__ = " + json.dumps(state)
                                 + "; (function").encode())
            if path == "/web/book/chapterInfos":
                catalog = {"bookId": BOOK_ID, "chapters": [
                    {"chapterUid": 99, "wordCount": 0, "title": "Cover"},
                ] + [{"chapterUid": uid, "wordCount": 10, "title": f"Chapter {uid}"}
                     for uid in range(1, self.catalog_count + 1)]}
                return Response(json.dumps(catalog).encode())
            uid = self.encoded_uids[parameters["c"]]
            assert parameters["sc"] == 1
            assert parameters["pc"] == reference.weread_e(parameters["ct"])
            unsigned = {key: value for key, value in parameters.items() if key != "s"}
            assert parameters["s"] == reference.weread_sign(reference.sorted_query(unsigned))
            if uid == self.fail_uid:
                raise urllib.error.HTTPError(url, 403, "denied", {}, io.BytesIO(SECRET_BODY.encode()))
            if uid in self.txt_uids:
                endpoint = path.rsplit("/", 1)[-1]
                if endpoint == "e_0":
                    return Response(json.dumps({"bookId": BOOK_ID}).encode())
                if endpoint == "t_0":
                    body = self.txt_bodies[uid]
                    return Response((hashlib.md5(body.encode()).hexdigest().upper() + body).encode())
                if endpoint == "t_1":
                    return Response(b"{}")
            part = {"e_0": 0, "e_1": 1, "e_3": 2}[path.rsplit("/", 1)[-1]]
            return Response(self.shards[uid][part].encode())
        finally:
            with self.lock:
                self.active -= 1


class ParallelChapterProbeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="weread-probe-spec-")
        self.addCleanup(self.temporary.cleanup)
        self.cookie_path = Path(self.temporary.name) / "input.cookies"
        jar = http.cookiejar.MozillaCookieJar(str(self.cookie_path))
        jar.set_cookie(cookie("wr_skey", SECRET_COOKIE))
        jar.save(ignore_discard=True, ignore_expires=True)
        self.original = self.cookie_path.read_bytes()
        self.cookie_path.chmod(0o400)
        self.transport = Transport()
        self.budget = probe.RequestBudget(interval=0)
        denied = patch("urllib.request.OpenerDirector.open", side_effect=AssertionError("real transport forbidden"))
        denied.start()
        self.addCleanup(denied.stop)

    def run_probe(self, modes=probe.DEFAULT_MODES, **options):
        return probe.run_probe(self.cookie_path, book_id=BOOK_ID, modes=modes,
                               client_factory=self.transport.factory, budget=self.budget, **options)

    def test_default_a_b_a_does_not_refresh_last_a(self):
        report = self.run_probe()
        self.assertNotIn("error", report)
        self.assertEqual([row["case"] for row in report["cases"]], ["baseline", "baseline", "isolated"])
        self.assertEqual([row["chapter_uid"] for row in report["cases"]], ["1", "2", "1"])
        self.assertTrue(report["cases"][-1]["matches_baseline"])
        last_calls = [item for item in self.transport.calls if item[0] == 3]
        self.assertEqual(len(last_calls), 3)
        self.assertTrue(all(item[1] == "POST" and item[3]["ps"] == "private-context-1" for item in last_calls))
        self.assertEqual(self.cookie_path.read_bytes(), self.original)
        self.assertTrue(report["cookie_input_unchanged"])
        serialized = json.dumps(report)
        self.assertNotIn(SECRET_COOKIE, serialized)
        self.assertNotIn(SECRET_BODY, serialized)
        self.assertNotIn("private-context", serialized)
        self.assertTrue(all(row["cookies_changed"] for row in report["cases"]))

    def test_shared_and_parallel_use_private_jars_and_cap_two(self):
        self.transport.sync_ids = {5, 6}
        report = self.run_probe(probe.MODES)
        self.assertNotIn("error", report)
        self.assertEqual(len(report["cases"]), 6)
        self.assertTrue(all("error" not in row and row.get("matches_baseline") is not False
                            for row in report["cases"]))
        self.assertEqual(self.transport.peak, 2)
        self.assertEqual(self.budget.peak_active, 2)
        self.assertEqual(report["request_stats"]["peak_in_flight"], 2)
        self.assertEqual(report["request_stats"]["request_count"], len(self.transport.calls))
        self.assertGreaterEqual(report["request_stats"]["min_start_spacing_seconds"], 0)
        self.assertGreater(report["parallel_wall_seconds"], 0)
        self.assertGreaterEqual(report["parallel_wall_seconds"] + 0.000001,
                                max(row["seconds"] for row in report["cases"] if row["case"] == "parallel"))
        shared_calls = [item for item in self.transport.calls if item[0] == 4]
        self.assertEqual(len(shared_calls), 3)
        self.assertTrue(all(item[1] == "POST" and item[3]["ps"] == "private-context-1"
                            and self.transport.encoded_uids[item[3]["c"]] == "2" for item in shared_calls))
        clients = self.transport.clients
        self.assertEqual(len({id(client.cookie_jar) for client in clients}), len(clients))
        originals = [next(cookie for cookie in client.cookie_jar if cookie.name == "wr_skey") for client in clients]
        self.assertEqual(len({id(item) for item in originals}), len(originals))
        for client in clients:
            self.assertIsNone(client.save_cookies)
            self.assertFalse(hasattr(client.cookie_jar, "filename"))
        self.assertEqual(self.cookie_path.read_bytes(), self.original)
        self.assertFalse(any("/read" == item[2].split("/book", 1)[-1]
                             or "renewal" in item[2] for item in self.transport.calls))

    def test_global_launch_interval_and_budget_hard_limit(self):
        now = [0.0]
        gate = probe.RequestBudget(clock=lambda: now[0], sleep=lambda seconds: now.__setitem__(0, now[0] + seconds))
        for _ in range(4):
            with gate.request():
                pass
        self.assertEqual(gate.interval, 0.3)
        for left, right in zip(gate.start_times, gate.start_times[1:]):
            self.assertAlmostEqual(right - left, 0.3)
        self.assertEqual(gate.summary(), {"request_count": 4, "peak_in_flight": 1,
                                          "min_start_spacing_seconds": 0.3})
        parallel_gate = probe.RequestBudget(interval=0)

        def held_request(_number):
            with parallel_gate.request():
                time.sleep(0.01)

        with ThreadPoolExecutor(max_workers=8) as executor:
            list(executor.map(held_request, range(8)))
        self.assertEqual(parallel_gate.peak_active, 2)
        self.assertEqual(parallel_gate.active, 0)

    def test_errors_are_redacted_and_stop_extra_requests(self):
        self.transport.fail_uid = "1"
        report = self.run_probe(probe.MODES)
        self.assertEqual(report["cases"][0]["error"], {"type": "HTTPError", "code": 403})
        self.assertTrue(report["advanced_cases_skipped"])
        self.assertEqual(len(self.transport.clients), 2)
        serialized = json.dumps(report)
        self.assertNotIn(SECRET_BODY, serialized)
        self.assertNotIn(SECRET_COOKIE, serialized)
        self.assertNotIn("https://", serialized)

    def test_forbidden_operations_never_reach_transport(self):
        client = self.transport.factory(http.cookiejar.CookieJar(), self.budget)
        for action in (
            lambda: client.renew(),
            lambda: client.persist_cookies(),
            lambda: client.request("https://weread.qq.com/web/book/read", method="POST", data={}),
            lambda: client.request("https://weread.qq.com/web/login/renewal", method="POST", data={}),
            lambda: client.request("https://example.test/web/reader/example"),
            lambda: client.request("https://weread.qq.com/web/reader/../../web/book/read"),
        ):
            with self.assertRaises(probe.ProbeError):
                action()
        self.assertEqual(self.transport.calls, [])

    def test_report_cannot_overwrite_cookie_input_or_its_hardlink(self):
        for output in (self.cookie_path, Path(self.temporary.name) / "linked-report.json"):
            if output != self.cookie_path:
                output.hardlink_to(self.cookie_path)
            stream = io.StringIO()
            with redirect_stdout(stream):
                result = probe.main(["--cookie-file", str(self.cookie_path), "--book-id", BOOK_ID,
                                     "--output", str(output)], client_factory=self.transport.factory)
            self.assertEqual(result, 1)
            self.assertEqual(json.loads(stream.getvalue())["error"]["code"],
                             "report_must_not_replace_cookie_file")
            self.assertEqual(self.cookie_path.read_bytes(), self.original)
        self.assertEqual(self.transport.clients, [])

    def test_explicit_selection_and_baseline_only(self):
        report = self.run_probe(("baseline",), chapters=["3", "1"])
        self.assertEqual([row["chapter_uid"] for row in report["cases"]], ["3", "1"])
        self.assertEqual(len(self.transport.clients), 3)
        self.assertEqual(self.cookie_path.read_bytes(), self.original)

    def test_interruption_is_redacted_without_an_exception_trace(self):
        output = Path(self.temporary.name) / "report.json"
        stream = io.StringIO()
        with patch.object(probe, "run_probe", side_effect=KeyboardInterrupt), redirect_stdout(stream):
            result = probe.main(["--cookie-file", str(self.cookie_path), "--book-id", BOOK_ID,
                                 "--output", str(output)], client_factory=self.transport.factory)
        self.assertEqual(result, 130)
        self.assertEqual(json.loads(stream.getvalue()), {"error": {"type": "KeyboardInterrupt"}})
        self.assertEqual(self.cookie_path.read_bytes(), self.original)

    def test_format_is_preserved_per_chapter(self):
        self.transport.txt_uids = {"2"}
        self.transport.sync_ids = {5, 6}
        report = self.run_probe(probe.MODES)
        self.assertNotIn("error", report)
        self.assertTrue(all("error" not in row and row.get("matches_baseline") is not False
                            for row in report["cases"]))
        repeated_a = [item[2].rsplit("/", 1)[-1] for item in self.transport.calls if item[0] == 3]
        self.assertEqual(repeated_a, ["e_0", "e_1", "e_3"])
        shared_b = [item[2].rsplit("/", 1)[-1] for item in self.transport.calls if item[0] == 4]
        self.assertEqual(shared_b, ["t_0", "t_1"])

    def test_malformed_cookie_parser_does_not_warn_with_credentials(self):
        malformed = ("# Netscape HTTP Cookie File\n"
                     f".weread.qq.com\tTRUE\t/\tTRUE\t{SECRET_BODY}\twr_skey\t{SECRET_COOKIE}\n").encode()
        self.cookie_path.chmod(0o600)
        self.cookie_path.write_bytes(malformed)
        self.cookie_path.chmod(0o400)
        stdout, stderr = io.StringIO(), io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            report = self.run_probe()
        self.assertEqual(report["error"]["type"], "LoadError")
        self.assertEqual(report["stage"], "credentials")
        self.assertEqual(stdout.getvalue(), "")
        self.assertEqual(stderr.getvalue(), "")
        self.assertNotIn(SECRET_BODY, json.dumps(report))
        self.assertNotIn(SECRET_COOKIE, json.dumps(report))
        self.assertEqual(self.transport.clients, [])
        self.assertEqual(self.cookie_path.read_bytes(), malformed)

    def test_optional_txt_shard_does_not_swallow_api_or_http_errors(self):
        for failure in ({"api_code": -2013}, {"api_code": -2010}, {"api_code": -2012},
                        {"api_code": -999}, {"status": 401}, {"status": 403}, {"status": 429}):
            with self.subTest(failure=failure):
                self.transport, self.budget = Transport(), probe.RequestBudget(interval=0)
                self.transport.txt_uids = {"1"}
                self.transport.failures[(1, "t_1")] = failure
                report = self.run_probe(probe.MODES)
                row = report["cases"][0]
                self.assertNotIn("sha256", row)
                self.assertEqual(row["stage"], "chapter")
                if "api_code" in failure:
                    self.assertEqual(row["error"], {"type": "ProbeError", "code": "api_error",
                                                     "api_code": failure["api_code"]})
                else:
                    self.assertEqual(row["error"], {"type": "HTTPError", "code": failure["status"]})
                self.assertTrue(report["advanced_cases_skipped"])
                self.assertEqual(len(self.transport.clients), 2)
                self.assertNotIn(SECRET_BODY, json.dumps(report))

    def test_advanced_failures_stop_later_cases_and_new_admission(self):
        for client_id, failure in ((3, {"status": 401}), (3, {"status": 403}), (3, {"status": 429}),
                                   (3, {"api_code": -2013}), (3, {"api_code": -2010}),
                                   (4, {"status": 429}), (4, {"api_code": -2012})):
            with self.subTest(client_id=client_id, failure=failure):
                self.transport, self.budget = Transport(), probe.RequestBudget(interval=0)
                self.transport.failures[(client_id, "e_0")] = failure
                report = self.run_probe(probe.MODES)
                self.assertTrue(report["advanced_cases_skipped"])
                self.assertEqual(len(self.transport.clients), client_id + 1)
                self.assertNotIn("parallel_wall_seconds", report)
                self.assertTrue(self.budget.stopped.is_set())
                count = len(self.transport.calls)
                with self.assertRaises(probe.ProbeError) as raised:
                    with self.budget.request():
                        self.fail("stopped probe admitted another request")
                self.assertEqual(raised.exception.code, "probe_stopped")
                self.assertEqual(len(self.transport.calls), count)
                self.assertEqual(report["request_stats"]["request_count"], count)

    def test_parallel_failure_stops_peer_before_its_next_request(self):
        self.transport.sync_ids = {3, 4}
        self.transport.wait_for_stop_ids = {4}
        self.transport.failures[(3, "reader")] = {"status": 403}
        report = self.run_probe(("parallel",))
        advanced = [item for item in self.transport.calls if item[0] >= 3]
        self.assertEqual(len(advanced), 2)
        self.assertTrue(all(item[1] == "GET" for item in advanced))
        self.assertEqual(report["request_stats"]["peak_in_flight"], 2)
        rows = [row for row in report["cases"] if row["case"] == "parallel"]
        self.assertEqual(rows[0]["error"], {"type": "HTTPError", "code": 403})
        self.assertEqual(rows[1]["error"], {"type": "ProbeError", "code": "probe_stopped"})
        self.assertGreater(report["parallel_wall_seconds"], 0)
        self.assertTrue(report["advanced_cases_skipped"])

    def test_setup_errors_report_a_fixed_stage_without_body_text(self):
        with patch.object(probe, "read_reader_state", side_effect=ValueError(SECRET_BODY)):
            report = self.run_probe()
        self.assertEqual(report["stage"], "reader_parse")
        self.assertEqual(report["request_stats"]["request_count"], 1)
        self.assertNotIn(SECRET_BODY, json.dumps(report))
        self.transport, self.budget = Transport(), probe.RequestBudget(interval=0)
        with patch.object(probe, "normalize_chapter_infos", side_effect=ValueError(SECRET_BODY)):
            report = self.run_probe()
        self.assertEqual(report["stage"], "catalog_parse")
        self.assertEqual(report["request_stats"]["request_count"], 2)
        self.assertNotIn(SECRET_BODY, json.dumps(report))

    def test_timing_controls_use_identical_txt_request_sequences(self):
        self.transport.txt_uids = {"1", "2"}
        self.transport.sync_ids = {5, 6}
        report = self.run_probe(("parallel",), timing_controls=True)
        self.assertEqual([row["case"] for row in report["cases"]],
                         ["baseline"] * 2 + ["serial_before"] * 2 + ["parallel"] * 2 + ["serial_after"] * 2)
        self.assertTrue(all("error" not in row and row.get("matches_baseline") is not False
                            for row in report["cases"]))
        for number in range(3, 9):
            endpoints = [item[2].rsplit("/", 1)[-1] if item[1] == "POST" else "reader"
                         for item in self.transport.calls if item[0] == number]
            self.assertEqual(endpoints, ["reader", "t_0", "t_1"])
        for label in ("serial_before", "parallel", "serial_after"):
            self.assertGreater(report[label + "_wall_seconds"], 0)
        self.assertEqual(report["request_stats"]["peak_in_flight"], 2)

    def test_timing_control_failure_does_not_start_parallel_requests(self):
        self.transport.failures[(3, "reader")] = {"status": 429}
        report = self.run_probe(("parallel",), timing_controls=True)
        self.assertTrue(report["advanced_cases_skipped"])
        self.assertEqual(len(self.transport.clients), 4)
        self.assertNotIn("parallel_wall_seconds", report)

    def test_digest_mismatch_stops_later_cases(self):
        with patch.object(probe, "decode_content_shards", side_effect=["first", "second", "changed"]):
            report = self.run_probe(probe.MODES)
        self.assertFalse(report["cases"][-1]["matches_baseline"])
        self.assertTrue(report["advanced_cases_skipped"])
        self.assertTrue(self.budget.stopped.is_set())
        self.assertEqual(len(self.transport.clients), 4)
        self.assertNotIn("parallel_wall_seconds", report)

    def test_five_and_ten_chapters_report_actual_phase_concurrency(self):
        for count, concurrency in ((5, 5), (10, 10), (10, 3), (5, 10)):
            with self.subTest(count=count, concurrency=concurrency):
                self.transport = Transport()
                self.budget = probe.RequestBudget(interval=0, concurrency=concurrency)
                actual_limit = min(count, concurrency)
                first_parallel = 2 * count + 1
                self.transport.sync_ids = set(range(first_parallel, first_parallel + actual_limit))
                self.transport.barrier = threading.Barrier(actual_limit)
                report = self.run_probe(("parallel",), timing_controls=True,
                                        chapter_count=count, concurrency=concurrency, start_interval=0)
                self.assertEqual(report["stage"], "complete")
                self.assertEqual(report["configured"], {"chapter_count": count, "concurrency": concurrency,
                                                        "start_interval_seconds": 0})
                self.assertEqual(len(report["cases"]), count * 4)
                self.assertTrue(all(row.get("content_format") == "epub" and "error" not in row
                                    and row.get("matches_baseline") is not False for row in report["cases"]))
                for stage in ("baseline", "serial_before", "parallel", "serial_after"):
                    self.assertEqual(report["stage_stats"][stage]["request_count"], count * 4)
                    expected_peak = actual_limit if stage == "parallel" else 1
                    self.assertEqual(report["stage_stats"][stage]["peak_in_flight"], expected_peak)
                    self.assertGreater(report["stage_stats"][stage]["wall_seconds"], 0)
                self.assertEqual(report["request_stats"]["peak_in_flight"], actual_limit)
                self.assertEqual(self.transport.peak, actual_limit)
                self.assertEqual(report["request_stats"]["request_count"], len(self.transport.calls))
                self.assertEqual(self.cookie_path.read_bytes(), self.original)
                self.assertNotIn(SECRET_BODY, json.dumps(report))

    def test_ten_chapter_failure_does_not_drain_queued_network_work(self):
        count, concurrency = 10, 5
        self.budget = probe.RequestBudget(interval=0, concurrency=concurrency)
        first_parallel = 2 * count + 1
        self.transport.sync_ids = set(range(first_parallel, first_parallel + concurrency))
        self.transport.barrier = threading.Barrier(concurrency)
        self.transport.failures[(first_parallel, "reader")] = {"status": 429}
        self.transport.wait_for_stop_ids = set(range(first_parallel + 1, first_parallel + count))
        report = self.run_probe(("parallel",), timing_controls=True,
                                chapter_count=count, concurrency=concurrency, start_interval=0)
        actual_parallel = [item for item in self.transport.calls if item[0] >= first_parallel]
        self.assertEqual(len(actual_parallel), concurrency)
        self.assertTrue(all(item[1] == "GET" for item in actual_parallel))
        self.assertEqual(report["stage_stats"]["parallel"]["request_count"], concurrency)
        self.assertEqual(report["stage_stats"]["parallel"]["peak_in_flight"], concurrency)
        self.assertNotIn("serial_after", report["stage_stats"])
        self.assertTrue(report["advanced_cases_skipped"])

    def test_five_chapter_mismatch_stops_queued_requests(self):
        self.budget = probe.RequestBudget(interval=0, concurrency=1)
        with patch.object(probe, "decode_content_shards", side_effect=["one", "two", "three", "four", "five", "changed"]):
            report = self.run_probe(("parallel",), chapter_count=5, concurrency=1, start_interval=0)
        parallel = [row for row in report["cases"] if row["case"] == "parallel"]
        self.assertFalse(parallel[0]["matches_baseline"])
        self.assertTrue(all(row["error"]["code"] == "probe_stopped" for row in parallel[1:]))
        self.assertEqual(report["stage_stats"]["parallel"]["request_count"], 4)
        self.assertTrue(report["advanced_cases_skipped"])

    def test_invalid_configuration_starts_zero_requests(self):
        invalid = ({"chapter_count": 1}, {"chapter_count": 11}, {"concurrency": 0}, {"concurrency": 11},
                   {"start_interval": -1}, {"start_interval": 11}, {"start_interval": float("inf")},
                   {"start_interval": float("nan")}, {"chapters": ["1"]}, {"chapters": ["1", "1"]})
        for options in invalid:
            with self.subTest(options=options):
                self.transport, self.budget = Transport(), probe.RequestBudget(interval=0)
                report = self.run_probe(("parallel",), **options)
                self.assertIn("error", report)
                self.assertEqual(report["stage"], "configuration")
                self.assertEqual(report["request_stats"]["request_count"], 0)
                self.assertEqual(self.transport.clients, [])
                self.assertEqual(self.transport.calls, [])
        for concurrency in (0, 11, True):
            with self.assertRaises(probe.ProbeError):
                probe.RequestBudget(concurrency=concurrency)

    def test_catalog_must_contain_the_requested_count(self):
        self.transport.catalog_count = 3
        report = self.run_probe(("parallel",), chapter_count=5)
        self.assertEqual(report["error"]["code"], "requested_readable_chapters_unavailable")
        self.assertEqual(report["stage"], "chapter_selection")
        self.assertEqual(report["request_stats"]["request_count"], 2)
        self.assertNotIn("baseline", report["stage_stats"])
        self.assertEqual(report["cases"], [])

    def test_cli_passes_count_concurrency_interval_and_uid_list(self):
        output = Path(self.temporary.name) / "report.json"
        report = {"cases": [], "cookie_input_unchanged": True}
        stream = io.StringIO()
        with patch.object(probe, "run_probe", return_value=report) as run, redirect_stdout(stream):
            result = probe.main(["--cookie-file", str(self.cookie_path), "--book-id", BOOK_ID,
                                 "--output", str(output), "--chapter-count", "5", "--concurrency", "5",
                                 "--start-interval", "0", "--chapters", "1", "2", "3", "4", "5",
                                 "--modes", "parallel", "--timing-controls"])
        self.assertEqual(result, 0)
        self.assertEqual(run.call_args.kwargs["chapter_count"], 5)
        self.assertEqual(run.call_args.kwargs["concurrency"], 5)
        self.assertEqual(run.call_args.kwargs["start_interval"], 0)
        self.assertEqual(run.call_args.kwargs["chapters"], ["1", "2", "3", "4", "5"])
        self.assertTrue(run.call_args.kwargs["timing_controls"])


if __name__ == "__main__":
    unittest.main()
