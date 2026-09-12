# Real chapter concurrency validation

Date: 2026-09-12. Execution environment: `ssh test-env` only.

This document records the initial two-chapter trials. The subsequent
[five- and ten-chapter trials](five-ten-chapter-validation.md) extend the
evidence and include an incomplete serial recheck after the ten-chapter burst.

The user supplied a browser Cookie file and one readable book. The intended
device is a first-generation Kindle Scribe running the latest Kindle-compatible
KOReader release reported by the user; the exact build and device measurements
were not available during this run.

## Findings

Two chapter acquisitions overlapped successfully. Both decoded bodies matched
their serial SHA-256 controls in every observation. Reusing chapter A's saved
reader context after reading B succeeded, as did reading B with A's saved
context. No authentication, throttling, transport, or API error was reported.

The matched-work timing run refreshed each chapter's reader page and used the
same detected format and shard request sequence for the serial and parallel
pairs. Each measured pair made six HTTP requests:

| Pair | Wall time |
| --- | ---: |
| Serial control before parallel | 2.062225 s |
| Two chapters in parallel | 1.774663 s |
| Serial control after parallel | 2.501508 s |

Parallel wall time was approximately 14-29% lower than these two serial
controls. This is one small paired experiment, with noticeable variation
between the controls. It does not establish a typical or whole-book speedup.

The initial automatic-format baseline performs extra format discovery and is
therefore excluded from the speed comparison. The decoded bodies contained
3,519 and 2,758 characters (9,977 and 7,938 UTF-8 bytes).

## Request and credential handling

The three runs made 58 HTTP requests in total. Peak concurrent requests were
one for the initial baseline and two for the overlapping runs. The minimum
observed global launch interval in the matched-work run was 0.300080 seconds.
Each chapter performed its own requests sequentially; shards were not run in
parallel within a chapter.

Each client used an independent in-memory Cookie jar. No Cookie changes were
observed and the input credential file remained unchanged. The probe did not
call renewal, read-report, reading-progress, image, or comment endpoints.
Reports contain only chapter UIDs, lengths, digests, timings, and fixed
diagnostic fields. The remote raw input and converted credential copy were
removed after testing; the user's original file was left intact.

Machine-readable reports are saved outside version control under
`dist/concurrency-validation/`: `baseline.json`, `contexts-parallel.json`, and
`timing-controlled.json`. No book identifier, credential value, chapter body,
or private annotation is included in this document.

## Coverage and remaining work

These results validate the reference Python request/context strategy for the
selected book and two chapters. They support proceeding with a two-chapter
plugin prototype. They do not validate every content format, a sustained
large-book download, image acquisition, annotation throughput, EPUB assembly
latency, or Kindle process memory and cancellation behavior.

The current plugin build still uses a serial background acquisition worker.
The production two-chapter scheduler has not been implemented or enabled.
Its required integration boundaries are:

- The UI owns and reaps both direct child processes. A book worker must not
  fork untracked grandchildren.
- Acquisition writes private files and a small ready manifest. It must not
  open SQLite or invoke the implicit annotation-source persistence in either
  the EPUB source path or the TXT source path.
- Short commit jobs serialize source/annotation storage. Ordered assembly runs
  after all required chapters have committed; the existing parent publication
  check remains the only path to register completed outputs.
- Cancellation, logout, and cache moves wait for every task in the book group.
  Credential updates have one owner. Foreground and background request entry
  points must be coordinated before claiming a global two-request cap.
- Kindle Scribe measurements must cover memory, cancellation/reaping, and
  sustained acquisition before enabling parallel downloads by default.

## Probe regression coverage

The probe now classifies nonzero API response codes before decoding, stops new
requests after errors or digest mismatches, and brackets optional parallel
timings with identical serial work. Optional TXT shards only tolerate their
known empty response. Reports include fixed stage labels and actual request
statistics without exception bodies or credentials.

All 34 offline Python helper tests passed on `test-env`, including 17 probe
tests and 17 credential-export tests. Python compilation and the repository's
sensitive-information scan passed.
