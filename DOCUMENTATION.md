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
  - `children()` (borrowed `[]const u32` index view)
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
| `rust-lang.html` | 1735.16 | 1571.67 | 338.63 |
| `wiki-html.html` | 1547.65 | 1154.10 | 259.52 |
| `mdn-html.html` | 2550.22 | 1812.55 | 396.56 |
| `w3-html52.html` | 991.37 | 718.93 | 188.66 |
| `hn.html` | 1224.96 | 842.38 | 209.48 |
| `python-org.html` | 1551.04 | 1281.43 | 274.39 |
| `kernel-org.html` | 1454.64 | 1191.55 | 275.70 |
| `gnu-org.html` | 1811.79 | 1402.23 | 301.16 |
| `ziglang-org.html` | 1488.76 | 1137.48 | 259.43 |
| `ziglang-doc-master.html` | 1129.30 | 1019.64 | 219.81 |
| `wikipedia-unicode-list.html` | 1275.31 | 989.51 | 223.42 |
| `whatwg-html-spec.html` | 1076.04 | 830.38 | 202.65 |
| `synthetic-forms.html` | 1036.07 | 743.74 | 177.12 |
| `synthetic-table-grid.html` | 871.98 | 663.71 | 162.47 |
| `synthetic-list-nested.html` | 849.31 | 598.06 | 153.20 |
| `synthetic-comments-doctype.html` | 1265.45 | 892.28 | 217.25 |
| `synthetic-template-rich.html` | 675.82 | 443.61 | 136.93 |
| `synthetic-whitespace-noise.html` | 1039.40 | 911.56 | 156.86 |
| `synthetic-news-feed.html` | 871.58 | 559.43 | 134.88 |
| `synthetic-ecommerce.html` | 720.76 | 557.12 | 140.80 |
| `synthetic-forum-thread.html` | 794.03 | 571.42 | 141.97 |

#### Query Match Throughput (ours)

| Case | ours ops/s | ours ns/op |
|---|---:|---:|
| `attr-heavy-button` | 1127992.73 | 886.53 |
| `attr-heavy-nav` | 1081872.50 | 924.32 |

#### Cached Query Throughput (ours)

| Case | ours ops/s | ours ns/op |
|---|---:|---:|
| `attr-heavy-button` | 1322342.66 | 756.23 |
| `attr-heavy-nav` | 1391254.29 | 718.78 |

#### Query Parse Throughput (ours)

| Selector case | Ops/s | ns/op |
|---|---:|---:|
| `simple` | 8129760.74 | 123.00 |
| `complex` | 4082989.79 | 244.92 |
| `grouped` | 4897240.23 | 204.20 |

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
