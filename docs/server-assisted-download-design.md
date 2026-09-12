# Public server-assisted download service

Date: 2026-09-12. Plugin baseline: `2943080` (`v1.4.2`).

The intended deployment is a public service for plugin users, rather than a
single-user private server. This is a feasibility and architecture proposal;
no service was implemented or deployed and no user credentials were accessed.
The follow-up used source inspection and official reference material, with no
local runtime verification.

Related investigations:

- [Chapter cache performance](chapter-cache-performance-investigation.md)
- [Whole-book download feasibility](whole-book-download-feasibility.md)

## Feasibility and expected benefit

The design is feasible. The server can fetch readable chapters and comments,
decode content, process images and footnotes, persist partial work, and build
one complete EPUB. The reader then downloads the finished artifact and imports
small annotation batches.

A forwarding proxy retains the plugin's existing request count, decoding,
packing, and foreground blocking. A download service moves those operations
into durable server jobs. It can also continue processing after the reader
disconnects or sleeps, once the task and required authorization are accepted.

The server still normally calls WeRead chapter APIs; it does not create a
previously unavailable upstream full-book EPUB endpoint. Device-side small
requests become a few job/status calls and a resumable artifact transfer.
Final device bandwidth, WeRead response latency, service throttling, and local
annotation mapping remain part of the total time. No fixed speedup is claimed.

## Processing flow

```text
KOReader plugin
    -> Authenticated job API
    -> Durable queue with per-account scheduling
    -> Worker: chapter acquisition, source indexes, images, annotations
    -> Worker: footnotes, EPUB assembly, manifest generation
    -> Private artifact storage
    -> Resumable device download and atomic local installation
    -> Bounded annotation import and local document matching
```

The API service should return a job identifier promptly. It must not hold one
HTTP request open for an entire large book. Progress is persisted independently
of a particular worker or client connection. Text and annotation completion
are separate states: an annotation failure must not cause a successful book
download to run again.

## Public-service identity and authorization

There are two distinct identities:

1. A service user/device credential authorizes job creation, status access,
   artifact retrieval, cancellation, and account unlinking.
2. That user's WeRead session authorizes upstream content access. The current
   plugin uses Web cookies for body acquisition and the user-bound official API
   key for gateway annotation requests. A service token is not a substitute for
   either upstream credential.

The [official skill documentation](https://github.com/Tencent/WeChatReading)
describes user-bound API keys and metadata/annotation capabilities. It does
not provide an authorization mechanism for this proposed public service to
download full body content on behalf of arbitrary users.

Two operating models are possible:

| Model | Server receives | Main effect |
| --- | --- | --- |
| Delegated acquisition | User-authorized WeRead session and any needed API key | Moves upstream fetching and processing off the device |
| Processing only | Already fetched source/asset data | Moves CPU and packing; upstream chapter requests remain on the device |

Full cloud acceleration therefore involves actual session custody. Encrypting
credentials at rest does not mean the worker can fetch on the user's behalf
without access to them. The plugin needs an explicit cloud-account connection
flow, a description of the data sent, and a way to revoke the connection.
Do not assume an official third-party OAuth flow exists.

An initial service can keep authorization only for a job's agreed lifetime;
restarting after that lifetime requires renewed authorization. Persistent
background access is a separate opt-in behavior. Credentials should not enter
URLs, queue payloads, ordinary logs, artifact manifests, or subprocess command
arguments. Jobs reference an account record; the worker resolves credentials
when executing them. Deleting or disconnecting that account must stop future
upstream work and make pending jobs report that authorization is required.

Session updates need generation checks and serialization per upstream account.
The plugin already applies this principle in `worker_settings.lua`: a worker
must not overwrite newer authentication state. A service must also avoid
mixing a user's cookies with an API key linked to a different WeRead identity.

## Tenant isolation and scheduling

Every account, job, intermediate file, and artifact has an owner. Job IDs and
book IDs are identifiers, not access credentials. Verify ownership at all API
operations, including polling, cancelling, and downloading output.

Artifact storage is private. Return an authenticated download route or a
short-lived, scoped download grant after an ownership check. Expired grants
can be refreshed without regenerating the book.

The cache identity must include at least the service owner, upstream account,
book, content/catalog revision, selected chapters, and output options. Start
with reuse within one user's account and devices. A cache keyed only by
`book_id` would mix access contexts and potentially user-specific content.

Use both per-account limits and a global worker limit. Start with one active
acquisition job per upstream account, then measure bounded shard concurrency.
Use fair scheduling so one very large book does not monopolize the queue.
Coalesce duplicate requests for the same user's identical artifact while
keeping each requesting device's subscription and cancellation semantics clear.

Persist successful chapters and annotation batches. Retries should target
transient failures and missing work, with bounded backoff. Expired login,
access denial, invalid input, and content changes need distinct states rather
than endless retries. A user's entitlement or login failure must not trigger
work under another user's credentials.

Bound job disk use, worker memory, output sizes, concurrent requests, and
retention. Treat downloaded HTML, archives, and metadata as untrusted inputs;
extract resources only into the job directory and generate artifact paths
internally. Expose book-oriented operations, not an arbitrary URL-fetch service.

## Artifact contract

An EPUB URL alone is insufficient for compatibility with the current plugin.
The server must produce a versioned manifest alongside the clean EPUB.

| Artifact/data | Required content | Device action |
| --- | --- | --- |
| EPUB | Clean text, images, processed footnotes | Save and atomically install |
| Manifest | Schema/generator version, account/book identity, content revision, byte size, digest, artifact identity | Validate compatibility and completed transfer |
| Catalog | Ordered chapter UID, index, title, word count, level, EPUB href | Register metadata and preserve progress mapping |
| Clean document descriptor | Exact chapter order represented in the EPUB | Register against the local file path |
| Original source index | Original HTML rune offsets, or TXT offset spans | Import for underline quote recovery |
| Annotation source batches | Book/chapter UID, revision, underlines, reviews, batch cursor | Import transactionally in bounded chunks |

Source indexes must be generated before text extraction, image rewriting, and
footnote conversion. WeRead ranges refer to positions in the original source,
including tag characters (`annotation_source.lua:1`). Recomputing those offsets
from the final EPUB would be incorrect.

The plugin identifies downloaded books using registered paths
(`reader_lifecycle.lua:328`). Installation must update the existing cache
record, catalog, and `annotation_documents[local_path]` clean descriptor
(`content.lua:1475`). Merely choosing the right EPUB title or UUID does not
preserve this integration.

XPointer projections remain local. Their current identity includes local file
information and engine version (`annotation_store.lua:179`), and matching uses
the local document/CREngine API (`external_annotations.lua:442`). The service
can prepare quotes and indexes, but a generic server-side XPointer cache is
not a portable substitute for the current device projection.

Do not send one enormous all-book JSON response or overwrite the live device
database with a server database file. Import logical, revisioned batches through
the local storage layer. A chapter commit needs source, source status, and
per-range thought data; a completion flag without its data would make the sync
pipeline skip required work. Commentary refreshes should not regenerate the
EPUB and invalidate every local projection.

## Minimal protocol

The following routes are proposed service endpoints, not existing WeRead APIs:

```text
POST   /v1/book-jobs
GET    /v1/book-jobs/{job_id}
DELETE /v1/book-jobs/{job_id}
GET    /v1/artifacts/{artifact_id}/manifest
GET    /v1/artifacts/{artifact_id}/book.epub
GET    /v1/artifacts/{artifact_id}/annotations?cursor=...
```

Job creation supplies an upstream account reference, book ID, chapter scope,
generation options, annotation options, and an idempotency key. Status exposes
phase, completed/total chapters, text and annotation readiness, retry state,
and a machine-readable error without credentials or private response bodies.

Artifact bytes must remain immutable for a given artifact ID. Support HTTP
Range, a stable strong ETag, and If-Range according to
[HTTP Semantics](https://www.rfc-editor.org/rfc/rfc9110.html#section-14).
The client checks whether the server resumed with `206` or restarted with
`200`; it must not append a whole replacement response to a partial file.
Verify final size and digest before installation. A refreshed download grant
must refer to the same artifact to reuse partial bytes.

The current `Client:download_to_file()` deletes its `.part` on each call
(`client.lua:370`), so this requires a real resumable client implementation.
That implementation must also run outside the foreground event loop, enforce
deadlines, and handle cancellation; otherwise a single large cloud transfer
can still freeze the reader.

The API service, durable queue, worker, metadata database, and private file
storage are logical roles. A limited pilot can colocate them with bounded
concurrency; production growth can separate them without changing the device
protocol. A large-book worker needs persistent execution and progress, even
if the request API is hosted in a short-lived cloud function.

## Reuse and implementation scope

`scripts/fetch_weread_epub.py` provides an acquisition prototype: cookies,
catalog lookup, chapter fetching, decoding, and EPUB output. It is not a
production-equivalent implementation of the current Lua pipeline:

- `extract_body()` takes only the first body (`:467`), while Lua handles
  concatenated XHTML documents.
- Resource handling lacks current ZIP support and merges identical hrefs
  across chapters (`:535`, `:595`).
- The EPUB writer receives title/body/assets tuples rather than chapter UIDs
  and produces no compatible catalog, descriptor, source index, or annotation
  bundle (`:561`).
- It lacks the current Lua footnote/CSS pipeline and accumulates the full book
  in memory (`:892`).

Use its protocol code as a starting point, while extracting reusable pure
content processing or porting it with parity fixtures. There is already a
Python-to-Lua footnote validation bridge in `scripts/verify_book_footnotes.py`.
Do not publish the research script merely by wrapping its entry point in HTTP.

Suggested delivery stages:

1. A bounded public pilot with per-user authorization, isolated durable jobs,
   correct EPUB/manifest output, private delivery, and text resume. The plugin
   gains job UI, background artifact download, and an atomic installer.
2. Server annotation acquisition and bounded device import. Keep local
   projection generation and retain separate text/comment completion.
3. In-account cache reuse, delta annotation updates, improved progress,
   measured concurrency, and retention/capacity tuning.

A public pilot needs ownership, credential handling, and resource isolation
from its first stage; those cannot be deferred until after multiple users
start using it. Direct device downloads can remain available independently.

## Validation before launch

Run verification on `ssh test-env` under the repository's current policy.
Use synthetic fixtures first and authorized accounts only for protocol checks.
The launch criteria should cover:

- Isolation across users for every job/artifact operation and cache lookup.
- Authentication expiry, generation changes, revocation, and worker restart.
- Fair scheduling, duplicate jobs, partial failures, and resume after reboot.
- Correct concatenated XHTML, same-name images, shared assets, footnotes,
  catalog ordering, and server/device schema compatibility.
- Slow artifact transfer, dropped connections, Range ignored by the server,
  changed artifact identity, cancellation, and atomic installation.
- Bounded annotation import and working local progress/highlight mappings.

Measure upstream request time, queue time, generation time, server storage,
artifact egress, device transfer time, and device import/matching time
separately. Cloud processing moves the work and can reuse results; final
download traffic and local mapping costs remain measurable capacity inputs.
