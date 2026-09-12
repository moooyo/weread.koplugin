# Five- and ten-chapter live validation

Date: 2026-09-12. All execution used `ssh test-env`. The user explicitly
requested trials at five and ten concurrent chapters on the previously
authorized book. No new device-level verification was performed.

## Result

Five chapters passed the complete sequence. Ten chapters were all acquired
correctly during the parallel phase, but the following serial verification
stopped on an upstream API error. The ten-chapter trial did not fully pass.

| Trial | Serial before | Parallel | Serial after | Actual parallel HTTP peak | Parallel content |
| --- | ---: | ---: | --- | ---: | --- |
| 5 chapters | 4.851794 s | 0.973161 s | 4.727870 s | 5 | 5/5 digests matched |
| 10 chapters | 9.542695 s | 1.170932 s | Stopped on chapter 4 | 10 | 10/10 digests matched |

The same chapters were used throughout each trial. Both samples used the TXT
content route, containing 42,579 and 76,194 decoded UTF-8 bytes respectively.
The measured serial and parallel phases each used exactly three requests per
chapter: a fresh reader page followed by the two TXT shard requests. Format
discovery ran in the baseline and was excluded from the speed comparison.

The maximum observed concurrency reached the requested five and ten HTTP
calls. These numbers are measured activity, rather than merely the configured
number of chapter tasks.

## The incomplete ten-chapter recheck

All ten baseline chapters, all ten serial-before chapters, and all ten parallel
chapters succeeded. In serial-after, chapters 1-3 matched, then chapter 4
returned API code `-10102`. The probe stopped new requests immediately and did
not retry, skip the failure, or run a higher-concurrency trial.

The code's meaning remains unconfirmed. No HTTP 429 was observed. The inspected
[official reader bundle](https://cdn.weread.qq.com/web/wrwebnjlogic/js/17.237e2b08.js)
explicitly handles `-2010/-2012` as reload cases and `-2013` as a session timeout;
other codes enter generic error handling. No reliable definition for `-10102`
was located in the inspected public frontend assets or repository references.

The failure occurred during a serial recheck after a burst of parallel work.
This experiment cannot distinguish concurrency, cumulative request frequency,
session state, or another upstream condition as its cause. It must not be
reported as proof that the service has a fixed concurrency limit below ten.

## Method and boundaries

- Run five chapters first; continue to ten only after the five-chapter trial
  fully succeeds.
- Establish a serial baseline, then run serial-before, parallel, and
  serial-after with the same selected UIDs, detected formats, reader refreshes,
  and initial in-memory Cookie snapshot.
- Set the artificial global start interval to zero in every phase. Keeping the
  old 0.3-second interval could prevent the intended overlap. This change
  applies only to these short trials; it is not a proposed production rate.
- Perform requests sequentially inside each chapter. Enforce a hard HTTP
  concurrency cap equal to the trial level. Stop on API/transport errors or
  decoded-content mismatches and let already in-flight requests finish.
- Compare decoded SHA-256 digests and byte counts. Do not log body text,
  credentials, or exception response bodies.

The five-chapter trial used 67 HTTP requests. The ten-chapter trial stopped
after 113 requests: 2 setup, 40 baseline, 30 serial-before, 30 parallel, and 11
serial-after requests. Both setup phases updated in-memory Cookie state; all
measurement clients started from the same post-setup snapshot within their
trial. The source credential file was unchanged. No explicit renewal,
read-report, image, or comment request was made. The temporary remote credential
copy was removed after testing; the user's local input was left intact.

These timings describe a small warmed sample on `test-env`. They do not measure
Kindle Scribe memory, device CPU time, EPUB/image packaging, annotations, or a
sustained large-book download. They cannot be compared directly with the
earlier two-chapter experiment, which used a different artificial pacing rate
and sample size. Five chapters passing once does not establish a long-term
production limit either.

## Changes and verification

`scripts/verify_parallel_chapters.py` now accepts `--chapter-count` (2-10),
`--concurrency` (1-10), and `--start-interval` (0-10 seconds). Its defaults remain
two chapters, two requests, and 0.3 seconds. The upper bound of ten is a limit
on this experiment tool, not a documented WeRead limit. Reports include
per-phase request counts, measured concurrency, and detected content format.

The plugin's serial book worker now pauses on the observed `-10102` rejection
without assigning it an unproven rate-limit meaning. It preserves committed
chapters, so a later manual retry can reuse them. It no longer advances through
the remaining chapters after that response. The plugin parallel scheduler is
still not implemented or enabled.

All 40 offline Python helper tests passed on `test-env`, including 23 probe
tests. The Lua worker regression covers immediate pause, no extra chapter
requests, and source reuse after a later successful retry. Static analysis
reported no warnings for the changed Lua files.

Machine-readable evidence is kept outside version control in
`dist/concurrency-validation/five.json` and `ten.json`. No account identifier,
book identifier, credential value, or chapter body is included in this document.
