#!/usr/bin/env python3
"""Compare chapter contexts without renewal or read-report API calls.

Credentials are loaded from a Netscape cookie file exactly once into private
in-memory jars. The input file is never saved. No renewal, read reporting,
progress API, image download, or unrecognized endpoint is permitted.

Every run establishes serial chapter baselines. The default additional case repeats
A with its saved reader parameters and cookie snapshot, without refreshing the
reader. Optional shared and parallel cases reuse A's context for B, or acquire
selected chapters through independent clients. Defaults are two chapters, two
request slots, and a global 0.3-second start interval. Explicit configuration is
limited to ten chapters and ten slots. Reports contain no body or secrets.
Optional timing controls bracket the parallel phase with serial phases using
the same detected formats, reader refreshes, and chapter request sequences.
"""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
import copy
from dataclasses import dataclass, field
import hashlib
import http.cookiejar
import json
import math
import os
from pathlib import Path
import tempfile
import threading
import time
from typing import Any, Callable, Iterable, Optional
import urllib.error
import urllib.parse
import urllib.request
import warnings

from fetch_weread_epub import (
    WeReadClient,
    decode_content_shards,
    make_content_params,
    normalize_chapter_infos,
    read_reader_state,
    reader_url_for,
)


MODES = ("baseline", "isolated", "shared", "parallel")
DEFAULT_MODES = ("baseline", "isolated")
MAX_CHAPTERS = MAX_CONCURRENCY = 10
MAX_START_INTERVAL = 10.0
CHAPTER_ENDPOINTS = {
    "/web/book/chapter/e_0", "/web/book/chapter/e_1", "/web/book/chapter/e_3",
    "/web/book/chapter/t_0", "/web/book/chapter/t_1",
}


class ProbeError(ValueError):
    """A fixed, non-sensitive diagnostic code."""

    def __init__(self, code: str, *, api_code: Optional[int] = None) -> None:
        self.code = code
        self.api_code = api_code
        super().__init__(code)


def safe_error(error: BaseException) -> dict[str, Any]:
    """Never stringify an upstream exception, whose message may contain a body."""
    current: Optional[BaseException] = error
    for _ in range(5):
        if isinstance(current, urllib.error.HTTPError):
            return {"type": "HTTPError", "code": int(current.code)}
        if current is None:
            break
        current = current.__cause__
    if isinstance(error, ProbeError):
        result = {"type": "ProbeError", "code": error.code}
        if error.api_code is not None:
            result["api_code"] = error.api_code
        return result
    result: dict[str, Any] = {"type": type(error).__name__}
    if isinstance(error, OSError) and isinstance(error.errno, int):
        result["code"] = error.errno
    return result


def check_api_response(payload: bytes) -> None:
    """Reject known error envelopes before treating their bytes as a shard."""
    if not payload.lstrip().startswith(b"{"):
        return
    try:
        value = json.loads(payload)
    except ValueError:
        raise ProbeError("invalid_api_response") from None
    for name in ("errCode", "errcode", "code"):
        raw_code = value.get(name)
        if raw_code is None:
            continue
        try:
            code = int(raw_code)
            if isinstance(raw_code, bool) or abs(code) > 2147483647 or (
                    isinstance(raw_code, float) and code != raw_code):
                raise ValueError
        except (ValueError, TypeError, OverflowError):
            raise ProbeError("invalid_api_code") from None
        if code != 0:
            raise ProbeError("api_error", api_code=code)
        break


def copy_cookie_jar(source: http.cookiejar.CookieJar) -> http.cookiejar.CookieJar:
    result = http.cookiejar.CookieJar()
    for cookie in source:
        result.set_cookie(copy.deepcopy(cookie))
    return result


def cookie_state(jar: http.cookiejar.CookieJar) -> list[dict[str, Any]]:
    return [copy.deepcopy(vars(cookie)) for cookie in sorted(
        jar, key=lambda item: (item.domain, item.path, item.name))]


def budget_configuration(concurrency: int, interval: float) -> tuple[int, float]:
    if isinstance(concurrency, bool) or not isinstance(concurrency, int) or not 1 <= concurrency <= MAX_CONCURRENCY:
        raise ProbeError("invalid_concurrency")
    try:
        interval = float(interval)
    except (TypeError, ValueError, OverflowError):
        raise ProbeError("invalid_start_interval") from None
    if not math.isfinite(interval) or not 0 <= interval <= MAX_START_INTERVAL:
        raise ProbeError("invalid_start_interval")
    return concurrency, interval


class RequestBudget:
    """One global start-rate gate and an explicitly bounded request cap."""

    def __init__(self, interval: float = 0.3, *, concurrency: int = 2, clock: Callable[[], float] = time.monotonic,
                 sleep: Callable[[float], None] = time.sleep) -> None:
        self.concurrency, self.interval = budget_configuration(concurrency, interval)
        self.clock, self.sleep = clock, sleep
        self.slots = threading.BoundedSemaphore(self.concurrency)
        self.start_lock, self.activity_lock = threading.Lock(), threading.Lock()
        self.next_start = 0.0
        self.active = self.peak_active = 0
        self.start_times: list[float] = []
        self.stopped = threading.Event()
        self.phase: Optional[str] = None
        self.phases: dict[str, dict[str, Any]] = {}

    def begin_phase(self, name: str) -> None:
        with self.start_lock, self.activity_lock:
            if self.active:
                raise ProbeError("phase_has_active_requests")
            now = self.clock()
            if self.phase is not None:
                self.phases[self.phase]["ended"] = now
            self.phase = name
            self.phases[name] = {"starts": [], "peak": 0, "started": now}

    def phase_summaries(self) -> dict[str, dict[str, Any]]:
        result = {}
        for name, phase in self.phases.items():
            starts = phase["starts"]
            spacing = min((right - left for left, right in zip(starts, starts[1:])), default=None)
            result[name] = {"request_count": len(starts), "peak_in_flight": phase["peak"],
                            "min_start_spacing_seconds": round(spacing, 6) if spacing is not None else None,
                            "wall_seconds": round(phase.get("ended", self.clock()) - phase["started"], 6)}
        return result

    def stop(self) -> None:
        self.stopped.set()

    def check_running(self) -> None:
        if self.stopped.is_set():
            raise ProbeError("probe_stopped")

    def summary(self) -> dict[str, Any]:
        starts = self.start_times[:]
        spacing = min((right - left for left, right in zip(starts, starts[1:])), default=None)
        return {"request_count": len(starts), "peak_in_flight": self.peak_active,
                "min_start_spacing_seconds": round(spacing, 6) if spacing is not None else None}

    @contextmanager
    def request(self) -> Iterable[None]:
        self.check_running()
        with self.slots:
            active = False
            try:
                with self.start_lock:
                    self.check_running()
                    delay = self.next_start - self.clock()
                    if delay > 0:
                        self.sleep(delay)
                    self.check_running()
                    started = self.clock()
                    self.next_start = started + self.interval
                    self.start_times.append(started)
                    with self.activity_lock:
                        self.active += 1
                        self.peak_active = max(self.peak_active, self.active)
                        if self.phase is not None:
                            phase = self.phases[self.phase]
                            phase["starts"].append(started)
                            phase["peak"] = max(phase["peak"], self.active)
                        active = True
                yield
            finally:
                if active:
                    with self.activity_lock:
                        self.active -= 1


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """A redirect must not bypass the request budget or endpoint allowlist."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class ProbeClient(WeReadClient):
    def __init__(self, source: http.cookiejar.CookieJar, budget: RequestBudget) -> None:
        # The reference request() updates its jar but never persists it. Do not
        # pass the input path to its constructor: save_cookies defaults to it.
        super().__init__(cookie_file=None, cookie_string=None, save_cookies=None)
        self.cookie_jar = copy_cookie_jar(source)
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(self.cookie_jar), NoRedirect())
        self.budget = budget
        self.cookies_changed = False

    def persist_cookies(self) -> None:
        raise ProbeError("cookie_persistence_forbidden")

    def renew(self, rq: str = "%2Fweb%2Fbook%2Fread") -> bool:
        raise ProbeError("renewal_forbidden")

    def request(self, url: str, *, method: str = "GET", data=None,
                referer: str = "https://weread.qq.com/",
                accept: str = "application/json, text/plain, */*") -> bytes:
        target = urllib.parse.urlsplit(url)
        reader_id = target.path.removeprefix("/web/reader/")
        reader = (method == "GET" and target.path.startswith("/web/reader/")
                  and reader_id.isascii() and reader_id.isalnum())
        post = method == "POST" and (target.path in CHAPTER_ENDPOINTS
                                     or target.path == "/web/book/chapterInfos")
        if (target.scheme != "https" or target.hostname != "weread.qq.com"
                or target.port not in (None, 443) or target.username or target.password
                or target.query or target.fragment or not (reader or post)):
            raise ProbeError("request_not_allowed")
        before = cookie_state(self.cookie_jar)
        try:
            with self.budget.request():
                try:
                    payload = super().request(url, method=method, data=data, referer=referer, accept=accept)
                    if method == "POST":
                        check_api_response(payload)
                    return payload
                except Exception:
                    self.budget.stop()
                    raise
        finally:
            self.cookies_changed = self.cookies_changed or before != cookie_state(self.cookie_jar)


@dataclass(frozen=True)
class SavedContext:
    psvts: str = field(repr=False)


def reader_context(client: ProbeClient, book_id: str, chapter_uid: str) -> SavedContext:
    url = reader_url_for(book_id, chapter_uid)
    state = read_reader_state(client.get_text(url, referer=url))
    if state.book_id != book_id:
        raise ProbeError("reader_book_mismatch")
    if not state.psvts:
        raise ProbeError("missing_reader_context")
    return SavedContext(psvts=state.psvts)


def chapter_text(client: ProbeClient, book_id: str, chapter_uid: str,
                 context: SavedContext, content_format: str = "auto") -> tuple[str, str]:
    referer = reader_url_for(book_id, chapter_uid)

    def post(endpoint: str) -> str:
        # Preserve the reference strategy, including sc=1 and its computed pc.
        params = make_content_params(book_id, chapter_uid, context.psvts, style=False, sc=1)
        text = client.request("https://weread.qq.com" + endpoint, method="POST",
                              data=params, referer=referer).decode("utf-8", "replace")
        if text == "{}":
            raise ProbeError("empty_chapter_response")
        return text

    if content_format != "txt":
        e0 = post("/web/book/chapter/e_0")
        if not (e0.startswith("{") and '"bookId"' in e0):
            e1 = post("/web/book/chapter/e_1")
            e3 = post("/web/book/chapter/e_3")
            return decode_content_shards(e0, e1, e3), "epub"
    t0 = post("/web/book/chapter/t_0")
    try:
        t1 = post("/web/book/chapter/t_1")
    except ProbeError as error:
        if error.code != "empty_chapter_response":
            raise
        t1 = ""
    return decode_content_shards(t0, t1, ""), "txt"


def observe(case: str, client: ProbeClient, book_id: str, chapter_uid: str,
            baseline: Optional[str], saved: Optional[SavedContext] = None,
            content_format: str = "auto") -> tuple[dict[str, Any], Optional[SavedContext], str]:
    started = time.monotonic()
    row: dict[str, Any] = {"case": case, "chapter_uid": chapter_uid,
                           "stage": "reader" if saved is None else "chapter"}
    try:
        context = saved if saved is not None else reader_context(client, book_id, chapter_uid)
        row["stage"] = "chapter"
        decoded, detected = chapter_text(client, book_id, chapter_uid, context, content_format)
        data = decoded.encode("utf-8")
        digest = hashlib.sha256(data).hexdigest()
        row.update(decoded_chars=len(decoded), decoded_bytes=len(data), sha256=digest,
                   matches_baseline=(digest == baseline) if baseline is not None else None,
                   content_format=detected, stage="complete")
        if row["matches_baseline"] is False:
            client.budget.stop()
        return row, context, detected
    except Exception as error:
        client.budget.stop()
        row["error"] = safe_error(error)
        return row, None, content_format
    finally:
        row["seconds"] = round(time.monotonic() - started, 6)
        row["cookies_changed"] = client.cookies_changed


def run_probe(cookie_file: Path, *, book_id: Optional[str] = None,
              reader_url: Optional[str] = None, chapters: Optional[list[str]] = None,
              modes: Iterable[str] = DEFAULT_MODES, client_factory=ProbeClient,
              budget: Optional[RequestBudget] = None, timing_controls: bool = False,
              chapter_count: int = 2, concurrency: int = 2, start_interval: float = 0.3) -> dict[str, Any]:
    report: dict[str, Any] = {"schema_version": 1, "cases": [], "stage": "configuration"}
    gate = budget
    original_digest: Optional[bytes] = None
    setup_started = time.monotonic()
    setup_client = None
    try:
        concurrency, start_interval = budget_configuration(concurrency, start_interval)
        if isinstance(chapter_count, bool) or not isinstance(chapter_count, int) or not 2 <= chapter_count <= MAX_CHAPTERS:
            raise ProbeError("invalid_chapter_count")
        if chapters is not None:
            chapters = [str(item) for item in chapters]
            if len(chapters) != chapter_count or len(set(chapters)) != chapter_count or any(not item for item in chapters):
                raise ProbeError("chapter_count_mismatch")
        requested = set(modes)
        if not requested.issubset(MODES):
            raise ProbeError("invalid_mode")
        gate = budget if budget is not None else RequestBudget(start_interval, concurrency=concurrency)
        report["configured"] = {"chapter_count": chapter_count, "concurrency": gate.concurrency,
                                "start_interval_seconds": gate.interval}
        gate.begin_phase("setup")
        report["stage"] = "credentials"
        original_digest = hashlib.sha256(cookie_file.read_bytes()).digest()
        initial = http.cookiejar.MozillaCookieJar()
        # cookiejar can warn with the original credential line before raising
        # LoadError. Suppress only this parser's warnings; report the safe type.
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            initial.load(str(cookie_file), ignore_discard=True, ignore_expires=True)
        setup_client = client_factory(initial, gate)
        first_url = reader_url or reader_url_for(book_id or "")
        report["stage"] = "reader"
        reader_html = setup_client.get_text(first_url, referer=first_url)
        report["stage"] = "reader_parse"
        state = read_reader_state(reader_html)
        if book_id is not None and str(book_id) != state.book_id:
            raise ProbeError("reader_book_mismatch")
        resolved_id = str(book_id or state.book_id)
        report["stage"] = "catalog"
        payload = setup_client.post_json("https://weread.qq.com/web/book/chapterInfos",
                                         {"bookIds": [resolved_id]}, referer=first_url)
        report["stage"] = "catalog_parse"
        _, catalog = normalize_chapter_infos(payload, resolved_id)
        readable = [item for item in catalog if int(item.get("wordCount") or 0) > 0
                    and str(item.get("title") or "") != "\u5c01\u9762"]
        selected = [str(item["chapterUid"]) for item in readable[:chapter_count]] if chapters is None else list(chapters)
        valid = {str(item["chapterUid"]) for item in readable}
        report["stage"] = "chapter_selection"
        if len(selected) != chapter_count or len(set(selected)) != chapter_count or any(uid not in valid for uid in selected):
            raise ProbeError("requested_readable_chapters_unavailable")
        report["setup_seconds"] = round(time.monotonic() - setup_started, 6)
        report["setup_cookies_changed"] = setup_client.cookies_changed
        first_uid, second_uid = selected[:2]
        source_jar = copy_cookie_jar(setup_client.cookie_jar)
        baselines: dict[str, str] = {}
        formats: dict[str, str] = {}
        saved_first, saved_jar = None, None
        report["stage"] = "chapter"
        gate.begin_phase("baseline")
        for ordinal, chapter_uid in enumerate(selected):
            client = client_factory(source_jar, gate)
            row, saved, detected = observe("baseline", client, resolved_id, chapter_uid, None,
                                           content_format="auto")
            report["cases"].append(row)
            if "error" in row:
                report["advanced_cases_skipped"] = True
                return report
            baselines[chapter_uid] = row["sha256"]
            formats[chapter_uid] = detected
            if ordinal == 0:
                saved_first, saved_jar = saved, copy_cookie_jar(client.cookie_jar)
        assert saved_first is not None and saved_jar is not None
        for mode, chapter_uid in (("isolated", first_uid), ("shared", second_uid)):
            if mode in requested:
                gate.begin_phase(mode)
                client = client_factory(saved_jar, gate)
                row, _, _ = observe(mode, client, resolved_id, chapter_uid, baselines[chapter_uid],
                                    saved=saved_first, content_format=formats[chapter_uid])
                report["cases"].append(row)
                if "error" in row or row.get("matches_baseline") is False:
                    report["advanced_cases_skipped"] = True
                    return report
        def serial_control(case: str) -> bool:
            gate.begin_phase(case)
            started = time.monotonic()
            for chapter_uid in selected:
                client = client_factory(source_jar, gate)
                row, _, _ = observe(case, client, resolved_id, chapter_uid, baselines[chapter_uid],
                                    content_format=formats[chapter_uid])
                report["cases"].append(row)
                if "error" in row or row.get("matches_baseline") is False:
                    report["advanced_cases_skipped"] = True
                    return False
            report[case + "_wall_seconds"] = round(time.monotonic() - started, 6)
            return True

        if "parallel" in requested:
            if timing_controls and not serial_control("serial_before"):
                return report
            gate.begin_phase("parallel")
            parallel_started = time.monotonic()
            clients = [client_factory(source_jar, gate) for _ in selected]
            with ThreadPoolExecutor(max_workers=gate.concurrency) as executor:
                futures = [executor.submit(observe, "parallel", client, resolved_id, chapter_uid,
                                            baselines[chapter_uid], content_format=formats[chapter_uid])
                           for client, chapter_uid in zip(clients, selected)]
                report["cases"].extend(future.result()[0] for future in futures)
            report["parallel_wall_seconds"] = round(time.monotonic() - parallel_started, 6)
            if any("error" in row or row.get("matches_baseline") is False for row in report["cases"]):
                report["advanced_cases_skipped"] = True
                return report
            if timing_controls and not serial_control("serial_after"):
                return report
        report["stage"] = "complete"
        return report
    except Exception as error:
        report["error"] = safe_error(error)
        return report
    finally:
        report["request_stats"] = gate.summary() if gate is not None else {
            "request_count": 0, "peak_in_flight": 0, "min_start_spacing_seconds": None,
        }
        report["stage_stats"] = gate.phase_summaries() if gate is not None else {}
        if "setup_seconds" not in report:
            report["setup_seconds"] = round(time.monotonic() - setup_started, 6)
        if setup_client is not None:
            report["setup_cookies_changed"] = setup_client.cookies_changed
        try:
            report["cookie_input_unchanged"] = original_digest is not None and original_digest == hashlib.sha256(
                cookie_file.read_bytes()).digest()
        except OSError:
            report["cookie_input_unchanged"] = False


def main(argv: Optional[list[str]] = None, *, client_factory=ProbeClient) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cookie-file", type=Path, required=True, help="Read-only Netscape cookie file")
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--book-id")
    target.add_argument("--reader-url")
    parser.add_argument("--chapters", nargs="+", metavar="UID")
    parser.add_argument("--chapter-count", type=int, choices=range(2, MAX_CHAPTERS + 1), default=2)
    parser.add_argument("--concurrency", type=int, choices=range(1, MAX_CONCURRENCY + 1), default=2)
    parser.add_argument("--start-interval", type=float, default=0.3,
                        help="Global request start interval in seconds, from 0 through 10")
    parser.add_argument("--modes", nargs="+", choices=MODES, default=list(DEFAULT_MODES),
                        help="Serial baseline always runs before the selected additional cases")
    parser.add_argument("--timing-controls", action="store_true",
                        help="Bracket the parallel phase with serial phases using identical request sequences")
    parser.add_argument("--output", type=Path, required=True, help="Summary JSON report")
    args = parser.parse_args(argv)
    try:
        if args.output.resolve() == args.cookie_file.resolve() or (
                args.output.exists() and os.path.samefile(args.output, args.cookie_file)):
            raise ProbeError("report_must_not_replace_cookie_file")
        report = run_probe(args.cookie_file, book_id=args.book_id, reader_url=args.reader_url,
                           chapters=args.chapters, modes=args.modes, client_factory=client_factory,
                           timing_controls=args.timing_controls, chapter_count=args.chapter_count,
                           concurrency=args.concurrency, start_interval=args.start_interval)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=args.output.parent,
                                         prefix=".chapter-probe-", suffix=".json", delete=False) as handle:
            temporary = Path(handle.name)
            json.dump(report, handle, ensure_ascii=True, indent=2)
            handle.write("\n")
        temporary.replace(args.output)
        print(json.dumps(report, ensure_ascii=True))
        failed = "error" in report or not report["cookie_input_unchanged"] or any(
            "error" in row or row.get("matches_baseline") is False for row in report["cases"])
        return 1 if failed else 0
    except KeyboardInterrupt:
        print(json.dumps({"error": {"type": "KeyboardInterrupt"}}))
        return 130
    except Exception as error:
        print(json.dumps({"error": safe_error(error)}, ensure_ascii=True))
        return 1


if __name__ == "__main__":
    sys_exit = main()
    raise SystemExit(sys_exit)
