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
    const a = links.next() orelse return error.TestUnexpectedResult;
    const href = (try a.getAttributeValue(std.testing.allocator, "href")) orelse return error.TestUnexpectedResult;
    defer href.free(&doc, std.testing.allocator);
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
- maximum parseable input size is controlled at build time with `-Dintlen`

### Query APIs

- Compile-time selectors:
  - `var it = doc.query(comptime selector); it.next()`
  - `doc.query(comptime selector)`
- Runtime selectors:
  - `var it = doc.queryRuntime(compiled_selector); it.next()`
  - `doc.queryRuntime(compiled_selector)`
- Cached runtime selectors:
  - `var it = doc.queryRuntime(selector); it.next()`
  - `doc.queryRuntime(selector)`
  - selector created via `try Selector.compileRuntime(allocator, source)`

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
  - `TextResult.free(doc, gpa)`
  - `innerTextOwnedWithOptions(gpa, TextOptions)` always allocates
- Attributes:
  - `getAttributeValue(gpa, name)` returns `!?AttributeValueResult`
  - `AttributeValueResult.value`
  - `AttributeValueResult.free(doc, gpa)`
  - `getAttributeValueRaw(name)` returns the current raw value bytes; destructive documents may expose bytes mutated by prior decoded lookups
- Scoped queries:
  - same iterator-first query family as `Document` (`query` and `queryRuntime`)

### Helpers

- `doc.html()`, `doc.head()`, `doc.body()`
- `TextResult.isBorrowed(doc)` to check whether text points into document source bytes

### Parse/Text options

- `ParseOptions`
  - `drop_whitespace_text_nodes: bool = true`
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
  - destructive mode may decode attrs/text in place on query-time APIs
  - non-destructive mode keeps attrs/text read-only and materializes decoded output only when needed

### Design Notes

- destructive parsing is the default because the parser and lazy decode paths mutate source bytes in place for throughput
- non-destructive parsing avoids a full-source copy and instead moves lazy attr/text decoding out of the input buffer
- nodes are stored in one contiguous array and linked by indexes rather than pointers to keep traversal cache-friendly and make `-Dintlen` effective
- attribute storage stays span-based instead of building heap objects so parse cost scales with actual queries, not attribute count
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
```

Artifacts:

- `bench/results/latest.md`
- `bench/results/latest.json`

Benchmark policy:

- parse comparisons include `strlen`, `lexbor`, and parse-only `lol-html`
- query parse/match/cached sections benchmark `html`
- repeated runtime selector workloads should use cached selectors

## Latest Benchmark Snapshot

Warning: throughput numbers are not conformance claims. This parser is permissive by design; see [Conformance Status](#conformance-status).

<!-- BENCHMARK_SNAPSHOT:START -->

Source: `bench/results/latest.json` (`stable` profile).

#### Parse Throughput Comparison (MB/s)

| Fixture | ours-compact | ours-full | ours-stream | lol-html |
|---|---:|---:|---:|---:|
| `rust-lang.html` | 2212.22 | 1706.19 | 3168.48 | 1461.02 |
| `wiki-html.html` | 1770.10 | 1970.25 | 2315.70 | 1159.67 |
| `mdn-html.html` | 2766.75 | 2880.74 | 4091.48 | 1777.94 |
| `w3-html52.html` | 1227.39 | 1217.30 | 1629.14 | 681.77 |
| `hn.html` | 1640.61 | 1701.25 | 2009.05 | 787.47 |
| `python-org.html` | 1695.76 | 1660.15 | 2496.19 | 1271.38 |
| `kernel-org.html` | 1948.98 | 1877.37 | 2702.05 | 1319.49 |
| `gnu-org.html` | 2593.17 | 2533.62 | 3127.86 | 1481.41 |
| `ziglang-org.html` | 1952.66 | 1439.35 | 2752.98 | 1149.61 |
| `ziglang-doc-master.html` | 1222.60 | 1122.34 | 1258.83 | 843.02 |
| `wikipedia-unicode-list.html` | 1579.78 | 1528.79 | 2275.96 | 884.53 |
| `whatwg-html-spec.html` | 1117.63 | 1255.07 | 1842.29 | 837.04 |
| `synthetic-forms.html` | 1151.99 | 1159.03 | 2102.73 | 669.29 |
| `synthetic-table-grid.html` | 1079.07 | 1032.55 | 1915.48 | 670.78 |
| `synthetic-list-nested.html` | 1307.44 | 1312.53 | 1551.10 | 636.65 |
| `synthetic-comments-doctype.html` | 2145.28 | 2035.30 | 1564.60 | 878.36 |
| `synthetic-template-rich.html` | 900.08 | 845.66 | 951.21 | 425.72 |
| `synthetic-whitespace-noise.html` | 1459.49 | 1507.28 | 2414.99 | 973.07 |
| `synthetic-news-feed.html` | 1206.80 | 1184.56 | 1502.22 | 584.15 |
| `synthetic-ecommerce.html` | 1147.83 | 1137.38 | 1408.86 | 605.44 |
| `synthetic-forum-thread.html` | 1172.55 | 1111.87 | 1457.36 | 605.82 |

#### Query Match Throughput

| Case | compact ops/s | compact ns/op | full ops/s | full ns/op |
|---|---:|---:|---:|---:|
| `attr-heavy-button` | 41131.99 | 24311.98 | 40770.50 | 24527.54 |
| `attr-heavy-nav` | 27383.04 | 36518.95 | 27492.28 | 36373.84 |

#### Cached Query Throughput

| Case | compact ops/s | compact ns/op | full ops/s | full ns/op |
|---|---:|---:|---:|---:|
| `attr-heavy-button` | 41524.55 | 24082.14 | 44423.13 | 22510.80 |
| `attr-heavy-nav` | 25261.42 | 39586.06 | 27699.12 | 36102.23 |

#### Query Parse Throughput (ours)

| Selector case | Ops/s | ns/op |
|---|---:|---:|
| `simple` | 9041900.35 | 110.60 |
| `complex` | 4853071.38 | 206.06 |
| `grouped` | 6597440.38 | 151.57 |

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
- call `TextResult.free(doc, gpa)` for non-owned text results

### Runtime iterator invalidation

Runtime selector memory must outlive any iterator returned by `queryRuntime`.

### Input buffer changed

Expected: parse and lazy decode paths mutate source bytes in place.

If the bytes must not change, instantiate a non-destructive document type.
