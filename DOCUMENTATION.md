# html Documentation

This is the canonical manual for usage, API, selector behavior, performance workflow, conformance expectations, and internals.

## Table of Contents

- [Requirements](#requirements)
- [Quick Start](#quick-start)
- [Core API](#core-api)
- [Non-Destructive Parsing](#non-destructive-parsing)
- [Selector Support](#selector-support)
- [Mode Guidance](#mode-guidance)
- [Performance and Benchmarks](#performance-and-benchmarks)
- [Latest Benchmark Snapshot](#latest-benchmark-snapshot)
- [Conformance Status](#conformance-status)
- [Architecture](#architecture)
- [Troubleshooting](#troubleshooting)

## Requirements

- Zig `0.16.0`
- Mutable input buffers (`[]u8`) for destructive parsing
- `[]const u8` inputs are supported when `ParseOptions.non_destructive = true`

## Quick Start

```zig
const std = @import("std");
const html = @import("html");
const options: html.ParseOptions = .{};

test "basic parse + query" {
    var input = "<div id='app'><a class='nav' href='/docs'>Docs</a></div>".*;
    var doc = try options.parse(std.testing.allocator, &input);
    defer doc.deinit();

    var links = doc.query("div#app > a.nav");
    const a = (try links.next()) orelse return error.TestUnexpectedResult;
    const href = (try a.getAttributeValue(std.testing.allocator, "href")) orelse return error.TestUnexpectedResult;
    defer href.free(std.testing.allocator);
    try std.testing.expectEqualStrings("/docs", href.value);
}
```

Source examples:

- `examples/basic_parse_query.zig`
- `examples/query_time_decode.zig`

All examples are verified by running `zig build examples-check`

## Core API

### Parse and document lifecycle

- `const opts: ParseOptions = .{};`
- `var doc = try opts.parse(allocator, input);`
- `doc.deinit()`
- `doc.clear()`
- destructive options accept mutable input and parse it in place
- non-destructive options accept read-only input and parse directly from the original bytes
- documents own node storage and borrow input; callers retain input ownership and must keep it alive
- `Node` and `ChildrenIter` values are views into the current document generation; `clear()`, reparsing into the document, or replacing the document invalidates them
- maximum parseable input size is controlled at build time with `-Dintlen`

### Query APIs

- Compile-time selectors:
  - `var it = doc.query(comptime selector); try it.next()`
  - `doc.query(comptime selector)`
- Runtime selectors:
  - `var it = doc.queryRuntime(compiled_selector); try it.next()`
  - `doc.queryRuntime(compiled_selector)`
- Cached runtime selectors:
  - `var it = doc.queryRuntime(selector); try it.next()`
  - `doc.queryRuntime(selector)`
  - selector created via `try Selector.compileRuntime(allocator, source)`
- Iterators may be copied before their first `next()`. After matching starts,
  keep the iterator at one address; using a copied or moved started iterator
  returns `error.QueryIteratorCopiedAfterStart`.
- A matcher error terminates that iterator. The failing `next()` returns the
  original error and later `next()` calls return `null`; create a new iterator
  to retry.

### Node APIs

- Navigation:
  - `tagName()`
  - `parentNode()`
  - `nextSibling()`
  - `prevSibling()`
  - `children()` (iterator of wrapped child nodes; `collect(allocator)` returns an owned `[]Node`)
  - `children().last()` only when `ParseOptions.store_last_child = true`
- Text:
  - `innerTextWithOptions(gpa, TextOptions)` returns `TextResult`
  - `TextResult.value`
  - `TextResult.free(gpa)`
  - `innerTextOwnedWithOptions(gpa, TextOptions)` always allocates
- Attributes:
  - `getAttributeValue(gpa, name)` returns `!?AttributeValueResult`
  - `AttributeValueResult.value`
  - `AttributeValueResult.free(gpa)`
  - `getAttributeValueRaw(name)` returns the currently stored payload; expanding full-table entities remain raw in destructive compact storage
- Point matching:
  - `matches(comptime_selector)` tests the node itself with candidate-centric RTL matching
  - `matchesRuntime(compiled_selector)` is the runtime-compiled equivalent
  - both reject leading relative combinators (`>`, `+`, `~`) rather than treating them as scoped queries
- Scoped queries:
  - same iterator-first query family as `Document` (`query` and `queryRuntime`)

### Helpers

- `doc.html()`, `doc.head()`, `doc.body()`
- `TextResult.owned` reports whether the result owns allocator-backed storage

### Parse/Text options

- `ParseOptions`
  - `drop_whitespace_text_nodes: ParseOptions.WhitespaceText = .nodes_and_preceding`
  - `non_destructive: bool = false`
- build option:
  - `-Dintlen=u16|u32|u64|usize`
  - controls the integer width used for source spans and node indexes
  - too-small widths fail fast with `error.InputTooLarge`
- `TextOptions`
  - `normalize_whitespace: bool = true`
  - `unescape: bool = true`
- parse/query work split:
  - parse keeps raw text and attribute spans as source slices
  - destructive mode compacts and decodes a tag's complete attribute list in place on its first attribute access
  - non-destructive mode keeps attrs/text read-only and materializes decoded output only when needed

### Design Notes

- destructive parsing is the default because the parser and lazy decode paths mutate source bytes in place for throughput
- non-destructive parsing avoids a full-source copy and instead moves lazy attr/text decoding out of the input buffer
- nodes are stored in one contiguous array and linked by indexes rather than pointers to keep traversal cache-friendly and make `-Dintlen` effective
- attribute storage stays span-based instead of building heap objects so parse cost scales with actual queries, not attribute count
- destructive attribute lists normally use `name<marker>valueNUL ... >`; `=` marks an in-place decoded value, while `/`, `'`, and `"` mark raw expanding values that originally used naked, single-quoted, and double-quoted syntax; empty assignments collapse to valueless attributes. A NUL where the next compact name would begin switches the malformed remainder of that tag back to raw attribute syntax when a recovered attribute name itself contains a marker byte.
- compact values may contain whitespace, `>`, `/`, `=`, and malformed UTF-8 because only NUL terminates them
- destructive decoding changes literal NUL bytes to spaces and numeric NUL references to U+FFFD; malformed leading UTF-8 bytes in attribute names are replaced with an internal marker
- tag and attribute names use delimiter blacklists rather than identifier whitelists, allowing framework names such as `@click`, `*ngIf`, `(change)`, and `[value]`
- destructive text spans use the byte immediately after the span as lazy state: `0x03` means decoded, `0x01` means an expanding reference requires an owned/streaming fallback, and `0x02` means raw text was normalized without decoding; terminal text without spare capacity may be checked again
- `.full` decoding can make `TextResult` or `AttributeValueResult` owned when a named reference expands (notably `&nLt;`/`&nGt;`); always call the result's `free(gpa)` helper
- `writeHtml(writer, comptime entities)` accepts `.never`, `.auto`, or `.force`; `.auto` re-encodes already-decoded destructive text, `.force` canonicalizes escapable text and attributes, and `format` uses `.never`
- `.entity_decoding` selects `.minimal` (five basic names), `.common` (adds `nbsp`, `copy`, `reg`, `mdash`, `ndash`, and `hellip`), or `.full` (the complete generated WHATWG table); numeric references are always decoded
- `script` and `style` are parsed as raw text and never entity-decoded; `title` and `textarea` are parsed opaquely as escapable raw text and do decode character references during extraction
- query-time decoding keeps parse throughput high by avoiding eager entity decode and whitespace normalization for bytes that may never be read

## Non-Destructive Parsing

Use a non-destructive document type when the caller bytes must remain unchanged.

```zig
const opts: html.ParseOptions = .{ .non_destructive = true };
const html_bytes = "<div id='x' data-v='a&amp;b'> hi &amp; bye </div>";
var doc = try opts.parse(std.testing.allocator, html_bytes);
defer doc.deinit();
```

Behavior:

- the default destructive path is unchanged and still parses caller memory directly
- non-destructive mode does not allocate or rewrite a full source copy
- lazy attribute reads never rewrite the source buffer
- malformed UTF-8 in read-only attribute names and values remains in the source and is traversed tolerantly
- lazy text reads never rewrite the source buffer
- text extraction allocates only when decoding or normalization requires materialized output
- `Document.writeHtml` and `Document.format` return the exact original source bytes in non-destructive mode
- node-level formatting still serializes from parsed state rather than replaying original source slices

Use cases:

- parsing file-backed memory maps
- preserving original bytes for hashing, diffing, or cache keys
- running parser queries without allowing in-place mutation of shared buffers

### Instrumentation wrappers

- `queryWithHooks(doc, comptime_selector, hooks)`
- `queryRuntimeWithHooks(doc, compiled_selector, hooks)`

## Selector Support

Supported selectors:

- tag selectors and universal `*`
- `#id`, `.class`
- attributes:
  - `[a]`, `[a=v]`, `[a^=v]`, `[a$=v]`, `[a*=v]`, `[a~=v]`, `[a|=v]`
- combinators:
  - descendant (`a b`)
  - child (`a > b`)
  - adjacent sibling (`a + b`)
  - general sibling (`a ~ b`)
- grouping: `a, b, c`
- pseudo-classes:
  - `:first-child`
  - `:last-child`
  - `:nth-child(An+B)` with `odd/even` and forms like `3n+1`, `+3n-2`, `-n+6`
  - `:not(...)` (simple selector payload)
- parser guardrails:
  - multiple `#id` predicates in one compound (for example `#a#b`) are rejected as invalid

Compilation modes:

- comptime selectors fail at compile time when invalid
- runtime selectors return `error.InvalidSelector`

## Mode Guidance

`html` is permissive by design. Choose the document type by workload:

| Mode | Parse Options | Best For | Tradeoffs |
|---|---|---|---|
| `strictest` | `const opts = html.ParseOptions{ .drop_whitespace_text_nodes = .none };` | traversal predictability and text fidelity | keeps whitespace-only text nodes |
| `fastest` | `const opts = html.ParseOptions{};` | throughput-first scraping | whitespace-only text nodes dropped; raw node metadata is compact |
| `non-destructive` | `const opts = html.ParseOptions{ .non_destructive = true };` | preserving input bytes, memory maps, exact whole-document formatting | decoded attrs/text are materialized outside the source buffer |
| `full metadata` | `const opts = html.ParseOptions{ .store_last_child = true, .store_prev_sibling = true };` | O(1) `children().last()` and previous-sibling traversal | two extra persisted node indexes |

Fallback playbook:

1. Start with `fastest` for bulk workloads.
2. Move unstable domains to `strictest`.
3. Compile runtime selectors once and reuse `queryRuntime` iterators for repeated queries.

## Performance and Benchmarks

Run benchmarks:

```bash
zig build bench-compare
zig build tools -- run-benchmarks --profile quick
zig build tools -- run-benchmarks --profile stable
zig build bench-interleaved -- --candidate .worktree/experiment --profile stable --runs 6
```

Artifacts:

- `bench/results/latest.md`
- `bench/results/latest.json`

Benchmark policy:

- parse comparisons include `strlen`, `lexbor`, and parse-only `lol-html`
- query parse/match/cached sections benchmark `html`
- repeated runtime selector workloads should use cached selectors
- checkout comparisons alternate which side runs first, report median speedups, and preserve every raw sample in `bench/results/interleaved_latest.json`

## Latest Benchmark Snapshot

Warning: throughput numbers are not conformance claims. This parser is permissive by design; see [Conformance Status](#conformance-status).

<!-- BENCHMARK_SNAPSHOT:START -->

Source: `bench/results/latest.json` (`stable` profile).

#### Parse Throughput Comparison (MB/s)

| Fixture | ours-compact | ours-full | ours-stream | lol-html |
|---|---:|---:|---:|---:|
| `rust-lang.html` | 2341.78 | 2451.33 | 4768.39 | 1579.24 |
| `wiki-html.html` | 2517.20 | 2678.26 | 4546.09 | 1744.36 |
| `mdn-html.html` | 3254.92 | 3553.53 | 6092.89 | 2091.96 |
| `w3-html52.html` | 1402.47 | 1545.00 | 2051.46 | 829.57 |
| `hn.html` | 1677.92 | 1716.20 | 3730.78 | 958.99 |
| `python-org.html` | 1729.45 | 1979.22 | 4089.49 | 1370.54 |
| `kernel-org.html` | 2213.53 | 2242.59 | 4197.49 | 1466.15 |
| `gnu-org.html` | 2430.52 | 2572.67 | 4547.02 | 1540.72 |
| `ziglang-org.html` | 2176.38 | 2199.98 | 3996.73 | 1286.06 |
| `ziglang-doc-master.html` | 1771.96 | 1796.65 | 1739.27 | 1185.20 |
| `wikipedia-unicode-list.html` | 2223.38 | 2319.16 | 4615.07 | 1344.84 |
| `whatwg-html-spec.html` | 1709.70 | 1735.51 | 2056.09 | 1031.08 |
| `synthetic-forms.html` | 1633.51 | 1792.59 | 2516.03 | 670.09 |
| `synthetic-table-grid.html` | 1361.83 | 1347.46 | 1448.73 | 461.05 |
| `synthetic-list-nested.html` | 1019.39 | 1036.58 | 1351.34 | 437.82 |
| `synthetic-comments-doctype.html` | 1892.59 | 1926.03 | 2165.39 | 972.85 |
| `synthetic-template-rich.html` | 1624.21 | 1742.75 | 2370.41 | 583.51 |
| `synthetic-whitespace-noise.html` | 1867.67 | 2064.31 | 3069.30 | 1169.06 |
| `synthetic-news-feed.html` | 1826.27 | 1928.41 | 2406.67 | 731.31 |
| `synthetic-ecommerce.html` | 1587.11 | 1786.72 | 2668.87 | 680.73 |
| `synthetic-forum-thread.html` | 1717.99 | 1844.81 | 2547.59 | 732.13 |

#### Query Match Throughput

| Case | compact ops/s | compact ns/op | full ops/s | full ns/op |
|---|---:|---:|---:|---:|
| `attr-heavy-button` | 280515.45 | 3564.87 | 310339.25 | 3222.28 |
| `attr-heavy-nav` | 161156.01 | 6205.17 | 173942.36 | 5749.03 |

#### Cached Query Throughput

| Case | compact ops/s | compact ns/op | full ops/s | full ns/op |
|---|---:|---:|---:|---:|
| `attr-heavy-button` | 282383.20 | 3541.29 | 310695.58 | 3218.58 |
| `attr-heavy-nav` | 161529.91 | 6190.80 | 173893.23 | 5750.66 |

#### Query Parse Throughput (ours)

| Selector case | Ops/s | ns/op |
|---|---:|---:|
| `simple` | 10093403.35 | 99.07 |
| `complex` | 5406825.43 | 184.95 |
| `grouped` | 6757224.51 | 147.99 |

For full per-parser, per-fixture tables and gate output:
- `bench/results/latest.md`
- `bench/results/latest.json`
<!-- BENCHMARK_SNAPSHOT:END -->

## Conformance Status

Run conformance suites:

```bash
zig build conformance
# or
zig build tools -- run-external-suites --mode both
```

Artifact: `bench/results/external_suite_report.json`

Tracked suites:

- selector suites: `nwmatcher`, `qwery_contextual`
- parser suites:
  - html5lib tree-construction subset
  - WHATWG HTML parsing corpus (via WPT `html/syntax/parsing/html5lib_*.html`)

Fetched suite repos are cached under `bench/.cache/suites/` (gitignored).

## Architecture

Core modules:

- `src/html/parser.zig`: permissive parse pipeline
- `src/html/scanner.zig`: byte-scanning hot-path helpers
- `src/html/tags.zig`: tag metadata and hash dispatch
- `src/html/attr.zig`: attribute scanning, lazy materialization, and decode helpers
- `src/html/entities.zig`: entity decode utilities
- `src/selector/runtime.zig`, `src/selector/compile_time.zig`: selector parsing
- `src/selector/matcher.zig`: selector matching/combinator traversal

Data model highlights:

- `Document` always owns node/index storage and may either parse a mutable caller buffer in place or borrow a read-only caller buffer unchanged
- parser-only construction state stays in `src/html/parser.zig`; `Document` retains only post-parse/query state
- nodes are contiguous and linked by indexes for traversal
- attributes are traversed directly from source spans (no heap attribute objects)
- the build-time `-Dintlen` option widens or shrinks those spans and indexes uniformly
- destructive mode is the performance baseline; non-destructive mode exists as an opt-in isolation boundary

## Troubleshooting

### Query returns nothing

- validate selector syntax with `Selector.compileRuntime(allocator, source)`
- check scope (`Document` vs scoped `Node`)

### Unexpected `innerText`

- default `innerText` normalizes whitespace
- use `innerTextWithOptions(..., .{ .normalize_whitespace = false })` for raw spacing
- use `innerTextWithOptions(..., .{ .unescape = false })` to preserve entity escapes
- use `innerTextOwnedWithOptions(...)` when output must always be allocated
- call `TextResult.free(gpa)` for every result; it frees only when `TextResult.owned` is true

### Runtime iterator invalidation

Runtime selector memory must outlive any iterator returned by `queryRuntime`. Clearing or replacing a
`Document` invalidates iterators created from its previous generation; an invalidated iterator returns
`null` rather than traversing the replacement tree.

### Input buffer changed

Expected: parse and lazy decode paths mutate source bytes in place.

If the bytes must not change, instantiate a non-destructive document type.
