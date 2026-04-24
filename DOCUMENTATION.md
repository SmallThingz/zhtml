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

    const a = doc.queryOne("div#app > a.nav") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("/docs", a.getAttributeValue("href").?);
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
  - `doc.queryOne(comptime selector)`
  - `doc.queryAll(comptime selector)`
- Runtime selectors:
  - `try doc.queryOneRuntime(selector)`
  - `try doc.queryAllRuntime(selector)`
- Cached runtime selectors:
  - `doc.queryOneCached(selector)`
  - `doc.queryAllCached(selector)`
  - selector created via `try Selector.compileRuntime(allocator, source)`
- Diagnostics:
  - `doc.queryOneDebug(comptime selector)`
  - `doc.queryOneRuntimeDebug(selector)`
  - both return `{ node, report, err }`

### Node APIs

- Navigation:
  - `tagName()`
  - `parentNode()`
  - `firstChild()`
  - `lastChild()`
  - `nextSibling()`
  - `prevSibling()`
  - `children()` (iterator of wrapped child nodes; `collect(allocator)` returns an owned `[]Node`)
- Text:
  - `innerText(allocator)` (borrowed or allocated depending on shape)
  - `innerTextWithOptions(allocator, TextOptions)`
  - `innerTextOwned(allocator)` (always allocated)
  - `innerTextOwnedWithOptions(allocator, TextOptions)`
- Attributes:
  - `getAttributeValue(name)`
- Scoped queries:
  - same query family as `Document` (`queryOne/queryAll`, runtime, cached, debug)

### Helpers

- `doc.html()`, `doc.head()`, `doc.body()`
- `doc.isOwned(slice)` to check whether a slice points into document source bytes

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

- `queryOneRuntimeWithHooks(doc, selector, hooks)`
- `queryOneCachedWithHooks(doc, selector, hooks)`
- `queryAllRuntimeWithHooks(doc, selector, hooks)`
- `queryAllCachedWithHooks(doc, selector, hooks)`

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
| `strictest` | `const opts = html.ParseOptions{ .drop_whitespace_text_nodes = false };` | traversal predictability and text fidelity | keeps whitespace-only text nodes |
| `fastest` | `const opts = html.ParseOptions{};` | throughput-first scraping | whitespace-only text nodes dropped |
| `non-destructive` | `const opts = html.ParseOptions{ .non_destructive = true };` | preserving input bytes, memory maps, exact whole-document formatting | decoded attrs/text are materialized outside the source buffer |

Fallback playbook:

1. Start with `fastest` for bulk workloads.
2. Move unstable domains to `strictest`.
3. Use `queryOneRuntimeDebug` and `QueryDebugReport` before changing selectors.

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

| Fixture | ours | lol-html | lexbor |
|---|---:|---:|---:|
| `rust-lang.html` | 2199.56 | 1442.47 | 318.93 |
| `wiki-html.html` | 1816.81 | 1278.46 | 263.09 |
| `mdn-html.html` | 2940.25 | 1921.43 | 402.79 |
| `w3-html52.html` | 990.34 | 737.14 | 192.09 |
| `hn.html` | 1562.25 | 914.17 | 220.11 |
| `python-org.html` | 1877.55 | 1395.20 | 269.40 |
| `kernel-org.html` | 1856.86 | 1329.13 | 287.68 |
| `gnu-org.html` | 2330.05 | 1544.83 | 309.74 |
| `ziglang-org.html` | 1876.32 | 1306.26 | 281.88 |
| `ziglang-doc-master.html` | 1406.16 | 1073.01 | 220.40 |
| `wikipedia-unicode-list.html` | 1686.31 | 1109.37 | 222.44 |
| `whatwg-html-spec.html` | 1329.69 | 967.17 | 223.20 |
| `synthetic-forms.html` | 1429.45 | 789.68 | 191.89 |
| `synthetic-table-grid.html` | 1182.31 | 768.89 | 178.50 |
| `synthetic-list-nested.html` | 1251.09 | 699.51 | 166.26 |
| `synthetic-comments-doctype.html` | 1984.29 | 967.36 | 212.42 |
| `synthetic-template-rich.html` | 904.66 | 477.37 | 142.18 |
| `synthetic-whitespace-noise.html` | 1398.46 | 1085.80 | 186.70 |
| `synthetic-news-feed.html` | 1191.30 | 646.31 | 155.61 |
| `synthetic-ecommerce.html` | 1041.96 | 664.92 | 161.78 |
| `synthetic-forum-thread.html` | 1078.45 | 647.24 | 160.30 |

#### Query Match Throughput (ours)

| Case | ours ops/s | ours ns/op |
|---|---:|---:|
| `attr-heavy-button` | 205155.55 | 4874.35 |
| `attr-heavy-nav` | 123426.81 | 8101.97 |

#### Cached Query Throughput (ours)

| Case | ours ops/s | ours ns/op |
|---|---:|---:|
| `attr-heavy-button` | 185576.06 | 5388.63 |
| `attr-heavy-nav` | 127393.57 | 7849.69 |

#### Query Parse Throughput (ours)

| Selector case | Ops/s | ns/op |
|---|---:|---:|
| `simple` | 10585837.17 | 94.47 |
| `complex` | 5661797.29 | 176.62 |
| `grouped` | 7520735.14 | 132.97 |

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

- validate selector syntax (`queryOneRuntime` can return `error.InvalidSelector`)
- check scope (`Document` vs scoped `Node`)
- use `queryOneRuntimeDebug` and inspect `QueryDebugReport`

### Unexpected `innerText`

- default `innerText` normalizes whitespace
- use `innerTextWithOptions(..., .{ .normalize_whitespace = false })` for raw spacing
- use `innerTextOwned(...)` when output must always be allocated
- use `doc.isOwned(slice)` to check borrowed vs allocated

### Runtime iterator invalidation

`queryAllRuntime` iterators are invalidated by newer `queryAllRuntime` calls on the same `Document`.

### Input buffer changed

Expected: parse and lazy decode paths mutate source bytes in place.

If the bytes must not change, instantiate a non-destructive document type.
