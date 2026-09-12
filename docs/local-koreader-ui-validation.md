# Local KOReader UI validation

Date: 2026-09-12

## Environment and scope

The user explicitly authorized local UI verification. Testing used the official
KOReader v2026.07.1 Linux x86_64 release in Debian on WSLg, with a 600 x 800 SDL
window and an isolated `KO_HOME`. Windows UI actions used the computer-use
interface. No physical Kindle was connected.

The official runtime archive SHA-256 was
`299aadb28147a25e9432ced1214ea444a4184393b5ae97cf42402c8a61b1a1b0`.
The installed `ffi/util.lua` and `ffi/SDL3.lua` matched that archive byte for
byte. The test package initially matched all 89 runtime files in the working
tree and the isolated plugin installation.

A profile-only userpatch supplied an eight-chapter synthetic book and replaced
the client's network transport. The actual KOReader UI, source decoder,
coordinator, forked workers, SQLite storage, EPUB assembly, and document reader
were retained. Unknown fixture requests were blocked. No real WeRead credentials
or book content were used in this UI test. Automatic reporting, synchronization,
prefetch, and update checks were disabled in the disposable profile.

## Observed behavior

- The download menu initially showed five parallel chapters and offered values
  from one through five. Selecting two and then five immediately updated the
  checkmark and persisted the corresponding value in the settings file.
- A slow full-book download remained interactive. Request start/end intervals
  showed a peak of five concurrent requests, with no unmatched intervals.
- Chapter four returned two synthetic HTTP 503 errors. Both triggered retries.
  Clicking Cancel during its next attempt closed the progress dialog; a process
  snapshot then showed zero remaining worker children.
- Restarting the download reused seven completed chapters. Their source-entry
  counters remained at one; only chapter four was acquired again.
- The published EPUB passed ZIP CRC and XML parsing checks, with eight distinct
  chapters in order and the final paragraph of each chapter present.
- KOReader opened the EPUB, displayed all eight table-of-contents entries, and
  navigated successfully to chapter eight.
- After the integration fixes, a fresh run with persistent HTTP 503 responses
  stopped after exactly three attempts for chapter four. The seven other
  chapters remained available for recovery, no incomplete full EPUB was
  published, and the worker child count returned to zero.
- Restoring the fixture transport and downloading again reused all seven
  successful chapters. The details page immediately changed to eight-of-eight
  and enabled Read, both beneath the completion dialog and after closing it.
- Repeating the completed full-book download added zero transport events and
  reused the identical EPUB path.

The initial cancellation/recovery observations are recorded in the ignored
`dist/local-ui-test/cancel-resume-results.json` and
`dist/local-ui-test/cancel-resume-events.jsonl` artifacts.

The final package was reinstalled and the five-chapter failure/recovery scenario
was repeated after all corrections. The actual dialog displayed the translated
pause/recovery instructions and HTTP 503, without a source path. The failed
chapter stopped at three attempts, while all seven other source counters stayed
at one. Recovery added one request for chapter four and generated a valid,
ordered eight-chapter EPUB. The details page updated to eight-of-eight.
The final event log recorded a peak of five, no unmatched request intervals,
and no unknown fixture requests. The final EPUB also opened normally in the
reader. All 89 packaged runtime files matched both the working tree and the
tested installation byte for byte. The isolated application exited normally,
and a final process snapshot found no remaining fixture processes.
The corresponding artifacts are
`dist/local-ui-test/final-pause-results.json`, `final-recovery-results.json`, and
`final-events.jsonl`.

Final test package: `dist/weread.koplugin-parallel-5-test.zip`.
SHA-256: `edef13e8d22af32e9901c24f467ca4f6c55ad8deec8ad1f74a3cc089f76d02d7`.
The plugin version remains 1.4.2; this is an unreleased test artifact.

## Issues found

1. The book details page retained its old cache count and disabled Read button
   after a successful full-book download. Leaving and reopening the page showed
   the correct eight-of-eight state. The completion flow now refreshes the
   still-visible details page without reopening a page the user has left. This
   correction passed the actual UI scenario as well as 82 related Lua checks.
2. A separate integration review reproduced a synchronous worker-start failure
   allowing a completion callback's newly submitted task to overtake an existing
   FIFO task. Completion callbacks now preserve the admission barrier, including
   nested callbacks, and queued work advances after an initial launch failure.
3. The retry limit worked, but its error dialog exposed a Lua source path and
   did not explain that saved chapter progress was reusable. Known pause
   outcomes now display a concise recovery message while retaining the original
   diagnostics for logs and completion callbacks.
4. A serial worker could write its final pause state between the parent's
   progress read and exit check. The parent now reads and deduplicates the final
   progress after reaping and before invoking completion. A deterministic test
   reproduced the previous failure and passed after the correction.
5. The socket client's `transport_timeout` diagnostic was missing from the
   network-failure classification. It now pauses the task after the third
   attempt, matching the existing policy for persistent network failures.

Targeted regressions passed, including 87 worker checks, 71 group checks,
85 real-process checks, 167 downloader checks, 690 coordinator checks, 139 book
worker checks, the download-policy suite, lifecycle checks, and cache-drain
checks. Static analysis reported no warnings or errors for the changed Lua
files. Original completion callbacks still receive exactly two arguments and
the unchanged diagnostic error.

## Limits

Synthetic transport makes failure and cancellation repeatable; these results
do not establish live-service throughput or server concurrency limits. The test
does not establish Kindle Scribe memory use, battery impact, network behavior,
or e-ink refresh characteristics. Real-account API comparisons are documented
separately in the chapter-concurrency reports.
