# Bounded parallel download feasibility

Date: 2026-09-12. Plugin revision: `2943080` (`v1.4.2`).

This investigation evaluates plugin-side batch and parallel downloads. It does
not implement the proposed changes. All runtime experiments ran through
`ssh test-env`, using synthetic fixtures or a localhost HTTP server. No local
tests, authenticated WeRead requests, or real book downloads were performed.

Related reports:

- [Chapter cache performance](chapter-cache-performance-investigation.md)
- [Whole-book download feasibility](whole-book-download-feasibility.md)
- [Public server-assisted downloads](server-assisted-download-design.md)

## Conclusion

Bounded parallel HTTP requests are feasible. The best first candidates are
content shards within one prepared chapter and independent annotation batches.
Cross-chapter parallelism needs more state isolation and ordering work. A
larger selection in the UI, a coroutine, or multiple callbacks on the same
event loop does not make the current blocking HTTP client parallel.

Official frontend code provides evidence for parallel requests within one
chapter and prefetching an adjacent chapter. It does not establish a general
multi-chapter body API or a safe sustained request limit for plugin accounts.

## Batch size, concurrency, and prefetch are separate

| Operation | Current evidence | Feasibility and dependency |
| --- | --- | --- |
| Several review ranges in one request | Already implemented: 30 ranges per batch | Reduces HTTP count; one request still addresses one chapter |
| EPUB shards within one chapter | Official frontend uses four requests with `Promise.all` | Prepare session and format first; preserve body/CSS roles |
| TXT shards within one chapter | Official frontend combines two parallel requests | Preserve format detection and response ordering |
| Different review batches | Current request parameters are independent once ranges are known | Suitable for bounded parallel fetching with a new completion ledger |
| Different chapters | Separate chapter IDs and mutable reader state | Requires isolated contexts, result ordering, and aggregate finalization |
| Chapter resources/images | Individual transfers can be independent | Requires unique paths and complete per-chapter resource references |
| Subsequent pages of one review range | Next cursor depends on the previous response | Pages within that range remain sequential |
| Several chapters in one body request | No confirmed interface in inspected sources | Do not assume that changing a chapter ID into an array is supported |

The current review client sends `count=30` per range, but the current
[official notes documentation](https://github.com/Tencent/WeChatReading/blob/main/skills/notes.md)
documents a server cap of 20. The present plugin fetches each range's initial
page; it does not follow `hasMore` to fetch every subsequent page. Parallelism
should preserve the current data scope unless pagination is separately added.

## Official reader evidence

The versioned [chapter reader bundle](https://cdn.weread.qq.com/web/wrwebnjlogic/js/17.237e2b08.js),
around character offsets 52380-62400, builds requests from a single chapter ID
and its reader state. Its EPUB branch uses four concurrent requests. The third
result is CSS, while results 0, 1, and 3 are joined in a fixed order before
decoding. The text branch combines two results.

There are prerequisite branches. Some requests first wait for a preparatory
operation, and the horizontal reader has additional membership/session work.
The official code also treats session/authentication failures as chapter-level
errors rather than publishing a partial body. The plugin must preserve its own
validated reader initialization, access parameters, and format detection; this
report does not propose copying obfuscated branches into the plugin.

The [main reader bundle](https://cdn.weread.qq.com/web/wrwebnjlogic/js/9.cab69770.js)
contains `preloadNextChapter` around offset 1145380, triggered near the end of
the current chapter. Its content action still addresses one next chapter and
uses internal shard parallelism. Array-valued chapter IDs seen in outline
features are not evidence of a multi-chapter body endpoint.

These files were inspected as text, not executed. The web search provider was
unavailable, so official source files were retrieved directly.

## Current transport is blocking

`Client:request()` calls `http.request()` synchronously (`client.lua:275`).
LuaSocket's high-level HTTP code connects, sends, receives, and pumps the body
before returning. A Lua coroutine only cooperates when execution yields;
wrapping this blocking call in a coroutine does not insert yields into it.

The current `socketutil:set_timeout/reset_timeout` also changes shared
transport/helper state (`client.lua:255`, `client.lua:276`). If the transport
were modified to yield, overlapping requests could interfere with those
globals and the total-timeout sink. Each genuinely asynchronous request needs
its own deadline and timeout state.

References: [LuaSocket HTTP](https://github.com/lunarmodules/luasocket/blob/a3bcaed18cb6d69e6e2ae711c93dbe99c7a220bb/src/http.lua),
[Lua coroutines](https://www.lua.org/manual/5.1/manual.html#2.11),
[KOReader socket helpers](https://github.com/koreader/koreader/blob/master/frontend/socketutil.lua).

### Controlled remote HTTP experiment

The experiment used the actual plugin `Client`, LuaJIT, and LuaSocket 3.1.0.
The KOReader logger/socket helper adapter was stubbed; HTTP transfers used
real sockets. A temporary Python HTTP server bound only to localhost returned
12 small responses, each after 200 ms. The parallel case used an external
bounded harness launching isolated Lua processes; no pool was added to the
plugin.

| Mode | Peak in-flight requests | Successful responses | Wall time |
| --- | ---: | ---: | ---: |
| Serial calls | 1 | 12/12 | 2.426 s |
| Coroutines around unchanged calls | 1 | 12/12 | 2.432 s |
| Two network process slots | 2 | 12/12 | 1.244 s |
| Four network process slots | 4 | 12/12 | 0.617 s |

This demonstrates overlapping network waits, not WeRead or Kindle throughput.
It excludes real DNS, TLS, bandwidth contention, decoding, archive work,
device memory pressure, and upstream account behavior.

A second synthetic condition rejected more than two simultaneous requests.
Two slots completed 12/12 requests in 1.234 s; four slots completed only 2/12
and received ten HTTP 429 responses. This artificial limit is not a measured
WeRead limit. It illustrates why elapsed time without successful completion
and retry counts is an invalid performance metric.

## Safest initial content unit: one chapter's shard group

The current plugin refreshes reader state, requests `e_0`, detects EPUB/TXT,
then fetches the remaining shards (`content.lua:1324-1347`). CSS is fetched
separately while the task has no cached CSS (`content.lua:1546`).

A first experiment should retain those boundaries:

1. Obtain a reader session and copy its required values into an immutable
   chapter context. Associate it with an authentication generation.
2. If format is unknown, retain the `e_0` detection request. Start parallel
   requests only when the required shard set is known.
3. Fetch independent members of that group within a global request window.
   Store results by endpoint/shard identity, not arrival order.
4. Verify and combine body shards in the required order, then decode once.
   `content.lua:570` joins encoded bodies before reversing swaps and Base64
   decoding; independently decoding every shard is not equivalent.
5. Retry within the same validated context only when appropriate. After a
   session/content revision change, do not combine old and new response groups.
6. Process and commit the chapter through one completion path.

With enough slots, a body wait resembling `t0 + t1 + t3` can approach
`max(t0, t1, t3)` plus coordination. A two-slot window may require two waves.
Reader initialization, unknown-format detection, decoding, images, footnotes,
and packaging remain additional costs. These equations are bounds on one
component, not a predicted overall speedup.

## Why cross-chapter parallelism needs more work

| Shared state or operation | Failure mode | Required change |
| --- | --- | --- |
| `book.psvts/pclts/token/reader_url` | Another chapter replaces session values before a request is built | Immutable per-chapter context |
| Reader-derived chapter/progress fields | Download preparation changes shared reading state | Separate download snapshot and controlled metadata write-back |
| `_content_format` and `state.css` | Result depends on which chapter finishes first | Coordinator-owned format and deterministic CSS policy |
| URL/name deduplication maps | Missing descriptors or name collisions | Private download paths plus a coordinated resource manifest |
| `remote-%06d.bin` temporary image names | Different chapters overwrite the same incoming path | Include task, chapter, request, and attempt identity |
| Chapter EPUB names based on title | Same-title chapters can contend for one `.part` and final path | UID-based identity plus controlled final naming |
| `dl.selected` append order | TOC, text, and descriptor follow completion order | Assemble by original catalog ordinal |
| Annotation SQLite and settings | Concurrent writers contend or publish stale state | Single committing owner |
| Footnote conversion | Per-chapter worker lacks cross-chapter definitions | Collect scans, build the shared index, then transform |

Relevant locations include `content.lua:1245`, `content.lua:1278`,
`reader_state.lua:37`, `content.lua:1177`, `content.lua:699`,
`downloader.lua:794`, and `chapter_prefetch_worker.lua:52`.

### Remote state-interleaving experiment

The probe used real `Content`, protocol, reader-state, crypto, and worker
settings modules, with a fake client/settings and synthetic credentials.
After refreshing A, refreshing B, and then building A's request from the same
book object, it observed:

```text
requested_chapter=101 encoded_chapter_matches_A=true
psvts_used=session-B expected_psvts=session-A
```

Isolating the two book objects restored `session-A`. This confirms the shared
state dependency. It does not prove that the real upstream necessarily rejects
every mixed session.

Two workers created from the same authentication snapshot then returned
different updates. The existing `WorkerSettings.merge()` accepted the first
and rejected the second because the fingerprint had changed:

```text
first_merge=true second_merge=false
retained_ticket=synthetic-ticket-A cookie_A=A cookie_B=nil
```

That is appropriate protection against stale single-worker state, but is not
a complete multi-worker cookie refresh protocol. Centralize renewal and apply
credential updates against an explicit generation.

## Annotation batches need an out-of-order completion protocol

Once underline ranges are known, different batch requests contain independent
book/chapter/range parameters (`client.lua:792`). The gateway uses a Bearer
key and `skip_cookie=true` (`client.lua:565`), so these requests do not depend
on the mutable Web reader session used for body content.

The current `Sync` is sequential, however. It writes
`next_batch = batch_index + 1` and later assumes every preceding batch exists
(`annotation_sync.lua:115-129`). Parallel network completion breaks that
assumption. Merely serializing database transactions is insufficient.

Remote experiments with the real sync/store and the test SQLite bridge showed:

| Injected completion/interleaving | Observed behavior with the current state protocol |
| --- | --- |
| Batches 2 and 3 finish; batch 1 is missing | Cursor becomes 4; resume issues no repair request and raises `Missing saved thoughts batch` |
| Batches finish in order 3, 1, 2 | Cursor regresses to 3; resume repeats already saved batch 3 |
| New refresh revision 2 commits before old revision 1 | Late old work replaces source with revision 1 while generation remains 2 |

These are hazards of introducing concurrency into the existing sequential
protocol, not evidence that the current single-slot downloader already runs
those overlapping jobs.

The proposed protocol is:

- Freeze the underline list, batch plan, request parameters, epoch, and plan
  hash. Changing batch size during resume must not reinterpret old batch IDs.
- Network workers return identities and result paths. They do not write the
  shared annotation database.
- A single writer validates epoch and plan, then atomically stores each
  completed batch. Saved batch rows form the completion set.
- A contiguous-prefix cursor is only a hint. Resume examines the plan and
  completion set and requests exactly the missing batches.
- Publish a chapter source only when all required batches are present. Reject
  results from cancelled or superseded epochs, and clean only that epoch's
  temporary rows.
- Keep matching/projection work separate from source downloads. Do not run
  simultaneous CREngine matching jobs on the same active document.

A small completion-set model covered all six permutations of three batches
and four interruption positions: 24 cases with no missing or repeated batch.
It establishes the scheduling model, not a completed plugin implementation.

## Transport implementation choices

### Bounded network child-process pool

This reuses blocking LuaSocket/LuaSec while isolating their global state. An
initial experiment can use two global network slots, shared by body shards,
comments, and resources. The UI parent should track every child PID and its
request identity. Children write response bodies to private temporary files;
the parent coordinates state without decoding large result JSON in the UI.

The current `BackgroundWorker` cannot simply be submitted a batch of jobs. It
has one active job and one pending slot; another pending submission replaces
the previous one (`background_worker.lua:263-271`). A real pending queue and
pool coordinator are required. The existing single top-level user download
can remain a single job containing this internal request pool.

Avoid an untracked nested pool. The upstream subprocess helper gives children
their own process groups, and termination addresses a particular group.
Killing an outer worker therefore does not automatically guarantee cleanup of
every grandchild created by the same helper. Track and reap all network
children from their owning parent. See
[KOReader subprocess helpers](https://github.com/koreader/koreader-base/blob/master/ffi/util.lua).

Budget process memory and buffered result bytes. Forked pages may initially
be shared, but writes and simultaneous decoders can increase resident memory.
The current worker also excludes Android, so platform support must be explicit.

### One worker with genuinely asynchronous transport

This may reduce process overhead, but needs a proven available transport or
a complete nonblocking implementation. It must handle DNS/connect behavior,
partial I/O, TLS read/write readiness, pending decrypted data, redirects,
independent deadlines, cancellation, and close behavior. `socket.select()`
alone or a coroutine wrapper does not supply those behaviors.

Do not assume all target devices provide `curl_multi` or another suitable
library. Confirm the dependency on supported KOReader/device builds before
selecting it. Reference behaviors:
[LuaSocket select](https://lunarmodules.github.io/luasocket/socket.html#select),
[TCP timeout](https://lunarmodules.github.io/luasocket/tcp.html#settimeout),
[LuaSec documentation](https://github.com/lunarmodules/luasec/wiki/LuaSec-1.3.x).

## Limits, cancellation, and evaluation

Concurrency and request rate need separate controls. A per-worker 0.3-second
delay permits aggregate request rate to grow as workers are added. Maintain
one account-wide scheduler, a global in-flight window, and bounded request
rate. Do not accidentally multiply a chapter window by a shard window:
two chapters with four simultaneous shards each would create eight requests.

Use two slots as an experimental starting point, not a documented WeRead
limit. Trial higher windows only after observing successful completion,
latency, retry counts, memory, and upstream responses. Reduce concurrency or
pause appropriately for low memory, repeated timeouts, authentication errors,
or throttling. Preserve structured status and `Retry-After`; converting every
failure into a string loses useful scheduling information.

CPU-heavy decoding, SQLite commits, footnote transformation, and archive
compression need separate bounds. Increasing network concurrency must not
accidentally create several full-book decoders or archive writers.

Cancellation stops queue admission, cancels all in-flight requests, and waits
for children to exit before deleting their workspaces. Late results must fail
task/epoch/attempt checks. Every completion path must release ownership even
when metadata or cleanup fails, including the already identified downloader
finalization defect.

Recommended investigation/implementation order:

1. Preserve content correctness and bounded storage: fix resource duplication,
   annotation checkpoint amplification, and task finalization.
2. Prototype a global request pool with immutable inputs, private outputs,
   per-request deadlines, cancellation, and one committing owner.
3. Validate one chapter's shard group, including unknown-format detection,
   missing shards, session refresh, and fixed-order decoding.
4. Add independent annotation batches with epoch/plan/completion-set resume.
5. Evaluate a small cross-chapter window after resource, catalog-order, and
   footnote barriers are correct.

Before production changes to Web API interactions, use the repository's
script-first process on the remote environment with authorized real samples.
The outstanding evidence includes real account concurrency tolerance, content
equivalence, TLS behavior on supported devices, and peak device memory.

Measure completed-book time, request count, retries, throttled responses,
peak RSS, buffered bytes, longest UI stall, cancellation latency, and repeated
requests after resume. Keep image-heavy, long TXT, annotation-heavy, and
high-latency cases separate. A faster error response is not a successful speedup.

## Remote experiment artifacts

The isolated test directory was `/tmp/weread-perf-bMY1l6` on `test-env`:

- `concurrency-http.lua` and `concurrency-http-probe.py`
- `concurrency-http-results.json`
- `concurrency-state-probe.lua`
- `annotation_parallel_probe.lua`

The HTTP probe used LuaSocket 3.1.0, revision
`95b7efa9da506ef968c1347edf3fc56370f0deed`, and LuaJIT revision `c6ffc14`.
The state/annotation probes used the existing repository test adapters.
All completed successfully after one transient SSH authentication refusal was
resolved by reconnecting. No local fallback verification was performed.

The focused [multi-chapter follow-up](multichapter-download-feasibility.md)
adds sliding-window HTTP measurements, image/path and cross-chapter footnote
experiments, durable coordinator design, and a reader-context validation plan.
