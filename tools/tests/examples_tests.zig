const examples = @import("examples");

test "example parity: basic parse and query" {
    try examples.basic_parse_query.run();
}

test "example parity: runtime selectors" {
    try examples.runtime_selector.run();
}

test "example parity: cached selector" {
    try examples.cached_selector.run();
}

test "example parity: navigation and children" {
    try examples.navigation_and_children.run();
}

test "example parity: innerText options" {
    try examples.inner_text_options.run();
}

test "example parity: strictest and fastest selectors agree" {
    try examples.strict_vs_fastest_parse.run();
}

test "example parity: debug query report" {
    try examples.debug_query_report.run();
}

test "example parity: instrumentation hooks" {
    try examples.instrumentation_hooks.run();
}

test "example parity: query-time decode" {
    try examples.query_time_decode.run();
}
