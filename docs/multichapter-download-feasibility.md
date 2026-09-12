# Multi-chapter parallel download investigation

Date: 2026-09-12. Baseline: `2943080` (`v1.4.2`).

Scope: plugin-side acquisition of multiple chapters at the same time. This is
a focused follow-up to the [parallel download study](parallel-download-feasibility.md).
No functional changes were made. Runtime experiments used `ssh test-env`
exclusively, with synthetic data and localhost HTTP. No real WeRead account
requests or local verification were performed.

## Decision and confidence

A sliding window of independent chapter acquisitions is implementable. It can
overlap reader-page, body, and resource waits across chapters, including time
that single-chapter shard parallelism cannot overlap. The implementation needs
a coordinator, isolated chapter state and files, durable completed bundles,
and an ordered final assembly stage.

The engineering model is supported by source inspection and remote experiments.
The unresolved protocol question is whether the real service accepts the chosen
reader-context and Cookie strategy during overlapping chapter requests. Local
state isolation alone cannot answer that question.

A useful initial experimental configuration is two active chapters with
sequential HTTP operations inside each acquisition, giving at most two such
requests in flight. This avoids multiplying chapter concurrency by shard
concurrency. It is a starting configuration to measure, not a documented
WeRead limit or a device-independent recommendation.

## Sliding acquisition rather than fixed waves

Keep one user-visible book job. When either active chapter finishes its
acquisition, immediately assign its slot to the next pending chapter. A slow
chapter occupies one slot, not the entire window. Retry backoff releases the
slot so unrelated chapters can continue.

For example, if chapter 1 is slow:

```text
Slot A: chapter 1 -------------------------->
Slot B: chapter 2 -> chapter 3 -> chapter 4 -> ...

Completed bundles: keyed by chapter UID, stored immediately on disk
Final book order:  chapter 1, chapter 2, chapter 3, chapter 4, ...
```

Do not wait for chapters 1 and 2 together before starting 3 and 4. Do not hold
completed chapter bodies in RAM while waiting for the earliest chapter.

### Remote scheduling experiment

Each of six synthetic chapters made four real HTTP requests in sequence:
reader, e0, e1, and e3. The actual plugin `Client` and LuaSocket were used;
logger and KOReader socket-helper adapters were stubbed. Chapter 1's server
delay was 300 ms per request, and the remaining chapters used 50 ms. Each
response was checked against its expected chapter and stage.

| Scheduler | Peak HTTP requests | Total requests | Time | Chapter completion order |
| --- | ---: | ---: | ---: | --- |
| Serial | 1 | 24 | 2.246 s | 1, 2, 3, 4, 5, 6 |
| Fixed waves of two | 2 | 24 | 1.625 s | 2, 1, 3, 4, 5, 6 |
| Sliding window of two | 2 | 24 | 1.208 s | 2, 3, 4, 5, 6, 1 |
| Sliding window of four | 4 | 24 | 1.210 s | 3, 2, 4, 6, 5, 1 |

Every case assembled results in catalog order, 1 through 6. The four-slot
case did not improve this workload because the long chapter's serial chain
was already the dominant remaining work. More balanced workloads can behave
differently.

The experiment used an external scheduling harness and localhost HTTP, not a
new plugin pool. It excluded TLS, real server throttling, content decoding,
images, SQLite, footnotes, ZIP work, and device memory. The measured speedups
therefore apply only to this synthetic request schedule.

For independent chapter durations `t_i` and W slots, a useful ideal lower
bound is `max(sum(t_i) / W, max(t_i))`, before coordination and later assembly.
This explains why adding slots need not shorten a long tail.

## Reader context: what is known and what is not

The official [reader bundle](https://cdn.weread.qq.com/web/wrwebnjlogic/js/9.cab69770.js)
contains adjacent-chapter prefetch. It passes another chapter UID to the
horizontal content action while reusing the current page state; it does not
first create a separate reader page for the next chapter.

The inspected frontend constructs `psvts` and `pclts` from server/client page
timestamps. They should not be described as proven unique per-chapter session
tokens. The server's validation rules and lifetime are not exposed by that
frontend code. The `token` used for reading-time reports is also not a body
shard parameter.

The plugin has its own validated parameter strategy:

- `protocol.lua:196-215` uses `ps=book.psvts`.
- It generates `pc` from the current request timestamp, rather than reading
  `book.pclts`.
- `book.token` is not included in this content payload.
- `Content.fetch_chapter_xhtml()` currently refreshes reader state for each
  chapter (`content.lua:1324`).

The previous state experiment showed that interleaving refreshes on a shared
`book` object can put B's `psvts` in an A request. That establishes an unintended
local data dependency, not proof that every such request is rejected upstream.
Use immutable acquisition contexts even if several contexts deliberately share
the same page timestamp values.

Two real-service strategies need separate evaluation:

| Strategy | Description | Remaining question |
| --- | --- | --- |
| Independent page snapshots | Obtain A and B reader state independently, retain each snapshot | Does obtaining B affect acceptance of the old A context? |
| Shared immutable page context | Use one valid page snapshot with different chapter IDs | Does the accepted adjacent-prefetch behavior extend to the selected chapters and current plugin parameters? |

Copying `book` does not isolate Cookie changes. `Client:request()` attaches
shared settings cookies and persists `Set-Cookie` (`client.lua:234-240`,
`client.lua:293-296`). Credential refresh and generation handling need an
explicit owner. A later authentication change must not silently combine
incompatible request groups or let an old worker overwrite newer credentials.

Fetching reader HTML without executing its JavaScript does not execute the
frontend's explicit reading-progress reporting actions. Server-side effects
of the GET itself cannot be ruled out from public frontend source. Keep that
uncertainty in the real-service experiment.

## New remote correctness findings

These probes used actual plugin modules and real temporary files. Network
and archive adapters were stubbed, with deterministic interleavings.

### Same-title chapters share an output path

`Content.save_chapter_epub()` names the output from the book and chapter
titles, without the chapter UID (`content.lua:699`). For distinct UIDs 101
and 202 with the same title, the probe returned:

```text
same_path=true descriptor_count=1 retained_uid=202
```

The second save replaced the first output and descriptor. This already occurs
sequentially; parallel saves additionally compete over the same `.part` path.
Use a stable UID-based output identity, retaining a readable title if desired.

### Shared image incoming paths lose a chapter's image

Inline image paths use a chapter-local counter such as `remote-000001.bin`
within the supplied workspace (`content.lua:1177`). The probe paused A after
writing that file, ran B against the same workspace, then resumed A. B moved
the shared file before A could consume it:

```text
shared_workspace chapter_A_assets=0 chapter_B_assets=1
shared_workspace chapter_A_localized=false chapter_B_localized=true
private_workspaces chapter_A_assets=1 chapter_B_assets=1
private_workspaces chapter_A_localized=true chapter_B_localized=true
```

Private workspaces preserved both expected image byte sequences. Paths need
job, epoch, chapter, and attempt identity; a shared `used_names` table is not
an adequate cross-process allocation protocol.

### Private directories require a final resource merger

The existing EPUB writer rejects file-backed assets from different parent
directories (`content.lua:395`). The probe confirmed that two otherwise valid
private chapter directories cannot simply be concatenated into its asset list.

Build a canonical final image directory and rewrite references per chapter.
Stable UID-prefixed filenames are a simple collision-free initial policy.
Content-based deduplication can be added using measured hashing costs; it must
not merge different files solely because both were called `cover.jpg`.
Rewrite complete chapter-local hrefs, not a global basename mapping.

Each independent chapter EPUB still needs its own complete referenced resource
set. A full-book EPUB can use the merged resource set once. Private downloads
may initially duplicate a shared image transfer; correctness should be secured
before adding cross-worker in-flight deduplication.

### The existing complete chapter worker is not a batch worker

`ChapterWorker.run()` builds an index containing only the current chapter
(`chapter_prefetch_worker.lua:52`). Using an actual cross-chapter footnote
fixture produced:

```text
real_chapter_worker_converted=0 real_chapter_worker_unresolved=1
full_index_converted=1 full_index_unresolved=0 full_index_valid=true
```

Concurrent acquisition workers should therefore return source files and scans,
not independently finalize every chapter's footnotes. Collect the selected
chapters' definition indexes, then transform against that shared index.

The existing worker also removes its workspace before returning
(`chapter_prefetch_worker.lua:86`). An intermediate-artifact worker must transfer
directory ownership to the coordinator instead, or returned paths will already
be invalid.

## Proposed architecture

Retain one active top-level download and its progress/cancel UI. Introduce a
chapter coordinator and a bounded acquisition pool beneath it. The current
`BackgroundWorker` has one active and one replaceable pending slot, so it
cannot serve as this pool without a real queue and child registry.

Each acquisition receives:

```text
job identity and epoch
chapter UID and catalog ordinal
immutable book/session/authentication snapshot
output options and private attempt directory
```

It returns a small manifest identifying staged raw/decoded source, required
assets, CSS, original offset information, footnote scans, byte counts, and
authentication-change proposals. Large bodies and images stay in files.

Workers must not write stable EPUB paths, shared settings, or the live shared
annotation database. Current source fetching calls `cache_annotation_source()`
and writes SQLite (`content.lua:1462`), so extracting a side-effect-controlled
acquisition phase is necessary. Disabling LuaSettings flush alone is insufficient.

A single committing lane validates results and updates durable state. It need
not perform expensive indexing or serialization in the UI thread: the UI
should receive small progress/state messages. Full-book footnote transformation,
resource merging, archive generation, and publication are subsequent coordinated
stages. Bound CPU-heavy work separately from the chapter request window.

The parent must track all children and cancel/reap each of them. Reusing the
subprocess helper inside an untracked outer worker can create independently
grouped grandchildren that survive termination of the outer process. Details
are in the [parallel transport study](parallel-download-feasibility.md).

## Persistent state and recovery

Use dedicated job storage rather than growing LuaSettings collections.

| Record | Important fields |
| --- | --- |
| Job | Owner/account scope, account epoch, job ID/epoch, run token, plan hash, ordered chapter UIDs, output mode, state |
| Chapter | UID, ordinal, state, attempt sequence/token, retry time, error, bundle manifest path, bundle bytes |
| Publication | Output identity/path, state, registration-pending flag |

Different identities protect against different stale results:

- Job epoch rejects an earlier refresh/generation.
- Run token rejects work from a previous coordinator/process lifetime.
- Attempt token rejects a timed-out request that finishes after its retry.
- Account epoch rejects work belonging to a disconnected or replaced account.

Chapter state can follow:

```text
pending -> running -> staged
             |
             +-> retry_wait -> running
             +-> failed
```

`staged` means that the chapter bundle is durably acquired, not that its final
EPUB has been published. Job states include running, assembling, publishing,
complete, draining, paused, and incomplete.

Workers write private attempt directories. The coordinator validates identity
and file manifests, commits an immutable bundle, and marks it staged in a short
transaction. Recovery must reconcile a crash between filesystem publication
and the database commit. It should preserve valid bundles and request only
missing/invalid chapters.

This requires changing existing recovery behavior. `Downloader:recover()`
currently only cleans stale downloads (`downloader.lua:66`), and
`Content.cleanup_stale_downloads()` removes matching workspaces and partial
files (`content.lua:295`). New durable bundle directories must not be deleted
as ordinary abandoned temporary work.

Store results by UID; final assembly traverses the frozen catalog plan.
`downloader.lua:794` currently appends to `selected` in completion order and
cannot remain the ordering rule. A missing chapter blocks publication of a
complete full book, while all other staged chapters remain reusable. A cache
registration failure after EPUB publication should retry registration, not
re-download the book.

## Backpressure and cancellation

Control all of the following:

- Active chapter workers and total HTTP requests, including other plugin work.
- Aggregate reserved worker memory, rather than separate checks that each sees
  the same available RAM.
- Completed-but-uncommitted result bytes and total staging disk use.
- Decoder/transformer/archive concurrency and per-chapter payload bounds.

The current 64 MiB available-memory admission threshold is a single-worker
guard, not proof that two workers fit (`background_worker.lua:16`). The current
decoder also creates expanded strings/tables. Concurrency should fall back to
one or pause when resource budgets are exhausted; one oversized chapter needs
a clear bounded outcome rather than an endless wait for impossible headroom.

Commit any completed chapter to free result-buffer budget, even if an earlier
chapter is slow. Waiting for catalog order during commit would recreate the
head-of-line stall that the sliding window is intended to avoid. Catalog order
is a publication requirement, not a requirement for storing completed work.

Cancellation should persist revocation, stop queue admission, signal every
active child, reject stale results, drain/terminate children, and only then
remove their transient directories. Preserve committed chapter bundles and
release the job/standby state exactly once.

Account disconnect must revoke the account epoch and cancel associated work.
The existing account-clear callback resets account/UI state without a unified
download cancellation (`common.lua:242`, `library.lua:99`). Authentication
fingerprint checks only prevent stale credential write-back; they do not stop
old children fetching data or publishing artifacts.

## Outstanding real-service validation

Use two authorized, stable, small adjacent chapters initially. Keep the current
plugin request parameter strategy fixed and use temporary credential state.
Do not send reading-time/progress reports, purchase requests, or automatic
renewal during this comparison. The reference Python script renews by default,
so a dedicated probe or at least explicit `--no-renew` is necessary.

| Case | Sequence | Question |
| --- | --- | --- |
| Time control | Obtain SA, read A, wait an equivalent interval, read A using saved SA | Does the context expire without B? |
| Independent-context interference | Obtain/read A with SA, obtain/read B with SB, read A again with saved SA | Does creating B affect acceptance of A's old context? |
| Shared-context use | Obtain SA, read A, read B with SA, read A again with SA | Can one immutable context serve the selected chapters? |
| Two-chapter overlap | After the sequential controls pass, overlap at most two requests across A and B | Does overlap change correctness or error behavior? |

The final A request must not call `fetch_chapter_xhtml()`, because that function
refreshes A automatically and would hide invalidation of the saved context.
Use the lower-level shard request with the saved snapshot and fresh request
time/random/signature values.

Compare decoded chapter identity, length, and digest, not just HTTP success
or encoded response bytes. Record credential generations and whether response
cookies changed, without printing secrets. A Cookie change or content update
is a confounder rather than automatic evidence of cross-chapter invalidation.
Read-only progress snapshots before/after can reveal unexpected changes; do
not automatically write progress back to compensate for an observed change.

Keep the official page-context parameter strategy and the plugin's current
strategy in separate experiments. In particular, do not change `pc` or access
parameters while also changing concurrency and then attribute every outcome
to the scheduler.

## Evidence and next decision

The current evidence supports a staged multi-chapter implementation, with a
sliding window and ordered final assembly. It does not support simply spawning
several existing complete chapter workers, or claiming a guaranteed twofold
speedup on a real device.

Before implementation is considered ready, verify real-service context reuse,
actual device memory, shuffled chapter completion, same-title/image conflicts,
cross-chapter footnotes, isolated retries, restart at each commit boundary,
late old attempts, account disconnect, and cancellation of every child.

Remote artifacts on `test-env`, under `/tmp/weread-perf-bMY1l6`:

- `multichapter-probe.lua`: real module/file correctness experiments.
- `multichapter-http.lua`: real Client and LuaSocket chapter request chain.
- `multichapter-scheduler.py`: synthetic serial/wave/sliding comparison.
- `multichapter-scheduler-results.json`: recorded timing and ordering results.

All experiments completed successfully. They demonstrate code behavior and
scheduling properties under the stated fixtures, not real upstream policy or
end-to-end device performance.

The consolidated [implementation plan](download-optimization-plan.md) defines
the selected scope, delivery order, and release gates across these studies.
