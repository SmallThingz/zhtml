# 🚀 htmlparser

High-throughput, destructive HTML parser + CSS selector engine for Zig.

[![zig](https://img.shields.io/badge/zig-0.15.2-orange)](https://ziglang.org/)
[![license](https://img.shields.io/badge/license-MIT-blue)](./LICENSE)
[![mode](https://img.shields.io/badge/parse-mutable%20input%20%28destructive%29-critical)](./DOCUMENTATION.md#mode-guidance)

## ⚠️ Conformance Warning

Performance numbers are **not** conformance claims. The parser is intentionally permissive and currently does not fully match browser-grade tree-construction behavior.

- Conformance details: [Documentation#conformance-status](./DOCUMENTATION.md#conformance-status)
- Benchmark methodology: [Documentation#performance-and-benchmarks](./DOCUMENTATION.md#performance-and-benchmarks)
- Raw outputs: `bench/results/latest.md`, `bench/results/latest.json`

## 🏁 Performance

See the [latest benchmark snapshot](./DOCUMENTATION.md#latest-benchmark-snapshot) for more details

<!-- README_AUTO_SUMMARY:START -->

Source: `bench/results/latest.json` (`stable` profile).

### Parse Throughput (Average Across Fixtures)

```text
ours     │████████████████████│ 1551.75 MB/s (100.00%)
lol-html │█████████████░░░░░░░│ 1016.94 MB/s (65.54%)
lexbor   │███░░░░░░░░░░░░░░░░░│ 231.08 MB/s (14.89%)
```

### Conformance Snapshot

| Profile | nwmatcher | qwery_contextual | html5lib subset | WHATWG HTML parsing |
|---|---:|---:|---:|---:|
| `strictest/fastest` | 20/20 (0 failed) | 54/54 (0 failed) | 524/600 (76 failed) | 440/500 (60 failed) |

Source: `bench/results/external_suite_report.json`
<!-- README_AUTO_SUMMARY:END -->

## ⚡ Features

- 🔎 CSS selector queries: comptime, runtime, and cached runtime selectors.
- 🧭 DOM navigation: parent, siblings, first/last child, and children iteration.
- 💤 Lazy decode/normalize path: attribute/entity decode and text normalization happen on query-time APIs.
- 🧪 Debug tooling: selector mismatch diagnostics and instrumentation wrappers.
- 🧰 Parse profiles: `strictest` and `fastest` option bundles for benchmarks/workloads.
- 🧵 Mutable-input parser model optimized for throughput.

## 🚀 Quick Start

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

## 📚 Documentation

- Full manual: [Documentation](./DOCUMENTATION.md)
- API details: [Documentation#core-api](./DOCUMENTATION.md#core-api)
- Selector grammar: [Documentation#selector-support](./DOCUMENTATION.md#selector-support)
- Parse mode guidance: [Documentation#mode-guidance](./DOCUMENTATION.md#mode-guidance)
- Conformance: [Documentation#conformance-status](./DOCUMENTATION.md#conformance-status)
- Architecture: [Documentation#architecture](./DOCUMENTATION.md#architecture)
- Troubleshooting: [Documentation#troubleshooting](./DOCUMENTATION.md#troubleshooting)

## 🧪 Build and Validation

```bash
zig build test
zig build docs-check
zig build examples-check
zig build ship-check
```

## 📎 Examples

- `examples/basic_parse_query.zig`
- `examples/runtime_selector.zig`
- `examples/cached_selector.zig`
- `examples/query_time_decode.zig`
- `examples/inner_text_options.zig`

## 📜 License

MIT. See [LICENSE](./LICENSE).
