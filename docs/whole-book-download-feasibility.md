# Whole-book download feasibility

Date: 2026-09-12. Plugin revision: `2943080` (`v1.4.2`).

This follows the [chapter cache investigation](chapter-cache-performance-investigation.md).
It evaluates whether whole-book downloads can avoid the cost of caching many
independent chapters. The follow-up used static code inspection and read-only
retrieval of current official documentation and public frontend bundles. It
did not run local verification, call authenticated content APIs, or download
a real book. Earlier remote synthetic results remain applicable.

## Decision

An efficient whole-book cache task is feasible and can reuse the existing UI.
The plugin already produces a combined EPUB, but internally fetches its text
chapter by chapter. Improving that task can remove repeated archives, reduce
memory usage, keep the UI responsive, and preserve completed work after errors.

No general single-file EPUB/TXT content download API was found in the inspected
official documentation or public frontend sources. This is a scoped finding,
not proof that no private mobile or other internal API exists.

The Web reader has a separate PDF file URL path, which is a candidate for a
format-specific direct-download feature. That path still requires authenticated
sample validation before its usability in this plugin can be established.

## Existing full-book support

The current book detail view contains `Download full book`
(`weread/ui/library.lua:784`). Its callback calls
`confirmDownloadAllChapters()` at line 1535, loads the catalog, and starts the
downloader with all chapters and `suffix = "full"`.

| Behavior | Selected chapters | Current full-book EPUB |
| --- | --- | --- |
| Text requests | Per chapter | Same per-chapter path |
| Final output | One EPUB per chapter | One combined EPUB |
| Image directory archives | Repeated because of the identified bug | Once for the full book |
| Comment acquisition | Separate annotation pipeline | Same separate pipeline |
| Foreground blocking | Present | Present |
| Body storage | All bodies retained until final processing | All bodies retained, plus assembled archive entries |
| Durable text resume | Missing | Missing |

Both modes reach `Content.fetch_single_chapter_source()`
(`downloader.lua:1063`). For normal EPUB content, each chapter refreshes its
reader HTML and obtains `e_0`, `e_1`, and `e_3` shards
(`content.lua:1324-1347`). CSS and image requests are additional. Changing the
output mode does not collapse those requests into one transfer.

For C comparable EPUB chapters, the current normal source path therefore has
roughly 4C reader/shard requests before shared CSS, initialization, catalog,
images, cover, retries, and format-detection overhead. This is a structural
request count, not an elapsed-time estimate.

The combined EPUB uses one resource-directory archive call
(`content.lua:809`) and one final `write_epub()` (`content.lua:884`). It avoids
the selected-chapter image amplification already demonstrated remotely. If K
selected chapters each cause the B-byte shared image directory to be archived,
that component falls from approximately K × B archive input to B. The whole
operation does not necessarily become K times faster: networking, decoding,
footnotes, and annotations remain.

The existing implementation has important limitations for large books:

- `save_book_epub()` constructs all wrapped XHTML entries before writing
  (`content.lua:811-827`), alongside the original bodies. Switching to the
  existing full-book option can increase the final memory peak.
- Packaging still runs synchronously in the UI callback
  (`downloader.lua:900`).
- If any chapter fails, the downloader correctly rejects an incomplete full
  book, but then discards its temporary workspace (`downloader.lua:845-864`).
  Starting again does not reuse the successful raw chapter downloads.
- Already cached chapter EPUBs are not automatically assembled into a full
  book by this path. The annotation `original` cache contains text/offset
  indexes, not complete reconstructible XHTML, CSS, and image data.

## Direct file API evidence

The official [WeRead Skill page](https://weread.qq.com/r/weread-skills) points
to [Tencent/WeChatReading](https://github.com/Tencent/WeChatReading).
Its current [book interface documentation](https://github.com/Tencent/WeChatReading/blob/main/skills/book.md)
describes metadata, catalogs, and reading progress; it exposes no full-text
or complete EPUB/TXT file endpoint.

The publicly loaded Web reader bundles were also examined: `app`, `common`,
`utils`, and 35 numbered chunks referenced by the reader page. EPUB/TXT processing
continues to reference chapter content and resource paths. Chapter `tar`
packages contain resources; they are not complete books. Frontend matches for
some `downloadUrl` names refer to installing the WeRead application, rather
than downloading book content.

### PDF-specific candidate

The official Web reader bundle includes `FETCH_READER_PDF_URL`, which requests:

```text
https://res.weread.qq.com/cos/download?getUrl=1
```

It supplies `bookId`, reads a returned `url`, and stores it as `pdfUrl`. The
caller uses this action through an `actualTreatBookAsPdf(bookInfo)` branch.
The effective format uses `otherType[0].type` when that entry has `showType`,
otherwise `bookInfo.format`, and the PDF branch requires the value `pdf`.
The returned URL reaches PDF.js through `getDocument({url,
withCredentials: true, ...})`, with progress and a standard PDF password
callback. No custom pre-load decryption was identified in that inspected
chain. The request helper's HTTP method was not conclusively resolved from
the obfuscated bundle during this bounded investigation.
The implementation is present in these official versioned assets:

- [Reader bundle 9.cab69770.js](https://cdn.weread.qq.com/web/wrwebnjlogic/js/9.cab69770.js)
- [Reader bundle 17.237e2b08.js](https://cdn.weread.qq.com/web/wrwebnjlogic/js/17.237e2b08.js)

This is stronger evidence for a direct PDF file path than for a general EPUB
download. It does not establish that any book ID can use that path, that a
returned URL always exposes a standalone usable PDF, or that the plugin's
current annotation/progress mapping works with PDF documents.

Before implementing this non-public API, follow the repository's script-first
workflow on `ssh test-env`: validate a readable PDF sample, authorization,
response format, complete-file readability, URL expiry, timeout/cancellation,
and any range support. Then implement a format-specific branch. Existing
XPointer-based annotation matching and chapter/offset progress assumptions
need separate PDF compatibility work.

## Whole-book comments remain a separate workload

The official [notes documentation](https://github.com/Tencent/WeChatReading/blob/main/skills/notes.md)
distinguishes several capabilities:

| Data | Book-wide access | Suitability for the current community annotation cache |
| --- | --- | --- |
| Personal highlights | `/book/bookmarklist` accepts a book ID | A different, narrower data set |
| Personal thoughts/reviews | `/review/list/mine` pages within a book | A different, narrower data set |
| Popular highlights | `/book/bestbookmarks`, `chapterUid=0` | Only the top 20; no pagination |
| Community underline heat | `/book/underlines` requires a chapter UID | Still per chapter |
| Thoughts attached to ranges | `/book/readreviews` requires chapter UID and ranges | Still chapter/range batches |

Consequently, neither a combined EPUB nor a direct PDF download removes the
community comment workload. The book-level personal APIs and top highlights
cannot be substituted without changing which data the user receives.

The plugin already shares annotation source data by book/chapter, so switching
to a full-book EPUB can reuse previously completed source downloads. Its
document-position projection is associated with a document key, however, and
the new EPUB may require matching again (`annotation_sync.lua:64-69`,
`annotation_sync_controller.lua:110`). The checkpoint-write and matching
optimizations from the earlier investigation are still required.

## Recommended implementation

Keep the existing full-book entry and implement a resumable background task:

```text
Catalog snapshot and cache identity
    -> Download missing chapter sources and referenced resources
    -> Persist each completed chapter and its resource manifest
    -> Resolve cross-chapter footnotes in a second pass
    -> Archive the staged book once
    -> Atomically publish the complete EPUB
```

1. Use a worker for network requests, decoding, resources, and packaging.
   Parent/child communication should contain paths, counters, and errors,
   rather than entire book bodies in result JSON. Give transfers deadlines,
   cancellation checks, byte progress, and a watchdog that understands long
   stages with continuing progress.
2. Persist raw sources and assets with a task manifest identifying the account,
   book, catalog/content revision, and generation options. Commit successful
   chapters as they complete. Resume only the missing or invalid work.
3. Keep cross-chapter footnote resolution by separating download/indexing from
   transformation. Read, transform, and release one staged body at a time;
   retain compact indexes rather than every full body.
4. Archive the staged directory once using the existing Kindle-compatible
   directory writer. Preserve EPUB `mimetype` placement and compression rules;
   avoid unnecessary recompression of already compressed images.
5. Atomically replace the finished full book, preserving an earlier valid file
   on failure. Make task cleanup unconditional so metadata or shelf-refresh
   errors cannot retain the active-job slot.
6. Offer a single user operation for text plus comments if desired, while
   tracking their completion separately. A failed comment batch should resume
   independently after the text is ready. Source comment caching can run in
   the background; document-position matching must respect the document's
   owning process.

The official [chapter reader bundle](https://cdn.weread.qq.com/web/wrwebnjlogic/js/17.237e2b08.js)
uses `Promise.all` for four content requests within an EPUB chapter. This
provides a concrete reference for testing bounded parallel shard retrieval in
the plugin; it is not evidence that high cross-chapter concurrency is safe.
Parallel requests or reusing reader session information may reduce latency,
but require measured validation of rate limits and session semantics.
Do not assume changing request headers provides connection
pooling, or remove per-chapter session refresh solely because its cost is high.

For existing chapter EPUB caches, investigate a separate import path that
extracts verified body/resource data into the new shared staging format. It
must account for transformed footnotes and resource ownership. New downloads
should populate that format directly so chapter and full-book outputs can
reuse the same validated source data.

## Expected outcome and remaining uncertainty

The proposed EPUB task can eliminate repeated archive work, bound body memory,
retain successful work across failures, and keep the interface responsive.
These benefits do not depend on discovering a new WeRead endpoint. The amount
of end-to-end speedup depends on whether archive work, network latency, source
processing, or annotations dominate the particular book.

A PDF fast path is a separate promising investigation, supported by current
official frontend code but awaiting authenticated sample validation. A general
direct EPUB/TXT transfer remains unconfirmed. No fixed speedup or device memory
number is claimed, and no functional plugin code was changed in this follow-up.

The subsequent [parallel download study](parallel-download-feasibility.md)
examines shard and annotation concurrency, including controlled remote HTTP
timings and state/resume interleaving experiments.
