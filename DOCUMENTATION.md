# htmlparser Documentation

This is the canonical manual for usage, API, selector behavior, performance workflow, conformance expectations, and internals.

## Table of Contents

- [Requirements](#requirements)
- [Quick Start](#quick-start)
- [Core API](#core-api)
- [Selector Support](#selector-support)
- [Mode Guidance](#mode-guidance)
- [Performance and Benchmarks](#performance-and-benchmarks)
- [Latest Benchmark Snapshot](#latest-benchmark-snapshot)
- [Conformance Status](#conformance-status)
- [Architecture](#architecture)
- [Troubleshooting](#troubleshooting)

## Requirements

- Zig `0.15.2`
- Mutable input buffers (`[]u8`) for parsing

## Quick Start

```zig
const std = @import("std");
const html = @import("htmlparser");
const options: html.ParseOptions = .{};
const Document = options.GetDocument();

test "basic parse + query" {
    var doc = Document.init(std.testing.allocator);
    defer doc.deinit();

    var input = "<div id='app'><a class='nav' href='/docs'>Docs</a></div>".*;
    try doc.parse(&input, .{});

    const a = doc.queryOne("div#app > a.nav") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("/docs", a.getAttributeValue("href").?);
}
```

Source examples:

- `examples/basic_parse_query.zig`
- `examples/query_time_decode.zig`

All examples are verified by running `zig build examples-check`

## Core API

### `Document` factory and lifecycle

- `const opts: ParseOptions = .{};`
- `const Document = opts.GetDocument();`
- `Document.init(allocator)`
- `doc.deinit()`
- `doc.clear()`
- `doc.parse(input: []u8, comptime opts: ParseOptions)`

### Query APIs

- Compile-time selectors:
  - `doc.queryOne(comptime selector)`
  - `doc.queryAll(comptime selector)`
- Runtime selectors:
  - `try doc.queryOneRuntime(selector)`
  - `try doc.queryAllRuntime(selector)`
- Cached runtime selectors:
  - `doc.queryOneCached(&selector)`
  - `doc.queryAllCached(&selector)`
  - selector created via `try Selector.compileRuntime(allocator, source)`
- Diagnostics:
  - `doc.queryOneDebug(comptime selector, report)`
  - `try doc.queryOneRuntimeDebug(selector, report)`

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
  - `eager_child_views: bool = true`
  - `drop_whitespace_text_nodes: bool = false`
- `TextOptions`
  - `normalize_whitespace: bool = true`
- parse/query work split:
  - parse keeps raw text and attribute spans in-place
  - entity decode and whitespace normalization are applied by query-time APIs (`getAttributeValue`, `innerText*`, selector attribute predicates)

### Instrumentation wrappers

- `parseWithHooks(doc, input, opts, hooks)`
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

`htmlparser` is permissive by design. Choose parse options by workload:

| Mode | Parse Options | Best For | Tradeoffs |
|---|---|---|---|
| `strictest` | `.eager_child_views = true`, `.drop_whitespace_text_nodes = false` | traversal predictability and text fidelity | higher parse-time work |
| `fastest` | `.eager_child_views = false`, `.drop_whitespace_text_nodes = true` | throughput-first scraping | whitespace-only text nodes dropped; child views built lazily |

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
- query parse/match/cached sections benchmark `htmlparser`
- repeated runtime selector workloads should use cached selectors

## Latest Benchmark Snapshot

Warning: throughput numbers are not conformance claims. This parser is permissive by design; see [Conformance Status](#conformance-status).

<!-- BENCHMARK_SNAPSHOT:START -->

Source: `bench/results/latest.json` (`stable` profile).

#### Parse Throughput Comparison (MB/s)

| Fixture | ours | lol-html | lexbor |
|---|---:|---:|---:|
| `rust-lang.html` | 1991.02 | 1571.45 | 339.17 |
| `wiki-html.html` | 1900.07 | 1224.55 | 267.91 |
| `mdn-html.html` | 3046.63 | 1842.19 | 407.11 |
| `w3-html52.html` | 1151.17 | 778.92 | 192.67 |
| `hn.html` | 1525.85 | 914.52 | 224.60 |
| `python-org.html` | 1951.28 | 1382.11 | 285.46 |
| `kernel-org.html` | 1873.48 | 1356.31 | 293.30 |
| `gnu-org.html` | 2303.94 | 1492.83 | 318.03 |
| `ziglang-org.html` | 1844.83 | 1249.50 | 289.41 |
| `ziglang-doc-master.html` | 1406.30 | 1058.17 | 228.39 |
| `wikipedia-unicode-list.html` | 1627.40 | 1095.23 | 229.35 |
| `whatwg-html-spec.html` | 1309.36 | 900.04 | 221.98 |
| `synthetic-forms.html` | 977.12 | 745.48 | 187.89 |
| `synthetic-table-grid.html` | 1002.77 | 713.24 | 169.54 |
| `synthetic-list-nested.html` | 1102.63 | 641.58 | 162.07 |
| `synthetic-comments-doctype.html` | 1778.75 | 932.01 | 221.18 |
| `synthetic-template-rich.html` | 888.10 | 474.13 | 143.93 |
| `synthetic-whitespace-noise.html` | 1449.97 | 1057.95 | 187.79 |
| `synthetic-news-feed.html` | 1181.44 | 643.54 | 157.65 |
| `synthetic-ecommerce.html` | 1131.80 | 635.65 | 163.42 |
| `synthetic-forum-thread.html` | 1142.74 | 646.30 | 161.91 |

#### Query Match Throughput (ours)

| Case | ours ops/s | ours ns/op |
|---|---:|---:|
| `attr-heavy-button` | 161984.99 | 6173.41 |
| `attr-heavy-nav` | 98666.66 | 10135.14 |

#### Cached Query Throughput (ours)

| Case | ours ops/s | ours ns/op |
|---|---:|---:|
| `attr-heavy-button` | 200039.23 | 4999.02 |
| `attr-heavy-nav` | 102493.12 | 9756.75 |

#### Query Parse Throughput (ours)

| Selector case | Ops/s | ns/op |
|---|---:|---:|
| `simple` | 10387913.79 | 96.27 |
| `complex` | 4917147.42 | 203.37 |
| `grouped` | 6262905.79 | 159.67 |

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
- `src/html/attr_inline.zig`: in-place attribute traversal/lazy materialization
- `src/html/entities.zig`: entity decode utilities
- `src/selector/runtime.zig`, `src/selector/compile_time.zig`: selector parsing
- `src/selector/matcher.zig`: selector matching/combinator traversal

Data model highlights:

- `Document` owns source bytes and node/index storage
- nodes are contiguous and linked by indexes for traversal
- attributes are traversed directly from source spans (no heap attribute objects)

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
