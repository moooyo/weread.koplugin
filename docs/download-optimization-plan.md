# Plugin download optimization implementation

Date: 2026-09-12. Investigated baseline: `2943080` (`v1.4.2`).

Status: implemented in the working tree; not released. The user requested a
five-chapter default after the live five-chapter trial. Supported background
platforms now use a UI-owned task group for multi-chapter downloads. The
concurrency setting accepts 1-5 and defaults to 5. Target-device measurements
on the first-generation Kindle Scribe remain outstanding.

## User-visible behavior

- Settings -> Download settings -> Concurrent chapter downloads selects 1-5
  chapters. Changes apply to new jobs; an active job retains its settings.
- Manual multi-chapter downloads use the configured background window. A
  single chapter, prefetch, or an explicitly selected concurrency of one uses
  the serial worker without extra per-chapter process launches.
- Temporary chapter acquisition failures receive at most three total attempts,
  with 0.8 and 1.6 second backoffs. Waiting for retry releases the acquisition
  slot, allowing other chapters to proceed.
- Recoverable remote-image requests also receive at most three attempts in
  the background path. A successfully recovered image is marked complete.
- Authentication failures, HTTP 403/429, and the observed API rejection
  `-10102` pause the job. Persistent transport/timeouts/server errors pause
  after the attempt budget is exhausted. The meaning of `-10102` remains
  unconfirmed; it is not labeled as a proven rate-limit code.
- A permanent chapter-specific failure is retained in the failed set. A full
  book is published only when every requested chapter's body is available.
  Best-effort missing images are reported and remain eligible for a later retry.
- Caching again reuses valid committed chapters and retries unfinished work.
  Changing image settings changes source identity. Recovery is at chapter/file
  boundaries, without resuming partial HTTP byte ranges.

## Task ownership and ordering

`background_worker.lua` retains one public root job and its protected FIFO
queue. `startGroup()` creates a virtual root job instead of forking another
coordinator process. `background_group.lua` owns up to five direct child slots;
all launches, scheduling decisions, and reaping occur in the UI parent.
Child tasks cannot start nested plugin workers.

`book_download_coordinator.lua` runs these phases:

1. **Prepare:** one child opens the download store, validates cached sources and
   a prior publication receipt, and returns a small immutable chapter plan.
2. **Acquire:** the first missing chapter primes shared CSS/format, then a
   sliding window obtains independent chapters. Each acquisition uses private
   files and sequential HTTP requests. It does not open SQLite or write the
   annotation source database.
3. **Commit:** a single commit lane validates UID/key/path/size and saves a
   durable bundle, then indexes original annotation text. The bounded window
   counts active acquisitions, ready manifests, and the active commit, so a
   slow writer cannot accumulate all book bodies or an unbounded ready queue
   in the UI process.
4. **Assemble:** after all acquisitions and commits finish, one child processes
   cross-chapter footnotes and builds the requested EPUB output from files.
   Cover retrieval runs in this isolated phase and has bounded retries.
5. **Publish:** the current UI callback moves a validated private candidate to
   an immutable filename and registers it. An old open edition is preserved.

The configured window is an upper bound. The group stops additional admission
when available memory is below the soft threshold. With no active child, a
continued low-memory condition becomes a bounded failure. Progress from all
slots is coalesced to at most one root update per poll.

Prefetch and annotation acquisition share the same root worker and wait behind
an active manual group. New automatic reading reports and automatic progress
sync yield while a manual download is active. A manual job waits for an already
running reading-report child before launching chapter workers, with cancellation
and a finite wait deadline. Explicit user-triggered sync actions retain their
existing behavior.

## Durable data and credentials

`download_store.lua` stores small manifests in per-book/account SQLite and
keeps source XHTML, raw annotation text, CSS, scans, and assets in immutable
private attempts. `newFiles()` provides acquisition-only filesystem operations
without loading/opening SQLite. Prepare and assembly cleanup run only when
no acquisition or commit task is active.

`WorkerSettings.job_factory()` freezes small configuration, account, Cookie,
and path fields at job start. Each child receives an independent in-memory
settings overlay and client. Parallel acquisitions return no authentication
snapshot. The final isolated assembly may return an update through the existing
parent fingerprint fence; an intervening account/Cookie change prevents an old
result from overwriting it. Scoped authentication hooks are restored in reverse
order, so serial downloads do not accumulate a wrapper per chapter.

Chapter filenames and resource hrefs include UID identity. Each chapter EPUB
contains its own referenced resources, including shared images. Whole-book
assembly uses one resource manifest and packages text and compressed images
appropriately. ZIP/ZIP64 central-directory and required-member checks precede
publication; these are structural checks, without full payload CRC validation
or a claim of power-loss durability.

## Cancellation and errors

Cancellation, account changes, and cache moves stop new work, revoke pending
retries, and signal every active child. Unresponsive children are terminated
after the grace period. Root completion and cache deletion wait until every
child is actually reaped. A callback failure follows the same cleanup path.

Per-book cache clearing preserves unrelated queued jobs. Completion callbacks
cannot start a new writer before cache exit callbacks finish. Old worker tokens
and downloader identity checks prevent cancelled or superseded results from
publishing files or credentials. Committed sources survive ordinary cancellation
and request failures; uncommitted attempts are cleaned on a later preparation.

## Annotation and processing improvements

Underline plans and successful thought batches are persisted independently.
Small cursors and incremental matching updates replace growing full checkpoints.
Source acquisition runs in the shared background worker before local matching.
Sparse UTF-8/range lookup, cooperative matching boundaries, byte-based Base64
decoding, and bounded footnote scans reduce repeated work and retained memory.
The chapter concurrency setting does not parallelize annotation API requests.

## Evidence and verification

Initial executable verification ran on `ssh test-env`, including Lua component
specs, real SQLite persistence, process lifecycle tests, static analysis, Python
helper tests, and package validation. The real-process regression observed five
direct children at once and verified cancellation callbacks only after reaping,
including forced termination of uncooperative children. Native libarchive checks
validated generated EPUB contents separately.

The integrated remote run passed 79 Lua spec files and 40 Python tests.
Luacheck reported zero warnings and zero errors across 163 Lua files. The final
configuration-freezing adjustment also passed downloader lifecycle and cache
drain regressions. After the user explicitly authorized local UI testing, the
official KOReader v2026.07.1 Linux runtime was tested in an isolated WSLg profile.
Synthetic transport exercised five simultaneous chapter requests, cancellation,
saved-source recovery, bounded retries, EPUB opening, and the actual details
page. See the local UI validation report for the exact scope and follow-up fixes.

The reference live probe verified identical decoded content for the selected
book at two, five, and ten simultaneous chapter acquisitions. The complete
five-chapter trial passed. The ten-chapter parallel phase passed, followed by a
serial recheck failure with API `-10102`; no higher trial or retry was performed.
The five/ten samples used TXT bodies and different pacing from the initial
pair, so the numbers do not establish a universal speedup or service limit.

- [Initial performance investigation](chapter-cache-performance-investigation.md)
- [Parallel feasibility](parallel-download-feasibility.md)
- [Multi-chapter scheduling study](multichapter-download-feasibility.md)
- [Initial live context comparison](real-chapter-concurrency-validation.md)
- [Five/ten-chapter live trial](five-ten-chapter-validation.md)
- [Local KOReader UI validation](local-koreader-ui-validation.md)
- [Testing instructions](testing.md)

The remaining validation limits are sustained mixed-format/image workloads
and first-generation Kindle Scribe memory,
responsiveness, and long-running stability. Source and synthetic/process tests
provide implementation coverage; live Python timings are not a benchmark of
the final plugin on that device.
