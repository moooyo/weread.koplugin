# Chapter cache performance investigation

Date: 2026-09-12

Revision examined: `2943080` (`v1.4.2`).

## Scope and evidence

The reported operation is manually caching selected chapters and their comments
on the latest installed plugin. In this revision, selected chapters enter through
`weread/ui/library.lua:1328` with `separate_chapters = true`. New EPUB downloads
contain clean text; underlines and thoughts use the separate annotation sync
pipeline. `downloader.lua:516` disables embedded annotations, and
`content.lua:1457` makes the old annotation insertion hook a no-op.

Both active pipelines were examined. The legacy `Thoughts.apply()` and
`Client:get_chapter_reviews()` loops are not used to explain current foreground
cache behavior.

All executable verification ran through `ssh test-env`, using an isolated
repository snapshot and LuaJIT under `/tmp/weread-perf-bMY1l6`. No local tests,
builds, or runtime probes were run. Synthetic fixtures contained no account
credentials or private book content. These experiments establish code behavior
and work amplification, rather than real-device latency or the cause of a
specific observed incident.

## 1. Each chapter can archive the entire task's image directory

**Confirmed by a remote probe. High priority for selected-chapter caching.**

The downloader creates one workspace for the whole selection
(`downloader.lua:564`). Each chapter collects its own resource descriptors, but
all image files reside in the same directory. At completion, the downloader
loops over the chapters and calls `save_chapter_epub()` with each chapter's
resource list (`downloader.lua:883`).

`append_asset_entries()` uses the resource list only to discover its parent
directory, then recursively archives that entire directory
(`content.lua:387-416`). Consequently, a chapter containing any file-backed
image can include all images downloaded for the selection. Its manifest still
declares only its own resource descriptors.

For K chapters with file-backed resource descriptors and B total staged image
bytes, the image input to the archive writer can approach K × B. If every
chapter has a similar image payload, work and total output can grow roughly
quadratically with the number of selected chapters.

The writer also switches to `deflate` for every entry after `mimetype`
(`content.lua:356`), ignoring the existing resource `store` flag. This repeatedly
compresses already compressed image formats.

The remote experiment used the real `Content` module, real temporary image
files, and an archive stub that enumerated the paths supplied to `addPath()`:

| Input | Declared images | Images passed to writer | Image bytes |
| --- | ---: | ---: | ---: |
| Chapter 1 | 1 | 2 | 12,288 |
| Chapter 2 | 1 | 2 | 12,288 |

Unique image bytes were 12,288; cumulative archive input was 24,576, a 2×
amplification. Both image directory calls used `deflate`. Actual ZIP compression
and Kindle timings were outside this experiment.

**Related correctness defect:** URL deduplication at `content.lua:1175` returns
the existing rewritten URL without adding its resource descriptor to the next
chapter. A second remote case downloaded a shared URL once, returned resource
counts of 1 and 0, and retained the image reference in both XHTML bodies. The
second independent chapter EPUB supplied no image to the archive writer.

**Repair:** retain a complete resource reference set for each chapter, including
deduplication hits. Stage only that set in a chapter-specific archive directory.
Preserve the directory-based archive API because the code documents individual
file issues on some Kindle builds. Use links where supported, with a copy
fallback; do not assume device filesystems support hard links. Honor compression
policy per resource. Simply saving chapters earlier while still archiving the
shared directory does not resolve resource contamination.

## 2. A completion error can permanently retain the active download

**Confirmed by remote fault injection. High priority for actual stuck jobs.**

`_scheduleGuarded()` handles an exception only when `dl.standby_guard` is still
set (`downloader.lua:403`). However, `_step()` releases that guard at line 912,
before saving cache metadata and refreshing the shelf at lines 913-959.

If settings persistence or shelf refresh throws at that point, the exception is
caught but its handler is skipped. `_finishJob()` and the completion callback
are never reached. `_active_job` remains occupied, and the next download is
rejected as already in progress.

The probe called the real `_step()` and `_scheduleGuarded()`, with a successful
stub EPUB save and an injected settings flush exception:

```text
late_error active_job_retained=true standby_released=true completion_callbacks=0 surfaced_errors=0
late_error subsequent_download_started=false message=Another download is already in progress.
```

The trigger is conditional on an exception after the guard is released. The
experiment does not show that a particular device encountered that exception.

**Repair:** make job finalization independent of the standby flag. Use an
idempotent cleanup path that always clears active-job ownership, closes the
dialog, reports the error, and notifies completion once. Protect individual
cleanup operations so one cleanup error cannot skip the rest. Treat a saved
chapter and failed metadata update as a recoverable state.

## 3. Foreground networking and packaging block the UI

**Confirmed by call-path inspection and upstream timeout semantics.**

Manual downloads run through `UIManager:scheduleIn()` and then perform
synchronous work inside each callback (`downloader.lua:400`). One chapter step
downloads the reader page and content shards, decodes the source, indexes its
annotation text, scans footnotes, and processes images before returning
(`downloader.lua:1063-1085`, `content.lua:1542`).

After all downloads and footnote processing, the selected-chapter path packages
every EPUB inside one callback (`downloader.lua:883-904`). There is no yield or
cancel check between those EPUB saves. Progress may remain at the packaging
stage while the UI cannot handle input.

Foreground annotations similarly call `request.job:step()` directly from the
UI callback (`annotation_sync_controller.lua:377`). Coroutine yields occur
between operations; they do not interrupt a synchronous HTTP call, JSON
encoding, SQLite write, or CREngine search.

Only the `prefetch` branches use a subprocess (`downloader.lua:541` and
`annotation_sync_controller.lua:327`). The worker watchdog therefore does not
protect ordinary manual cache operations.

### Timeout gaps

`Client:request()` defaults to a 15-second blocking timeout and an unlimited
total timeout (`client.lua:247-255`). The upstream KOReader socket helper
explains that the underlying timeout resets during receive operations, and
DNS is outside its coverage. When the total timeout is negative, the table
sink adds no request-wide deadline. A slowly progressing response can therefore
last much longer than 15 seconds.

The custom file sink (`client.lua:385`) only checks size and writes chunks. It
does not implement cancellation, byte progress, or a wall-clock deadline. Even
passing a finite total timeout would not provide the helper's request-wide
deadline through this sink. Redirects must also share one absolute deadline,
rather than starting a fresh budget for every request.

The existing worker uses time since its last application progress event
(`background_worker.lua:317`). A long file transfer can make byte progress
without producing another application event, and be terminated after the
180-second inactivity budget. Moving foreground work to this worker requires
fixing progress reporting too.

**Repair:** run manual network, decoding, image, and archive work outside the UI
process, with request cancellation and progress events. Keep live document
operations on the owning UI process and divide matching work into bounded time
slices. Reuse the worker's launch and cleanup mechanisms while adding distinct
no-progress and overall deadlines. Handle platforms where subprocess support
is unavailable; the current worker explicitly excludes Android.

## 4. Annotation checkpoints repeat growing payloads

**Confirmed by a remote deterministic counting probe.**

The download stage stores the complete chapter underline list. Each completed
30-range review batch rewrites this entire stage merely to advance
`next_batch` (`annotation_sync.lua:87`, `annotation_sync.lua:115-119`). With U
underlines, cumulative underline rows serialized into stage values are:

```text
U × (1 + ceil(U / 30))
```

Matching stores every accumulated record again after each group of 16
underlines (`external_annotations.lua:576`). Those records initially include
comment popup items (`external_annotations.lua:561`). Only after matching ends
does the sync pipeline remove those items (`annotation_sync.lua:189`), then
build the per-range popup cache separately.

The probe ran the real `Sync`, `External.locate`, client batching method, and
annotation store. It used the repository's SQLite test bridge and table codec,
with fake network and document services. Each range had three synthetic
comments:

| Underlines | API requests | Cumulative stage underline rows | Cumulative checkpoint records | Checkpoint comment rows |
| ---: | ---: | ---: | ---: | ---: |
| 240 | 9 | 2,160 | 1,920 | 5,760 |
| 480 | 17 | 8,160 | 7,440 | 22,320 |
| 960 | 33 | 31,680 | 29,280 | 87,840 |

A 4× input increase produced 14.7× and 15.3× cumulative row counts. These are
work-volume measurements, not JSON byte counts or elapsed-time benchmarks.
The final projection retained zero comment items in every case.

**Repair:** save the immutable underline list once. Persist only the batch
cursor and revision in the download checkpoint. Store matching results in
bounded incremental batches, with a small resumable cursor. Avoid building
popup items in the matcher. Keep one shared comment representation per range.
Preserve the current atomic commit and resume guarantees.

## 5. Additional costs and conditional matching degradation

### Request count and deliberate waits

For an EPUB-format chapter, the normal source path refreshes the reader page
and fetches three content shards (`content.lua:1324-1347`); CSS is fetched while
the task has no cached CSS. Images add TAR and individual image requests.
Requests are serial.

For U underline ranges, annotation sync normally makes
`1 + ceil(U / 30)` requests, excluding original-text recovery and retries.
Each range asks for up to 30 reviews, so one batch can request up to 900 reviews
(`client.lua:762`). The official
[notes API documentation](https://github.com/Tencent/WeChatReading/blob/main/skills/notes.md),
retrieved during the whole-book follow-up, documents a server cap of 20 reviews
per range. The 900 figure describes the requested count, not an observed
response size; under that documented cap a 30-range batch returns at most 600
reviews. Each initial request is delayed by 0.3 seconds, with failed
attempts adding 4 and 8 seconds before retries (`annotation_sync.lua:35`).
For 3,000 ranges, the 101 requests alone schedule 30.3 seconds of initial
waiting, before network and local processing.

Upstream LuaSocket's high-level HTTP function opens and closes a connection
for each request; LuaSec performs the TLS setup. Adding only a keep-alive
header does not create a reusable transport.

First remove redundant work and add request measurements. Then evaluate
connection reuse and a small adaptive concurrency limit. Preserve rate-limit
backoff and validate session behavior before changing request ordering.
Fetching comments on demand would reduce work but changes offline availability;
it should be an explicit product choice.

### Memory and source processing

Selected-chapter downloads retain all completed XHTML in `dl.bodies`
(`downloader.lua:791`) until all footnotes are processed and all EPUBs are
written. Image files already stream to disk, so describing current image
storage as entirely in-memory would be incorrect.

Base64 decoding expands data into a sixfold bit-character string before
converting it back to bytes (`content.lua:477`). The content unscrambler also
splits the complete encoded body into a single-character Lua table to perform
a small number of swaps (`content.lua:546`). Annotation source caching indexes
the entire source and writes it even during clean-text downloads
(`content.lua:1462`, `annotation_source.lua:16`).

Use a byte-oriented or native Base64 decoder, sparse swaps, and staged chapter
files. Retain only the index required for cross-chapter footnotes, then load,
transform, package, and release one chapter at a time. Footnote scanning can
also repeatedly clean the same large block for nested anchors
(`footnotes.lua:304`); clean each block once. Device CPU and peak RSS measurements
are needed to rank these costs against networking and archive amplification.

### Annotation lookup and matching

`quote_for()` and the matching record builder repeatedly scan chapter reviews
by range (`external_annotations.lua:55`, `external_annotations.lua:552`). Build
a range lookup once. `Source.quote()` scans spans from the beginning for every
quote (`annotation_source.lua:58`); a TXT source uses one whole-chapter span,
so repeated rune-to-byte counting can approach U × chapter length. Use ordered
extraction or indexed span/rune lookup.

The matcher normally has a chapter text index. A mapping mismatch disables
that index, after which unmatched quotes can call whole-book `findAllText()`
(`external_annotations.lua:512-520`). F fallback searches over book length L
can approach F × L work. This is a conditional path, not evidence that every
book undergoes whole-book searching. Bound fallback work, record its cause,
and defer difficult matches instead of repeatedly scanning a large book in
one foreground step.

The annotation store also repeatedly opens connections and prepares SQL
(`annotation_store.lua:36-85`). Reusing a connection and statements within an
owning process should reduce overhead, with explicit cleanup and no sharing
of live database handles across worker processes.

## Recommended implementation order

1. Correct chapter image ownership, shared-URL resource descriptors, and
   unconditional download finalization. Add regression cases for both resource
   isolation and exceptions after the standby guard is released.
2. Replace full annotation checkpoint rewrites with immutable source data,
   incremental matching rows, and small cursors. Add work-volume assertions
   across increasing chapter sizes.
3. Move manual transfers and packaging into cancellable background work.
   Enforce absolute request deadlines in all sinks; emit byte progress and
   distinguish inactivity from total task duration.
4. Stage chapter bodies on disk, commit successful chapter state incrementally,
   and support restart from those checkpoints. Preserve cross-chapter footnote
   resolution and previous valid cache files.
5. Optimize decoding, review lookup, quote extraction, database connection use,
   and fallback matching. Tune batching or concurrency after measuring request
   latency and service throttling.

## Verification and acceptance criteria

Six existing focused specs passed remotely: client, client annotation batches,
downloader completion, downloader lifecycle, disk assets, and external
annotation sync. Their current fixtures do not cover the image-directory
amplification or the late completion exception described above.

Additional remote probes also completed successfully and confirmed the
existing defects:

- `/tmp/weread-perf-bMY1l6/content-probe.lua`
- `/tmp/weread-perf-bMY1l6/annotation_perf_probe.lua`
- `/tmp/weread-perf-bMY1l6/late-error-probe.lua`

Future fixes should satisfy these checks:

- Each chapter archive contains its complete referenced resource set and no
  unrelated chapter images; shared URLs remain present in each independent
  EPUB that references them.
- Increasing chapter/range counts produces approximately linear resource
  traffic and persistence volume for a fixed per-chapter/range payload.
- Metadata, shelf-refresh, and cleanup faults always release job ownership and
  report one completion; a subsequent download can start.
- Slow streams, no-data responses, redirects, interrupted downloads, and
  cancellation have bounded outcomes. Progressing large files do not trip an
  inactivity timeout merely because their stage has not changed.
- Cancellation or restart reuses successfully committed chapters and comment
  batches; it does not replace a valid complete cache with incomplete output.
- Large TXT chapters and forced chapter-index failures have bounded matching
  slices and an explicit fallback budget.

Useful existing logs include `download_perf` stages, `download assets staged`
byte counts and `lua_kb`, and annotation matching modes. Add request elapsed
time, response bytes, retry reason, checkpoint payload bytes, archive input
bytes, and peak memory. Measure device behavior separately from the synthetic
remote probes; no real-book throughput, actual OOM, or device freeze was
reproduced in this investigation.

## Upstream references

Official sources were retrieved read-only during the investigation. The web
search provider was unavailable, so upstream files were fetched directly.
Installed device versions should be checked when implementing transport
changes.

- [KOReader socket timeouts and sinks](https://github.com/koreader/koreader/blob/master/frontend/socketutil.lua)
- [KOReader subprocess termination](https://github.com/koreader/koreader-base/blob/master/ffi/util.lua)
- [LuaSocket HTTP connection lifecycle](https://github.com/lunarmodules/luasocket/blob/master/src/http.lua)
- [LuaSocket fixed-length response source](https://github.com/lunarmodules/luasocket/blob/master/src/socket.lua)
- [LuaSec connection and TLS setup](https://github.com/lunarmodules/luasec/blob/master/src/https.lua)

The follow-up [whole-book download feasibility study](whole-book-download-feasibility.md)
compares the existing combined EPUB path with a direct file download and
examines current official API and Web reader evidence.
